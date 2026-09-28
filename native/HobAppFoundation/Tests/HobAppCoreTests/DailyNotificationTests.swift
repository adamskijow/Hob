// SPDX-License-Identifier: MIT
import Foundation
import Testing
import UserNotifications
@testable import HobNotifications
import HobAppCore

@MainActor private final class TestNotificationCenter: NotificationCenterClient {
    var delegate: (any UNUserNotificationCenterDelegate)?
    var requests: [String: UNNotificationRequest] = [:]
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func pendingNotificationRequests() async -> [UNNotificationRequest] { Array(requests.values) }
    func deliveredRequests() async -> [UNNotificationRequest] { [] }
    func add(_ request: UNNotificationRequest) async throws { requests[request.identifier] = request }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        for identifier in identifiers { requests.removeValue(forKey: identifier) }
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
}

@Test @MainActor func morningAndEveningActuallyScheduleAndCancelOnThisPlatform() async throws {
    let center = TestNotificationCenter()
    let scheduler = LocalNotificationScheduler(client: center)
    _ = await scheduler.refreshAuthorization()
    try await scheduler.replaceMorningDigests([], time: "07:15", now: Date())
    try await scheduler.replaceEveningRecaps([], time: "20:30", now: Date())
    #expect(center.requests.count == 2)
    #expect(center.requests.values.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.repeats == true })
    try await scheduler.replaceMorningDigests([], time: "08:45", now: Date())
    #expect(center.requests.count == 2)
    let morning = try #require(center.requests.values.first { $0.identifier.hasPrefix("hob.morning.") })
    #expect((morning.trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour == 8)
    await scheduler.cancelMorningDigests()
    #expect(center.requests.count == 1)
    await scheduler.cancelEveningRecaps()
    #expect(center.requests.isEmpty)
}

@Test @MainActor func dailyCheckInsRepeatWithoutASevenDayExpiry() throws {
    let request = try LocalNotificationScheduler.dailyRequest(time: "20:15", timezone: "America/New_York",
        identifierPrefix: "hob.evening.", title: "What got done today?")
    let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
    #expect(trigger.repeats)
    #expect(trigger.dateComponents.year == nil)
    #expect(trigger.dateComponents.day == nil)
    #expect(trigger.dateComponents.hour == 20)
    #expect(trigger.dateComponents.minute == 15)
    #expect(trigger.nextTriggerDate() != nil)
    #expect(request.content.body.contains("Open Hob"))
    #expect(request.content.body.contains("review today"))
}
