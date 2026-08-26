// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimeRecurrenceRule: Codable, Equatable, Sendable {
    public let frequency: String
    public let interval: Int
    public let weekdays: [String]
    public let monthDay: Int?
    public let month: Int?
    public let anchor: String
    public let endDate: String?
    public let count: Int?
    public var completed: Int

    public init(
        frequency: String,
        interval: Int = 1,
        weekdays: [String] = [],
        monthDay: Int? = nil,
        month: Int? = nil,
        anchor: String = "fixed",
        endDate: String? = nil,
        count: Int? = nil,
        completed: Int = 0
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.monthDay = monthDay
        self.month = month
        self.anchor = anchor
        self.endDate = endDate
        self.count = count
        self.completed = completed
    }

    public var isValid: Bool {
        let validWeekdays = Set(["sun", "mon", "tue", "wed", "thu", "fri", "sat"])
        return ["day", "week", "month", "year"].contains(frequency)
            && (1...365).contains(interval)
            && Set(weekdays).count == weekdays.count
            && weekdays.allSatisfy(validWeekdays.contains)
            && (monthDay.map { (1...31).contains($0) } ?? true)
            && (month.map { (1...12).contains($0) } ?? true)
            && ["fixed", "completion"].contains(anchor)
            && (endDate.map(Self.validDate) ?? true)
            && (count.map { (1...10_000).contains($0) } ?? true)
            && completed >= 0
            && completed <= (count ?? 10_000)
            && (frequency == "week" || weekdays.isEmpty)
            && (["month", "year"].contains(frequency) || monthDay == nil)
            && (frequency == "year" || month == nil)
    }

    private static func validDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

public struct RuntimeTask: Codable, Equatable, Sendable {
    public let id: String
    public let rawText: String
    public var task: String
    public var dueDate: String?
    public var dueTime: String?
    public var deadlineDate: String?
    public var durationMinutes: Int?
    public var priority: String?
    public var recurrence: RuntimeRecurrenceRule?
    public var note: String?
    public var waitingSince: String?
    public var completionHistory: [String]?
    public var status: String
    public let createdAt: String
    public var updatedAt: String
    public var sourceArchive: String?

    public init(
        id: String,
        rawText: String,
        task: String,
        dueDate: String?,
        dueTime: String?,
        deadlineDate: String? = nil,
        durationMinutes: Int? = nil,
        priority: String? = nil,
        recurrence: RuntimeRecurrenceRule? = nil,
        note: String? = nil,
        waitingSince: String? = nil,
        completionHistory: [String]? = nil,
        status: String,
        createdAt: String,
        updatedAt: String,
        sourceArchive: String? = nil
    ) {
        self.id = id
        self.rawText = rawText
        self.task = task
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.deadlineDate = deadlineDate
        self.durationMinutes = durationMinutes
        self.priority = priority
        self.recurrence = recurrence
        self.note = note
        self.waitingSince = waitingSince
        self.completionHistory = completionHistory
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceArchive = sourceArchive
    }
}

public extension RuntimeTask {
    /// A clock time describes a one-time appointment. Once its date has passed,
    /// Hob keeps the item for recovery without silently moving it to another day.
    func isMissedTimedItem(on day: String) -> Bool {
        status == "open"
            && dueTime != nil
            && (dueDate ?? String(createdAt.prefix(10))) < day
    }

    var isWaiting: Bool { waitingSince != nil }

    var completedAt: String? { completionHistory?.last }
}

public struct RuntimeDateIntent: Codable, Equatable, Sendable {
    public let kind: String
    public let which: String?
    public let day: String?
    public let n: Int?
    public let unit: String?
    public let part: String?
    public let anchor: String?
    public let year: Int?
    public let month: Int?
    public let dayNumber: Int?

    public init(
        kind: String,
        which: String? = nil,
        day: String? = nil,
        n: Int? = nil,
        unit: String? = nil,
        part: String? = nil,
        anchor: String? = nil,
        year: Int? = nil,
        month: Int? = nil,
        dayNumber: Int? = nil
    ) {
        self.kind = kind
        self.which = which
        self.day = day
        self.n = n
        self.unit = unit
        self.part = part
        self.anchor = anchor
        self.year = year
        self.month = month
        self.dayNumber = dayNumber
    }
}

public struct RuntimeAction: Codable, Equatable, Sendable {
    public let type: String
    public let task: String?
    public let raw: String?
    public let target: String?
    public let when: RuntimeDateIntent?
    public let deadline: RuntimeDateIntent?
    public let time: String?
    public let durationMinutes: Int?
    public let priority: String?
    public let recurrence: RuntimeRecurrenceRule?
    public let recurrenceOperation: String?
    public let note: String?
    public let clearFields: [String]?
    public let queryKind: String?
    public let queryTerm: String?
    public let queryPeriod: String?
    public let analysisKind: String?
    public let horizonDays: Int?
    public let budgetMinutes: Int?
    public let hypotheticalDurationMinutes: Int?
    public let reply: String?
    public let confidence: Double?

