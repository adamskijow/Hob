// SPDX-License-Identifier: MIT
import Foundation

public enum RuntimeTaskQueryError: Error, Equatable, Sendable {
    case invalidRequest
}

public enum RuntimeTaskQueryEngine {
    public static func answer(
        action: RuntimeAction,
        tasks: [RuntimeTask],
        now: Date,
        timezone: TimeZone
    ) throws -> String {
        guard action.type == "query", let kind = action.queryKind else {
            throw RuntimeTaskQueryError.invalidRequest
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let today = calendar.startOfDay(for: now)
        let todayText = day(today, calendar: calendar)
        let open = tasks.filter { $0.status == "open" }
        let title: String
        let matches: [RuntimeTask]

        switch kind {
        case "today":
            title = "Today"
            matches = open.filter {
                !$0.isWaiting && ($0.dueDate.map { $0 <= todayText } ?? true)
            }
        case "date":
            guard let date = resolve(action.when, from: today, calendar: calendar) else {
                throw RuntimeTaskQueryError.invalidRequest
            }
            let dateText = day(date, calendar: calendar)
            title = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            matches = open.filter { !$0.isWaiting && $0.dueDate == dateText }
        case "week":
            let end = calendar.date(byAdding: .day, value: 7, to: today) ?? today
            title = "Next 7 days"
            matches = open.filter { task in
                guard !task.isWaiting, let due = task.dueDate,
                      let date = parse(due, calendar: calendar) else { return false }
                return date >= today && date < end
            }
        case "overdue":
            title = "Overdue"
            matches = open.filter { !$0.isWaiting && ($0.dueDate.map { $0 < todayText } ?? false) }
        case "all":
            title = "Open tasks"
            matches = open
        case "waiting":
            title = "Waiting"
            matches = open.filter(\.isWaiting)
        case "search":
            let term = action.queryTerm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !term.isEmpty else { throw RuntimeTaskQueryError.invalidRequest }
            title = "Matches for “\(term)”"
            matches = tasks.filter {
                $0.task.localizedCaseInsensitiveContains(term)
                    || ($0.note?.localizedCaseInsensitiveContains(term) ?? false)
            }
        case "done":
            return completionAnswer(
                tasks: tasks,
                period: action.queryPeriod ?? "week",
                today: today,
                calendar: calendar
            )
        default:
            throw RuntimeTaskQueryError.invalidRequest
        }
        return list(title: title, tasks: matches)
    }

    private static func completionAnswer(
        tasks: [RuntimeTask],
        period: String,
        today: Date,
        calendar: Calendar
    ) -> String {
        let lowerBound: Date?
        let title: String
        switch period {
        case "today":
            lowerBound = today
            title = "Completed today"
        case "all":
            lowerBound = nil
            title = "Completed"
        default:
            lowerBound = calendar.date(byAdding: .day, value: -6, to: today)
            title = "Completed in the last 7 days"
        }
        let upperBound = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let matches = tasks.compactMap { task -> (RuntimeTask, Date)? in
            let recorded = task.completionHistory
                ?? (task.status == "done" ? [task.updatedAt] : [])
            let dates = recorded.compactMap(ISO8601DateFormatter().date)
            guard let latest = dates.max(), latest < upperBound,
                  lowerBound.map({ latest >= $0 }) ?? true else { return nil }
            return (task, latest)
        }.sorted { $0.1 > $1.1 }.map(\.0)
        return list(title: title, tasks: matches)
    }

    private static func list(title: String, tasks: [RuntimeTask]) -> String {
        let ordered = tasks.sorted {
            ($0.dueDate ?? "9999", $0.dueTime ?? "99:99", $0.updatedAt, $0.id)
                < ($1.dueDate ?? "9999", $1.dueTime ?? "99:99", $1.updatedAt, $1.id)
        }
        guard !ordered.isEmpty else { return "\(title): nothing." }
        let visible = ordered.prefix(8).enumerated().map { index, task in
            var detail: [String] = []
            if task.isWaiting { detail.append("waiting") }
            if let due = task.dueDate { detail.append(task.dueTime.map { "\(due) \($0)" } ?? due) }
            if task.status != "open" { detail.append(task.status) }
            return "\(index + 1). \(task.task)\(detail.isEmpty ? "" : " · " + detail.joined(separator: " · "))"
        }
        let remainder = ordered.count - visible.count
        return (["\(title):"] + visible + (remainder > 0 ? ["+\(remainder) more"] : []))
            .joined(separator: "\n")
    }

    private static func resolve(
        _ intent: RuntimeDateIntent?,
        from today: Date,
        calendar: Calendar
    ) -> Date? {
        guard let intent else { return nil }
        switch intent.kind {
        case "today": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        case "weekday":
            let values = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            guard let target = intent.day.flatMap({ values[$0] }) else { return nil }
            let current = calendar.component(.weekday, from: today)
            var delta = (target - current + 7) % 7
            if delta == 0 && intent.which != "this" { delta = 7 }
            return calendar.date(byAdding: .day, value: delta, to: today)
        case "offset":
            guard let n = intent.n else { return nil }
            let component: Calendar.Component
            switch intent.unit {
            case "day": component = .day
            case "week": component = .weekOfYear
            case "month": component = .month
            case "year": component = .year
            default: return nil
            }
            return calendar.date(byAdding: component, value: n, to: today)
        case "absolute":
            guard let year = intent.year, let month = intent.month,
                  let day = intent.dayNumber else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        default: return nil
        }
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    private static func parse(_ value: String, calendar: Calendar) -> Date? {
        let values = value.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }
}
