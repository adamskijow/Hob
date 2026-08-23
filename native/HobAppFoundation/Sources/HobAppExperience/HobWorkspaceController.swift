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
#if canImport(HobCloudSync)
import HobCloudSync
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
    @Published public private(set) var morningDigest: RuntimeMorningDigest?
    @Published public private(set) var morningDigestEnabled: Bool
    @Published public private(set) var morningDigestTime: String
    @Published public private(set) var morningDigestNeedsAttention = false
    @Published public private(set) var syncAvailability: RuntimeTaskSyncAvailability
    @Published public private(set) var syncNeedsAttention = false
    @Published public private(set) var planningPreferences: RuntimePlanningPreferences = .default
    @Published public private(set) var importReport: OpenLocalImportResult?
    @Published public private(set) var modelReadiness: ModelReadinessState

    private let runtime: DurableTaskRuntime?
    private let interpreter: any RuntimeMessageInterpreting
    private let calendarStore: any RuntimeCalendarScheduling
    private let notificationStore: any RuntimeNotificationScheduling
    private let syncStore: any RuntimeTaskSyncing
    private let gregorianCalendar: Calendar
    private let timezone: TimeZone
    private let now: @Sendable () -> Date
    private let modelProbe: (@Sendable () async throws -> Void)?
    private let defaults: UserDefaults

    private enum DefaultsKey {
        static let morningDigestEnabled = "hob.morning.digest.enabled"
        static let morningDigestTime = "hob.morning.digest.time"
    }

    public convenience init() {
        let appleInterpreter = AppleFoundationInterpreter()
        do {
            let directory = try SharedStorage.system.taskStateDirectory()
            self.init(
                store: TaskStateStore(directoryURL: directory),
                interpreter: appleInterpreter,
                calendarStore: EventKitScheduleStore(),
                notificationStore: LocalNotificationScheduler(),
                syncStore: ICloudTaskSyncStore(),
                defaults: .standard,
                modelReadiness: appleInterpreter.isAvailable ? .notChecked : .unavailable,
                modelProbe: { try await appleInterpreter.probe() }
            )
        } catch {
            self.init(
                runtime: nil,
                interpreter: appleInterpreter,
                calendarStore: EventKitScheduleStore(),
                notificationStore: LocalNotificationScheduler(),
                syncStore: ICloudTaskSyncStore(),
                defaults: .standard,
                timezone: .current,
                now: Date.init,
                modelReadiness: appleInterpreter.isAvailable ? .notChecked : .unavailable,
                modelProbe: { try await appleInterpreter.probe() }
            )
            errorMessage = "Hob could not open its private task storage."
        }
    }

    public convenience init(
        store: TaskStateStore,
        interpreter: any RuntimeMessageInterpreting,
        calendarStore: any RuntimeCalendarScheduling = EventKitScheduleStore(),
        notificationStore: any RuntimeNotificationScheduling,
        syncStore: any RuntimeTaskSyncing,
        defaults: UserDefaults = .standard,
        timezone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        modelReadiness: ModelReadinessState = .available,
        modelProbe: (@Sendable () async throws -> Void)? = nil
    ) {
        let durable = try? DurableTaskRuntime(store: store)
        self.init(
            runtime: durable,
            interpreter: interpreter,
            calendarStore: calendarStore,
            notificationStore: notificationStore,
            syncStore: syncStore,
            defaults: defaults,
            timezone: timezone,
            now: now,
            modelReadiness: modelReadiness,
            modelProbe: modelProbe
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
        syncStore: any RuntimeTaskSyncing,
        defaults: UserDefaults,
        timezone: TimeZone,
        now: @escaping @Sendable () -> Date,
        modelReadiness: ModelReadinessState,
        modelProbe: (@Sendable () async throws -> Void)?
    ) {
        self.runtime = runtime
        self.interpreter = interpreter
        self.calendarStore = calendarStore
        self.calendarAuthorization = calendarStore.authorization
        self.notificationStore = notificationStore
        self.notificationAuthorization = notificationStore.authorization
        self.syncStore = syncStore
        self.syncAvailability = syncStore.availability
        self.defaults = defaults
        self.morningDigestEnabled = defaults.object(
            forKey: DefaultsKey.morningDigestEnabled
        ) == nil || defaults.bool(forKey: DefaultsKey.morningDigestEnabled)
        let savedDigestTime = defaults.string(forKey: DefaultsKey.morningDigestTime)
        self.morningDigestTime = savedDigestTime.flatMap {
            Self.validMorningDigestTimes.contains($0) ? $0 : nil
        } ?? "07:00"
        self.timezone = timezone
        self.now = now
        self.modelReadiness = modelReadiness
        self.modelProbe = modelProbe
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        self.gregorianCalendar = calendar
        notificationStore.setActionHandler { [weak self] response in
            await self?.receiveNotificationResponse(response)
        }
        Task {
            notificationAuthorization = await notificationStore.refreshAuthorization()
            syncAvailability = await syncStore.refreshAvailability()
            await refresh()
            if calendarCleanupPending || notificationCleanupPending
                || notificationActionsPending {
                resumePendingWork()
            } else if syncAvailability == .available {
                syncNow()
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

    public static let validMorningDigestTimes = ["06:00", "07:00", "08:00", "09:00"]

    public func setMorningDigestEnabled(_ enabled: Bool) {
        morningDigestEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.morningDigestEnabled)
        Task { await refreshMorningDigestNotifications() }
    }

    public func setMorningDigestTime(_ time: String) {
        guard Self.validMorningDigestTimes.contains(time) else { return }
        morningDigestTime = time
        defaults.set(time, forKey: DefaultsKey.morningDigestTime)
        Task { await refreshMorningDigestNotifications() }
    }

    public func markDone(taskID: String) {
        run {
            guard let runtime = self.runtime else { return }
            let snapshot = await runtime.snapshot()
            guard let task = snapshot.tasks.first(where: {
                $0.id == taskID && $0.status == "open"
            }) else {
                self.notice = "That task is already closed."
                await self.refresh()
                return
            }
            let instant = self.now()
            _ = try await self.applyCompletion(
                taskID: task.id,
                message: "Done from Today",
                requestID: UUID().uuidString,
                at: instant,
                runtime: runtime
            )
            await self.syncTasks()
            self.notice = "Done: \(task.task)."
            await self.refresh()
        }
    }

    public func renameTask(taskID: String, to title: String) {
        let updatedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updatedTitle.isEmpty else { return }
        guard updatedTitle.utf8.count <= 10_000 else {
            errorMessage = "That task name is too long."
            return
        }
        run {
            guard let runtime = self.runtime else { return }
            let snapshot = await runtime.snapshot()
            guard let task = snapshot.tasks.first(where: {
                $0.id == taskID && $0.status == "open"
            }) else {
                self.notice = "That task is already closed."
                await self.refresh()
                return
            }
            guard task.task != updatedTitle else {
                self.notice = "No changes to save."
                return
            }
            let instant = self.now()
            let completedAt = self.timestamp(instant)
            let requestID = UUID().uuidString
            let response = try await runtime.process(RuntimeTurnRequest(
                requestID: requestID,
                message: "Edited from Today",
                now: completedAt,
                timezone: self.timezone.identifier,
                actions: [RuntimeAction(
                    type: "amend",
                    task: updatedTitle,
                    target: taskID
                )]
            ))
            try? await runtime.markDelivered(
                dedupeKey: "turn:\(requestID)",
                at: completedAt
            )
            guard response.outcome.disposition == .applied else {
                self.notice = "That task could not be updated."
                await self.refresh()
                return
            }
            try await self.cleanupCalendarEventsIfNeeded()
            try await self.cleanupNotificationsIfNeeded()
            _ = try await runtime.proposeSchedule(
                try self.scheduleRequest(at: instant)
            )
            await self.syncTasks()
            self.notice = "Updated: \(updatedTitle)."
            await self.refresh()
        }
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
            let interpreted = try await self.interpreter.interpret(
                message: text,
                now: timestamp,
                timezone: self.timezone.identifier,
                tasks: current
            )
            let actions = self.stableActions(
                interpreted,
                tasks: current,
                at: instant
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
                await self.syncTasks()
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
            self.notice = "Morning digest and start reminders enabled."
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

    public func syncNow() {
        run {
            self.syncAvailability = await self.syncStore.refreshAvailability()
            guard self.syncAvailability == .available else {
                self.syncNeedsAttention = true
                self.notice = self.syncUnavailableNotice
                return
            }
            let tasksBeforeSync = self.tasks
            await self.syncTasks()
            await self.refresh()
            if self.syncNeedsAttention {
                self.notice = "iCloud sync needs attention."
            } else if self.tasks != tasksBeforeSync {
                self.notice = "Tasks updated from iCloud."
            }
        }
    }

    public func checkModelReadiness() {
        guard let modelProbe else {
            modelReadiness = .available
            return
        }
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        modelReadiness = .checking
        Task {
            do {
                try await modelProbe()
                modelReadiness = .available
                notice = "Apple Intelligence is ready."
            } catch {
                modelReadiness = .unavailable
                errorMessage = ModelReadinessState.unavailable.guidance
            }
            isWorking = false
        }
    }

    public func updatePlanningPreferences(
        workStart: String,
        workEnd: String,
        workDays: [Int],
        defaultDurationMinutes: Int,
        transitionBufferMinutes: Int
    ) {
        let preferences = RuntimePlanningPreferences(
            workStart: workStart,
            workEnd: workEnd,
            workDays: workDays,
            defaultDurationMinutes: defaultDurationMinutes,
            transitionBufferMinutes: transitionBufferMinutes
        )
        run {
            guard let runtime = self.runtime else { return }
            try await runtime.setPlanningPreferences(preferences)
            if self.tasks.contains(where: { $0.status == "open" }) {
                _ = try await runtime.proposeSchedule(
                    try self.scheduleRequest(at: self.now(), preferences: preferences)
                )
            }
            self.notice = "Planning hours updated."
            await self.refresh()
        }
    }

    public func importOpenLocal(from url: URL) {
        run {
            guard let runtime = self.runtime else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size <= OpenLocalExportImporter.maximumBytes else {
                throw OpenLocalImportError.tooLarge
            }
            let result = try await runtime.importOpenLocal(
                Data(contentsOf: url, options: [.mappedIfSafe])
            )
            self.importReport = result
            if result.tasks.contains(where: { $0.status == "open" }) {
                _ = try await runtime.proposeSchedule(
                    try self.scheduleRequest(at: self.now())
                )
            }
            await self.syncTasks()
            self.notice = result.preservedDetailCount == 0
                ? "Imported \(result.tasks.count) Open Local tasks."
                : "Imported \(result.tasks.count) tasks and preserved \(result.preservedDetailCount) advanced detail(s)."
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
            if response.outcome.disposition == .applied {
                await self.syncTasks()
            }
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
        syncAvailability = syncStore.availability
        planningPreferences = snapshot.planningPreferences
        let activeProposal = snapshot.adoptedSchedule?.proposal ?? snapshot.latestProposal
        morningDigest = RuntimeMorningDigestBuilder.build(
            for: now(),
            tasks: snapshot.tasks,
            proposal: activeProposal,
            timezone: timezone
        )
        await refreshMorningDigestNotifications(
            tasks: snapshot.tasks,
            proposal: activeProposal
        )
    }

    private func refreshMorningDigestNotifications(
        tasks: [RuntimeTask]? = nil,
        proposal: RuntimeScheduleProposal? = nil
    ) async {
        guard morningDigestEnabled,
              notificationStore.authorization == .authorized else {
            await notificationStore.cancelMorningDigests()
            morningDigestNeedsAttention = false
            return
        }
        let resolvedTasks: [RuntimeTask]
        let resolvedProposal: RuntimeScheduleProposal?
        if let tasks {
            resolvedTasks = tasks
            resolvedProposal = proposal
        } else if let runtime {
            let snapshot = await runtime.snapshot()
            resolvedTasks = snapshot.tasks
            resolvedProposal = snapshot.adoptedSchedule?.proposal ?? snapshot.latestProposal
        } else {
            await notificationStore.cancelMorningDigests()
            return
        }
        do {
            try await notificationStore.replaceMorningDigests(
                RuntimeMorningDigestBuilder.upcoming(
                    from: now(),
                    days: 7,
                    tasks: resolvedTasks,
                    proposal: resolvedProposal,
                    timezone: timezone
                ),
                time: morningDigestTime,
                now: now()
            )
            morningDigestNeedsAttention = false
        } catch {
            morningDigestNeedsAttention = true
        }
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
            } catch let error as OpenLocalImportError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = "Hob could not finish that safely. Review the task list before retrying."
            }
        }
    }

    private func scheduleRequest(
        at instant: Date,
        preferences: RuntimePlanningPreferences? = nil
    ) throws -> RuntimeScheduleRequest {
        let preferences = preferences ?? planningPreferences
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
            workStart: preferences.workStart,
            workEnd: preferences.workEnd,
            defaultDurationMinutes: preferences.defaultDurationMinutes,
            transitionBufferMinutes: preferences.transitionBufferMinutes,
            workDays: preferences.workDays,
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
            await self.syncTasks()
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
            await self.syncTasks()
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
            let instant = now()
            _ = try await applyCompletion(
                taskID: response.taskID,
                message: "Done from schedule reminder",
                requestID: "notification:\(response.id)",
                at: instant,
                runtime: runtime
            )
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

    private func applyCompletion(
        taskID: String,
        message: String,
        requestID: String,
        at instant: Date,
        runtime: DurableTaskRuntime
    ) async throws -> RuntimeTurnResponse {
        let completedAt = timestamp(instant)
        let result = try await runtime.process(RuntimeTurnRequest(
            requestID: requestID,
            message: message,
            now: completedAt,
            timezone: timezone.identifier,
            actions: [RuntimeAction(type: "complete", target: taskID)]
        ))
        try? await runtime.markDelivered(
            dedupeKey: "turn:\(requestID)",
            at: completedAt
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
        return result
    }

    private func timestamp(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = gregorianCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.string(from: value)
    }

    private func stableActions(
        _ actions: [RuntimeAction],
        tasks: [RuntimeTask],
        at instant: Date
    ) -> [RuntimeAction] {
        let open = tasks.filter { $0.status == "open" }.sorted { $0.id < $1.id }
        let milliseconds = Int64(instant.timeIntervalSince1970 * 1_000)
        return actions.enumerated().map { index, action in
            let target: String?
            if action.type == "capture" {
                target = action.target ?? [
                    "task",
                    String(milliseconds),
                    String(format: "%02d", index),
                    UUID().uuidString.lowercased(),
                ].joined(separator: "-")
            } else if let raw = action.target,
                      let position = Int(raw),
                      open.indices.contains(position - 1) {
                target = open[position - 1].id
            } else {
                target = action.target
            }
            return RuntimeAction(
                type: action.type,
                task: action.task,
                raw: action.raw,
                target: target,
                when: action.when,
                deadline: action.deadline,
                time: action.time,
                durationMinutes: action.durationMinutes,
                priority: action.priority,
                confidence: action.confidence
            )
        }
    }

    private func day(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = gregorianCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }

    private func syncTasks() async {
        guard syncAvailability == .available,
              let runtime else { return }
        do {
            let local = await runtime.taskOperationJournal()
            let merged = try await syncStore.exchange(localOperations: local)
            let changed = try await runtime.mergeTaskOperations(merged)
            if changed {
                try await cleanupCalendarEventsIfNeeded()
                try await cleanupNotificationsIfNeeded()
                let snapshot = await runtime.snapshot()
                if snapshot.tasks.contains(where: { $0.status == "open" }) {
                    _ = try await runtime.proposeSchedule(
                        try scheduleRequest(at: now())
                    )
                }
            }
            syncNeedsAttention = false
            await refresh()
        } catch {
            syncNeedsAttention = true
        }
    }

    private var syncUnavailableNotice: String {
        switch syncAvailability {
        case .available:
            return "iCloud sync needs attention."
        case .noAccount:
            return "Sign in to iCloud to sync tasks."
        case .restricted:
            return "iCloud task sync is restricted on this device."
        case .unavailable:
            return "iCloud task sync is unavailable. Try again later."
        }
    }
}
