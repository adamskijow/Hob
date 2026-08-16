// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
#if canImport(HobAppCore)
import HobAppCore
#endif
#if canImport(HobAppStorage)
import HobAppStorage
#endif
#if canImport(HobAppleIntelligence)
import HobAppleIntelligence
#endif
#if canImport(HobCalendar)
import HobCalendar
#endif
#if canImport(HobNotifications)
import HobNotifications
#endif

@MainActor
public final class HobWorkspaceController: ObservableObject {
    @Published public var draft = ""
    @Published public private(set) var tasks: [RuntimeTask] = []
    @Published public private(set) var proposal: RuntimeScheduleProposal?
    @Published public private(set) var adoptedSchedule: RuntimeAdoptedSchedule?
    @Published public private(set) var isWorking = false
    @Published public private(set) var notice: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var calendarAuthorization: RuntimeCalendarAuthorization
    @Published public private(set) var calendarCleanupPending = false
    @Published public private(set) var notificationAuthorization: RuntimeNotificationAuthorization
    @Published public private(set) var notificationCleanupPending = false
    @Published public private(set) var notificationActionsPending = false

    private let runtime: DurableTaskRuntime?
    private let interpreter: any RuntimeMessageInterpreting
    private let calendarStore: any RuntimeCalendarScheduling
    private let notificationStore: any RuntimeNotificationScheduling
    private let gregorianCalendar: Calendar
    private let timezone: TimeZone
    private let now: @Sendable () -> Date

    public convenience init() {
        do {
            let directory = try SharedStorage.system.taskStateDirectory()
            self.init(
                store: TaskStateStore(directoryURL: directory),
                interpreter: AppleFoundationInterpreter(),
                calendarStore: EventKitScheduleStore(),
                notificationStore: LocalNotificationScheduler()
            )
        } catch {
            self.init(
                runtime: nil,
                interpreter: AppleFoundationInterpreter(),
                calendarStore: EventKitScheduleStore(),
                notificationStore: LocalNotificationScheduler(),
                timezone: .current,
                now: Date.init
            )
            errorMessage = "Hob could not open its private task storage."
        }
    }

    public convenience init(
        store: TaskStateStore,
        interpreter: any RuntimeMessageInterpreting,
        calendarStore: any RuntimeCalendarScheduling = EventKitScheduleStore(),
        notificationStore: any RuntimeNotificationScheduling,
        timezone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let durable = try? DurableTaskRuntime(store: store)
        self.init(
            runtime: durable,
            interpreter: interpreter,
            calendarStore: calendarStore,
            notificationStore: notificationStore,
            timezone: timezone,
            now: now
        )
        if durable == nil {
            errorMessage = "Hob could not safely read its task storage."
        }
    }

    private init(
        runtime: DurableTaskRuntime?,
        interpreter: any RuntimeMessageInterpreting,
        calendarStore: any RuntimeCalendarScheduling,
        notificationStore: any RuntimeNotificationScheduling,
        timezone: TimeZone,
        now: @escaping @Sendable () -> Date
    ) {
        self.runtime = runtime
        self.interpreter = interpreter
        self.calendarStore = calendarStore
        self.calendarAuthorization = calendarStore.authorization
        self.notificationStore = notificationStore
        self.notificationAuthorization = notificationStore.authorization
        self.timezone = timezone
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        self.gregorianCalendar = calendar
        notificationStore.setActionHandler { [weak self] response in
            await self?.receiveNotificationResponse(response)
        }
        Task {
            notificationAuthorization = await notificationStore.refreshAuthorization()
            await refresh()
            if calendarCleanupPending || notificationCleanupPending
                || notificationActionsPending {
                resumePendingWork()
            }
        }
    }

    public var canSubmit: Bool {
        !isWorking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && runtime != nil
    }

    public var scheduleDiff: RuntimeScheduleDiff? {
        guard let current = adoptedSchedule?.proposal,
              let proposal,
              current.id != proposal.id else { return nil }
        return RuntimeScheduleDiff(current: current, proposed: proposal)
    }

