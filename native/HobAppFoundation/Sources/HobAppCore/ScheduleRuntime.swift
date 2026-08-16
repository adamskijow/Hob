// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimeBusyInterval: Codable, Equatable, Sendable {
    public let startAt: String
    public let endAt: String

    public init(startAt: String, endAt: String) {
        self.startAt = startAt
        self.endAt = endAt
    }
}

public struct RuntimeScheduleRequest: Codable, Equatable, Sendable {
    public let proposalID: String
    public let generatedAt: String
    public let startDate: String
    public let timezone: String
    public let horizonDays: Int
    public let workStart: String
    public let workEnd: String
    public let defaultDurationMinutes: Int
    public let transitionBufferMinutes: Int
    public let busy: [RuntimeBusyInterval]

    public init(
        proposalID: String,
        generatedAt: String,
        startDate: String,
        timezone: String,
        horizonDays: Int = 7,
        workStart: String = "09:00",
        workEnd: String = "17:30",
        defaultDurationMinutes: Int = 30,
        transitionBufferMinutes: Int = 0,
        busy: [RuntimeBusyInterval] = []
    ) {
        self.proposalID = proposalID
        self.generatedAt = generatedAt
        self.startDate = startDate
        self.timezone = timezone
        self.horizonDays = horizonDays
        self.workStart = workStart
        self.workEnd = workEnd
        self.defaultDurationMinutes = defaultDurationMinutes
        self.transitionBufferMinutes = transitionBufferMinutes
        self.busy = busy
    }
}

public struct RuntimeScheduleBlock: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let taskID: String
    public let task: String
    public let startAt: String
    public let endAt: String
    public let durationMinutes: Int
    public let priority: String

    public init(
        id: String,
        taskID: String,
        task: String,
        startAt: String,
        endAt: String,
        durationMinutes: Int,
        priority: String
    ) {
        self.id = id
        self.taskID = taskID
        self.task = task
        self.startAt = startAt
        self.endAt = endAt
        self.durationMinutes = durationMinutes
        self.priority = priority
    }
}

public struct RuntimeUnscheduledTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String { taskID }
    public let taskID: String
    public let task: String
    public let reason: String

    public init(taskID: String, task: String, reason: String) {
        self.taskID = taskID
        self.task = task
        self.reason = reason
    }
}

public struct RuntimeScheduleProposal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let generatedAt: String
    public let startDate: String
    public let timezone: String
    public let workStart: String
    public let workEnd: String
    public let taskVersions: [String: String]
    public let blocks: [RuntimeScheduleBlock]
    public let unscheduled: [RuntimeUnscheduledTask]
    public let assumptions: [String]

    public init(
        id: String,
        generatedAt: String,
        startDate: String,
        timezone: String,
        workStart: String,
        workEnd: String,
        taskVersions: [String: String],
        blocks: [RuntimeScheduleBlock],
        unscheduled: [RuntimeUnscheduledTask],
        assumptions: [String]
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.startDate = startDate
        self.timezone = timezone
        self.workStart = workStart
        self.workEnd = workEnd
        self.taskVersions = taskVersions
        self.blocks = blocks
        self.unscheduled = unscheduled
        self.assumptions = assumptions
    }
}

public struct RuntimeAdoptedSchedule: Codable, Equatable, Sendable {
    public let proposal: RuntimeScheduleProposal
    public let adoptedAt: String
    public let calendarEventIDs: [String]
    public let notificationIDs: [String]

    public init(
        proposal: RuntimeScheduleProposal,
        adoptedAt: String,
        calendarEventIDs: [String] = [],
        notificationIDs: [String] = []
    ) {
        self.proposal = proposal
        self.adoptedAt = adoptedAt
        self.calendarEventIDs = calendarEventIDs
        self.notificationIDs = notificationIDs
    }

    private enum CodingKeys: String, CodingKey {
        case proposal, adoptedAt, calendarEventIDs, notificationIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        proposal = try values.decode(RuntimeScheduleProposal.self, forKey: .proposal)
        adoptedAt = try values.decode(String.self, forKey: .adoptedAt)
        calendarEventIDs = try values.decodeIfPresent(
            [String].self,
            forKey: .calendarEventIDs
        ) ?? []
        notificationIDs = try values.decodeIfPresent(
            [String].self,
            forKey: .notificationIDs
        ) ?? []
    }
}