    public init(
        type: String,
        task: String? = nil,
        raw: String? = nil,
        target: String? = nil,
        when: RuntimeDateIntent? = nil,
        deadline: RuntimeDateIntent? = nil,
        time: String? = nil,
        durationMinutes: Int? = nil,
        priority: String? = nil,
        recurrence: RuntimeRecurrenceRule? = nil,
        recurrenceOperation: String? = nil,
        note: String? = nil,
        clearFields: [String]? = nil,
        queryKind: String? = nil,
        queryTerm: String? = nil,
        queryPeriod: String? = nil,
        analysisKind: String? = nil,
        horizonDays: Int? = nil,
        budgetMinutes: Int? = nil,
        hypotheticalDurationMinutes: Int? = nil,
        reply: String? = nil,
        confidence: Double? = nil
    ) {
        self.type = type
        self.task = task
        self.raw = raw
        self.target = target
        self.when = when
        self.deadline = deadline
        self.time = time
        self.durationMinutes = durationMinutes
        self.priority = priority
        self.recurrence = recurrence
        self.recurrenceOperation = recurrenceOperation
        self.note = note
        self.clearFields = clearFields
        self.queryKind = queryKind
        self.queryTerm = queryTerm
        self.queryPeriod = queryPeriod
        self.analysisKind = analysisKind
        self.horizonDays = horizonDays
        self.budgetMinutes = budgetMinutes
        self.hypotheticalDurationMinutes = hypotheticalDurationMinutes
        self.reply = reply
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

    public init(
        disposition: RuntimeDisposition,
        appliedKinds: [String],
        tasks: [RuntimeTask]
    ) {
        self.disposition = disposition
        self.appliedKinds = appliedKinds
        self.tasks = tasks
    }
}

public struct RuntimeTurnResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let outcome: RuntimeTurnOutcome

    public init(version: Int, requestID: String, outcome: RuntimeTurnOutcome) {
        self.version = version
        self.requestID = requestID
        self.outcome = outcome
    }
}

public enum RuntimeStateError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidState
}

public enum RuntimeInboundStatus: String, Codable, Equatable, Sendable {
    case pending
    case completed
    case quarantined
}

public struct RuntimeInboundRecord: Codable, Equatable, Sendable {
    public let sequence: Int
    public let request: RuntimeTurnRequest
    public let receivedAt: String
    public let status: RuntimeInboundStatus
    public let updatedAt: String
    public let failureCode: String?

    public init(
        sequence: Int,
        request: RuntimeTurnRequest,
        receivedAt: String,
        status: RuntimeInboundStatus,
        updatedAt: String,
        failureCode: String? = nil
    ) {
        self.sequence = sequence
        self.request = request
        self.receivedAt = receivedAt
        self.status = status
        self.updatedAt = updatedAt
        self.failureCode = failureCode
    }
}

public enum RuntimeOutboundStatus: String, Codable, Equatable, Sendable {
    case pending
    case delivered
}

public struct RuntimeDeliverySummary: Codable, Equatable, Sendable {
    public let disposition: RuntimeDisposition
    public let appliedKinds: [String]
    public let affectedTaskIDs: [String]

    public init(
        disposition: RuntimeDisposition,
        appliedKinds: [String],
        affectedTaskIDs: [String]
    ) {
        self.disposition = disposition
        self.appliedKinds = appliedKinds
        self.affectedTaskIDs = affectedTaskIDs
    }
}

public struct RuntimeOutboundRecord: Codable, Equatable, Sendable {
    public let sequence: Int
    public let requestID: String
    public let dedupeKey: String
    public let createdAt: String
    public let status: RuntimeOutboundStatus
    public let deliveredAt: String?
    public let attempts: Int
    public let lastFailureCode: String?
    public let summary: RuntimeDeliverySummary

    public init(
        sequence: Int,
        requestID: String,
        dedupeKey: String,
        createdAt: String,
        status: RuntimeOutboundStatus,
        deliveredAt: String? = nil,
        attempts: Int = 0,
        lastFailureCode: String? = nil,
        summary: RuntimeDeliverySummary
    ) {
        self.sequence = sequence
        self.requestID = requestID
        self.dedupeKey = dedupeKey
        self.createdAt = createdAt
        self.status = status
        self.deliveredAt = deliveredAt
        self.attempts = attempts
        self.lastFailureCode = lastFailureCode
        self.summary = summary
    }
}

public struct RuntimePipelineStatus: Codable, Equatable, Sendable {
    public let pendingInbound: Int
    public let completedInbound: Int
    public let quarantinedInbound: Int
    public let pendingOutbound: Int
    public let deliveredOutbound: Int
    public let failedDeliveryAttempts: Int

    public var needsAttention: Bool {
        quarantinedInbound > 0 || failedDeliveryAttempts > 0
    }
}

public struct RuntimePersistentState: Codable, Equatable, Sendable {
    public static let currentVersion = 8

    public let version: Int
    public let tasks: [RuntimeTask]
    public let undoSnapshots: [[RuntimeTask]]
    public let inbox: [RuntimeInboundRecord]
    public let outbox: [RuntimeOutboundRecord]
    public let nextSequence: Int
    public let latestProposal: RuntimeScheduleProposal?
    public let adoptedSchedule: RuntimeAdoptedSchedule?
    public let calendarCleanupEventIDs: [String]
    public let notificationCleanupIDs: [String]
    public let pendingNotificationResponses: [RuntimeNotificationResponse]
    public let taskOperations: [RuntimeTaskOperation]

