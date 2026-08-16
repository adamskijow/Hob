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
    case writeFailed
    case removalFailed
}

@MainActor
public protocol RuntimeCalendarScheduling: AnyObject {
    var authorization: RuntimeCalendarAuthorization { get }

    func requestAccess() async throws -> RuntimeCalendarAuthorization

    func busyIntervals(
        from start: Date,
        to end: Date,
        timezone: TimeZone
    ) throws -> [RuntimeBusyInterval]

    func write(_ proposal: RuntimeScheduleProposal) throws -> [String]

    func remove(eventIDs: [String]) throws
}
