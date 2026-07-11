// SPDX-License-Identifier: MIT
import EventKit
import Foundation

private let iso = ISO8601DateFormatter()

private func emit(_ object: [String: Any], exitCode: Int32 = 0) -> Never {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("calendar bridge JSON error: \(error)\n".utf8))
    }
    exit(exitCode)
}

private func authorizationName() -> String {
    let status = EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .notDetermined:
        return "not_determined"
    case .restricted:
        return "restricted"
    case .denied:
        return "denied"
    case .authorized:
        return "authorized"
    case .fullAccess:
        return "authorized"
    case .writeOnly:
        return "write_only"
    @unknown default:
        return "unavailable"
    }
}

private func parseDate(_ value: String) -> Date? {
    if let parsed = iso.date(from: value) {
        return parsed
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
    return formatter.date(from: value)
}

private let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    emit(["status": "unavailable", "detail": "missing command"], exitCode: 2)
}

if command == "status" {
    emit(["status": authorizationName()])
}

if command == "request-access" {
    let store = EKEventStore()
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    var failure: String?
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { allowed, error in
            granted = allowed
            failure = error?.localizedDescription
            semaphore.signal()
        }
    } else {
        store.requestAccess(to: .event) { allowed, error in
            granted = allowed
            failure = error?.localizedDescription
            semaphore.signal()
        }
    }
    if semaphore.wait(timeout: .now() + 120) == .timedOut {
        emit(["status": "unavailable", "detail": "calendar permission request timed out"], exitCode: 1)
    }
    var response: [String: Any] = ["status": granted ? "authorized" : authorizationName()]
    if let failure { response["detail"] = failure }
    emit(response, exitCode: granted ? 0 : 1)
}

if command == "events" {
    guard arguments.count == 3,
          let start = parseDate(arguments[1]),
          let end = parseDate(arguments[2]),
          end > start else {
        emit(["status": "unavailable", "detail": "events requires valid start and end timestamps"], exitCode: 2)
    }
    guard authorizationName() == "authorized" else {
        emit(["status": authorizationName(), "events": []])
    }
    let store = EKEventStore()
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let events: [[String: Any]] = store.events(matching: predicate)
        .filter { $0.availability != .free }
        .sorted { $0.startDate < $1.startDate }
        .map { event in
            [
                "start": iso.string(from: event.startDate),
                "end": iso.string(from: event.endDate),
                "all_day": event.isAllDay,
            ]
        }
    emit(["status": "authorized", "events": events])
}

emit(["status": "unavailable", "detail": "unknown command"], exitCode: 2)