public enum RuntimeScheduleError: Error, Equatable, Sendable {
    case invalidRequest
    case noProposal
    case proposalMismatch
    case staleProposal
    case calendarCleanupPending
}

public enum RuntimeScheduleValidator {
    public static func valid(_ proposal: RuntimeScheduleProposal?) -> Bool {
        guard let proposal else { return true }
        guard identifier(proposal.id, maximum: 128),
              timestamp(proposal.generatedAt),
              date(proposal.startDate),
              TimeZone(identifier: proposal.timezone) != nil,
              time(proposal.workStart),
              time(proposal.workEnd),
              proposal.workStart < proposal.workEnd,
              proposal.taskVersions.count <= 10_000,
              proposal.blocks.count <= 10_000,
              proposal.unscheduled.count <= 10_000,
              proposal.assumptions.count <= 10_000 else { return false }
        guard proposal.taskVersions.allSatisfy({
            identifier($0.key, maximum: 128) && timestamp($0.value)
        }) else { return false }
        var blockIDs: Set<String> = []
        for block in proposal.blocks {
            guard identifier(block.id, maximum: 300),
                  blockIDs.insert(block.id).inserted,
                  identifier(block.taskID, maximum: 128),
                  !block.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  block.task.utf8.count <= 10_000,
                  timestamp(block.startAt),
                  timestamp(block.endAt),
                  let start = ISO8601DateFormatter().date(from: block.startAt),
                  let end = ISO8601DateFormatter().date(from: block.endAt),
                  end > start,
                  (5...480).contains(block.durationMinutes),
                  ["high", "normal", "low"].contains(block.priority),
                  proposal.taskVersions[block.taskID] != nil else { return false }
        }
        return proposal.unscheduled.allSatisfy {
            identifier($0.taskID, maximum: 128)
                && !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.task.utf8.count <= 10_000
                && !$0.reason.isEmpty
                && $0.reason.utf8.count <= 512
                && proposal.taskVersions[$0.taskID] != nil
        } && proposal.assumptions.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 512
        }
    }

    public static func valid(_ adopted: RuntimeAdoptedSchedule?) -> Bool {
        guard let adopted else { return true }
        return valid(adopted.proposal)
            && timestamp(adopted.adoptedAt)
            && adopted.calendarEventIDs.count <= adopted.proposal.blocks.count
            && Set(adopted.calendarEventIDs).count == adopted.calendarEventIDs.count
            && adopted.calendarEventIDs.allSatisfy {
                identifier($0, maximum: 1_024)
            }
            && adopted.notificationIDs.count <= adopted.proposal.blocks.count
            && Set(adopted.notificationIDs).count == adopted.notificationIDs.count
            && adopted.notificationIDs.allSatisfy {
                identifier($0, maximum: 512)
            }
    }

    private static func identifier(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && !value.isEmpty && value.utf8.count <= maximum
    }

    private static func timestamp(_ value: String) -> Bool {
        ISO8601DateFormatter().date(from: value) != nil
    }

    private static func date(_ value: String) -> Bool {
        strictDateFormatter.string(from: strictDateFormatter.date(from: value) ?? .distantPast)
            == value
    }

    private static func time(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts[0].count == 2
            && parts[1].count == 2
            && Int(parts[0]).map { (0...23).contains($0) } == true
            && Int(parts[1]).map { (0...59).contains($0) } == true
    }

    private static var strictDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

