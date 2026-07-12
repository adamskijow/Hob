// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimeTask: Codable, Equatable, Sendable {
    public let id: String
    public let rawText: String
    public var task: String
    public var dueDate: String?
    public var dueTime: String?
    public var status: String
    public let createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        rawText: String,
        task: String,
        dueDate: String?,
        dueTime: String?,
        status: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.rawText = rawText
        self.task = task
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RuntimeDateIntent: Codable, Equatable, Sendable {
    public let kind: String
    public let which: String?
    public let day: String?

    public init(kind: String, which: String? = nil, day: String? = nil) {
        self.kind = kind
        self.which = which
        self.day = day
    }
}

public struct RuntimeAction: Codable, Equatable, Sendable {
    public let type: String
    public let task: String?
    public let raw: String?
    public let target: String?
    public let when: RuntimeDateIntent?
    public let time: String?
    public let confidence: Double?

    public init(
        type: String,
        task: String? = nil,
        raw: String? = nil,
        target: String? = nil,
        when: RuntimeDateIntent? = nil,
        time: String? = nil,
        confidence: Double? = nil
    ) {
        self.type = type
        self.task = task
        self.raw = raw
        self.target = target
        self.when = when
        self.time = time
        self.confidence = confidence
    }
}

public struct RuntimeTurnRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let message: String
    public let now: String
    public let timezone: String
    public let actions: [RuntimeAction]

    public init(
        version: Int = 1,
        requestID: String,
        message: String,
        now: String,
        timezone: String,
        actions: [RuntimeAction]
    ) {
        self.version = version
        self.requestID = requestID
        self.message = message
        self.now = now
        self.timezone = timezone
        self.actions = actions
    }
}

public enum RuntimeDisposition: String, Codable, Equatable, Sendable {
    case applied
    case clarificationRequired
    case confirmationRequired
    case rejected
    case noChange
}

public struct RuntimeTurnOutcome: Codable, Equatable, Sendable {
    public let disposition: RuntimeDisposition
    public let appliedKinds: [String]
    public let tasks: [RuntimeTask]
}

public struct RuntimeTurnResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let outcome: RuntimeTurnOutcome
}

public enum RuntimeStateError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidState
}

public struct RuntimePersistentState: Codable, Equatable, Sendable {
    public let version: Int
    public let tasks: [RuntimeTask]
    public let undoSnapshots: [[RuntimeTask]]

    public init(
        version: Int = 1,
        tasks: [RuntimeTask],
        undoSnapshots: [[RuntimeTask]]
    ) {
        self.version = version
        self.tasks = tasks
        self.undoSnapshots = undoSnapshots
    }

    public static let empty = RuntimePersistentState(tasks: [], undoSnapshots: [])

    public func validated() throws -> RuntimePersistentState {
        guard version == 1 else { throw RuntimeStateError.unsupportedVersion }
        guard tasks.count <= 10_000, undoSnapshots.count <= 100 else {
            throw RuntimeStateError.invalidState
        }
        try Self.validate(tasks)
        for snapshot in undoSnapshots {
            guard snapshot.count <= 10_000 else { throw RuntimeStateError.invalidState }
            try Self.validate(snapshot)
        }
        return self
    }

    private static func validate(_ tasks: [RuntimeTask]) throws {
        var identifiers: Set<String> = []
        for task in tasks {
            guard !task.id.isEmpty,
                  task.id.utf8.count <= 128,
                  identifiers.insert(task.id).inserted,
                  !task.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.task.utf8.count <= 10_000,
                  !task.rawText.isEmpty,
                  task.rawText.utf8.count <= 20_000,
                  ["open", "done", "dropped"].contains(task.status),
                  ISO8601DateFormatter().date(from: task.createdAt) != nil,
                  ISO8601DateFormatter().date(from: task.updatedAt) != nil,
                  validDate(task.dueDate),
                  validTime(task.dueTime) else {
                throw RuntimeStateError.invalidState
            }
        }
    }

    private static func validDate(_ value: String?) -> Bool {
        guard let value else { return true }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func validTime(_ value: String?) -> Bool {
        guard let value else { return true }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts[0].count == 2
            && parts[1].count == 2
            && Int(parts[0]).map { (0...23).contains($0) } == true
            && Int(parts[1]).map { (0...59).contains($0) } == true
    }
}

public struct TaskRuntime: Sendable {
    public private(set) var tasks: [RuntimeTask]
    private var undoSnapshots: [[RuntimeTask]] = []

