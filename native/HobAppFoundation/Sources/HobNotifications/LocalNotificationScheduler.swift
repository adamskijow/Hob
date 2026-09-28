// SPDX-License-Identifier: MIT
import Foundation
@preconcurrency import UserNotifications

#if canImport(HobAppCore)
    import HobAppCore
#endif

/// The same scheduler runs on both platforms; tests supply a center without
/// touching the user's notification permissions or delivered reminders.
@MainActor
protocol NotificationCenterClient: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func deliveredRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: NotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func deliveredRequests() async -> [UNNotificationRequest] {
        await deliveredNotifications().map(\.request)
    }
}

@MainActor
public final class LocalNotificationScheduler: RuntimeNotificationScheduling {
    fileprivate enum Identifier {
        static let category = "HOB_SCHEDULE_BLOCK"
        static let morningPrefix = "hob.morning."
        static let eveningPrefix = "hob.evening."
        static let done = "HOB_DONE"
        static let snooze = "HOB_SNOOZE"
        static let replan = "HOB_REPLAN"
    }

    private let center: any NotificationCenterClient
    private let router: NotificationResponseRouter
    private var reminderReconciliation: Task<Void, Error>?
    public private(set) var authorization: RuntimeNotificationAuthorization = .notDetermined

    public convenience init(center: UNUserNotificationCenter = .current()) {
        self.init(client: center)
    }

    init(client center: any NotificationCenterClient) {
        self.center = center
        self.router = NotificationResponseRouter()
        center.delegate = router
        center.setNotificationCategories([Self.category])
    }

    public func refreshAuthorization() async -> RuntimeNotificationAuthorization {
        authorization = Self.map(await center.authorizationStatus())
        return authorization
    }

    public func requestAccess() async throws -> RuntimeNotificationAuthorization {
        let granted = try await center.requestAuthorization(
            options: [.alert, .sound, .badge]
        )
        authorization = granted ? .authorized : .denied
        return authorization
    }

