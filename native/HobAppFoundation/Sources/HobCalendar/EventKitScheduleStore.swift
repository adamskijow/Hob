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

    public func busyIntervals(
        from start: Date,
        to end: Date,
        timezone: TimeZone
    ) throws -> [RuntimeBusyInterval] {
        guard authorization == .fullAccess else {
            throw RuntimeCalendarError.permissionDenied
        }
        guard end > start else { throw RuntimeCalendarError.invalidSchedule }
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > $0.startDate }
            .map {
                RuntimeBusyInterval(
                    startAt: timestamp($0.startDate, timezone: timezone),
                    endAt: timestamp($0.endDate, timezone: timezone)
                )
            }
    }

    public func write(_ proposal: RuntimeScheduleProposal) throws -> [String] {
        guard authorization == .fullAccess else {
            throw RuntimeCalendarError.permissionDenied
        }
        guard RuntimeScheduleValidator.valid(proposal),
              let calendar = store.defaultCalendarForNewEvents
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
}
