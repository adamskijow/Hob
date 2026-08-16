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

    private let runtime: DurableTaskRuntime?
    private let interpreter: any RuntimeMessageInterpreting
    private let calendarStore: any RuntimeCalendarScheduling
    private let gregorianCalendar: Calendar
    private let timezone: TimeZone
    private let now: @Sendable () -> Date

    public convenience init() {
        do {
            let directory = try SharedStorage.system.taskStateDirectory()
            self.init(
                store: TaskStateStore(directoryURL: directory),
                interpreter: AppleFoundationInterpreter(),
                calendarStore: EventKitScheduleStore()
            )
        } catch {
            self.init(
                runtime: nil,
                interpreter: AppleFoundationInterpreter(),
                calendarStore: EventKitScheduleStore(),
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
        timezone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let durable = try? DurableTaskRuntime(store: store)
        self.init(
            runtime: durable,
            interpreter: interpreter,
            calendarStore: calendarStore,
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
        timezone: TimeZone,
        now: @escaping @Sendable () -> Date
    ) {
        self.runtime = runtime
        self.interpreter = interpreter
        self.calendarStore = calendarStore
        self.calendarAuthorization = calendarStore.authorization
        self.timezone = timezone
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        self.gregorianCalendar = calendar
        Task {
            await refresh()
            if calendarAuthorization == .fullAccess, calendarCleanupPending {
                retryCalendarCleanup()
            }
        }
    }

    public var canSubmit: Bool {
        !isWorking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && runtime != nil
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
                _ = try await runtime.proposeSchedule(
                    try self.scheduleRequest(at: instant)
                )
                self.notice = actions.count == 1
                    ? "Captured and planned one task."
                    : "Captured and planned \(actions.count) tasks."
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
            do {
                _ = try await runtime.adoptSchedule(
                    proposalID: proposal.id,
                    at: self.timestamp(self.now()),
                    calendarEventIDs: eventIDs
                )
            } catch {
                try? self.calendarStore.remove(eventIDs: eventIDs)
                throw error
            }
            self.notice = "Schedule added to Calendar."
            await self.refresh()
        }
    }

    public func cancelAdoptedSchedule() {
        run {
            guard let runtime = self.runtime else { return }
            if let eventIDs = self.adoptedSchedule?.calendarEventIDs,
               !eventIDs.isEmpty {
                try self.calendarStore.remove(eventIDs: eventIDs)
            }
            try await runtime.cancelAdoptedSchedule()
            self.notice = "Calendar blocks removed. Tasks remain open."
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
        calendarAuthorization = calendarStore.authorization
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await operation()
            } catch RuntimeInterpretationError.modelUnavailable {
                errorMessage = "Apple Intelligence is unavailable. Check that it is enabled and ready."
            } catch RuntimeInterpretationError.invalidOutput {
                errorMessage = "I could not safely interpret that message. Nothing changed."
            } catch RuntimeScheduleError.staleProposal {
                errorMessage = "The tasks changed after this plan was made. Build a fresh plan first."
            } catch RuntimeScheduleError.calendarCleanupPending {
                errorMessage = "Remove the old Calendar blocks before adopting a new plan."
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