    public func schedule(
        proposal: RuntimeScheduleProposal,
        now: Date
    ) async throws -> [String] {
        guard authorization == .authorized else {
            throw RuntimeNotificationError.permissionDenied
        }
        guard RuntimeScheduleValidator.valid(proposal),
            let timezone = TimeZone(identifier: proposal.timezone)
        else { throw RuntimeNotificationError.invalidRequest }

        var scheduled: [String] = []
        do {
            for block in proposal.blocks {
                guard let start = ISO8601DateFormatter().date(from: block.startAt)
                else { throw RuntimeNotificationError.invalidRequest }
                guard start > now else { continue }
                let identifier = "hob.\(proposal.id).\(block.id)"
                let content = Self.content(
                    task: block.task,
                    duration: block.durationMinutes,
                    proposalID: proposal.id,
                    blockID: block.id,
                    taskID: block.taskID,
                    revision: proposal.taskVersions[block.taskID]
                )
                content.userInfo["fireAt"] = ISO8601DateFormatter().string(from: start)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timezone
                let components = calendar.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                    from: start
                )
                try await center.add(
                    UNNotificationRequest(
                        identifier: identifier,
                        content: content,
                        trigger: UNCalendarNotificationTrigger(
                            dateMatching: components,
                            repeats: false
                        )
                    ))
                scheduled.append(identifier)
            }
            return scheduled
        } catch let error as RuntimeNotificationError {
            cancel(notificationIDs: scheduled)
            throw error
        } catch {
            cancel(notificationIDs: scheduled)
            throw RuntimeNotificationError.schedulingFailed
        }
    }

    public func snooze(
        response: RuntimeNotificationResponse,
        minutes: Int
    ) async throws {
        guard authorization == .authorized else {
            throw RuntimeNotificationError.permissionDenied
        }
        guard response.isValid, (1...1_440).contains(minutes) else {
            throw RuntimeNotificationError.invalidRequest
        }
        let content = Self.content(
            task: response.task,
            duration: nil,
            proposalID: response.proposalID,
            blockID: response.blockID,
            taskID: response.taskID,
            revision: response.taskRevision
        )
        content.userInfo["snoozed"] = true
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: response.notificationID,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(
                        timeInterval: TimeInterval(minutes * 60),
                        repeats: false
                    )
                ))
        } catch {
            throw RuntimeNotificationError.schedulingFailed
        }
    }

    public func replaceMorningDigests(
        _ digests: [RuntimeMorningDigest],
        time: String,
        now: Date
    ) async throws {
        try await replaceDailyNotifications(
            digests,
            time: time,
            identifierPrefix: Identifier.morningPrefix,
            title: "Morning. Here is today."
        )
    }

    public func cancelMorningDigests() async {
        await cancelDailyNotifications(prefix: Identifier.morningPrefix)
    }

    public func replaceEveningRecaps(
        _ digests: [RuntimeMorningDigest],
        time: String,
        now: Date
    ) async throws {
        try await replaceDailyNotifications(
            digests,
            time: time,
            identifierPrefix: Identifier.eveningPrefix,
            title: "What got done today?"
        )
    }

    public func cancelEveningRecaps() async {
        await cancelDailyNotifications(prefix: Identifier.eveningPrefix)
    }

    private func cancelDailyNotifications(prefix: String) async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredRequests()
        let identifiers = (pending.map(\.identifier) + delivered.map(\.identifier)).filter {
            $0.hasPrefix(prefix)
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func replaceDailyNotifications(
        _ digests: [RuntimeMorningDigest],
        time: String,
        identifierPrefix: String,
        title: String
    ) async throws {
        guard authorization == .authorized else {
            throw RuntimeNotificationError.permissionDenied
        }
        let request = try Self.dailyRequest(
            time: time,
            timezone: digests.first?.timezone ?? TimeZone.current.identifier,
            identifierPrefix: identifierPrefix, title: title)
        await cancelDailyNotifications(prefix: identifierPrefix)
        do {
            try await center.add(request)
        } catch {
            throw RuntimeNotificationError.schedulingFailed
        }
    }

    static func dailyRequest(time: String, timezone: String, identifierPrefix: String, title: String) throws
        -> UNNotificationRequest
    {
        guard let clock = clock(time), let zone = TimeZone(identifier: timezone) else {
            throw RuntimeNotificationError.invalidRequest
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body =
            identifierPrefix == Identifier.eveningPrefix
            ? "Open Hob to review today and tell me what got done."
            : "Open Hob to see what’s on deck today."
        content.sound = .default
        var components = DateComponents()
        components.timeZone = zone
        components.hour = clock.hour
        components.minute = clock.minute
        return UNNotificationRequest(
            identifier: identifierPrefix + "daily", content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
    }

    public func replaceTaskReminders(_ reminders: [RuntimeTaskReminder], now: Date) async throws {
        let previous = reminderReconciliation
        let next = Task { @MainActor in
            _ = try? await previous?.value
            try await self.reconcile(reminders, now: now)
        }
        reminderReconciliation = next
        try await next.value
    }

    private func reconcile(_ reminders: [RuntimeTaskReminder], now: Date) async throws {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredRequests()
        let desired = Dictionary(uniqueKeysWithValues: reminders.map { ($0.identifier, $0) })
        let managed = (pending + delivered).filter { $0.content.categoryIdentifier == Identifier.category }
        func matches(_ request: UNNotificationRequest, _ reminder: RuntimeTaskReminder) -> Bool {
            request.content.userInfo["taskRevision"] as? String == reminder.revision
                && (request.content.userInfo["snoozed"] as? Bool == true
                    || request.content.userInfo["fireAt"] as? String
                        == ISO8601DateFormatter().string(from: reminder.fireAt))
        }
        cancel(
            notificationIDs: managed.filter {
                guard let reminder = desired[$0.identifier] else { return true }
                return !matches($0, reminder)
            }.map(\.identifier))
        guard authorization == .authorized else { return }
        for reminder in reminders where reminder.fireAt > now {
            if managed.contains(where: { $0.identifier == reminder.identifier && matches($0, reminder) }) { continue }
            let content = Self.content(
                task: reminder.task, duration: reminder.duration,
                proposalID: reminder.proposalID, blockID: reminder.blockID,
                taskID: reminder.taskID, revision: reminder.revision)
            content.userInfo["fireAt"] = ISO8601DateFormatter().string(from: reminder.fireAt)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: reminder.timezone) ?? .current
            do {
                try await center.add(
                    UNNotificationRequest(
                        identifier: reminder.identifier, content: content,
                        trigger: UNCalendarNotificationTrigger(
                            dateMatching: calendar.dateComponents(
                                [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: reminder.fireAt),
                            repeats: false)))
            } catch { throw RuntimeNotificationError.schedulingFailed }
        }
    }

    public func cancel(notificationIDs: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: notificationIDs)
        center.removeDeliveredNotifications(withIdentifiers: notificationIDs)
    }

    public func setActionHandler(
        _ handler:
            @escaping @MainActor @Sendable (
                RuntimeNotificationResponse
            ) async -> Void
    ) {
        router.setHandler(handler)
    }

    private static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: Identifier.category,
            actions: [
                UNNotificationAction(
                    identifier: Identifier.done,
                    title: "Done",
                    options: [.authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: Identifier.snooze,
                    title: "Snooze longer"
                ),
                UNNotificationAction(
                    identifier: Identifier.replan,
                    title: "Replan",
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: []
        )
    }

    private static func content(
        task: String,
        duration: Int?,
        proposalID: String,
        blockID: String,
        taskID: String,
        revision: String? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Time for \(task)"
        content.body =
            duration.map { "\($0) minutes scheduled." }
            ?? "Ready when you are."
        content.sound = .default
        content.categoryIdentifier = Identifier.category
        content.userInfo = [
            "proposalID": proposalID,
            "blockID": blockID,
            "taskID": taskID,
            "task": task,
        ]
        if let revision { content.userInfo["taskRevision"] = revision }
        return content
    }

    private static func map(
        _ status: UNAuthorizationStatus
    ) -> RuntimeNotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    private static func clock(_ value: String) -> (hour: Int, minute: Int)? {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
            pieces[0].count == 2,
            pieces[1].count == 2,
            let hour = Int(pieces[0]),
            let minute = Int(pieces[1]),
            (0...23).contains(hour),
            (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }

}

@MainActor
private final class NotificationResponseRouter: NSObject, UNUserNotificationCenterDelegate {
    private var handler:
        (
            @MainActor @Sendable (
                RuntimeNotificationResponse
            ) async -> Void
        )?
    private var buffered: [RuntimeNotificationResponse] = []

    func setHandler(
        _ handler:
            @escaping @MainActor @Sendable (
                RuntimeNotificationResponse
            ) async -> Void
    ) {
        self.handler = handler
        let pending = buffered
        buffered.removeAll()
        Task {
            for response in pending {
                await handler(response)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let decoded = Self.decode(response) else { return }
        await deliver(decoded)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func deliver(_ response: RuntimeNotificationResponse) async {
        if let handler {
            await handler(response)
        } else if buffered.count < 100 {
            buffered.append(response)
        }
    }

    nonisolated private static func decode(
        _ response: UNNotificationResponse
    ) -> RuntimeNotificationResponse? {
        let action: RuntimeNotificationAction
        switch response.actionIdentifier {
        case LocalNotificationScheduler.Identifier.done: action = .done
        case LocalNotificationScheduler.Identifier.snooze: action = .snooze
        case LocalNotificationScheduler.Identifier.replan: action = .replan
        default: return nil
        }
        let request = response.notification.request
        guard
            request.content.categoryIdentifier
                == LocalNotificationScheduler.Identifier.category,
            let proposalID = request.content.userInfo["proposalID"] as? String,
            let blockID = request.content.userInfo["blockID"] as? String,
            let taskID = request.content.userInfo["taskID"] as? String,
            let task = request.content.userInfo["task"] as? String
        else { return nil }
        let decoded = RuntimeNotificationResponse(
            id: UUID().uuidString,
            action: action,
            notificationID: request.identifier,
            proposalID: proposalID,
            blockID: blockID,
            taskID: taskID,
            task: task,
            receivedAt: ISO8601DateFormatter().string(from: Date()),
            taskRevision: request.content.userInfo["taskRevision"] as? String
        )
        return decoded.isValid ? decoded : nil
    }
}
