// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimeTask: Codable, Equatable, Sendable {
    public let id: String
    public let rawText: String
    public var task: String
    public var dueDate: String?
    public var dueTime: String?
    public var deadlineDate: String?
    public var durationMinutes: Int?
    public var priority: String?
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
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceArchive = sourceArchive
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
    public let deadline: RuntimeDateIntent?
    public let time: String?
    public let durationMinutes: Int?
    public let priority: String?
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
    public let planningPreferences: RuntimePlanningPreferences

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
        taskOperations: [RuntimeTaskOperation]? = nil,
        planningPreferences: RuntimePlanningPreferences = .default
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
        self.planningPreferences = planningPreferences
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
                },
                planningPreferences: .default
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
              migrated.planningPreferences.isValid,
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
        case planningPreferences
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
        planningPreferences = try container.decodeIfPresent(
            RuntimePlanningPreferences.self,
            forKey: .planningPreferences
        ) ?? .default
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
        try container.encode(planningPreferences, forKey: .planningPreferences)
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
            && (action.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && (action.when.map {
                validIdentifier($0.kind)
                    && bounded($0.which, maxBytes: 32)
                    && bounded($0.day, maxBytes: 32)
            } ?? true)
            && (action.deadline.map {
                validIdentifier($0.kind)
                    && bounded($0.which, maxBytes: 32)
                    && bounded($0.day, maxBytes: 32)
            } ?? true)
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
            let dueDate: String?
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
            guard action.durationMinutes.map({ (5...480).contains($0) }) ?? true,
                  action.priority.map({ ["high", "normal", "low"].contains($0) }) ?? true
            else { return .clarification }
            if let dueDate, let deadlineDate, dueDate > deadlineDate {
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
                status: "open",
                createdAt: now,
                updatedAt: now
            )))
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