    public init(tasks: [RuntimeTask] = []) {
        self.tasks = tasks.sorted { $0.id < $1.id }
    }

    public init(persistentState: RuntimePersistentState) throws {
        let state = try persistentState.validated()
        tasks = state.tasks.sorted { $0.id < $1.id }
        undoSnapshots = state.undoSnapshots
    }

    public var persistentState: RuntimePersistentState {
        RuntimePersistentState(tasks: tasks, undoSnapshots: undoSnapshots)
    }

    public mutating func process(_ request: RuntimeTurnRequest) -> RuntimeTurnResponse {
        let trimmedRequestID = request.requestID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let safeRequestID = trimmedRequestID.utf8.count <= 128 ? trimmedRequestID : ""
        guard request.version == 1,
              !safeRequestID.isEmpty,
              request.message.utf8.count <= 20_000,
              request.now.utf8.count <= 64,
              request.timezone.utf8.count <= 64,
              TimeZone(identifier: request.timezone) != nil,
              ISO8601DateFormatter().date(from: request.now) != nil else {
            return response(safeRequestID, outcome: outcome(.rejected))
        }
        return response(
            safeRequestID,
            outcome: process(
                actions: request.actions,
                now: request.now,
                timezone: request.timezone
            )
        )
    }

    private mutating func process(
        actions: [RuntimeAction],
        now: String,
        timezone: String
    ) -> RuntimeTurnOutcome {
        guard !actions.isEmpty, actions.count <= 32 else {
            return outcome(.rejected)
        }
        if actions.contains(where: { $0.type == "undo" }) {
            guard actions.count == 1 else { return outcome(.rejected) }
            guard let snapshot = undoSnapshots.popLast() else {
                return outcome(.noChange)
            }
            tasks = snapshot
            return outcome(.applied, kinds: ["undo"])
        }
        var prepared: [PreparedMutation] = []
        var nextID = nextItemID()
        for action in actions {
            switch prepare(
                action,
                now: now,
                timezone: timezone,
                nextID: &nextID
            ) {
            case .success(let mutation):
                prepared.append(mutation)
            case .clarification:
                return outcome(.clarificationRequired)
            case .confirmation:
                return outcome(.confirmationRequired)
            case .rejected:
                return outcome(.rejected)
            }
        }

        let before = tasks
        for mutation in prepared {
            apply(mutation, now: now)
        }
        if undoSnapshots.count == 100 { undoSnapshots.removeFirst() }
        undoSnapshots.append(before)
        return outcome(.applied, kinds: prepared.map(\.kind))
    }

    private func response(
        _ requestID: String,
        outcome: RuntimeTurnOutcome
    ) -> RuntimeTurnResponse {
        RuntimeTurnResponse(version: 1, requestID: requestID, outcome: outcome)
    }

    private func outcome(
        _ disposition: RuntimeDisposition,
        kinds: [String] = []
    ) -> RuntimeTurnOutcome {
        RuntimeTurnOutcome(
            disposition: disposition,
            appliedKinds: kinds,
            tasks: tasks.sorted { $0.id < $1.id }
        )
    }

    private func nextItemID() -> Int {
        tasks.compactMap { task in
            guard task.id.first == "a" else { return nil }
            return Int(task.id.dropFirst())
        }.max().map { $0 + 1 } ?? 1
    }

    private func resolvedTarget(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 128 else { return nil }
        if tasks.contains(where: { $0.id == raw && $0.status == "open" }) {
            return raw
        }
        if let position = Int(raw), position > 0 {
            let open = tasks.filter { $0.status == "open" }.sorted { $0.id < $1.id }
            guard position <= open.count else { return nil }
            return open[position - 1].id
        }
        return nil
    }