public enum RuntimeSchedulePlanner {
    public static func propose(
        tasks: [RuntimeTask],
        request: RuntimeScheduleRequest
    ) throws -> RuntimeScheduleProposal {
        guard valid(request),
              let zone = TimeZone(identifier: request.timezone),
              let startDay = parseDay(request.startDate, zone: zone),
              let generatedAt = ISO8601DateFormatter().date(from: request.generatedAt)
        else { throw RuntimeScheduleError.invalidRequest }

        let open = tasks.filter { $0.status == "open" }
        let versions = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0.updatedAt) })
        let ordered = open.sorted(by: taskOrder)
        var occupied = request.busy.compactMap { interval -> DateInterval? in
            guard let start = ISO8601DateFormatter().date(from: interval.startAt),
                  let end = ISO8601DateFormatter().date(from: interval.endAt),
                  end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
        var blocks: [RuntimeScheduleBlock] = []
        var unscheduled: [RuntimeUnscheduledTask] = []
        var assumptions: [String] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        for task in ordered {
            let duration = task.durationMinutes ?? request.defaultDurationMinutes
            if task.durationMinutes == nil {
                assumptions.append("\(task.task): \(duration)m default estimate")
            }
            var placed: RuntimeScheduleBlock?
            for offset in 0..<request.horizonDays {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startDay),
                      eligible(task, on: day, startDay: startDay, zone: zone) else { continue }
                if let deadline = task.deadlineDate.flatMap({ parseDay($0, zone: zone) }),
                   day > deadline { break }
                guard let bounds = workBounds(
                    day: day,
                    start: request.workStart,
                    end: request.workEnd,
                    zone: zone
                ) else { continue }
                var lowerBound = bounds.start
                if calendar.isDate(day, inSameDayAs: generatedAt) {
                    lowerBound = max(lowerBound, roundedUp(generatedAt, calendar: calendar))
                }
                guard lowerBound < bounds.end else { continue }

                if let dueTime = task.dueTime,
                   let fixedStart = instant(day: day, time: dueTime, zone: zone) {
                    let fixedEnd = fixedStart.addingTimeInterval(Double(duration * 60))
                    let candidate = DateInterval(start: fixedStart, end: fixedEnd)
                    if fixedStart >= lowerBound, fixedEnd <= bounds.end,
                       !overlaps(candidate, occupied: occupied, buffer: request.transitionBufferMinutes) {
                        placed = block(task, request: request, interval: candidate, duration: duration, zone: zone)
                    }
                } else if let interval = firstOpening(
                    within: DateInterval(start: lowerBound, end: bounds.end),
                    duration: duration,
                    occupied: occupied,
                    buffer: request.transitionBufferMinutes
                ) {
                    placed = block(task, request: request, interval: interval, duration: duration, zone: zone)
                }
                if let placed {
                    guard let start = ISO8601DateFormatter().date(from: placed.startAt),
                          let end = ISO8601DateFormatter().date(from: placed.endAt) else {
                        throw RuntimeScheduleError.invalidRequest
                    }
                    occupied.append(DateInterval(start: start, end: end))
                    blocks.append(placed)
                    break
                }
            }
            if placed == nil {
                unscheduled.append(RuntimeUnscheduledTask(
                    taskID: task.id,
                    task: task.task,
                    reason: task.deadlineDate == nil
                        ? "No open block fits in the planning window."
                        : "No open block fits before the deadline."
                ))
            }
        }

        let proposal = RuntimeScheduleProposal(
            id: request.proposalID,
            generatedAt: request.generatedAt,
            startDate: request.startDate,
            timezone: request.timezone,
            workStart: request.workStart,
            workEnd: request.workEnd,
            taskVersions: versions,
            blocks: blocks.sorted { $0.startAt < $1.startAt },
            unscheduled: unscheduled,
            assumptions: assumptions
        )
        guard RuntimeScheduleValidator.valid(proposal) else {
            throw RuntimeScheduleError.invalidRequest
        }
        return proposal
    }

    private static func valid(_ request: RuntimeScheduleRequest) -> Bool {
        let identifier = request.proposalID.trimmingCharacters(in: .whitespacesAndNewlines)
        let busyIsValid = request.busy.allSatisfy { interval in
            guard let start = ISO8601DateFormatter().date(from: interval.startAt),
                  let end = ISO8601DateFormatter().date(from: interval.endAt)
            else { return false }
            return end > start
        }
        return !identifier.isEmpty
            && identifier == request.proposalID
            && identifier.utf8.count <= 128
            && ISO8601DateFormatter().date(from: request.generatedAt) != nil
            && TimeZone(identifier: request.timezone) != nil
            && validClock(request.workStart)
            && validClock(request.workEnd)
            && (1...14).contains(request.horizonDays)
            && (5...480).contains(request.defaultDurationMinutes)
            && (0...120).contains(request.transitionBufferMinutes)
            && request.workStart < request.workEnd
            && request.busy.count <= 10_000
            && busyIsValid
    }

    private static func validClock(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts[0].count == 2
            && parts[1].count == 2
            && Int(parts[0]).map { (0...23).contains($0) } == true
            && Int(parts[1]).map { (0...59).contains($0) } == true
    }

    private static func taskOrder(_ lhs: RuntimeTask, _ rhs: RuntimeTask) -> Bool {
        let rank = ["high": 0, "normal": 1, "low": 2]
        let leftRank = rank[lhs.priority ?? "normal"] ?? 1
        let rightRank = rank[rhs.priority ?? "normal"] ?? 1
        if leftRank != rightRank { return leftRank < rightRank }
        let leftDate = lhs.deadlineDate ?? lhs.dueDate ?? "9999-12-31"
        let rightDate = rhs.deadlineDate ?? rhs.dueDate ?? "9999-12-31"
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.id < rhs.id
    }

    private static func eligible(
        _ task: RuntimeTask,
        on day: Date,
        startDay: Date,
        zone: TimeZone
    ) -> Bool {
        if let due = task.dueDate.flatMap({ parseDay($0, zone: zone) }) {
            return day >= max(due, startDay)
        }
        return true
    }

    private static func workBounds(
        day: Date,
        start: String,
        end: String,
        zone: TimeZone
    ) -> DateInterval? {
        guard let lower = instant(day: day, time: start, zone: zone),
              let upper = instant(day: day, time: end, zone: zone),
              upper > lower else { return nil }
        return DateInterval(start: lower, end: upper)
    }

    private static func firstOpening(
        within bounds: DateInterval,
        duration: Int,
        occupied: [DateInterval],
        buffer: Int
    ) -> DateInterval? {
        let seconds = Double(duration * 60)
        let bufferSeconds = Double(buffer * 60)
        let relevant = occupied
            .map { DateInterval(
                start: $0.start.addingTimeInterval(-bufferSeconds),
                end: $0.end.addingTimeInterval(bufferSeconds)
            ) }
            .filter { $0.end > bounds.start && $0.start < bounds.end }
            .sorted { $0.start < $1.start }
        var cursor = bounds.start
        for interval in relevant {
            if interval.start.timeIntervalSince(cursor) >= seconds {
                return DateInterval(start: cursor, duration: seconds)
            }
            cursor = max(cursor, interval.end)
            if cursor >= bounds.end { return nil }
        }
        guard bounds.end.timeIntervalSince(cursor) >= seconds else { return nil }
        return DateInterval(start: cursor, duration: seconds)
    }

    private static func overlaps(
        _ candidate: DateInterval,
        occupied: [DateInterval],
        buffer: Int
    ) -> Bool {
        let seconds = Double(buffer * 60)
        return occupied.contains {
            candidate.intersects(DateInterval(
                start: $0.start.addingTimeInterval(-seconds),
                end: $0.end.addingTimeInterval(seconds)
            ))
        }
    }

    private static func block(
        _ task: RuntimeTask,
        request: RuntimeScheduleRequest,
        interval: DateInterval,
        duration: Int,
        zone: TimeZone
    ) -> RuntimeScheduleBlock {
        RuntimeScheduleBlock(
            id: "\(request.proposalID):\(task.id)",
            taskID: task.id,
            task: task.task,
            startAt: timestamp(interval.start, zone: zone),
            endAt: timestamp(interval.end, zone: zone),
            durationMinutes: duration,
            priority: task.priority ?? "normal"
        )
    }

    private static func roundedUp(_ value: Date, calendar: Calendar) -> Date {
        let minute = calendar.component(.minute, from: value)
        let remainder = minute % 5
        guard remainder != 0 else {
            return calendar.date(bySetting: .second, value: 0, of: value) ?? value
        }
        let seconds = (5 - remainder) * 60 - calendar.component(.second, from: value)
        return value.addingTimeInterval(Double(seconds))
    }

    private static func parseDay(_ value: String, zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: value), formatter.string(from: parsed) == value
        else { return nil }
        return parsed
    }

    private static func instant(day: Date, time: String, zone: TimeZone) -> Date? {
        let pieces = time.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let hour = Int(pieces[0]), (0...23).contains(hour),
              let minute = Int(pieces[1]), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private static func timestamp(_ value: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.string(from: value)
    }
}
