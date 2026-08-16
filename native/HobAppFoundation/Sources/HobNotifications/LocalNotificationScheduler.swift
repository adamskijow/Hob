// SPDX-License-Identifier: MIT
import Foundation
@preconcurrency import UserNotifications
#if canImport(HobAppCore)
import HobAppCore
#endif

@MainActor
public final class LocalNotificationScheduler: RuntimeNotificationScheduling {
    fileprivate enum Identifier {
        static let category = "HOB_SCHEDULE_BLOCK"
        static let done = "HOB_DONE"
        static let snooze = "HOB_SNOOZE"
        static let replan = "HOB_REPLAN"
    }

    private let center: UNUserNotificationCenter
    private let router: NotificationResponseRouter
    public private(set) var authorization: RuntimeNotificationAuthorization = .notDetermined

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        self.router = NotificationResponseRouter()
        center.delegate = router
        center.setNotificationCategories([Self.category])
    }

    public func refreshAuthorization() async -> RuntimeNotificationAuthorization {
        authorization = Self.map(await center.notificationSettings().authorizationStatus)
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
                    taskID: block.taskID
                )
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timezone
                let components = calendar.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                    from: start
                )
                try await center.add(UNNotificationRequest(
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
        guard response.isValid, (1...240).contains(minutes) else {
            throw RuntimeNotificationError.invalidRequest
        }
        let content = Self.content(
            task: response.task,
            duration: nil,
            proposalID: response.proposalID,
            blockID: response.blockID,
            taskID: response.taskID
        )
        do {
            try await center.add(UNNotificationRequest(
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

    public func cancel(notificationIDs: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: notificationIDs)
        center.removeDeliveredNotifications(withIdentifiers: notificationIDs)
    }

    public func setActionHandler(
        _ handler: @escaping @MainActor @Sendable (
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
                    title: "Snooze 15m"
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
        taskID: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Time for \(task)"
        content.body = duration.map { "\($0) minutes scheduled." }
            ?? "Ready when you are."
        content.sound = .default
        content.categoryIdentifier = Identifier.category
        content.userInfo = [
            "proposalID": proposalID,
            "blockID": blockID,
            "taskID": taskID,
            "task": task,
        ]
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
}

@MainActor
private final class NotificationResponseRouter: NSObject, UNUserNotificationCenterDelegate {
    private var handler: (@MainActor @Sendable (
        RuntimeNotificationResponse
    ) async -> Void)?
    private var buffered: [RuntimeNotificationResponse] = []

    func setHandler(
        _ handler: @escaping @MainActor @Sendable (
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
        guard request.content.categoryIdentifier
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
            receivedAt: ISO8601DateFormatter().string(from: Date())
        )
        return decoded.isValid ? decoded : nil
    }
}
