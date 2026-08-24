// SPDX-License-Identifier: MIT
import EventKit
import Foundation
#if canImport(HobAppCore)
import HobAppCore
#endif

@MainActor
public final class EventKitScheduleStore: RuntimeCalendarScheduling {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public var authorization: RuntimeCalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return .fullAccess
        case .denied, .writeOnly:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    public func requestAccess() async throws -> RuntimeCalendarAuthorization {
        let granted = try await store.requestFullAccessToEvents()
        return granted ? .fullAccess : .denied
    }

    public func calendars() throws -> [RuntimeCalendarDescriptor] {
        guard authorization == .fullAccess else {
            throw RuntimeCalendarError.permissionDenied
        }
        return store.calendars(for: .event)
            .map(descriptor)
            .sorted {
                let sourceOrder = $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle)
                if sourceOrder == .orderedSame {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return sourceOrder == .orderedAscending
            }
    }

    public func busyIntervals(
        from start: Date,
        to end: Date,
        timezone: TimeZone,
        calendarIDs: Set<String>?,
        blockAllDayEvents: Bool,
        excludingProposalID: String?
    ) throws -> [RuntimeBusyInterval] {
        guard authorization == .fullAccess else {
            throw RuntimeCalendarError.permissionDenied
        }
        guard end > start else { throw RuntimeCalendarError.invalidSchedule }
        let selectedCalendars: [EKCalendar]?
        if let calendarIDs {
            guard !calendarIDs.isEmpty else { return [] }
            selectedCalendars = calendarIDs.compactMap(store.calendar(withIdentifier:))
            guard selectedCalendars?.count == calendarIDs.count else {
                throw RuntimeCalendarError.selectionUnavailable
            }
        } else {
            selectedCalendars = nil
        }
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: selectedCalendars
        )
        return store.events(matching: predicate)
            .filter {
                $0.endDate > $0.startDate
                    && EventKitBusyEventPolicy.blocksTime(
                        isAllDay: $0.isAllDay,
                        isCanceled: $0.status == .canceled,
                        isFree: $0.availability == .free,
                        url: $0.url,
                        blockAllDayEvents: blockAllDayEvents,
                        excludingProposalID: excludingProposalID
                    )
            }
            .map {
                RuntimeBusyInterval(
                    startAt: timestamp($0.startDate, timezone: timezone),
                    endAt: timestamp($0.endDate, timezone: timezone)
                )
            }
            .sorted { $0.startAt < $1.startAt }
    }

    public func write(
        _ proposal: RuntimeScheduleProposal,
        calendarID: String?
    ) throws -> [String] {
        guard authorization == .fullAccess else {
            throw RuntimeCalendarError.permissionDenied
        }
        let calendar = calendarID.flatMap(store.calendar(withIdentifier:))
            ?? (calendarID == nil ? store.defaultCalendarForNewEvents : nil)
        guard RuntimeScheduleValidator.valid(proposal),
              let calendar,
              calendar.allowsContentModifications
        else { throw RuntimeCalendarError.unavailable }

        var events: [EKEvent] = []
        do {
            for block in proposal.blocks {
                guard let start = ISO8601DateFormatter().date(from: block.startAt),
                      let end = ISO8601DateFormatter().date(from: block.endAt),
                      end > start
                else { throw RuntimeCalendarError.invalidSchedule }
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = block.task
                event.startDate = start
                event.endDate = end
                event.notes = "Scheduled by Hob"
                event.url = URL(string: "hob://schedule/\(proposal.id)/\(block.id)")
                try store.save(event, span: .thisEvent, commit: false)
                events.append(event)
            }
            try store.commit()
        } catch let error as RuntimeCalendarError {
            store.reset()
            throw error
        } catch {
            store.reset()
            throw RuntimeCalendarError.writeFailed
        }

        let identifiers = events.compactMap(\.eventIdentifier)
        guard identifiers.count == events.count else {
            try? remove(eventIDs: identifiers)
            throw RuntimeCalendarError.writeFailed
        }
        return identifiers
    }

    public func createHobCalendar() throws -> RuntimeCalendarDescriptor {
        guard authorization == .fullAccess else {
            throw RuntimeCalendarError.permissionDenied
        }
        guard let source = store.defaultCalendarForNewEvents?.source,
              source.sourceType != .subscribed,
              source.sourceType != .birthdays
        else { throw RuntimeCalendarError.unavailable }

        if let existing = store.calendars(for: .event).first(where: {
            $0.title == "Hob"
                && $0.source.sourceIdentifier == source.sourceIdentifier
                && $0.allowsContentModifications
        }) {
            return descriptor(existing)
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Hob"
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
            return descriptor(calendar)
        } catch {
            throw RuntimeCalendarError.writeFailed
        }
    }

    public func remove(eventIDs: [String]) throws {
        guard authorization == .fullAccess else {
            throw RuntimeCalendarError.permissionDenied
        }
        do {
            for identifier in eventIDs {
                guard let event = store.event(withIdentifier: identifier) else { continue }
                try store.remove(event, span: .thisEvent, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()
            throw RuntimeCalendarError.removalFailed
        }
    }

    private func timestamp(_ date: Date, timezone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.string(from: date)
    }

    private func descriptor(_ calendar: EKCalendar) -> RuntimeCalendarDescriptor {
        RuntimeCalendarDescriptor(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            sourceTitle: calendar.source.title,
            allowsContentModifications: calendar.allowsContentModifications,
            isSubscribed: calendar.source.sourceType == .subscribed
        )
    }

}

enum EventKitBusyEventPolicy {
    static func blocksTime(
        isAllDay: Bool,
        isCanceled: Bool,
        isFree: Bool,
        url: URL?,
        blockAllDayEvents: Bool,
        excludingProposalID: String?
    ) -> Bool {
        guard !isCanceled,
              !isFree,
              blockAllDayEvents || !isAllDay
        else { return false }
        guard let excludingProposalID,
              let url,
              url.scheme == "hob",
              url.host == "schedule"
        else { return true }
        return url.pathComponents.dropFirst().first != excludingProposalID
    }
}
