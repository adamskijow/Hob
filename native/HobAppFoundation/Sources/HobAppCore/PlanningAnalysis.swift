// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimePlanningAnalysis: Equatable, Identifiable, Sendable {
    public let id: String
    public let generatedAt: String
    public let kind: String
    public let horizonDays: Int
    public let requiredMinutes: Int
    public let capacityMinutes: Int
    public let fits: Bool
    public let headline: String
    public let details: [String]
    public let assumptions: [String]
    public let proposal: RuntimeScheduleProposal

    public init(
        id: String,
        generatedAt: String,
        kind: String,
        horizonDays: Int,
        requiredMinutes: Int,
        capacityMinutes: Int,
        fits: Bool,
        headline: String,
        details: [String],
        assumptions: [String],
        proposal: RuntimeScheduleProposal
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.kind = kind
        self.horizonDays = horizonDays
        self.requiredMinutes = requiredMinutes
        self.capacityMinutes = capacityMinutes
        self.fits = fits
        self.headline = headline
        self.details = details
        self.assumptions = assumptions
        self.proposal = proposal
    }
}

public enum RuntimePlanningAnalyzer {
    public static func analyze(
        tasks: [RuntimeTask],
        action: RuntimeAction,
        request: RuntimeScheduleRequest
    ) throws -> RuntimePlanningAnalysis {
        guard action.type == "analysis",
              let kind = action.analysisKind,
              ["capacity", "explain", "what_if"].contains(kind),
              let horizon = action.horizonDays,
              (1...31).contains(horizon) else {
            throw RuntimeScheduleError.invalidRequest
        }
        let horizonEnd = endDate(
            from: request.startDate,
            days: horizon,
            timezone: request.timezone
        )
        let open = tasks.filter {
            guard $0.status == "open" else { return false }
            if $0.id == action.target { return true }
            let relevantDate = $0.deadlineDate ?? $0.dueDate
            return relevantDate.map { $0 <= horizonEnd } ?? true
        }
        var simulated = open
        let target = action.target.flatMap { target in
            simulated.firstIndex { $0.id == target }
        }
        if kind == "explain" || kind == "what_if" {
            guard target != nil else { throw RuntimeScheduleError.invalidRequest }
        }
        if kind == "what_if" {
            guard let target,
                  let duration = action.hypotheticalDurationMinutes,
                  (5...480).contains(duration) else {
                throw RuntimeScheduleError.invalidRequest
            }
            simulated[target].durationMinutes = duration
        }
        let untimed = simulated.filter { $0.dueTime == nil }.map(\.id)
        let analysisRequest = RuntimeScheduleRequest(
            proposalID: request.proposalID,
            generatedAt: request.generatedAt,
            startDate: request.startDate,
            timezone: request.timezone,
            horizonDays: horizon,
            workStart: request.workStart,
            workEnd: request.workEnd,
            defaultDurationMinutes: request.defaultDurationMinutes,
            transitionBufferMinutes: request.transitionBufferMinutes,
            workDays: request.workDays,
            busy: request.busy,
            includedUntimedTaskIDs: untimed
        )
        let proposal = try RuntimeSchedulePlanner.propose(
            tasks: simulated, request: analysisRequest
        )
        let taskMinutes = simulated.reduce(0) {
            $0 + ($1.durationMinutes ?? request.defaultDurationMinutes)
        }
        let required = taskMinutes + max(
            0,
            simulated.count - 1
        ) * request.transitionBufferMinutes
        let calendarCapacity = availableMinutes(analysisRequest)
        let capacity = min(calendarCapacity, action.budgetMinutes ?? calendarCapacity)
        let fits = proposal.unscheduled.isEmpty && required <= capacity
        let assumed = simulated.filter { $0.durationMinutes == nil }
            .map { "Assumed \(request.defaultDurationMinutes)m for \($0.task)." }
        let window = "Planning window: \(request.workStart)–\(request.workEnd) on \(daySummary(request.workDays))."
        let details: [String]
        let headline: String
        if kind == "explain", let target,
           let task = simulated[safe: target] {
            headline = task.task
            if let block = proposal.blocks.first(where: { $0.taskID == task.id }) {
                if task.dueTime != nil {
                    details = ["It keeps the time you stated: \(display(block.startAt, timezone: request.timezone))."]
                } else {
                    var reason = "It uses the first open block after higher-priority and earlier-deadline work."
                    if task.priority == "high" { reason = "High priority moves it ahead of normal and low-priority work." }
                    if let deadline = task.deadlineDate { reason += " Its deadline is \(deadline)." }
                    details = ["Proposed for \(display(block.startAt, timezone: request.timezone)).", reason]
                }
            } else if let deferred = proposal.unscheduled.first(where: { $0.taskID == task.id }) {
                details = [deferred.reason]
            } else {
                details = ["It falls outside this \(horizon)-day analysis."]
            }
        } else if kind == "what_if", let target,
                  let task = simulated[safe: target],
                  let duration = action.hypotheticalDurationMinutes {
            headline = fits ? "It still fits." : "It no longer all fits."
            details = [
                "\(task.task) is temporarily treated as \(duration)m.",
                fitDetail(proposal: proposal, required: required, capacity: capacity),
            ]
        } else {
            headline = fits ? "Everything fits." : "Something needs room."
            details = [fitDetail(
                proposal: proposal, required: required, capacity: capacity
            )]
        }
        return RuntimePlanningAnalysis(
            id: request.proposalID,
            generatedAt: request.generatedAt,
            kind: kind,
            horizonDays: horizon,
            requiredMinutes: required,
            capacityMinutes: capacity,
            fits: fits,
            headline: headline,
            details: details,
            assumptions: [window] + assumed,
            proposal: proposal
        )
    }

