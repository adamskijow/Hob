// SPDX-License-Identifier: MIT
import Foundation
import Testing
import HobAppCore
import HobAppStorage

/// An effect oracle independent of interpreter actions and title matching.
/// A successful completion must affect exactly the specified durable identity.
enum InteractionEffectOracle {
    static func completion(before: [RuntimeTask], after: [RuntimeTask], saved: [RuntimeTask],
                           taskID: String, reply: String) throws -> [String] {
        var failures: [String] = []
        if Set(before.map(\.id)) != Set(after.map(\.id)) { failures.append("unexpected IDs") }
        if saved.sorted(by: { $0.id < $1.id }) != after.sorted(by: { $0.id < $1.id }) { failures.append("not saved") }
        for original in before {
            guard let actual = after.first(where: { $0.id == original.id }) else { failures.append("missing task"); continue }
            if original.id != taskID {
                if original != actual { failures.append("unrelated task changed") }
                continue
            }
            if actual.status != "done" { failures.append("not completed") }
            if (actual.completionHistory?.count ?? 0) != (original.completionHistory?.count ?? 0) + 1 { failures.append("completion not recorded exactly once") }
            func immutableFields(_ task: RuntimeTask) throws -> NSDictionary {
                var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
                for field in ["status", "updatedAt", "revisionID", "completionHistory"] { fields.removeValue(forKey: field) }
                return fields as NSDictionary
            }
            if try immutableFields(actual) != immutableFields(original) { failures.append("unrequested field changed") }
            if !reply.hasPrefix("Done:") || !reply.contains(original.task) { failures.append("untruthful reply") }
        }
        return failures
    }
}

@Test @MainActor
func injectedFaultsAreDetectedByEffectOracle() async throws {
    let initial = [MessageBenchmarkCorpus.task("a1", "Call Alex"), MessageBenchmarkCorpus.task("a2", "Call Sam")]
    let faults = ["control", "lost-context", "wrong-target", "wrong-status", "duplicate-action", "missing-save", "false-success", "unrelated-field"]
    var results: [[String: Any]] = []
    for fault in faults {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hob-fault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStateStore(directoryURL: directory)
        try store.save(RuntimePersistentState(tasks: initial, undoSnapshots: []))
        let runtime = try DurableTaskRuntime(store: store)
        var actions = [RuntimeAction(type: "complete", target: "a1")]
        switch fault {
        case "lost-context": actions = [.init(type: "capture", task: "Done", raw: "Done")]
        case "wrong-target": actions = [.init(type: "complete", target: "a2")]
        case "wrong-status": actions = [.init(type: "drop", target: "a1")]
        case "duplicate-action": actions += [.init(type: "capture", task: "Done", raw: "Done")]
        case "false-success": actions = [.init(type: "social", reply: "Done: Call Alex.")]
        default: break
        }
        _ = try await runtime.process(RuntimeTurnRequest(requestID: UUID().uuidString, message: "Call Alex is done",
            now: MessageBenchmarkCorpus.now, timezone: "America/New_York", actions: actions))
        var after = await runtime.snapshot().tasks
        if fault == "unrelated-field" {
            after[1].dueTime = "09:00"
        }
        let saved = fault == "missing-save" ? initial : try store.load().tasks
        let failures = try InteractionEffectOracle.completion(before: initial, after: after, saved: saved,
                                                              taskID: "a1", reply: "Done: Call Alex.")
        let expected = fault == "control" ? failures.isEmpty : !failures.isEmpty
        #expect(expected, "Oracle failed to distinguish \(fault): \(failures)")
        results.append(["fault": fault, "passed": expected, "detections": failures])
    }
    if let path = ProcessInfo.processInfo.environment["HOB_FAULT_REPORT"] {
        try JSONSerialization.data(withJSONObject: ["results": results], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

@Test func questionStateInvalidatesOnRevisionDayOrTimezoneChange() throws {
    let task = MessageBenchmarkCorpus.task("a1", "Plan picnic", stale: true)
    let question = RuntimePendingQuestion(kind: .chooseDate, text: RuntimeInteraction.moveDateQuestion,
        originalMessage: "Move", taskIDs: [task.id], tasks: [task], day: "2026-09-07", timezone: "America/New_York")
    #expect(question.isValid(tasks: [task], day: "2026-09-07", timezone: "America/New_York"))
    #expect(!question.isValid(tasks: [], day: "2026-09-07", timezone: "America/New_York"))
    #expect(!question.isValid(tasks: [task], day: "2026-09-08", timezone: "America/New_York"))
    #expect(!question.isValid(tasks: [task], day: "2026-09-07", timezone: "Europe/London"))
    let renamed = MessageBenchmarkCorpus.task("a1", "Plan a different picnic", stale: true)
    #expect(!question.isValid(tasks: [renamed], day: "2026-09-07", timezone: "America/New_York"))
    let restored = try JSONDecoder().decode(RuntimePendingQuestion.self, from: JSONEncoder().encode(question))
    #expect(restored == question)
}
