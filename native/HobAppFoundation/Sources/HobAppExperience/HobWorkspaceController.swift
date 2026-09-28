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

public struct HobConversationMessage: Identifiable, Equatable, Sendable {
    public enum Author: String, Equatable, Sendable {
        case user
        case hob
    }

    public let id: UUID
    public let author: Author
    public let text: String
    public let isError: Bool

    public init(
        id: UUID = UUID(),
        author: Author,
        text: String,
        isError: Bool = false
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.isError = isError
    }
}

@MainActor
public final class HobWorkspaceController: ObservableObject {
    @Published public var draft = ""
    @Published public private(set) var conversationMessages: [HobConversationMessage] = []
    @Published public private(set) var tasks: [RuntimeTask] = []
    @Published public private(set) var proposal: RuntimeScheduleProposal?
    @Published public private(set) var adoptedSchedule: RuntimeAdoptedSchedule?
    @Published public private(set) var isWorking = false
    @Published public private(set) var notice: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var calendarAuthorization: RuntimeCalendarAuthorization
    @Published public private(set) var calendarIntegrationEnabled: Bool
    @Published public private(set) var calendars: [RuntimeCalendarDescriptor] = []
    @Published public private(set) var inputCalendarIDs: Set<String>?
    @Published public private(set) var blockAllDayEvents: Bool
    @Published public private(set) var calendarCleanupPending = false
    @Published public private(set) var notificationAuthorization: RuntimeNotificationAuthorization
    @Published public private(set) var notificationCleanupPending = false
    @Published public private(set) var taskRemindersNeedAttention = false
    @Published public private(set) var notificationActionsPending = false
    @Published public private(set) var morningDigest: RuntimeMorningDigest?
    @Published public private(set) var morningDigestEnabled: Bool
    @Published public private(set) var morningDigestTime: String
    @Published public private(set) var morningDigestNeedsAttention = false
    @Published public private(set) var eveningRecapEnabled: Bool
    @Published public private(set) var eveningRecapTime: String
    @Published public private(set) var eveningRecapNeedsAttention = false
    @Published public private(set) var syncAvailability: RuntimeTaskSyncAvailability
    @Published public private(set) var syncNeedsAttention = false
    @Published public private(set) var syncAttentionMessage: String? = nil
    @Published public private(set) var importReport: OpenLocalImportResult?
    @Published public private(set) var modelReadiness: ModelReadinessState
    @Published public private(set) var planningAnalysis: RuntimePlanningAnalysis? = nil
    @Published public private(set) var longRangeConfirmation: String? = nil
    @Published public private(set) var reviewQuestion: RuntimePendingQuestion?
    @Published public private(set) var conversationState = RuntimeConversationState()

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
    private var pendingLongRangeSubmission: PendingLongRangeSubmission?
    private var focusedTaskIDs: [String] = []
    private var clarificationPending = false
    private var unresolvedMessage: String?

    private struct PendingLongRangeSubmission {
        let text: String
        let actions: [RuntimeAction]
        let instant: Date
    }

    private enum DefaultsKey {
        static let morningDigestEnabled = "hob.morning.digest.enabled"
        static let morningDigestTime = "hob.morning.digest.time"
        static let eveningRecapEnabled = "hob.evening.recap.enabled"
        static let eveningRecapTime = "hob.evening.recap.time"
        static let calendarIntegrationEnabled = "hob.calendar.integration.enabled"
        static let inputCalendarIDs = "hob.calendar.input.ids"
        static let blockAllDayEvents = "hob.calendar.block.all.day"
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
        self.calendarIntegrationEnabled = defaults.bool(
            forKey: DefaultsKey.calendarIntegrationEnabled
        )
        if defaults.object(forKey: DefaultsKey.inputCalendarIDs) != nil {
            self.inputCalendarIDs = Set(
                defaults.stringArray(forKey: DefaultsKey.inputCalendarIDs) ?? []
            )
        } else {
            self.inputCalendarIDs = nil
        }
        self.blockAllDayEvents = defaults.bool(forKey: DefaultsKey.blockAllDayEvents)
        self.notificationStore = notificationStore
        self.notificationAuthorization = notificationStore.authorization
        self.syncStore = syncStore
        self.syncAvailability = syncStore.availability
        self.defaults = defaults
        defaults.removeObject(forKey: "hob.calendar.output.id")
        self.morningDigestEnabled =
            defaults.object(
                forKey: DefaultsKey.morningDigestEnabled
            ) == nil || defaults.bool(forKey: DefaultsKey.morningDigestEnabled)
        let savedDigestTime = defaults.string(forKey: DefaultsKey.morningDigestTime)
        self.morningDigestTime =
            savedDigestTime.flatMap {
                Self.validMorningDigestTimes.contains($0) ? $0 : nil
            } ?? "07:00"
        self.eveningRecapEnabled =
            defaults.object(
                forKey: DefaultsKey.eveningRecapEnabled
            ) == nil || defaults.bool(forKey: DefaultsKey.eveningRecapEnabled)
        let savedRecapTime = defaults.string(forKey: DefaultsKey.eveningRecapTime)
        self.eveningRecapTime =
            savedRecapTime.flatMap {
                Self.validMorningDigestTimes.contains($0) ? $0 : nil
            } ?? "20:00"
        self.timezone = timezone
        self.now = now
        self.modelReadiness = modelReadiness
        self.modelProbe = modelProbe
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        self.gregorianCalendar = calendar
        if let data = defaults.data(forKey: "hob.conversation.context.v2"),
            let saved = try? JSONDecoder().decode(RuntimeConversationState.self, from: data)
        {
            self.conversationState = saved
        }
        notificationStore.setActionHandler { [weak self] response in
            await self?.receiveNotificationResponse(response)
        }
        Task {
            notificationAuthorization = await notificationStore.refreshAuthorization()
            syncAvailability = await syncStore.refreshAvailability()
            await refresh()
            if calendarCleanupPending || notificationCleanupPending
                || notificationActionsPending
            {
                resumePendingWork()
            } else if syncAvailability == .available {
                performSync()
            }
        }
    }

    public var canSubmit: Bool {
        !isWorking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && runtime != nil
    }

