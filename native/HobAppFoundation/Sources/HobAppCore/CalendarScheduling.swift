// SPDX-License-Identifier: MIT
import Foundation

public enum RuntimeCalendarAuthorization: String, Codable, Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
    case restricted
}

public enum RuntimeCalendarError: Error, Equatable, Sendable {
    case permissionDenied
    case unavailable
    case invalidSchedule
    case selectionUnavailable
    case writeFailed
    case removalFailed
}

public struct RuntimeCalendarDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceTitle: String
    public let allowsContentModifications: Bool
    public let isSubscribed: Bool

    public init(
        id: String,
        title: String,
        sourceTitle: String,
        allowsContentModifications: Bool,
        isSubscribed: Bool
    ) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.allowsContentModifications = allowsContentModifications
        self.isSubscribed = isSubscribed
    }
}

@MainActor
public protocol RuntimeCalendarScheduling: AnyObject {
    var authorization: RuntimeCalendarAuthorization { get }

    func requestAccess() async throws -> RuntimeCalendarAuthorization

    func calendars() throws -> [RuntimeCalendarDescriptor]

    func busyIntervals(
        from start: Date,
        to end: Date,
        timezone: TimeZone,
        calendarIDs: Set<String>?,
        blockAllDayEvents: Bool,
        excludingProposalID: String?
    ) throws -> [RuntimeBusyInterval]

    func write(
        _ proposal: RuntimeScheduleProposal,
        calendarID: String?
    ) throws -> [String]

    func createHobCalendar() throws -> RuntimeCalendarDescriptor

    func remove(eventIDs: [String]) throws
}