    public func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !text.isEmpty else { return }
        draft = ""
        run {
            guard let runtime = self.runtime else { return }
            let instant = self.now()
            let timestamp = self.timestamp(instant)
            let current = await runtime.snapshot().tasks
            let actions = try await self.interpreter.interpret(
                message: text,
                now: timestamp,
                timezone: self.timezone.identifier,
                tasks: current
            )
            let requestID = UUID().uuidString
            let response = try await runtime.process(RuntimeTurnRequest(
                requestID: requestID,
                message: text,
                now: timestamp,
                timezone: self.timezone.identifier,
                actions: actions
            ))
            try? await runtime.markDelivered(
                dedupeKey: "turn:\(requestID)",
                at: timestamp
            )
            switch response.outcome.disposition {
            case .applied:
                try await self.cleanupCalendarEventsIfNeeded()
                try await self.cleanupNotificationsIfNeeded()
                _ = try await runtime.proposeSchedule(
                    try self.scheduleRequest(at: instant)
                )
                if response.outcome.appliedKinds == ["replan"] {
                    self.notice = "Built a new plan from what changed."
                } else if response.outcome.appliedKinds.allSatisfy({ $0 == "capture" }) {
                    self.notice = actions.count == 1
                        ? "Captured and planned one task."
                        : "Captured and planned \(actions.count) tasks."
                } else {
                    self.notice = "Updated the tasks and built a new plan."
                }
            case .clarificationRequired:
                self.notice = "I need a clearer date or task before changing anything."
            case .confirmationRequired:
                self.notice = "Review the task before I apply it."
            case .rejected, .noChange:
                self.notice = "Nothing changed. Try describing the task another way."
            }
            await self.refresh()
        }
    }

    public func adoptProposal() {
        guard let proposal else { return }
        run {
            guard let runtime = self.runtime else { return }
            try await self.cleanupCalendarEventsIfNeeded()
            guard self.calendarStore.authorization == .fullAccess else {
                throw RuntimeCalendarError.permissionDenied
            }
            let eventIDs = try self.calendarStore.write(proposal)
            var notificationIDs: [String] = []
            do {
                if self.notificationStore.authorization == .authorized {
                    notificationIDs = try await self.notificationStore.schedule(
                        proposal: proposal,
                        now: self.now()
                    )
                }
                _ = try await runtime.adoptSchedule(
                    proposalID: proposal.id,
                    at: self.timestamp(self.now()),
                    calendarEventIDs: eventIDs,
                    notificationIDs: notificationIDs
                )
            } catch {
                self.notificationStore.cancel(notificationIDs: notificationIDs)
                try? self.calendarStore.remove(eventIDs: eventIDs)
                throw error
            }
            await self.refresh()
            try await self.cleanupCalendarEventsIfNeeded()
            try await self.cleanupNotificationsIfNeeded()
            self.notice = notificationIDs.isEmpty
                ? "Calendar schedule updated. Notifications are off."
                : "Calendar schedule updated with start reminders."
            await self.refresh()
        }
    }

    public func keepAdoptedSchedule() {
        guard let proposal else { return }
        run {
            guard let runtime = self.runtime else { return }
            try await runtime.discardScheduleProposal(proposalID: proposal.id)
            self.notice = "Kept the current Calendar schedule."
            await self.refresh()
        }
    }

    public func cancelAdoptedSchedule() {
        run {
            guard let runtime = self.runtime else { return }
            if let notificationIDs = self.adoptedSchedule?.notificationIDs {
                self.notificationStore.cancel(notificationIDs: notificationIDs)
            }
            if let eventIDs = self.adoptedSchedule?.calendarEventIDs,
               !eventIDs.isEmpty {
                try self.calendarStore.remove(eventIDs: eventIDs)
            }
            try await runtime.cancelAdoptedSchedule()
            self.notice = "Calendar blocks removed. Tasks remain open."
            await self.refresh()
        }
    }

    public func requestNotificationAccess() {
        run {
            self.notificationAuthorization = try await self.notificationStore.requestAccess()
            guard self.notificationAuthorization == .authorized else {
                self.errorMessage = "Notifications are off. Enable them in Settings."
                return
            }
            if let adopted = self.adoptedSchedule,
               adopted.notificationIDs.isEmpty,
               let runtime = self.runtime {
                let identifiers = try await self.notificationStore.schedule(
                    proposal: adopted.proposal,
                    now: self.now()
                )
                do {
                    try await runtime.attachNotificationIDs(
                        proposalID: adopted.proposal.id,
                        notificationIDs: identifiers
                    )
                } catch {
                    self.notificationStore.cancel(notificationIDs: identifiers)
                    throw error
                }
            }
            self.notice = "Start reminders enabled."
            await self.refresh()
        }
    }

    public func requestCalendarAccess() {
        run {
            self.calendarAuthorization = try await self.calendarStore.requestAccess()
            if self.calendarAuthorization == .fullAccess {
                try await self.cleanupCalendarEventsIfNeeded()
                self.notice = "Calendar connected. New plans will avoid busy time."
                if self.tasks.contains(where: { $0.status == "open" }),
                   let runtime = self.runtime {
                    _ = try await runtime.proposeSchedule(
                        try self.scheduleRequest(at: self.now())
                    )
                }
            } else {
                self.errorMessage = "Calendar access is off. Enable full access in Settings."
            }
            await self.refresh()
        }
    }

    public func retryCalendarCleanup() {
        run {
            try await self.cleanupCalendarEventsIfNeeded()
            self.notice = "Old Calendar blocks removed."
            await self.refresh()
        }
    }

    public func retryNotificationCleanup() {
        run {
            try await self.cleanupNotificationsIfNeeded()
            self.notice = "Old reminders removed."
            await self.refresh()
        }
    }

    public func undoLastChange() {
        run {
            guard let runtime = self.runtime else { return }
            let instant = self.now()
            let timestamp = self.timestamp(instant)
            let requestID = UUID().uuidString
            let response = try await runtime.process(RuntimeTurnRequest(
                requestID: requestID,
                message: "undo",
                now: timestamp,
                timezone: self.timezone.identifier,
                actions: [RuntimeAction(type: "undo")]
            ))
            try? await runtime.markDelivered(
                dedupeKey: "turn:\(requestID)",
                at: timestamp
            )
            if response.outcome.disposition == .applied,
               response.outcome.tasks.contains(where: { $0.status == "open" }) {
                try await self.cleanupCalendarEventsIfNeeded()
                try await self.cleanupNotificationsIfNeeded()
                _ = try await runtime.proposeSchedule(
                    try self.scheduleRequest(at: instant)
                )
            }
            self.notice = response.outcome.disposition == .applied
                ? "Last task change undone."
                : "There is no task change to undo."
            await self.refresh()
        }
    }

    public func refresh() async {
        guard let runtime else { return }
        let snapshot = await runtime.snapshot()
        tasks = snapshot.tasks
        proposal = snapshot.latestProposal
        adoptedSchedule = snapshot.adoptedSchedule
        calendarCleanupPending = !snapshot.calendarCleanupEventIDs.isEmpty
        notificationCleanupPending = !snapshot.notificationCleanupIDs.isEmpty
        notificationActionsPending = !snapshot.pendingNotificationResponses.isEmpty
        calendarAuthorization = calendarStore.authorization
        notificationAuthorization = notificationStore.authorization
    }

    private func run(
        processPendingResponsesAfterward: Bool = true,
        _ operation: @escaping () async throws -> Void
    ) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer {
                isWorking = false
                if processPendingResponsesAfterward,
                   notificationActionsPending {
                    processNotificationResponses()
                }
            }
            do {
                try await operation()
            } catch RuntimeInterpretationError.modelUnavailable {
                errorMessage = "Apple Intelligence is unavailable. Check that it is enabled and ready."
            } catch RuntimeInterpretationError.invalidOutput {
                errorMessage = "I could not safely interpret that message. Nothing changed."
            } catch RuntimeScheduleError.staleProposal {
                errorMessage = "The tasks changed after this plan was made. Build a fresh plan first."
            } catch RuntimeScheduleError.calendarCleanupPending {
                errorMessage = "Remove the old Calendar blocks and reminders before adopting a new plan."
            } catch RuntimeCalendarError.permissionDenied {
                errorMessage = "Connect Calendar before adopting this schedule."
            } catch RuntimeCalendarError.writeFailed {
                errorMessage = "Calendar could not save the full schedule. No partial schedule was kept."
            } catch RuntimeCalendarError.removalFailed {
                errorMessage = "Calendar could not remove every Hob block. Try again before replanning."
            } catch RuntimeCalendarError.unavailable {
                errorMessage = "Calendar has no writable default calendar."
            } catch RuntimeCalendarError.invalidSchedule {
                errorMessage = "The proposed times are invalid. Build a fresh plan."
            } catch RuntimeNotificationError.permissionDenied {
                errorMessage = "Enable notifications before scheduling reminders."
            } catch RuntimeNotificationError.schedulingFailed {
                errorMessage = "Hob could not schedule every reminder. No partial reminder set was kept."
            } catch RuntimeNotificationError.invalidRequest {
                errorMessage = "That reminder is no longer valid."
            } catch {
                errorMessage = "Hob could not finish that safely. Review the task list before retrying."
            }
        }
    }

    private func scheduleRequest(at instant: Date) throws -> RuntimeScheduleRequest {
        let end = gregorianCalendar.date(
            byAdding: .day,
            value: 7,
            to: instant
        ) ?? instant.addingTimeInterval(7 * 86_400)
        let busy = calendarStore.authorization == .fullAccess
            ? try calendarStore.busyIntervals(
                from: instant,
                to: end,
                timezone: timezone
            )
            : []
        return RuntimeScheduleRequest(
            proposalID: UUID().uuidString,
            generatedAt: timestamp(instant),
            startDate: day(instant),
            timezone: timezone.identifier,
            busy: busy
        )
    }

    private func cleanupCalendarEventsIfNeeded() async throws {
        guard let runtime else { return }
        let eventIDs = await runtime.snapshot().calendarCleanupEventIDs
        guard !eventIDs.isEmpty else { return }
        try calendarStore.remove(eventIDs: eventIDs)
        try await runtime.acknowledgeCalendarCleanup(eventIDs: eventIDs)
        calendarCleanupPending = false
    }

    private func cleanupNotificationsIfNeeded() async throws {
        guard let runtime else { return }
        let identifiers = await runtime.snapshot().notificationCleanupIDs
        guard !identifiers.isEmpty else { return }
        notificationStore.cancel(notificationIDs: identifiers)
        try await runtime.acknowledgeNotificationCleanup(
            notificationIDs: identifiers
        )
        notificationCleanupPending = false
    }

    private func receiveNotificationResponse(
        _ response: RuntimeNotificationResponse
    ) async {
        guard let runtime else { return }
        do {
            try await runtime.enqueueNotificationResponse(response)
            await refresh()
            if !isWorking { processNotificationResponses() }
        } catch {
            errorMessage = "Hob saved no notification action. Open Hob and try again."
        }
    }

    public func processNotificationResponses() {
        run(processPendingResponsesAfterward: false) {
            guard let runtime = self.runtime else { return }
            try await self.drainNotificationResponses(runtime: runtime)
            await self.refresh()
        }
    }

    private func resumePendingWork() {
        run(processPendingResponsesAfterward: false) {
            guard let runtime = self.runtime else { return }
            if self.calendarStore.authorization == .fullAccess {
                try await self.cleanupCalendarEventsIfNeeded()
            }
            try await self.cleanupNotificationsIfNeeded()
            try await self.drainNotificationResponses(runtime: runtime)
            await self.refresh()
        }
    }

    private func drainNotificationResponses(
        runtime: DurableTaskRuntime
    ) async throws {
        let responses = await runtime.snapshot().pendingNotificationResponses
        for response in responses {
            try await processNotificationResponse(response, runtime: runtime)
            try await runtime.acknowledgeNotificationResponse(
                responseID: response.id
            )
        }
        notificationActionsPending = false
    }

    private func processNotificationResponse(
        _ response: RuntimeNotificationResponse,
        runtime: DurableTaskRuntime
    ) async throws {
        let snapshot = await runtime.snapshot()
        let taskIsOpen = snapshot.tasks.contains {
            $0.id == response.taskID && $0.status == "open"
        }
        switch response.action {
        case .done:
            guard taskIsOpen else {
                notice = "That task was already closed."
                return
            }
            let requestID = "notification:\(response.id)"
            let instant = now()
            let result = try await runtime.process(RuntimeTurnRequest(
                requestID: requestID,
                message: "Done from schedule reminder",
                now: timestamp(instant),
                timezone: timezone.identifier,
                actions: [RuntimeAction(
                    type: "complete",
                    target: response.taskID
                )]
            ))
            try? await runtime.markDelivered(
                dedupeKey: "turn:\(requestID)",
                at: timestamp(instant)
            )
            guard result.outcome.disposition == .applied else {
                throw RuntimeNotificationError.invalidRequest
            }
            try await cleanupCalendarEventsIfNeeded()
            try await cleanupNotificationsIfNeeded()
            if result.outcome.tasks.contains(where: { $0.status == "open" }) {
                _ = try await runtime.proposeSchedule(
                    try scheduleRequest(at: instant)
                )
            }
            notice = "Done: \(response.task). Review the updated plan."
        case .snooze:
            guard taskIsOpen,
                  snapshot.adoptedSchedule?.proposal.id == response.proposalID
            else {
                notice = "That schedule is no longer active."
                return
            }
            try await notificationStore.snooze(
                response: response,
                minutes: 15
            )
            notice = "Snoozed \(response.task) for 15 minutes."
        case .replan:
            guard taskIsOpen else {
                notice = "That task was already closed."
                return
            }
            draft = "I need to replan \(response.task) because "
            notice = "What changed? Finish the sentence and Hob will rebuild the plan."
        }
    }

    private func timestamp(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = gregorianCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.string(from: value)
    }

    private func day(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = gregorianCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }
}
