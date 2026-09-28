// SPDX-License-Identifier: MIT
import Foundation
import Testing
import HobAppCore
import HobAppStorage
import HobAppleIntelligence
@testable import HobAppExperience

private final class BenchmarkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(days: Int) { lock.withLock { value = value.addingTimeInterval(Double(days) * 86_400) } }
}

// Captures diagnostics only for synthetic fixtures. No application prompts are
// logged, and these tests never use real Calendar, notifications, or iCloud.
private final class BenchmarkTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var actions: [RuntimeAction] = []
    private var focus: [String] = []
    func event(_ value: AppleFoundationInterpreter.DiagnosticEvent) {
        lock.withLock { events.append(value.rawValue) }
    }
    func parsed(_ value: [RuntimeAction], context: RuntimeConversationContext) {
        lock.withLock { actions = value; focus = context.focusedTaskIDs }
    }
    func reset() { lock.withLock { events = []; actions = []; focus = [] } }
    func snapshot() -> ([String], [RuntimeAction], [String]) {
        lock.withLock { (events, actions, focus) }
    }
}

private struct BenchmarkInterpreter: RuntimeMessageInterpreting {
    let trace: BenchmarkTrace
    func interpret(message: String, now: String, timezone: String,
                   tasks: [RuntimeTask]) async throws -> [RuntimeAction] {
        try await interpret(message: message, now: now, timezone: timezone,
                            tasks: tasks, context: .empty)
    }
    func interpret(message: String, now: String, timezone: String,
                   tasks: [RuntimeTask], context: RuntimeConversationContext) async throws -> [RuntimeAction] {
        trace.parsed([], context: context)
        let result = try await AppleFoundationInterpreter(onDiagnostic: trace.event).interpret(
            message: message, now: now, timezone: timezone, tasks: tasks, context: context)
        trace.parsed(result, context: context)
        return result
    }
}

private struct BenchmarkRow: Codable {
    let id: String
    let category: String
    let split: String
    let repetition: Int
    let turn: Int
    let message: String
    let seconds: Double
    let events: [String]
    let actions: [RuntimeAction]
    let focus: [String]
    let tasks: [RuntimeTask]
    let reply: String
    let failures: [String]
    let unintendedMutation: Bool
    let presentedQuestion: RuntimePendingQuestion?
}