    public var hasUnplannedOnDeckTasks: Bool {
        let planned = Set(
            proposal?.plannedUntimedTaskIDs
                ?? adoptedSchedule?.proposal.plannedUntimedTaskIDs
                ?? []
        )
        return tasks.contains {
            $0.status == "open" && !$0.isWaiting
                && $0.dueTime == nil && !planned.contains($0.id)
        }
    }

    public var scheduleDiff: RuntimeScheduleDiff? {
        guard let current = adoptedSchedule?.proposal,
            let proposal,
            current.id != proposal.id
        else { return nil }
        return RuntimeScheduleDiff(current: current, proposed: proposal)
    }

    public static let validMorningDigestTimes = (0..<24).map {
        String(format: "%02d:00", $0)
    }

    public static func morningDigestTimeLabel(_ time: String) -> String {
        guard let hour = Int(time.prefix(2)), (0..<24).contains(hour) else {
            return time
        }
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return "\(displayHour):00 \(hour < 12 ? "AM" : "PM")"
    }

    public var usesAllInputCalendars: Bool { inputCalendarIDs == nil }

    public var inputCalendarSummary: String {
        guard let inputCalendarIDs else { return "All calendars" }
        if inputCalendarIDs.isEmpty { return "None" }
        return inputCalendarIDs.count == 1
            ? calendars.first(where: { inputCalendarIDs.contains($0.id) })?.title ?? "1 calendar"
            : "\(inputCalendarIDs.count) calendars"
    }

    public var unavailableInputCalendarCount: Int {
        guard let inputCalendarIDs else { return 0 }
        return inputCalendarIDs.subtracting(calendars.map(\.id)).count
    }

    public func setCalendarIntegrationEnabled(_ enabled: Bool) {
        if !enabled {
            calendarIntegrationEnabled = false
            defaults.set(false, forKey: DefaultsKey.calendarIntegrationEnabled)
            run {
                if self.tasks.contains(where: { $0.status == "open" }),
                    let runtime = self.runtime
                {
                    _ = try await runtime.proposeSchedule(
                        try self.scheduleRequest(at: self.now())
                    )
                    await self.refresh()
                }
                self.notice = "Calendar availability off."
            }
            return
        }
        run {
            let authorization =
                self.calendarStore.authorization == .notDetermined
                ? try await self.calendarStore.requestAccess()
                : self.calendarStore.authorization
            self.calendarAuthorization = authorization
            guard authorization == .fullAccess else {
                self.calendarIntegrationEnabled = false
                self.defaults.set(false, forKey: DefaultsKey.calendarIntegrationEnabled)
                self.errorMessage = "Calendar access is off. Enable full access in Settings."
                return
            }
            self.calendarIntegrationEnabled = true
            self.defaults.set(true, forKey: DefaultsKey.calendarIntegrationEnabled)
            self.refreshCalendarChoices()
            try await self.cleanupCalendarEventsIfNeeded()
            self.notice = "Calendar availability on."
            if self.tasks.contains(where: { $0.status == "open" }),
                let runtime = self.runtime
            {
                _ = try await runtime.proposeSchedule(
                    try self.scheduleRequest(at: self.now())
                )
                await self.refresh()
            }
        }
    }

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