    public init(
        version: Int = RuntimePersistentState.currentVersion,
        tasks: [RuntimeTask],
        undoSnapshots: [[RuntimeTask]],
        inbox: [RuntimeInboundRecord] = [],
        outbox: [RuntimeOutboundRecord] = [],
        nextSequence: Int = 1,
        latestProposal: RuntimeScheduleProposal? = nil,
        adoptedSchedule: RuntimeAdoptedSchedule? = nil,
        calendarCleanupEventIDs: [String] = [],
        notificationCleanupIDs: [String] = [],
        pendingNotificationResponses: [RuntimeNotificationResponse] = [],
        taskOperations: [RuntimeTaskOperation]? = nil
    ) {
        self.version = version
        self.tasks = tasks
        self.undoSnapshots = undoSnapshots
        self.inbox = inbox
        self.outbox = outbox
        self.nextSequence = nextSequence
        self.latestProposal = latestProposal
        self.adoptedSchedule = adoptedSchedule
        self.calendarCleanupEventIDs = calendarCleanupEventIDs
        self.notificationCleanupIDs = notificationCleanupIDs
        self.pendingNotificationResponses = pendingNotificationResponses
        self.taskOperations = taskOperations ?? tasks.map {
            RuntimeTaskOperation(
                id: "baseline-\($0.id)",
                taskID: $0.id,
                occurredAt: $0.updatedAt,
                task: $0
            )
        }
    }

    public static let empty = RuntimePersistentState(tasks: [], undoSnapshots: [])

    public var pipelineStatus: RuntimePipelineStatus {
        RuntimePipelineStatus(
            pendingInbound: inbox.count { $0.status == .pending },
            completedInbound: inbox.count { $0.status == .completed },
            quarantinedInbound: inbox.count { $0.status == .quarantined },
            pendingOutbound: outbox.count { $0.status == .pending },
            deliveredOutbound: outbox.count { $0.status == .delivered },
            failedDeliveryAttempts: outbox.reduce(0) {
                $0 + ($1.status == .pending ? $1.attempts : 0)
            }
        )
    }

