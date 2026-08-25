// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimeMorningDigestItem: Equatable, Identifiable, Sendable {
    public let taskID: String
    public let task: String
    public let time: String?
    public let isOverdue: Bool

    public var id: String { taskID }

    public init(taskID: String, task: String, time: String?, isOverdue: Bool) {
        self.taskID = taskID
        self.task = task
        self.time = time
        self.isOverdue = isOverdue
    }
}

public struct RuntimeMorningDigest: Equatable, Identifiable, Sendable {
    public let date: String
    public let timezone: String
    public let items: [RuntimeMorningDigestItem]

    public var id: String { date }

    public init(
        date: String,
        timezone: String,
        items: [RuntimeMorningDigestItem]
    ) {
        self.date = date
        self.timezone = timezone
        self.items = items
    }

    public var notificationBody: String {
        guard !items.isEmpty else { return "Nothing on deck today." }
        let visible = items.prefix(5).enumerated().map { index, item in
            "\(index + 1): \(item.summary)"
        }
        let remainder = items.count - visible.count
        return remainder > 0
            ? (visible + ["+\(remainder) more in Hob"]).joined(separator: "\n")
            : visible.joined(separator: "\n")
    }

    public var eveningRecapBody: String {
        guard !items.isEmpty else {
            return "Nothing is still open from today. Anything else to capture?"
        }
        let visible = items.prefix(4).enumerated().map { index, item in
            "\(index + 1): \(item.summary)"
        }
        let remainder = items.count - visible.count
        let openItems = remainder > 0
            ? visible + ["+\(remainder) more in Hob"]
            : visible
        return (["Tell Hob naturally and it’ll check things off."] + openItems)
            .joined(separator: "\n")
    }
}

public extension RuntimeMorningDigestItem {
    var summary: String {
        if let time { return "\(time) · \(task)" }
        if isOverdue { return "\(task) · overdue" }
        return task
    }
}

public enum RuntimeMorningDigestBuilder {
    public static func build(
        for date: Date,
        tasks: [RuntimeTask],
        proposal: RuntimeScheduleProposal?,
        timezone: TimeZone
    ) -> RuntimeMorningDigest {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let day = dayString(date, calendar: calendar)
        let open = Dictionary(uniqueKeysWithValues: tasks
            .filter { $0.status == "open" && !$0.isMissedTimedItem(on: day) }
            .map { ($0.id, $0) })
        var items: [RuntimeMorningDigestItem] = []
        var included: Set<String> = []

        if let proposal, RuntimeScheduleValidator.valid(proposal) {
            for block in proposal.blocks {
                guard let task = open[block.taskID],
                      let start = ISO8601DateFormatter().date(from: block.startAt),
                      dayString(start, calendar: calendar) == day else { continue }
                items.append(RuntimeMorningDigestItem(
                    taskID: task.id,
                    task: task.task,
                    time: displayTime(start, calendar: calendar),
                    isOverdue: false
                ))
                included.insert(task.id)
            }
        }

        let due = open.values
            .filter { task in
                !included.contains(task.id)
                    && task.dueDate.map { $0 <= day } == true
            }
            .sorted {
                ($0.dueDate ?? "", $0.dueTime ?? "", $0.createdAt, $0.id)
                    < ($1.dueDate ?? "", $1.dueTime ?? "", $1.createdAt, $1.id)
            }
        items += due.map { task in
            RuntimeMorningDigestItem(
                taskID: task.id,
                task: task.task,
                time: task.dueDate == day ? task.dueTime.flatMap(displayClock) : nil,
                isOverdue: task.dueDate.map { $0 < day } == true
            )
        }

        return RuntimeMorningDigest(
            date: day,
            timezone: timezone.identifier,
            items: items
        )
    }

    public static func upcoming(
        from now: Date,
        days: Int,
        tasks: [RuntimeTask],
        proposal: RuntimeScheduleProposal?,
        timezone: TimeZone
    ) -> [RuntimeMorningDigest] {
        guard (1...14).contains(days) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let start = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map {
                build(for: $0, tasks: tasks, proposal: proposal, timezone: timezone)
            }
        }
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    private static func displayTime(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func displayClock(_ value: String) -> String? {
        let pieces = value.split(separator: ":").compactMap { Int($0) }
        guard pieces.count == 2,
              (0...23).contains(pieces[0]),
              (0...59).contains(pieces[1]) else { return nil }
        let suffix = pieces[0] < 12 ? "AM" : "PM"
        let hour = pieces[0] % 12 == 0 ? 12 : pieces[0] % 12
        return String(format: "%d:%02d %@", hour, pieces[1], suffix)
    }
}