    private static func fitDetail(
        proposal: RuntimeScheduleProposal,
        required: Int,
        capacity: Int
    ) -> String {
        guard !proposal.unscheduled.isEmpty else {
            return "\(required)m of work fits within \(capacity)m of available time."
        }
        let labels = proposal.unscheduled.prefix(3).map(\.task).joined(separator: ", ")
        let more = proposal.unscheduled.count > 3
            ? " and \(proposal.unscheduled.count - 3) more" : ""
        return "\(required)m of work exceeds \(capacity)m of available time. Needs room: \(labels)\(more)."
    }

    private static func availableMinutes(_ request: RuntimeScheduleRequest) -> Int {
        guard let zone = TimeZone(identifier: request.timezone),
              let start = day(request.startDate, zone: zone) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let busy = request.busy.compactMap { item -> DateInterval? in
            guard let start = ISO8601DateFormatter().date(from: item.startAt),
                  let end = ISO8601DateFormatter().date(from: item.endAt),
                  end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
        var total = 0
        for offset in 0..<request.horizonDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start),
                  request.workDays.contains(normalizedWeekday(
                    calendar.component(.weekday, from: date)
                  )),
                  let lower = instant(date, clock: request.workStart, calendar: calendar),
                  let upper = instant(date, clock: request.workEnd, calendar: calendar),
                  upper > lower else { continue }
            let window = DateInterval(start: lower, end: upper)
            let blocked = merged(busy.compactMap { intersection($0, window) })
                .reduce(0) { $0 + Int($1.duration / 60) }
            total += max(0, Int(window.duration / 60) - blocked)
        }
        return total
    }

    private static func normalizedWeekday(_ value: Int) -> Int {
        value == 1 ? 7 : value - 1
    }

    private static func day(_ value: String, zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    private static func instant(
        _ day: Date, clock: String, calendar: Calendar
    ) -> Date? {
        let values = clock.split(separator: ":").compactMap { Int($0) }
        guard values.count == 2 else { return nil }
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = values[0]
        parts.minute = values[1]
        return calendar.date(from: parts)
    }

    private static func intersection(
        _ left: DateInterval, _ right: DateInterval
    ) -> DateInterval? {
        let start = max(left.start, right.start)
        let end = min(left.end, right.end)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    private static func merged(_ values: [DateInterval]) -> [DateInterval] {
        values.sorted { $0.start < $1.start }.reduce(into: []) { result, value in
            if let last = result.last, value.start <= last.end {
                result[result.count - 1] = DateInterval(
                    start: last.start, end: max(last.end, value.end)
                )
            } else { result.append(value) }
        }
    }

    private static func display(_ value: String, timezone: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value),
              let zone = TimeZone(identifier: timezone) else { return value }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func daySummary(_ days: [Int]) -> String {
        days == [1, 2, 3, 4, 5] ? "weekdays" : days.map(String.init).joined(separator: ", ")
    }

    private static func endDate(
        from start: String,
        days: Int,
        timezone: String
    ) -> String {
        guard let zone = TimeZone(identifier: timezone),
              let date = day(start, zone: zone) else { return start }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let end = calendar.date(byAdding: .day, value: max(0, days - 1), to: date) ?? date
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: end)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