    public func validated() throws -> RuntimePersistentState {
        guard (1...Self.currentVersion).contains(version) else {
            throw RuntimeStateError.unsupportedVersion
        }
        let migrated: RuntimePersistentState
        if version < Self.currentVersion {
            if version == 1,
               (!inbox.isEmpty || !outbox.isEmpty || nextSequence != 1) {
                throw RuntimeStateError.invalidState
            }
            migrated = RuntimePersistentState(
                tasks: tasks,
                undoSnapshots: undoSnapshots,
                inbox: version == 1 ? [] : inbox,
                outbox: version == 1 ? [] : outbox,
                nextSequence: version == 1 ? 1 : nextSequence,
                latestProposal: version >= 3 ? latestProposal : nil,
                adoptedSchedule: version >= 3 ? adoptedSchedule : nil,
                calendarCleanupEventIDs: version >= 5
                    ? calendarCleanupEventIDs : [],
                notificationCleanupIDs: version >= 6
                    ? notificationCleanupIDs : [],
                pendingNotificationResponses: version >= 6
                    ? pendingNotificationResponses : [],
                taskOperations: version >= 7 ? taskOperations : tasks.map {
                    RuntimeTaskOperation(
                        id: "baseline-\($0.id)",
                        taskID: $0.id,
                        occurredAt: $0.updatedAt,
                        task: $0
                    )
                }
            )
        } else {
            migrated = self
        }
        guard migrated.tasks.count <= 10_000,
              migrated.undoSnapshots.count <= 100,
              migrated.inbox.count <= 10_000,
              migrated.outbox.count <= 10_000,
              migrated.calendarCleanupEventIDs.count <= 10_000,
              Set(migrated.calendarCleanupEventIDs).count
                == migrated.calendarCleanupEventIDs.count,
              migrated.calendarCleanupEventIDs.allSatisfy({
                  Self.validIdentifier($0, maxBytes: 1_024)
              }),
              migrated.notificationCleanupIDs.count <= 10_000,
              Set(migrated.notificationCleanupIDs).count
                == migrated.notificationCleanupIDs.count,
              migrated.notificationCleanupIDs.allSatisfy({
                  Self.validIdentifier($0, maxBytes: 512)
              }),
              migrated.pendingNotificationResponses.count <= 100,
              Set(migrated.pendingNotificationResponses.map(\.id)).count
                == migrated.pendingNotificationResponses.count,
              migrated.pendingNotificationResponses.allSatisfy(\.isValid),
              migrated.taskOperations.count <= 50_000,
              Set(migrated.taskOperations.map(\.id)).count
                == migrated.taskOperations.count,
              migrated.taskOperations.allSatisfy(\.isValid),
              migrated.nextSequence > 0 else {
            throw RuntimeStateError.invalidState
        }
        try Self.validate(migrated.tasks)
        guard (try? RuntimeTaskOperationMerge.tasks(
            from: migrated.taskOperations
        )) == migrated.tasks.sorted(by: { $0.id < $1.id }) else {
            throw RuntimeStateError.invalidState
        }
        for snapshot in migrated.undoSnapshots {
            guard snapshot.count <= 10_000 else { throw RuntimeStateError.invalidState }
            try Self.validate(snapshot)
        }
        try Self.validatePipeline(migrated)
        guard RuntimeScheduleValidator.valid(migrated.latestProposal),
              RuntimeScheduleValidator.valid(migrated.adoptedSchedule) else {
            throw RuntimeStateError.invalidState
        }
        return migrated
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case tasks
        case undoSnapshots
        case inbox
        case outbox
        case nextSequence
        case latestProposal
        case adoptedSchedule
        case calendarCleanupEventIDs
        case notificationCleanupIDs
        case pendingNotificationResponses
        case taskOperations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        tasks = try container.decode([RuntimeTask].self, forKey: .tasks)
        undoSnapshots = try container.decode([[RuntimeTask]].self, forKey: .undoSnapshots)
        inbox = try container.decodeIfPresent(
            [RuntimeInboundRecord].self,
            forKey: .inbox
        ) ?? []
        outbox = try container.decodeIfPresent(
            [RuntimeOutboundRecord].self,
            forKey: .outbox
        ) ?? []
        nextSequence = try container.decodeIfPresent(Int.self, forKey: .nextSequence) ?? 1
        latestProposal = try container.decodeIfPresent(
            RuntimeScheduleProposal.self,
            forKey: .latestProposal
        )
        adoptedSchedule = try container.decodeIfPresent(
            RuntimeAdoptedSchedule.self,
            forKey: .adoptedSchedule
        )
        calendarCleanupEventIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .calendarCleanupEventIDs
        ) ?? []
        notificationCleanupIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .notificationCleanupIDs
        ) ?? []
        pendingNotificationResponses = try container.decodeIfPresent(
            [RuntimeNotificationResponse].self,
            forKey: .pendingNotificationResponses
        ) ?? []
        taskOperations = try container.decodeIfPresent(
            [RuntimeTaskOperation].self,
            forKey: .taskOperations
        ) ?? tasks.map {
            RuntimeTaskOperation(
                id: "baseline-\($0.id)",
                taskID: $0.id,
                occurredAt: $0.updatedAt,
                task: $0
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(undoSnapshots, forKey: .undoSnapshots)
        try container.encode(inbox, forKey: .inbox)
        try container.encode(outbox, forKey: .outbox)
        try container.encode(nextSequence, forKey: .nextSequence)
        try container.encodeIfPresent(latestProposal, forKey: .latestProposal)
        try container.encodeIfPresent(adoptedSchedule, forKey: .adoptedSchedule)
        try container.encode(calendarCleanupEventIDs, forKey: .calendarCleanupEventIDs)
        try container.encode(notificationCleanupIDs, forKey: .notificationCleanupIDs)
        try container.encode(
            pendingNotificationResponses,
            forKey: .pendingNotificationResponses
        )
        try container.encode(taskOperations, forKey: .taskOperations)
    }

    private static func validatePipeline(_ state: RuntimePersistentState) throws {
        var inboundIDs: Set<String> = []
        var inboundSequences: Set<Int> = []
        for record in state.inbox {
            guard record.sequence > 0,
                  inboundSequences.insert(record.sequence).inserted,
                  validRequest(record.request),
                  inboundIDs.insert(record.request.requestID).inserted,
                  validTimestamp(record.receivedAt),
                  validTimestamp(record.updatedAt),
                  validFailureCode(record.failureCode),
                  (record.status == .quarantined) == (record.failureCode != nil)
            else { throw RuntimeStateError.invalidState }
        }
        let inboundByID = Dictionary(
            uniqueKeysWithValues: state.inbox.map { ($0.request.requestID, $0) }
        )

        var outboundIDs: Set<String> = []
        var outboundKeys: Set<String> = []
        var outboundSequences: Set<Int> = []
        var outboundCountByRequestID: [String: Int] = [:]
        for record in state.outbox {
            guard record.sequence > 0,
                  outboundSequences.insert(record.sequence).inserted,
                  validIdentifier(record.requestID),
                  outboundIDs.insert(record.requestID).inserted,
                  validIdentifier(record.dedupeKey, maxBytes: 256),
                  record.dedupeKey == "turn:\(record.requestID)",
                  outboundKeys.insert(record.dedupeKey).inserted,
                  validTimestamp(record.createdAt),
                  record.attempts >= 0,
                  record.attempts <= 1_000,
                  validFailureCode(record.lastFailureCode),
                  record.summary.appliedKinds.count <= 32,
                  record.summary.appliedKinds.allSatisfy({ validIdentifier($0) }),
                  record.summary.affectedTaskIDs.count <= 64,
                  Set(record.summary.affectedTaskIDs).count == record.summary.affectedTaskIDs.count,
                  record.summary.affectedTaskIDs.allSatisfy({ validIdentifier($0) })
            else { throw RuntimeStateError.invalidState }
            if record.status == .pending && record.deliveredAt != nil {
                throw RuntimeStateError.invalidState
            }
            if record.status == .delivered && !validTimestamp(record.deliveredAt) {
                throw RuntimeStateError.invalidState
            }
            guard let inbound = inboundByID[record.requestID],
                  inbound.status == .completed,
                  inbound.sequence == record.sequence else {
                throw RuntimeStateError.invalidState
            }
            outboundCountByRequestID[record.requestID, default: 0] += 1
        }
        for inbound in state.inbox {
            let outboundCount = outboundCountByRequestID[inbound.request.requestID] ?? 0
            guard (inbound.status == .completed && outboundCount == 1)
                    || (inbound.status != .completed && outboundCount == 0)
            else { throw RuntimeStateError.invalidState }
        }
        let largestSequence = max(
            state.inbox.map(\.sequence).max() ?? 0,
            state.outbox.map(\.sequence).max() ?? 0
        )
        guard state.nextSequence > largestSequence else {
            throw RuntimeStateError.invalidState
        }
    }

    private static func validRequest(_ request: RuntimeTurnRequest) -> Bool {
        request.version == 1
            && validIdentifier(request.requestID)
            && request.message.utf8.count <= 20_000
            && request.now.utf8.count <= 64
            && request.timezone.utf8.count <= 64
            && TimeZone(identifier: request.timezone) != nil
            && validTimestamp(request.now)
            && !request.actions.isEmpty
            && request.actions.count <= 32
            && request.actions.allSatisfy(validAction)
    }

    private static func validAction(_ action: RuntimeAction) -> Bool {
        validIdentifier(action.type)
            && bounded(action.task, maxBytes: 10_000)
            && bounded(action.raw, maxBytes: 20_000)
            && bounded(action.target, maxBytes: 128)
            && bounded(action.time, maxBytes: 16)
            && (action.durationMinutes.map { (5...480).contains($0) } ?? true)
            && (action.priority.map { ["high", "normal", "low"].contains($0) } ?? true)
            && (action.recurrence?.isValid ?? true)
            && (action.recurrenceOperation.map {
                ["skip", "stop"].contains($0)
            } ?? true)
            && bounded(action.note, maxBytes: 10_000)
            && (action.clearFields.map {
                $0.count <= 8 && Set($0).count == $0.count
                    && $0.allSatisfy {
                        ["date", "time", "deadline", "duration", "priority", "note"].contains($0)
                    }
            } ?? true)
            && (action.queryKind.map {
                ["today", "date", "all", "overdue", "week", "search", "done", "waiting"].contains($0)
            } ?? true)
            && bounded(action.queryTerm, maxBytes: 1_000)
            && (action.queryPeriod.map { ["today", "week", "all"].contains($0) } ?? true)
            && (action.analysisKind.map {
                ["capacity", "explain", "what_if"].contains($0)
            } ?? true)
            && (action.horizonDays.map { (1...31).contains($0) } ?? true)
            && (action.budgetMinutes.map { (5...10_080).contains($0) } ?? true)
            && (action.hypotheticalDurationMinutes.map {
                (5...480).contains($0)
            } ?? true)
            && bounded(action.reply, maxBytes: 500)
            && (action.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && (action.when.map(validDateIntent) ?? true)
            && (action.deadline.map(validDateIntent) ?? true)
    }

    private static func validDateIntent(_ value: RuntimeDateIntent) -> Bool {
        validIdentifier(value.kind)
            && bounded(value.which, maxBytes: 32)
            && bounded(value.day, maxBytes: 32)
            && bounded(value.unit, maxBytes: 32)
            && bounded(value.part, maxBytes: 32)
            && bounded(value.anchor, maxBytes: 32)
            && (value.n.map { (1...10_000).contains($0) } ?? true)
            && (value.year.map { (1...9999).contains($0) } ?? true)
            && (value.month.map { (1...12).contains($0) } ?? true)
            && (value.dayNumber.map { (1...31).contains($0) } ?? true)
    }

    private static func bounded(_ value: String?, maxBytes: Int) -> Bool {
        value.map { $0.utf8.count <= maxBytes } ?? true
    }

    private static func validIdentifier(_ value: String, maxBytes: Int = 128) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value && value.utf8.count <= maxBytes
    }

    private static func validFailureCode(_ value: String?) -> Bool {
        guard let value else { return true }
        return validIdentifier(value, maxBytes: 64)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func validTimestamp(_ value: String?) -> Bool {
        guard let value else { return false }
        return ISO8601DateFormatter().date(from: value) != nil
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
                  validTime(task.dueTime),
                  validDate(task.deadlineDate),
                  (task.durationMinutes.map { (5...480).contains($0) } ?? true),
                  (task.priority.map { ["high", "normal", "low"].contains($0) } ?? true),
                  (task.recurrence?.isValid ?? true),
                  (task.note.map { $0.utf8.count <= 10_000 } ?? true),
                  (task.waitingSince.map { validTimestamp($0) } ?? true),
                  (task.completionHistory.map {
                      $0.count <= 10_000 && $0.allSatisfy(validTimestamp)
                  } ?? true),
                  (task.sourceArchive.map { $0.utf8.count <= 20_000 } ?? true),
                  task.dueDate == nil || task.deadlineDate == nil
                    || task.dueDate! <= task.deadlineDate! else {
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
        if actions.contains(where: { $0.type == "acknowledge" }) {
            guard actions == [RuntimeAction(type: "acknowledge")] else {
                return outcome(.rejected)
            }
            return outcome(.applied, kinds: ["acknowledge"])
        }
        if actions.contains(where: { $0.type == "social" }) {
            guard actions.count == 1,
                  let reply = actions[0].reply?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ),
                  !reply.isEmpty,
                  actions[0] == RuntimeAction(type: "social", reply: reply)
            else { return outcome(.rejected) }
            return outcome(.applied, kinds: ["social"])
        }
        if actions.contains(where: { $0.type == "undo" }) {
            guard actions.count == 1 else { return outcome(.rejected) }
            guard let snapshot = undoSnapshots.popLast() else {
                return outcome(.noChange)
            }
            let current = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            tasks = snapshot.map { restored in
                guard current[restored.id] != restored else { return restored }
                var updated = restored
                updated.updatedAt = now
                return updated
            }
            return outcome(.applied, kinds: ["undo"])
        }
        if actions.contains(where: { $0.type == "replan" }) {
            guard actions == [RuntimeAction(type: "replan")] else {
                return outcome(.rejected)
            }
            return outcome(.applied, kinds: ["replan"])
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
            var dueDate: String?
            switch resolve(action.when, now: now, timezone: timezone) {
            case .date(let resolved): dueDate = resolved
            case .ambiguous: return .clarification
            case .invalid: return .rejected
            }
            let deadlineDate: String?
            switch resolve(action.deadline, now: now, timezone: timezone) {
            case .date(let resolved): deadlineDate = resolved
            case .ambiguous: return .clarification
            case .invalid: return .rejected
            }
            let dueTime = validTime(action.time)
            if action.time != nil && dueTime == nil { return .clarification }
            if dueTime != nil && dueDate == nil {
                dueDate = String(now.prefix(10))
            }
            guard action.durationMinutes.map({ (5...480).contains($0) }) ?? true,
                  action.priority.map({ ["high", "normal", "low"].contains($0) }) ?? true
            else { return .clarification }
            if let dueDate, let deadlineDate, dueDate > deadlineDate {
                return .clarification
            }
            if action.recurrence != nil && dueDate == nil {
                dueDate = String(now.prefix(10))
            }
            if let recurrence = action.recurrence,
               let endDate = recurrence.endDate,
               let dueDate,
               endDate < dueDate {
                return .clarification
            }
            let assignedID: String
            if let requested = action.target {
                let clean = requested.trimmingCharacters(in: .whitespacesAndNewlines)
                guard requested == clean,
                      !requested.isEmpty,
                      requested.utf8.count <= 128,
                      !tasks.contains(where: { $0.id == requested }) else {
                    return .rejected
                }
                assignedID = requested
            } else {
                assignedID = "a\(nextID)"
                nextID += 1
            }
            return .success(.capture(RuntimeTask(
                id: assignedID,
                rawText: raw,
                task: task,
                dueDate: dueDate,
                dueTime: dueTime,
                deadlineDate: deadlineDate,
                durationMinutes: action.durationMinutes,
                priority: action.priority,
                recurrence: action.recurrence,
                status: "open",
                createdAt: now,
                updatedAt: now
            )))
        }

        guard [
            "complete", "drop", "reschedule", "amend", "revise", "note",
            "wait", "resume", "keep", "recurrence",
        ].contains(action.type)
        else { return .rejected }
        guard let target = resolvedTarget(action.target) else {
            return .clarification
        }
        if (action.confidence ?? 1.0) < 0.5 {
            return .confirmation
        }
        if action.type == "complete" { return .success(.complete(target)) }
        if action.type == "drop" { return .success(.drop(target)) }
        if action.type == "keep" { return .success(.keep(target)) }
        if action.type == "wait" { return .success(.wait(target)) }
        if action.type == "resume" { return .success(.resume(target)) }
        if action.type == "note" {
            guard let note = bounded(action.note, maxBytes: 10_000) else {
                return .clarification
            }
            let existing = tasks.first(where: { $0.id == target })?.note ?? ""
            guard existing.utf8.count + note.utf8.count + (existing.isEmpty ? 0 : 1)
                    <= 10_000 else { return .clarification }
            return .success(.note(target, note))
        }
        if action.type == "recurrence" {
            guard let operation = action.recurrenceOperation,
                  ["skip", "stop"].contains(operation) else {
                return .clarification
            }
            return .success(.recurrence(target, operation))
        }
        if action.type == "amend" {
            guard let task = bounded(action.task, maxBytes: 10_000) else {
                return .clarification
            }
            return .success(.amend(target, task))
        }
        if action.type == "revise" {
            let clear = Set(action.clearFields ?? [])
            let revisedTask = action.task.flatMap { bounded($0, maxBytes: 10_000) }
            if action.task != nil && revisedTask == nil { return .clarification }
            let revisedNote = action.note.flatMap { bounded($0, maxBytes: 10_000) }
            if action.note != nil && revisedNote == nil { return .clarification }
            let revisedDate: String?
            if let when = action.when {
                switch resolve(when, now: now, timezone: timezone) {
                case .date(let value): revisedDate = value
                case .ambiguous: return .clarification
                case .invalid: return .rejected
                }
            } else {
                revisedDate = nil
            }
            let revisedDeadline: String?
            if let deadline = action.deadline {
                switch resolve(deadline, now: now, timezone: timezone) {
                case .date(let value): revisedDeadline = value
                case .ambiguous: return .clarification
                case .invalid: return .rejected
                }
            } else {
                revisedDeadline = nil
            }
            let revisedTime = validTime(action.time)
            if action.time != nil && revisedTime == nil { return .clarification }
            guard action.durationMinutes.map({ (5...480).contains($0) }) ?? true,
                  action.priority.map({ ["high", "normal", "low"].contains($0) }) ?? true
            else { return .clarification }
            guard revisedTask != nil || revisedNote != nil || action.when != nil
                    || action.deadline != nil || revisedTime != nil
                    || action.durationMinutes != nil || action.priority != nil
                    || !clear.isEmpty else {
                return .clarification
            }
            guard let current = tasks.first(where: { $0.id == target }) else {
                return .clarification
            }
            let finalDate = clear.contains("date") ? nil
                : (action.when != nil ? revisedDate : current.dueDate)
            let finalDeadline = clear.contains("deadline") ? nil
                : (action.deadline != nil ? revisedDeadline : current.deadlineDate)
            if let finalDate, let finalDeadline, finalDate > finalDeadline {
                return .clarification
            }
            return .success(.revise(target, TaskRevision(
                task: revisedTask,
                dueDate: revisedDate,
                hasDueDate: action.when != nil,
                dueTime: revisedTime,
                deadlineDate: revisedDeadline,
                hasDeadlineDate: action.deadline != nil,
                durationMinutes: action.durationMinutes,
                priority: action.priority,
                note: revisedNote,
                clearFields: clear
            )))
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
        case "yesterday":
            resolved = calendar.date(byAdding: .day, value: -1, to: base)
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
        case "offset":
            guard let amount = intent.n, amount > 0 else { return .invalid }
            let component: Calendar.Component
            switch intent.unit {
            case "day": component = .day
            case "week": component = .weekOfYear
            case "month": component = .month
            case "year": component = .year
            default: return .invalid
            }
            resolved = calendar.date(byAdding: component, value: amount, to: base)
        case "weekend":
            let current = calendar.component(.weekday, from: base)
            if intent.which == "this", current == 1 || current == 7 {
                resolved = base
            } else {
                var daysToSaturday = (7 - current + 7) % 7
                if intent.which == "next" {
                    if current != 1 { daysToSaturday += 7 }
                }
                resolved = calendar.date(
                    byAdding: .day, value: daysToSaturday, to: base
                )
            }
        case "week":
            let current = calendar.component(.weekday, from: base)
            let daysSinceMonday = (current + 5) % 7
            guard let thisMonday = calendar.date(
                byAdding: .day, value: -daysSinceMonday, to: base
            ) else { return .invalid }
            let weekOffset = intent.which == "next" ? 7 : 0
            let partOffset: Int
            switch intent.part {
            case nil, "start", "early": partOffset = 0
            case "mid": partOffset = 2
            case "end", "late": partOffset = 4
            default: return .invalid
            }
            resolved = calendar.date(
                byAdding: .day, value: weekOffset + partOffset, to: thisMonday
            )
        case "month":
            var parts = calendar.dateComponents([.year, .month], from: base)
            parts.day = 1
            guard var month = calendar.date(from: parts) else { return .invalid }
            if intent.which == "next" {
                guard let advanced = calendar.date(byAdding: .month, value: 1, to: month)
                else { return .invalid }
                month = advanced
            }
            if intent.anchor == "end" || intent.part == "late" {
                resolved = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: month)
            } else if intent.part == "mid" {
                resolved = calendar.date(byAdding: .day, value: 14, to: month)
            } else {
                resolved = month
            }
        case "month_day", "ordinal_day":
            guard let dayNumber = intent.dayNumber else { return .invalid }
            var parts = calendar.dateComponents([.year, .month], from: base)
            if let month = intent.month { parts.month = month }
            parts.day = dayNumber
            guard var candidate = calendar.date(from: parts),
                  calendar.component(.day, from: candidate) == dayNumber else {
                return .invalid
            }
            if candidate < base {
                let component: Calendar.Component = intent.month == nil ? .month : .year
                guard let advanced = calendar.date(
                    byAdding: component, value: 1, to: candidate
                ) else { return .invalid }
                candidate = advanced
            }
            resolved = candidate
        case "absolute":
            guard let year = intent.year,
                  let month = intent.month,
                  let day = intent.dayNumber else { return .invalid }
            resolved = calendar.date(from: DateComponents(
                calendar: calendar, timeZone: zone,
                year: year, month: month, day: day
            )).flatMap { candidate in
                let values = calendar.dateComponents([.year, .month, .day], from: candidate)
                return values.year == year && values.month == month && values.day == day
                    ? candidate : nil
            }
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
            complete(target, now: now)
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
        case .revise(let target, let revision):
            update(target, now: now) { task in
                if revision.clearFields.contains("date") { task.dueDate = nil }
                if revision.clearFields.contains("time") { task.dueTime = nil }
                if revision.clearFields.contains("deadline") { task.deadlineDate = nil }
                if revision.clearFields.contains("duration") { task.durationMinutes = nil }
                if revision.clearFields.contains("priority") { task.priority = nil }
                if revision.clearFields.contains("note") { task.note = nil }
                if let value = revision.task { task.task = value }
                if revision.hasDueDate { task.dueDate = revision.dueDate }
                if let value = revision.dueTime {
                    task.dueTime = value
                    if task.dueDate == nil { task.dueDate = String(now.prefix(10)) }
                }
                if revision.hasDeadlineDate { task.deadlineDate = revision.deadlineDate }
                if let value = revision.durationMinutes { task.durationMinutes = value }
                if let value = revision.priority { task.priority = value }
                if let value = revision.note { task.note = value }
            }
        case .note(let target, let note):
            update(target, now: now) { task in
                task.note = task.note.map { "\($0)\n\(note)" } ?? note
            }
        case .wait(let target):
            update(target, now: now) { $0.waitingSince = now }
        case .resume(let target):
            update(target, now: now) { $0.waitingSince = nil }
        case .keep(let target):
            update(target, now: now) { _ in }
        case .recurrence(let target, let operation):
            if operation == "stop" {
                update(target, now: now) { $0.recurrence = nil }
            } else {
                skip(target, now: now)
            }
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

    private mutating func complete(_ target: String, now: String) {
        guard let index = tasks.firstIndex(where: { $0.id == target }) else { return }
        var history = tasks[index].completionHistory ?? []
        history.append(now)
        if history.count > 10_000 {
            history.removeFirst(history.count - 10_000)
        }
        tasks[index].completionHistory = history
        guard var recurrence = tasks[index].recurrence else {
            tasks[index].status = "done"
            tasks[index].waitingSince = nil
            tasks[index].updatedAt = now
            return
        }
        recurrence.completed += 1
        if recurrence.count.map({ recurrence.completed >= $0 }) == true {
            tasks[index].status = "done"
            tasks[index].waitingSince = nil
            tasks[index].recurrence = recurrence
            tasks[index].updatedAt = now
            return
        }
        let base = recurrence.anchor == "completion"
            ? String(now.prefix(10))
            : (tasks[index].dueDate ?? String(now.prefix(10)))
        guard let next = nextRecurrenceDate(after: base, rule: recurrence),
              recurrence.endDate.map({ next <= $0 }) ?? true else {
            tasks[index].status = "done"
            tasks[index].waitingSince = nil
            tasks[index].recurrence = recurrence
            tasks[index].updatedAt = now
            return
        }
        tasks[index].dueDate = next
        tasks[index].status = "open"
        tasks[index].recurrence = recurrence
        tasks[index].updatedAt = now
    }

    private mutating func skip(_ target: String, now: String) {
        guard let index = tasks.firstIndex(where: { $0.id == target }),
              let recurrence = tasks[index].recurrence,
              let base = tasks[index].dueDate else { return }
        guard let next = nextRecurrenceDate(after: base, rule: recurrence),
              recurrence.endDate.map({ next <= $0 }) ?? true else {
            tasks[index].status = "done"
            tasks[index].updatedAt = now
            return
        }
        tasks[index].dueDate = next
        tasks[index].updatedAt = now
    }

    private func nextRecurrenceDate(
        after value: String,
        rule: RuntimeRecurrenceRule
    ) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let next: Date?
        switch rule.frequency {
        case "day":
            next = calendar.date(byAdding: .day, value: rule.interval, to: date)
        case "week":
            let weekdayValues = [
                "sun": 1, "mon": 2, "tue": 3, "wed": 4,
                "thu": 5, "fri": 6, "sat": 7,
            ]
            let selected = rule.weekdays.compactMap { weekdayValues[$0] }.sorted()
            if selected.isEmpty {
                next = calendar.date(byAdding: .day, value: 7 * rule.interval, to: date)
            } else {
                let current = calendar.component(.weekday, from: date)
                if let later = selected.first(where: { $0 > current }) {
                    next = calendar.date(byAdding: .day, value: later - current, to: date)
                } else if let first = selected.first {
                    next = calendar.date(
                        byAdding: .day,
                        value: 7 * rule.interval - (current - first),
                        to: date
                    )
                } else { next = nil }
            }
        case "month":
            guard let advanced = calendar.date(
                byAdding: .month, value: rule.interval, to: date
            ) else { return nil }
            if let day = rule.monthDay {
                next = dateClampingDay(day, around: advanced, calendar: calendar)
            } else { next = advanced }
        case "year":
            guard let advanced = calendar.date(
                byAdding: .year, value: rule.interval, to: date
            ) else { return nil }
            if let month = rule.month, let day = rule.monthDay {
                var parts = calendar.dateComponents([.year], from: advanced)
                parts.month = month
                parts.day = 1
                next = calendar.date(from: parts).flatMap {
                    dateClampingDay(day, around: $0, calendar: calendar)
                }
            } else { next = advanced }
        default:
            next = nil
        }
        return next.map(formatter.string)
    }

    private func dateClampingDay(
        _ requestedDay: Int,
        around date: Date,
        calendar: Calendar
    ) -> Date? {
        guard let range = calendar.range(of: .day, in: .month, for: date) else {
            return nil
        }
        var parts = calendar.dateComponents([.year, .month], from: date)
        parts.day = min(requestedDay, range.count)
        return calendar.date(from: parts)
    }
}

private enum PreparedMutation {
    case capture(RuntimeTask)
    case complete(String)
    case drop(String)
    case reschedule(String, String?, String?)
    case amend(String, String)
    case revise(String, TaskRevision)
    case note(String, String)
    case wait(String)
    case resume(String)
    case keep(String)
    case recurrence(String, String)

    var kind: String {
        switch self {
        case .capture: return "capture"
        case .complete: return "complete"
        case .drop: return "drop"
        case .reschedule: return "reschedule"
        case .amend: return "amend"
        case .revise: return "revise"
        case .note: return "note"
        case .wait: return "wait"
        case .resume: return "resume"
        case .keep: return "keep"
        case .recurrence: return "recurrence"
        }
    }
}

private struct TaskRevision {
    let task: String?
    let dueDate: String?
    let hasDueDate: Bool
    let dueTime: String?
    let deadlineDate: String?
    let hasDeadlineDate: Bool
    let durationMinutes: Int?
    let priority: String?
    let note: String?
    let clearFields: Set<String>
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
