// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimeReminderGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tasks: [RuntimeTask]
}

/// A read-only view of stated reminder dates, never a generated schedule.
public struct RuntimeReminderList: Equatable, Sendable {
    public let upcoming: [RuntimeReminderGroup]
    public let history: [RuntimeTask]

    public init(tasks: [RuntimeTask], now: Date, timezone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let tomorrow = formatter.string(from: calendar.date(byAdding: .day, value: 1, to: now)!)
        let weekEnd = formatter.string(from: calendar.dateInterval(of: .weekOfYear, for: now)!.end)
        history = tasks.filter { $0.status != "open" || $0.isWaiting || $0.isMissedTimedItem(on: today) }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        let future = tasks.filter {
            $0.status == "open" && !$0.isWaiting && ($0.dueDate ?? "") > today
        }.sorted {
            ($0.dueDate ?? "", $0.dueTime ?? "", $0.task, $0.id)
                < ($1.dueDate ?? "", $1.dueTime ?? "", $1.task, $1.id)
        }
        upcoming = [
            RuntimeReminderGroup(id: "tomorrow", title: "Tomorrow", tasks: future.filter { $0.dueDate == tomorrow }),
            RuntimeReminderGroup(
                id: "week", title: "This week",
                tasks: future.filter { ($0.dueDate ?? "") > tomorrow && ($0.dueDate ?? "") < weekEnd }),
            RuntimeReminderGroup(
                id: "later", title: "Later",
                tasks: future.filter { $0.dueDate != tomorrow && ($0.dueDate ?? "") >= weekEnd }),
        ].filter { !$0.tasks.isEmpty }
    }
}