    public func setEveningRecapEnabled(_ enabled: Bool) {
        eveningRecapEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.eveningRecapEnabled)
        Task { await refreshEveningRecapNotifications() }
    }

    public func setEveningRecapTime(_ time: String) {
        guard Self.validMorningDigestTimes.contains(time) else { return }
        eveningRecapTime = time
        defaults.set(time, forKey: DefaultsKey.eveningRecapTime)
        Task { await refreshEveningRecapNotifications() }
    }

    public func setUsesAllInputCalendars(_ usesAll: Bool) {
        inputCalendarIDs = usesAll ? nil : Set(calendars.map(\.id))
        persistCalendarPreferences()
    }

    public func setInputCalendar(_ calendarID: String, included: Bool) {
        var selected = inputCalendarIDs ?? Set(calendars.map(\.id))
        if included {
            selected.insert(calendarID)
        } else {
            selected.remove(calendarID)
        }
        inputCalendarIDs = selected
        persistCalendarPreferences()
    }

    public func removeUnavailableInputCalendars() {
        guard let inputCalendarIDs else { return }
        self.inputCalendarIDs = inputCalendarIDs.intersection(calendars.map(\.id))
        persistCalendarPreferences()
    }

    public func setBlockAllDayEvents(_ blocks: Bool) {
        blockAllDayEvents = blocks
        persistCalendarPreferences()
    }

    public func applyCalendarSettings() {
        run {
            self.refreshCalendarChoices()
            guard let runtime = self.runtime,
                self.tasks.contains(where: { $0.status == "open" })
            else {
                self.notice = "Calendar settings updated."
                return
            }
            _ = try await runtime.proposeSchedule(
                try self.scheduleRequest(at: self.now())
            )
            self.notice =
                self.adoptedSchedule == nil
                ? "Schedule updated for your calendars."
                : "Review the schedule changes before updating Calendar."
            await self.refresh()
        }
    }

    public func markDone(taskID: String) {
        run {
            guard let runtime = self.runtime else { return }
            let snapshot = await runtime.snapshot()
            guard
                let task = snapshot.tasks.first(where: {
                    $0.id == taskID && $0.status == "open"
                })
            else {
                self.notice = "That task is already closed."
                await self.refresh()
                return
            }
            let instant = self.now()
            self.planningAnalysis = nil
            let result = try await self.applyCompletion(
                taskID: task.id,
                message: "Done from Today",
                requestID: UUID().uuidString,
                at: instant,
                runtime: runtime
            )
            await self.syncTasks()
            if let next = result.outcome.tasks.first(where: {
                $0.id == task.id && $0.status == "open" && $0.recurrence != nil
            }) {
                self.notice = "Next: \(next.task)\(next.dueDate.map { " on \($0)" } ?? "")."
            } else {
                self.notice = "Done: \(task.task)."
            }
            await self.refresh()
        }
    }

    public func task(taskID: String) -> RuntimeTask? {
        tasks.first { $0.id == taskID }
    }

    public func skipOccurrence(taskID: String) {
        updateRecurrence(taskID: taskID, operation: "skip")
    }

    public func stopRepeating(taskID: String) {
        updateRecurrence(taskID: taskID, operation: "stop")
    }

    public func dismissPlanningAnalysis() {
        planningAnalysis = nil
    }

    public func confirmLongRangeSubmission() {
        guard let pending = pendingLongRangeSubmission else { return }
        pendingLongRangeSubmission = nil
        longRangeConfirmation = nil
        run {
            guard let runtime = self.runtime else { return }
            try await self.applySubmittedActions(
                pending.actions,
                text: pending.text,
                instant: pending.instant,
                runtime: runtime
            )
        }
    }

    public func cancelLongRangeSubmission() {
        guard pendingLongRangeSubmission != nil || longRangeConfirmation != nil else {
            return
        }
        pendingLongRangeSubmission = nil
        longRangeConfirmation = nil
        publishConversationReply("Canceled.")
    }

    public func taskStatusLabel(_ task: RuntimeTask) -> String {
        if task.status != "open" { return task.status == "dropped" ? "Removed" : task.status.capitalized }
        if task.isWaiting { return "Waiting" }
        return task.isMissedTimedItem(on: day(now())) ? "Missed" : task.status.capitalized
    }

    public var reminderList: RuntimeReminderList {
        RuntimeReminderList(tasks: tasks, now: now(), timezone: timezone)
    }

    public var reminderTimezone: TimeZone { timezone }
    public var reminderNow: Date { now() }

    public func editReminder(
        taskID: String, title: String, date: String?, time: String?, keepIndefinitely: Bool = false
    ) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 2_000 else { return }
        var clear: [String] = []
        let parts = date?.split(separator: "-").compactMap { Int($0) } ?? []
        guard date == nil || parts.count == 3 else { return }
        let when =
            date == nil
            ? nil : RuntimeDateIntent(kind: "absolute", year: parts[0], month: parts[1], dayNumber: parts[2])
        if date == nil { clear.append("date") }
        if date == nil || time == nil { clear.append("time") }
        updateTask(
            taskID: taskID,
            action: RuntimeAction(
                type: "revise", task: clean, target: taskID,
                when: when,
                time: date == nil ? nil : time, clearFields: clear.isEmpty ? nil : clear,
                reviewPolicy: keepIndefinitely ? "never" : "standard"), success: "Updated: \(clean).")
    }

    public func autosaveReminder(
        original: RuntimeTask, title: String, date: String?, time: String?,
        keepIndefinitely: Bool, note: String
    ) {
        guard original.status == "open" else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let changedTitle =
            cleanTitle != original.task && !cleanTitle.isEmpty
            && cleanTitle.utf8.count <= 2_000
        let changedDate = date != original.dueDate
        let changedTime = time != original.dueTime
        let changedPolicy = keepIndefinitely != (original.reviewPolicy == "never")
        let changedNote = note != (original.note ?? "")
        guard changedTitle || changedDate || changedTime || changedPolicy || changedNote else { return }

        let dateParts = date?.split(separator: "-").compactMap { Int($0) } ?? []
        guard date == nil || dateParts.count == 3 else { return }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanNote.utf8.count <= 10_000 else { return }
        let when =
            changedDate && date != nil
            ? RuntimeDateIntent(kind: "absolute", year: dateParts[0], month: dateParts[1], dayNumber: dateParts[2])
            : nil
        var clear: [String] = []
        if changedDate && date == nil { clear.append("date") }
        if (changedDate || changedTime) && time == nil { clear.append("time") }
        if changedNote && cleanNote.isEmpty { clear.append("note") }
        let action = RuntimeAction(
            type: "revise", task: changedTitle ? cleanTitle : nil, target: original.id,
            when: when, time: changedTime ? time : nil,
            note: changedNote && !cleanNote.isEmpty ? cleanNote : nil,
            clearFields: clear.isEmpty ? nil : clear,
            reviewPolicy: changedPolicy ? (keepIndefinitely ? "never" : "standard") : nil)

        // A sheet may close while another operation is finishing. Keep the edit
        // until the runtime can accept it instead of dropping the final change.
        Task { [weak self] in
            guard let self else { return }
            while self.isWorking { try? await Task.sleep(for: .milliseconds(50)) }
            self.updateTask(
                taskID: original.id, action: action,
                success: "Updated: \(changedTitle ? cleanTitle : original.task).")
        }
    }

    public func addNote(taskID: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 10_000 else { return }
        updateTask(
            taskID: taskID,
            action: RuntimeAction(
                type: "note", target: taskID, note: clean
            ), success: "Note saved.")
    }

    public func setWaiting(taskID: String, waiting: Bool) {
        updateTask(
            taskID: taskID,
            action: RuntimeAction(type: waiting ? "wait" : "resume", target: taskID),
            success: waiting ? "Moved to Waiting." : "Back on deck."
        )
    }

    private func updateTask(
        taskID: String,
        action: RuntimeAction,
        success: String
    ) {
        run {
            guard let runtime = self.runtime,
                self.tasks.contains(where: { $0.id == taskID && $0.status == "open" })
            else { return }
            let instant = self.now()
            let timestamp = self.timestamp(instant)
            let requestID = UUID().uuidString
            let response = try await runtime.process(
                RuntimeTurnRequest(
                    requestID: requestID,
                    message: success,
                    now: timestamp,
                    timezone: self.timezone.identifier,
                    actions: [action]
                ))
            try? await runtime.markDelivered(dedupeKey: "turn:\(requestID)", at: timestamp)
            guard response.outcome.disposition == .applied else {
                self.notice = "That task could not be updated."
                return
            }
            await self.refresh()
            try await self.cleanupCalendarEventsIfNeeded()
            try await self.cleanupNotificationsIfNeeded()
            _ = try await runtime.proposeSchedule(try self.scheduleRequest(at: instant))
            await self.syncTasks()
            self.focusedTaskIDs = [taskID]
            self.rememberFocus([taskID], tasks: response.outcome.tasks)
            self.notice = success
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
            guard
                let task = snapshot.tasks.first(where: {
                    $0.id == taskID && $0.status == "open"
                })
            else {
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
            let response = try await runtime.process(
                RuntimeTurnRequest(
                    requestID: requestID,
                    message: "Edited from Today",
                    now: completedAt,
                    timezone: self.timezone.identifier,
                    actions: [
                        RuntimeAction(
                            type: "amend",
                            task: updatedTitle,
                            target: taskID
                        )
                    ]
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
        notice = nil
        appendConversationMessage(author: .user, text: text)
        draft = ""
        run(recordsErrorsInConversation: true) {
            guard let runtime = self.runtime else { return }
            let instant = self.now()
            let timestamp = self.timestamp(instant)
            let current = await runtime.snapshot().tasks
            self.validateConversation(tasks: current)
            let interpreted: [RuntimeAction]
            do {
                interpreted = try await self.interpreter.interpret(
                    message: text,
                    now: timestamp,
                    timezone: self.timezone.identifier,
                    tasks: current,
                    context: RuntimeConversationContext(
                        focusedTaskIDs: self.conversationFocus(for: text),
                        unresolvedMessage: self.conversationState.pending?.originalMessage ?? self.unresolvedMessage,
                        clarificationPending: self.conversationState.pending != nil || self.clarificationPending,
                        pendingQuestion: self.conversationState.pending
                    )
                )
            } catch {
                if case RuntimeInterpretationError.question(let request) = error {
                    self.conversationState.pending = RuntimePendingQuestion(
                        kind: request.kind, text: request.text, originalMessage: text,
                        taskIDs: request.taskIDs, tasks: current, day: self.day(instant),
                        timezone: self.timezone.identifier)
                    self.persistConversation()
                }
                self.unresolvedMessage = text
                if case RuntimeInterpretationError.clarification = error {
                    self.focusedTaskIDs = self.conversationFocus(for: text)
                    self.clarificationPending = true
                } else {
                    self.clarificationPending = false
                }
                throw error
            }
            let actions = self.stableActions(
                interpreted,
                tasks: current,
                at: instant
            )
            let isConversation = actions.allSatisfy { ["social", "acknowledge"].contains($0.type) }
            let cancelled = ["cancel", "never mind", "nevermind"].contains(text.lowercased())
            if !isConversation || cancelled {
                self.conversationState.pending = nil
                self.clarificationPending = false
                self.unresolvedMessage = nil
                self.persistConversation()
            }
            if actions.count == 1, actions[0].type == "analysis" {
                self.conversationState.recent = nil
                self.persistConversation()
                self.unresolvedMessage = nil
                let horizon = actions[0].horizonDays ?? 7
                let analysis = try RuntimePlanningAnalyzer.analyze(
                    tasks: current,
                    action: actions[0],
                    request: try self.scheduleRequest(
                        at: instant,
                        horizonDays: horizon
                    )
                )
                self.planningAnalysis = analysis
                if self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    self.draft = ""
                }
                self.notice = nil
                self.appendConversationMessage(
                    author: .hob,
                    text: ([analysis.headline] + analysis.details)
                        .joined(separator: " ")
                )
                return
            }
            if actions.count == 1, actions[0].type == "query" {
                self.conversationState.recent = nil
                self.persistConversation()
                let answer = try RuntimeTaskQueryEngine.answer(
                    action: actions[0],
                    tasks: current,
                    now: instant,
                    timezone: self.timezone
                )
                self.publishConversationReply(answer)
                self.unresolvedMessage = nil
                if self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    self.draft = ""
                }
                return
            }
            if let confirmation = self.longRangeMessage(
                actions: actions,
                tasks: current,
                text: text,
                instant: instant
            ) {
                self.pendingLongRangeSubmission = PendingLongRangeSubmission(
                    text: text,
                    actions: actions,
                    instant: instant
                )
                self.longRangeConfirmation = confirmation
                self.appendConversationMessage(author: .hob, text: confirmation)
                return
            }
            self.planningAnalysis = nil
            try await self.applySubmittedActions(
                actions, text: text, instant: instant, runtime: runtime
            )
        }
    }

    private func conversationFocus(for message: String) -> [String] {
        if let pending = conversationState.pending { return pending.taskIDs }
        let words = message.lowercased().split { !$0.isLetter }.map(String.init)
        let hasPronoun = words.contains { ["it", "that", "this"].contains($0) }
        if !hasPronoun, RuntimeTaskReviewReply.parse(message) != nil,
            let reviewQuestion
        {
            return reviewQuestion.taskIDs
        }
        if let recent = conversationState.recent { return recent.taskIDs }
        if (hasPronoun && !conversationMessages.contains(where: { $0.author == .hob }))
            || (!hasPronoun && RuntimeTaskReviewReply.parse(message) != nil)
        {
            return reviewQuestion?.taskIDs ?? []
        }
        return []
    }

    private func persistConversation() {
        if let data = try? JSONEncoder().encode(conversationState) {
            defaults.set(data, forKey: "hob.conversation.context.v2")
        }
    }

    private func validateConversation(tasks: [RuntimeTask]) {
        let previousQuestion = conversationState.pending
        conversationState.validate(tasks: tasks, day: day(now()), timezone: timezone.identifier)
        if let previousQuestion, conversationState.pending == nil {
            let text = "The task or day changed. Which task do you mean now?"
            conversationState.pending = RuntimePendingQuestion(
                kind: .chooseTask, text: text,
                originalMessage: previousQuestion.originalMessage,
                taskIDs: Array(tasks.filter { $0.status == "open" }.prefix(8).map(\.id)),
                tasks: tasks, day: day(now()), timezone: timezone.identifier)
            appendConversationMessage(author: .hob, text: text)
        }
        if conversationState.pending == nil {
            clarificationPending = false
            unresolvedMessage = nil
        }
        focusedTaskIDs = conversationState.recent?.taskIDs ?? []
        persistConversation()
    }

    private func rememberFocus(_ ids: [String], tasks: [RuntimeTask]) {
        let openIDs = ids.filter { id in tasks.contains { $0.id == id && $0.status == "open" } }
        conversationState.recent =
            openIDs.isEmpty
            ? nil
            : RuntimePendingQuestion(
                kind: .freeform, text: "", taskIDs: Array(Set(openIDs)).sorted(), tasks: tasks,
                day: day(now()), timezone: timezone.identifier)
        focusedTaskIDs = openIDs
        persistConversation()
    }

    private func applySubmittedActions(
        _ actions: [RuntimeAction],
        text: String,
        instant: Date,
        runtime: DurableTaskRuntime
    ) async throws {
        let timestamp = self.timestamp(instant)
        let previousIDs = Set(await runtime.snapshot().tasks.map(\.id))
        let requestID = UUID().uuidString
        let response = try await runtime.process(
            RuntimeTurnRequest(
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
        if response.outcome.disposition == .applied,
            response.outcome.appliedKinds == ["social"]
        {
            self.unresolvedMessage = nil
            if self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                self.draft = ""
            }
            self.publishConversationReply(actions.first?.reply ?? "Anytime.")
            return
        }
        switch response.outcome.disposition {
        case .applied:
            self.unresolvedMessage = nil
            let addedIDs = response.outcome.tasks.filter { !previousIDs.contains($0.id) }.map(\.id)
            let changedIDs = actions.compactMap(\.target)
            if !addedIDs.isEmpty || !changedIDs.isEmpty {
                self.focusedTaskIDs = Array((changedIDs + addedIDs).prefix(8))
                self.rememberFocus(self.focusedTaskIDs, tasks: response.outcome.tasks)
            }
            let isReplan = response.outcome.appliedKinds == ["replan"]
            if !isReplan {
                if response.outcome.appliedKinds == ["acknowledge"] {
                    self.publishConversationReply("Okay. Nothing marked done.")
                } else if response.outcome.appliedKinds == ["keep"] {
                    self.publishConversationReply("Keeping it on deck.")
                } else if response.outcome.appliedKinds == ["revise"],
                    actions.count == 1, actions[0].reviewPolicy == "never"
                {
                    self.publishConversationReply("I’ll keep it on Today without checking again.")
                } else if response.outcome.appliedKinds == ["revise"],
                    actions.count == 1, actions[0].reviewPolicy == "standard"
                {
                    self.publishConversationReply("Okay, Hob can check in about it again.")
                } else if response.outcome.appliedKinds == ["undo"] {
                    self.publishConversationReply("Undid the last task change.")
                } else if response.outcome.appliedKinds.allSatisfy({ $0 == "capture" }) {
                    if actions.count == 1, let task = actions[0].task {
                        self.publishConversationReply("Added “\(task)”")
                    } else {
                        self.publishConversationReply("Added \(actions.count) tasks.")
                    }
                } else {
                    let titles = actions.compactMap { action in
                        response.outcome.tasks.first { $0.id == action.target }?.task
                    }.joined(separator: ", ")
                    let kinds = Set(response.outcome.appliedKinds)
                    let verb =
                        kinds == ["complete"]
                        ? "Done"
                        : kinds == ["drop"]
                            ? "Removed"
                            : kinds == ["reschedule"]
                                ? "Moved"
                                : kinds == ["note"] ? "Noted progress on" : "Updated"
                    self.publishConversationReply(titles.isEmpty ? "Updated the tasks." : "\(verb): \(titles).")
                }
                await self.refresh()
            }
            try await self.cleanupCalendarEventsIfNeeded()
            try await self.cleanupNotificationsIfNeeded()
            let explicitlyPlannedIDs =
                isReplan
                ? response.outcome.tasks.filter {
                    $0.status == "open" && $0.dueTime == nil
                }.map(\.id)
                : nil
            _ = try await runtime.proposeSchedule(
                try self.scheduleRequest(
                    at: instant,
                    includedUntimedTaskIDs: explicitlyPlannedIDs
                ))
            await self.syncTasks()
            if isReplan {
                self.publishConversationReply("Built a new plan from what changed.")
            }
        case .clarificationRequired:
            self.unresolvedMessage = text
            self.publishConversationReply(
                "I need a clearer date or task before changing anything."
            )
        case .confirmationRequired:
            self.publishConversationReply("Review the task before I apply it.")
        case .rejected, .noChange:
            self.publishConversationReply(
                "Nothing changed. Try describing the task another way."
            )
        }
        await self.refresh()
    }

    private func publishConversationReply(_ text: String) {
        notice = text
        appendConversationMessage(author: .hob, text: text)
    }

    private func appendConversationMessage(
        author: HobConversationMessage.Author,
        text: String,
        isError: Bool = false
    ) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        conversationMessages.append(
            HobConversationMessage(
                author: author,
                text: clean,
                isError: isError
            ))
        if conversationMessages.count > 40 {
            conversationMessages.removeFirst(conversationMessages.count - 40)
        }
    }

    private func longRangeMessage(
        actions: [RuntimeAction],
        tasks: [RuntimeTask],
        text: String,
        instant: Date
    ) -> String? {
        var preview = TaskRuntime(tasks: tasks)
        let response = preview.process(
            RuntimeTurnRequest(
                requestID: "long-range-preview",
                message: text,
                now: timestamp(instant),
                timezone: timezone.identifier,
                actions: actions
            ))
        guard response.outcome.disposition == .applied,
            let boundary = gregorianCalendar.date(
                byAdding: .year, value: 2, to: instant
            )
        else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = gregorianCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        let boundaryDay = formatter.string(from: boundary)
        let affected = Set(actions.compactMap(\.target))
        let newIDs = Set(response.outcome.tasks.map(\.id)).subtracting(tasks.map(\.id))
        let farDates = response.outcome.tasks.filter {
            affected.contains($0.id) || newIDs.contains($0.id)
        }.flatMap { [$0.dueDate, $0.deadlineDate].compactMap { $0 } }
            .filter { $0 > boundaryDay }
            .sorted()
        guard let farthest = farDates.last,
            let date = formatter.date(from: farthest)
        else { return nil }
        let years = max(
            2,
            gregorianCalendar.dateComponents(
                [.year],
                from: gregorianCalendar.startOfDay(for: instant),
                to: date
            ).year ?? 2
        )
        return "Are you sure it’s \(years) years away?"
    }

    public func planOnDeckWork() {
        let taskIDs = tasks.filter {
            $0.status == "open" && !$0.isWaiting && $0.dueTime == nil
        }.map(\.id)
        guard !taskIDs.isEmpty else {
            notice = "Nothing untimed is waiting on deck."
            return
        }
        run {
            guard let runtime = self.runtime else { return }
            _ = try await runtime.proposeSchedule(
                try self.scheduleRequest(
                    at: self.now(),
                    includedUntimedTaskIDs: taskIDs
                ))
            self.notice = "Built a proposed schedule for on-deck work."
            await self.refresh()
        }
    }

    public func adoptProposal() {
        guard let proposal else { return }
        run {
            guard let runtime = self.runtime else { return }
            try await self.cleanupCalendarEventsIfNeeded()
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
                    calendarEventIDs: [],
                    notificationIDs: notificationIDs
                )
            } catch {
                self.notificationStore.cancel(notificationIDs: notificationIDs)
                throw error
            }
            await self.refresh()
            try await self.cleanupCalendarEventsIfNeeded()
            try await self.cleanupNotificationsIfNeeded()
            self.notice =
                notificationIDs.isEmpty
                ? "Schedule adopted. Notifications are off."
                : "Schedule adopted with start reminders."
            await self.refresh()
        }
    }

    public func keepAdoptedSchedule() {
        guard let proposal else { return }
        run {
            guard let runtime = self.runtime else { return }
            try await runtime.discardScheduleProposal(proposalID: proposal.id)
            self.notice = "Kept the current schedule."
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
                !eventIDs.isEmpty
            {
                try self.calendarStore.remove(eventIDs: eventIDs)
            }
            try await runtime.cancelAdoptedSchedule()
            self.notice = "Schedule cancelled. Tasks remain open."
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
                let runtime = self.runtime
            {
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
            self.notice = "Notifications enabled."
            await self.refresh()
        }
    }

    public func requestCalendarAccess() {
        run {
            self.calendarAuthorization = try await self.calendarStore.requestAccess()
            if self.calendarAuthorization == .fullAccess {
                self.calendarIntegrationEnabled = true
                self.defaults.set(true, forKey: DefaultsKey.calendarIntegrationEnabled)
                self.refreshCalendarChoices()
                try await self.cleanupCalendarEventsIfNeeded()
                self.notice = "Calendar connected. New plans will avoid busy time."
                if self.tasks.contains(where: { $0.status == "open" }),
                    let runtime = self.runtime
                {
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
        performSync()
    }

    public func refreshForDayChange() {
        guard morningDigest?.date != day(now()) else { return }
        run { await self.refresh() }
    }

    private func performSync() {
        run {
            _ = await self.notificationStore.refreshAuthorization()
            await self.refresh()
            self.calendarAuthorization = self.calendarStore.authorization
            self.refreshCalendarChoices()
            self.syncAvailability = await self.syncStore.refreshAvailability()
            guard self.syncAvailability == .available else {
                self.syncNeedsAttention = true
                self.syncAttentionMessage = self.syncUnavailableNotice
                return
            }
            await self.syncTasks()
            await self.refresh()
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

    public func importOpenLocal(from url: URL) {
        run {
            guard let runtime = self.runtime else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                let size = values.fileSize,
                size <= OpenLocalExportImporter.maximumBytes
            else {
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
            self.notice =
                result.preservedDetailCount == 0
                ? "Imported \(result.tasks.count) Open Local tasks."
                : "Imported \(result.tasks.count) tasks and preserved \(result.preservedDetailCount) advanced detail(s)."
            await self.refresh()
        }
    }

    public func retryCalendarCleanup() {
        run {
            try await self.cleanupCalendarEventsIfNeeded(force: true)
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
            let response = try await runtime.process(
                RuntimeTurnRequest(
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
                response.outcome.tasks.contains(where: { $0.status == "open" })
            {
                try await self.cleanupCalendarEventsIfNeeded()
                try await self.cleanupNotificationsIfNeeded()
                _ = try await runtime.proposeSchedule(
                    try self.scheduleRequest(at: instant)
                )
            }
            self.notice =
                response.outcome.disposition == .applied
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
        var snapshot = await runtime.snapshot()
        if snapshot.adoptedSchedule?.calendarEventIDs.isEmpty == false {
            _ = try? await runtime.detachCalendarEventsFromAdoptedSchedule()
            snapshot = await runtime.snapshot()
        }
        if calendarStore.authorization == .fullAccess,
            !snapshot.calendarCleanupEventIDs.isEmpty
        {
            let identifiers = snapshot.calendarCleanupEventIDs
            if (try? calendarStore.remove(eventIDs: identifiers)) != nil {
                try? await runtime.acknowledgeCalendarCleanup(eventIDs: identifiers)
                snapshot = await runtime.snapshot()
            }
        }
        if snapshot.adoptedSchedule == nil,
            let previous = snapshot.latestProposal
        {
            let taskByID = Dictionary(
                uniqueKeysWithValues: snapshot.tasks.map {
                    ($0.id, $0)
                })
            let planned = Set(previous.plannedUntimedTaskIDs)
            let hasLegacyAutomaticBlock = previous.blocks.contains { block in
                taskByID[block.taskID]?.dueTime == nil && !planned.contains(block.taskID)
            }
            if hasLegacyAutomaticBlock,
                let replacement = try? scheduleRequest(
                    at: now(), includedUntimedTaskIDs: []
                )
            {
                _ = try? await runtime.proposeSchedule(replacement)
                snapshot = await runtime.snapshot()
            }
        }
        // Match the runtime's stable ID order even before the first turn; a
        // refresh after a read-only reply must not reorder the visible state.
        tasks = snapshot.tasks.sorted { $0.id < $1.id }
        proposal = snapshot.latestProposal
        adoptedSchedule = snapshot.adoptedSchedule
        calendarCleanupPending = !snapshot.calendarCleanupEventIDs.isEmpty
        notificationCleanupPending = !snapshot.notificationCleanupIDs.isEmpty
        notificationActionsPending = !snapshot.pendingNotificationResponses.isEmpty
        calendarAuthorization = calendarStore.authorization
        refreshCalendarChoices()
        notificationAuthorization = notificationStore.authorization
        syncAvailability = syncStore.availability
        do {
            try await notificationStore.replaceTaskReminders(
                RuntimeTaskReminder.build(
                    tasks: snapshot.tasks, adopted: snapshot.adoptedSchedule,
                    timezone: timezone), now: now())
            taskRemindersNeedAttention = false
        } catch { taskRemindersNeedAttention = true }
        let activeProposal = snapshot.adoptedSchedule?.proposal ?? snapshot.latestProposal
        morningDigest = RuntimeMorningDigestBuilder.build(
            for: now(),
            tasks: snapshot.tasks,
            proposal: activeProposal,
            timezone: timezone
        )
        validateConversation(tasks: snapshot.tasks)
        if let stale = morningDigest?.items.filter(\.isStale).max(by: { $0.daysOnDeck < $1.daysOnDeck }) {
            let text = RuntimeInteraction.reviewText(task: stale.task, days: stale.daysOnDeck)
            if reviewQuestion?.text != text
                || reviewQuestion?.isValid(tasks: snapshot.tasks, day: day(now()), timezone: timezone.identifier)
                    != true
            {
                reviewQuestion = RuntimePendingQuestion(
                    kind: .taskReview, text: text,
                    taskIDs: [stale.taskID], tasks: snapshot.tasks, day: day(now()), timezone: timezone.identifier)
            }
        } else {
            reviewQuestion = nil
        }
        if conversationMessages.isEmpty, let pending = conversationState.pending {
            appendConversationMessage(author: .hob, text: pending.text)
        }
        await refreshMorningDigestNotifications(
            tasks: snapshot.tasks,
            proposal: activeProposal
        )
        await refreshEveningRecapNotifications(
            tasks: snapshot.tasks,
            proposal: activeProposal
        )
    }

    private func refreshMorningDigestNotifications(
        tasks: [RuntimeTask]? = nil,
        proposal: RuntimeScheduleProposal? = nil
    ) async {
        guard morningDigestEnabled,
            notificationStore.authorization == .authorized
        else {
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

    private func refreshEveningRecapNotifications(
        tasks: [RuntimeTask]? = nil,
        proposal: RuntimeScheduleProposal? = nil
    ) async {
        guard eveningRecapEnabled,
            notificationStore.authorization == .authorized
        else {
            await notificationStore.cancelEveningRecaps()
            eveningRecapNeedsAttention = false
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
            await notificationStore.cancelEveningRecaps()
            return
        }
        do {
            try await notificationStore.replaceEveningRecaps(
                RuntimeMorningDigestBuilder.upcoming(
                    from: now(),
                    days: 7,
                    tasks: resolvedTasks,
                    proposal: resolvedProposal,
                    timezone: timezone
                ),
                time: eveningRecapTime,
                now: now()
            )
            eveningRecapNeedsAttention = false
        } catch {
            eveningRecapNeedsAttention = true
        }
    }

    private func run(
        processPendingResponsesAfterward: Bool = true,
        recordsErrorsInConversation: Bool = false,
        _ operation: @escaping () async throws -> Void
    ) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer {
                isWorking = false
                if processPendingResponsesAfterward,
                    notificationActionsPending
                {
                    processNotificationResponses()
                }
            }
            do {
                try await operation()
            } catch RuntimeInterpretationError.modelUnavailable {
                errorMessage = "Apple Intelligence is unavailable. Check that it is enabled and ready."
            } catch RuntimeInterpretationError.clarification(let question) {
                publishConversationReply(question)
            } catch RuntimeInterpretationError.question(let request) {
                publishConversationReply(request.text)
            } catch RuntimeInterpretationError.invalidOutput {
                errorMessage = "I could not safely interpret that message. Nothing changed."
            } catch RuntimeScheduleError.staleProposal {
                errorMessage = "The tasks changed after this plan was made. Build a fresh plan first."
            } catch RuntimeScheduleError.calendarCleanupPending {
                errorMessage = "Finish removing old reminders before adopting a new plan."
            } catch RuntimeCalendarError.permissionDenied {
                errorMessage = "Calendar access is off. Review Calendar settings."
            } catch RuntimeCalendarError.removalFailed {
                errorMessage = "Calendar could not remove every Hob block. Try again before replanning."
            } catch RuntimeCalendarError.unavailable {
                errorMessage = "Calendar is unavailable. Review Calendar settings."
            } catch RuntimeCalendarError.selectionUnavailable {
                errorMessage = "A calendar Hob plans around is unavailable. Review Calendar settings."
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
            // A task commit can succeed even if a later Calendar or sync step
            // fails. Always reconcile visible state and alerts before returning.
            await refresh()
            if recordsErrorsInConversation, let errorMessage {
                appendConversationMessage(
                    author: .hob,
                    text: errorMessage,
                    isError: true
                )
            }
        }
    }

    private func scheduleRequest(
        at instant: Date,
        includedUntimedTaskIDs: [String]? = nil,
        horizonDays: Int = 7
    ) throws -> RuntimeScheduleRequest {
        let preferences = RuntimePlanningPreferences.default
        let end =
            gregorianCalendar.date(
                byAdding: .day,
                value: horizonDays,
                to: instant
            ) ?? instant.addingTimeInterval(Double(horizonDays) * 86_400)
        let busy =
            calendarIntegrationEnabled
                && calendarStore.authorization == .fullAccess
            ? try calendarStore.busyIntervals(
                from: instant,
                to: end,
                timezone: timezone,
                calendarIDs: inputCalendarIDs,
                blockAllDayEvents: blockAllDayEvents,
                excludingProposalID: adoptedSchedule?.proposal.id
            )
            : []
        return RuntimeScheduleRequest(
            proposalID: UUID().uuidString,
            generatedAt: timestamp(instant),
            startDate: day(instant),
            timezone: timezone.identifier,
            horizonDays: horizonDays,
            workStart: preferences.workStart,
            workEnd: preferences.workEnd,
            defaultDurationMinutes: preferences.defaultDurationMinutes,
            transitionBufferMinutes: preferences.transitionBufferMinutes,
            workDays: preferences.workDays,
            busy: busy,
            includedUntimedTaskIDs: includedUntimedTaskIDs
                ?? proposal?.plannedUntimedTaskIDs
                ?? adoptedSchedule?.proposal.plannedUntimedTaskIDs
                ?? []
        )
    }

    private func refreshCalendarChoices() {
        guard calendarIntegrationEnabled,
            calendarStore.authorization == .fullAccess
        else {
            calendars = []
            return
        }
        do {
            calendars = try calendarStore.calendars()
        } catch {
            calendars = []
        }
    }

    private func persistCalendarPreferences() {
        if let inputCalendarIDs {
            defaults.set(
                inputCalendarIDs.sorted(),
                forKey: DefaultsKey.inputCalendarIDs
            )
        } else {
            defaults.removeObject(forKey: DefaultsKey.inputCalendarIDs)
        }
        defaults.set(blockAllDayEvents, forKey: DefaultsKey.blockAllDayEvents)
    }

    private func cleanupCalendarEventsIfNeeded(force: Bool = false) async throws {
        guard calendarIntegrationEnabled || force else { return }
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
        guard let currentTask = snapshot.tasks.first(where: { $0.id == response.taskID }),
            currentTask.status == "open"
        else {
            notice = "That reminder is no longer current."
            return
        }
        let validRevision =
            response.taskRevision.map { $0 == currentTask.revision }
            ?? (snapshot.adoptedSchedule?.proposal.id == response.proposalID
                && snapshot.adoptedSchedule?.proposal.taskVersions[response.taskID] == currentTask.revision)
        guard validRevision else {
            notice = "That reminder is no longer current."
            return
        }
        switch response.action {
        case .done:
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
            let key = "hob.snooze.v2.\(response.proposalID).\(response.blockID)"
            let saved = defaults.dictionary(forKey: key)
            if saved?["revision"] as? String == currentTask.revision,
                saved?["responseID"] as? String == response.id
            {
                notice = "That snooze was already saved."
                return
            }
            let prior =
                saved?["revision"] as? String == currentTask.revision
                ? (saved?["count"] as? Int ?? 0) : 0
            let step = RuntimeSnoozeSequence.step(after: prior)
            if let minutes = step.minutes {
                try await notificationStore.snooze(
                    response: response,
                    minutes: minutes
                )
                let next = step.nextLabel.map { " Next snooze: \($0)." } ?? ""
                notice = "Snoozed \(response.task) for \(step.label)." + next
            } else {
                notice = "Snoozed \(response.task) indefinitely. It stays on deck."
            }
            // Advance only after scheduling succeeded; retry the same step on failure.
            defaults.set(
                ["revision": currentTask.revision, "count": prior + 1, "responseID": response.id], forKey: key)
        case .replan:
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
        let result = try await runtime.process(
            RuntimeTurnRequest(
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
        await refresh()
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

    private func updateRecurrence(taskID: String, operation: String) {
        run {
            guard let runtime = self.runtime else { return }
            let snapshot = await runtime.snapshot()
            guard
                let task = snapshot.tasks.first(where: {
                    $0.id == taskID && $0.status == "open" && $0.recurrence != nil
                })
            else {
                self.notice = "That repeating task is no longer open."
                await self.refresh()
                return
            }
            self.planningAnalysis = nil
            let instant = self.now()
            let occurredAt = self.timestamp(instant)
            let requestID = UUID().uuidString
            let result = try await runtime.process(
                RuntimeTurnRequest(
                    requestID: requestID,
                    message: operation == "skip" ? "Skip occurrence" : "Stop repeating",
                    now: occurredAt,
                    timezone: self.timezone.identifier,
                    actions: [
                        RuntimeAction(
                            type: "recurrence",
                            target: taskID,
                            recurrenceOperation: operation
                        )
                    ]
                ))
            try? await runtime.markDelivered(
                dedupeKey: "turn:\(requestID)",
                at: occurredAt
            )
            guard result.outcome.disposition == .applied else {
                self.notice = "That recurrence could not be changed."
                return
            }
            try await self.cleanupCalendarEventsIfNeeded()
            try await self.cleanupNotificationsIfNeeded()
            _ = try await runtime.proposeSchedule(
                try self.scheduleRequest(at: instant)
            )
            await self.syncTasks()
            if operation == "skip",
                let updated = result.outcome.tasks.first(where: { $0.id == taskID })
            {
                self.notice = "Next: \(updated.task)\(updated.dueDate.map { " on \($0)" } ?? "")."
            } else {
                self.notice = "Stopped repeating: \(task.task)."
            }
            await self.refresh()
        }
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
                target =
                    action.target
                    ?? [
                        "task",
                        String(milliseconds),
                        String(format: "%02d", index),
                        UUID().uuidString.lowercased(),
                    ].joined(separator: "-")
            } else if let raw = action.target,
                let position = Int(raw),
                open.indices.contains(position - 1)
            {
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
                recurrence: action.recurrence,
                recurrenceOperation: action.recurrenceOperation,
                note: action.note,
                clearFields: action.clearFields,
                reviewPolicy: action.reviewPolicy,
                queryKind: action.queryKind,
                queryTerm: action.queryTerm,
                queryPeriod: action.queryPeriod,
                analysisKind: action.analysisKind,
                horizonDays: action.horizonDays,
                budgetMinutes: action.budgetMinutes,
                hypotheticalDurationMinutes: action.hypotheticalDurationMinutes,
                reply: action.reply,
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
            let runtime
        else { return }
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
            syncAttentionMessage = nil
            await refresh()
        } catch {
            syncNeedsAttention = true
            syncAttentionMessage = syncMessage(for: error)
        }
    }

    private func syncMessage(for error: Error) -> String {
        guard let error = error as? RuntimeTaskSyncError else {
            return "Couldn’t sync tasks. Try again."
        }
        switch error {
        case .accountUnavailable:
            return "Sign in to iCloud to sync tasks."
        case .invalidRemoteData:
            return "Some iCloud task data could not be read."
        case .conflict:
            return "Task history conflicts across devices."
        case .transportFailed:
            return "Task history is too large to sync."
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