private struct BenchmarkReport: Codable {
    var version = 1
    let completed: Bool
    let revision: String
    let operatingSystem: String
    let split: String
    let repetitions: Int
    let rows: [BenchmarkRow]
    let p50Seconds: Double
    let p95Seconds: Double
    let maxSeconds: Double
    let passed: Bool
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HOB_MESSAGE_BENCHMARK"] == "1"))
struct MessageBenchmarkTests {
    @Test @MainActor
    func liveBehaviorBenchmark() async throws {
        guard AppleFoundationInterpreter().isAvailable else {
            Issue.record("LIVE MODEL UNAVAILABLE: benchmark was not run; this is not a pass.")
            return
        }
        let env = ProcessInfo.processInfo.environment
        let split = env["HOB_BENCHMARK_SPLIT"] ?? "development"
        let repeats = max(1, Int(env["HOB_BENCHMARK_REPEATS"] ?? "2") ?? 2)
        let selected = split == "matrix" ? MessageBenchmarkCorpus.interactionMatrix
            : split == "interaction" ? MessageBenchmarkCorpus.interactionChallenge
            : split == "device" ? MessageBenchmarkCorpus.device + MessageBenchmarkCorpus.interactionChallenge
            : split == "fresh" ? MessageBenchmarkCorpus.freshChallenge
            : split == "challenge" ? MessageBenchmarkCorpus.challenge + MessageBenchmarkCorpus.freshChallenge
            : split == "all" ? MessageBenchmarkCorpus.development + MessageBenchmarkCorpus.challenge + MessageBenchmarkCorpus.freshChallenge + MessageBenchmarkCorpus.interactionChallenge + MessageBenchmarkCorpus.interactionMatrix
            : MessageBenchmarkCorpus.development
        let cases = selected.filter { env["HOB_BENCHMARK_CASE"].map($0.id.contains) ?? true }
        guard !cases.isEmpty else { Issue.record("No benchmark cases selected"); return }
        var rows: [BenchmarkRow] = []
        for repetition in 1...repeats {
            for testCase in cases {
                let clock = BenchmarkClock(try #require(ISO8601DateFormatter().date(from: testCase.now)))
                let timezone = try #require(TimeZone(identifier: testCase.timezone))
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hob-benchmark-\(UUID())")
                defer { try? FileManager.default.removeItem(at: directory) }
                let suite = "hob-benchmark-\(UUID())"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = TaskStateStore(directoryURL: directory)
                try store.save(RuntimePersistentState(tasks: testCase.initial, undoSnapshots: []))
                let trace = BenchmarkTrace()
                let notifications = StubNotifications()
                func makeController() -> HobWorkspaceController { HobWorkspaceController(store: store,
                    interpreter: BenchmarkInterpreter(trace: trace), calendarStore: StubCalendar(),
                    notificationStore: notifications, syncStore: StubSync(),
                    defaults: defaults, timezone: timezone, now: { clock.now() }) }
                var controller = makeController()
                await controller.refresh()
                if let taskID = testCase.notificationDoneTaskID {
                    let task = try #require(testCase.initial.first { $0.id == taskID })
                    await notifications.send(RuntimeNotificationResponse(
                        id: "benchmark-done", action: .done, notificationID: "fixture-notification",
                        proposalID: "fixture-proposal", blockID: "fixture-block", taskID: task.id,
                        task: task.task, receivedAt: MessageBenchmarkCorpus.now, taskRevision: task.revision))
                    for _ in 0..<200 {
                        if !controller.isWorking && controller.tasks.first(where: { $0.id == taskID })?.status == "done" { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try #require(controller.tasks.first(where: { $0.id == taskID })?.status == "done",
                                 "Notification prerequisite must complete before the chat flow")
                }
                for (index, turn) in testCase.turns.enumerated() {
                    clock.advance(days: turn.advanceDaysBefore)
                    if turn.restartBefore { controller = makeController() }
                    await controller.refresh()
                    let before = controller.tasks
                    let presentedQuestion = controller.conversationState.pending ?? controller.reviewQuestion
                    let historyCount = controller.conversationMessages.count
                    trace.reset()
                    controller.draft = turn.message
                    let started = ContinuousClock.now
                    controller.submit()
                    if turn.duplicateSubmission { controller.submit() }
                    while controller.isWorking && started.duration(to: .now) < .seconds(60) {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let elapsed = started.duration(to: .now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    let (events, actions, focus) = trace.snapshot()
                    let tasks = controller.tasks
                    let reply = controller.conversationMessages.last?.text ?? ""
                    var failures: [String] = []
                    if controller.isWorking { failures.append("timeout") }
                    if controller.errorMessage != nil { failures.append("interpretation: \(controller.errorMessage!)") }
                    if !turn.kinds.isEmpty && actions.map(\.type) != turn.kinds {
                        failures.append("intent: expected \(turn.kinds), got \(actions.map(\.type))")
                    }
                    if let targetID = turn.targetID {
                        let open = before.filter { $0.status == "open" }.sorted { $0.id < $1.id }
                        let index = actions.first?.target.flatMap(Int.init).map { $0 - 1 }
                        if index == nil || !open.indices.contains(index!) || open[index!].id != targetID {
                            failures.append("target: review reply did not affect the prompted task")
                        }
                    }
                    if turn.unchanged && turn.kinds.isEmpty && !turn.clarification,
                       !actions.allSatisfy({ ["social", "acknowledge"].contains($0.type) }) {
                        failures.append("intent: a nonaction must not request a task mutation")
                    }
                    let stateMatches = turn.unchanged ? tasks == before
                        : tasks.count == turn.expected.count && turn.expected.allSatisfy { expected in
                            tasks.filter(expected.matches).count == 1
                        }
                    if !stateMatches { failures.append("state: unexpected task contents or constraints") }
                    if try store.load().tasks.sorted(by: { $0.id < $1.id }) != tasks.sorted(by: { $0.id < $1.id }) {
                        failures.append("storage: saved tasks differ from displayed tasks")
                    }
                    let formatter = DateFormatter()
                    formatter.timeZone = timezone; formatter.dateFormat = "yyyy-MM-dd"
                    let today = formatter.string(from: clock.now())
                    let expectedVisible = Set(tasks.filter {
                        $0.status == "open" && ($0.dueDate == nil || $0.dueDate! <= today)
                            && !($0.dueTime != nil && ($0.dueDate ?? "") < today)
                    }.map(\.id))
                    if Set(controller.morningDigest?.items.map(\.taskID) ?? []) != expectedVisible {
                        failures.append("display: digest does not reflect task state")
                    }
                    if !controller.draft.isEmpty || controller.conversationMessages.count != historyCount + 2
                        || controller.conversationMessages.dropFirst(historyCount).first?.text != turn.message || reply.isEmpty {
                        failures.append("conversation: missing prompt/reply or uncleared composer")
                    }
                    if turn.clarification {
                        let pending = controller.conversationState.pending
                        if pending == nil || pending?.text != reply || pending?.originalMessage != turn.message
                            || (turn.questionKind != nil && pending?.kind != turn.questionKind)
                            || pending?.isValid(tasks: tasks, day: today, timezone: timezone.identifier) != true {
                            failures.append("clarification: missing or mismatched typed question, target, or original request")
                        }
                    }
                    if let expected = turn.replyContains, !reply.localizedCaseInsensitiveContains(expected) {
                        failures.append("response: missing expected task reference")
                    }
                    if turn.replyExcludes.contains(where: { reply.localizedCaseInsensitiveContains($0) }) {
                        failures.append("response: contains an excluded task")
                    }
                    if turn.proposal && controller.proposal?.blocks.isEmpty != false {
                        failures.append("planning: missing proposed schedule")
                    }
                    if turn.kinds == ["complete"] && stateMatches && !reply.hasPrefix("Done:") {
                        failures.append("response: completion must name what was marked done")
                    }
                    if turn.kinds == ["complete"], let expected = turn.expected.first(where: { expected in
                        expected.status == "done" && before.contains { $0.status == "open" && $0.task.localizedCaseInsensitiveContains(expected.words) }
                    }),
                       let target = before.first(where: { $0.task.localizedCaseInsensitiveContains(expected.words) }), target.recurrence == nil {
                        failures += try InteractionEffectOracle.completion(before: before, after: tasks,
                            saved: store.load().tasks, taskID: turn.targetID ?? target.id, reply: reply)
                    }
                    let unintended = !stateMatches && tasks != before
                    let row = BenchmarkRow(id: testCase.id, category: testCase.category,
                        split: testCase.split, repetition: repetition, turn: index,
                        message: turn.message, seconds: seconds, events: events, actions: actions,
                        focus: focus, tasks: tasks, reply: reply, failures: failures,
                        unintendedMutation: unintended, presentedQuestion: presentedQuestion)
                    rows.append(row)
                    print("BENCHMARK \(failures.isEmpty ? "PASS" : "FAIL") \(testCase.id)/\(index) \(String(format: "%.2f", seconds))s \(failures.joined(separator: "; "))")
                    // Write after every turn so interruption retains diagnostic evidence.
                    try writeReport(rows, split: split, repeats: repeats, env: env)
                    if controller.isWorking { Issue.record("Benchmark timed out; aborting to avoid overlapping model calls"); return }
                    if !failures.isEmpty { break } // dependent turns cannot be scored after a failed prerequisite
                }
            }
        }
        let report = try writeReport(rows, split: split, repeats: repeats, env: env, completed: true)
        let passed = report.passed
        print("BENCHMARK SUMMARY \(rows.count) turns; p95 \(report.p95Seconds)s; max \(report.maxSeconds)s; passed \(passed)")
        #expect(passed, "Release gate failed; inspect benchmark JSON for failures and latency")
    }

    @discardableResult
    private func writeReport(_ rows: [BenchmarkRow], split: String, repeats: Int,
                             env: [String: String], completed: Bool = false) throws -> BenchmarkReport {
        let times = rows.map(\.seconds).sorted()
        func percentile(_ fraction: Double) -> Double {
            times.isEmpty ? 0 : times[max(0, Int(ceil(Double(times.count) * fraction)) - 1)]
        }
        let report = BenchmarkReport(completed: completed, revision: env["HOB_BENCHMARK_REVISION"] ?? "local worktree",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            split: split, repetitions: repeats, rows: rows, p50Seconds: percentile(0.5),
            p95Seconds: percentile(0.95), maxSeconds: times.last ?? 0,
            passed: completed && !rows.isEmpty && rows.allSatisfy { $0.failures.isEmpty }
                && percentile(0.95) <= (Double(env["HOB_BENCHMARK_P95_SECONDS"] ?? "15") ?? 15)
                && (times.last ?? 0) <= 45)
        if let path = env["HOB_BENCHMARK_REPORT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return report
    }
}