    private func prepare(
        _ action: RuntimeAction,
        now: String,
        timezone: String,
        nextID: inout Int
    ) -> Preparation {
        if action.type == "capture" {
            guard let task = bounded(action.task, maxBytes: 10_000),
                  let raw = bounded(action.raw, maxBytes: 20_000) else {
                return .rejected
            }
            switch resolve(action.when, now: now, timezone: timezone) {
            case .date(let dueDate):
                let dueTime = validTime(action.time)
                if action.time != nil && dueTime == nil { return .clarification }
                defer { nextID += 1 }
                return .success(.capture(RuntimeTask(
                    id: "a\(nextID)",
                    rawText: raw,
                    task: task,
                    dueDate: dueDate,
                    dueTime: dueTime,
                    status: "open",
                    createdAt: now,
                    updatedAt: now
                )))
            case .ambiguous:
                return .clarification
            case .invalid:
                return .rejected
            }
        }

        guard ["complete", "drop", "reschedule", "amend"].contains(action.type)
        else { return .rejected }
        guard let target = resolvedTarget(action.target) else {
            return .clarification
        }
        if (action.confidence ?? 1.0) < 0.5 {
            return .confirmation
        }
        if action.type == "complete" { return .success(.complete(target)) }
        if action.type == "drop" { return .success(.drop(target)) }
        if action.type == "amend" {
            guard let task = bounded(action.task, maxBytes: 10_000) else {
                return .clarification
            }
            return .success(.amend(target, task))
        }
        switch resolve(action.when, now: now, timezone: timezone) {
        case .date(let dueDate):
            let dueTime = validTime(action.time)
            guard dueDate != nil || dueTime != nil else { return .clarification }
            if action.time != nil && dueTime == nil { return .clarification }
            return .success(.reschedule(target, dueDate, dueTime))
        case .ambiguous:
            return .clarification
        case .invalid:
            return .rejected
        }
    }

    private func bounded(_ value: String?, maxBytes: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxBytes else { return nil }
        return trimmed
    }

    private func validTime(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute),
              parts[0].count == 2, parts[1].count == 2 else { return nil }
        return value
    }

    private func resolve(
        _ intent: RuntimeDateIntent?,
        now: String,
        timezone: String
    ) -> DateResolution {
        guard let intent else { return .date(nil) }
        if intent.kind == "none" { return .date(nil) }
        if intent.kind == "ambiguous" { return .ambiguous }
        guard let zone = TimeZone(identifier: timezone),
              let instant = ISO8601DateFormatter().date(from: now) else {
            return .invalid
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let base = calendar.startOfDay(for: instant)
        let resolved: Date?
        switch intent.kind {
        case "today":
            resolved = base
        case "tomorrow":
            resolved = calendar.date(byAdding: .day, value: 1, to: base)
        case "weekday":
            let weekdays = [
                "sun": 1, "mon": 2, "tue": 3, "wed": 4,
                "thu": 5, "fri": 6, "sat": 7,
            ]
            guard let target = intent.day.flatMap({ weekdays[$0] }) else {
                return .invalid
            }
            let current = calendar.component(.weekday, from: base)
            var delta = (target - current + 7) % 7
            if delta == 0 && intent.which != "this" { delta = 7 }
            resolved = calendar.date(byAdding: .day, value: delta, to: base)
        default:
            return .invalid
        }
        guard let resolved else { return .invalid }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return .date(formatter.string(from: resolved))
    }

    private mutating func apply(_ mutation: PreparedMutation, now: String) {
        switch mutation {
        case .capture(let task):
            tasks.append(task)
        case .complete(let target):
            update(target, now: now) { $0.status = "done" }
        case .drop(let target):
            update(target, now: now) { $0.status = "dropped" }
        case .reschedule(let target, let date, let time):
            update(target, now: now) {
                if let date { $0.dueDate = date }
                if let time {
                    $0.dueTime = time
                    if $0.dueDate == nil { $0.dueDate = String(now.prefix(10)) }
                }
            }
        case .amend(let target, let task):
            update(target, now: now) { $0.task = task }
        }
        tasks.sort { $0.id < $1.id }
    }

    private mutating func update(
        _ target: String,
        now: String,
        change: (inout RuntimeTask) -> Void
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == target }) else { return }
        change(&tasks[index])
        tasks[index].updatedAt = now
    }
}

private enum PreparedMutation {
    case capture(RuntimeTask)
    case complete(String)
    case drop(String)
    case reschedule(String, String?, String?)
    case amend(String, String)

    var kind: String {
        switch self {
        case .capture: return "capture"
        case .complete: return "complete"
        case .drop: return "drop"
        case .reschedule: return "reschedule"
        case .amend: return "amend"
        }
    }
}

private enum Preparation {
    case success(PreparedMutation)
    case clarification
    case confirmation
    case rejected
}

private enum DateResolution {
    case date(String?)
    case ambiguous
    case invalid
}
