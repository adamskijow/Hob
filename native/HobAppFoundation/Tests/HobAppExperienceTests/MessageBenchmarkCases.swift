// SPDX-License-Identifier: MIT
import Foundation
import HobAppCore

// Reviewed behavioral expectations. Challenge topics and constructions are kept
// separate from development cases; do not copy them into interpreter prompts.
struct MessageBenchmarkCase: Sendable {
    let id: String
    let category: String
    var split = "development"
    var source = "behavior specification"
    var initial: [RuntimeTask] = []
    var notificationDoneTaskID: String? = nil
    var now = MessageBenchmarkCorpus.now
    var timezone = "America/New_York"
    let turns: [MessageBenchmarkTurn]
}

struct MessageBenchmarkTurn: Sendable {
    let message: String
    var kinds: [String] = []
    var expected: [BenchmarkTask] = []
    var unchanged = false
    var clarification = false
    var proposal = false
    var replyContains: String? = nil
    var targetID: String? = nil
    var restartBefore = false
    var advanceDaysBefore = 0
    var duplicateSubmission = false
    var questionKind: RuntimeInteraction? = nil
    var replyExcludes: [String] = []
}

struct BenchmarkTask: Sendable {
    let words: String
    var status = "open"
    var date: String? = nil
    var time: String? = nil
    var deadline: String? = nil
    var recurrence: String? = nil
    var duration: Int? = nil
    var priority: String? = nil
    var note: String? = nil
    var reviewPolicy: String? = nil

    func matches(_ task: RuntimeTask) -> Bool {
        task.task.localizedCaseInsensitiveContains(words)
            && task.status == status && task.dueDate == date
            && task.dueTime == time && task.deadlineDate == deadline
            && task.recurrence?.frequency == recurrence
            && task.durationMinutes == duration
            && (priority == nil ? (task.priority == nil || task.priority == "normal") : task.priority == priority)
            && task.note == note && task.reviewPolicy == reviewPolicy && task.waitingSince == nil
            && (task.recurrence == nil || task.recurrence?.interval == 1)
    }
}

enum MessageBenchmarkCorpus {
    static var device: [MessageBenchmarkCase] {
        let ids: Set<String> = ["capture-1", "nonaction-1", "complete-2", "deadline", "coordinated",
                                "capture-chain", "ambiguous-target", "notification-to-chat", "ongoing-review-policy"]
        return development.filter { ids.contains($0.id) || $0.id.hasPrefix("review-") || $0.id.hasPrefix("command-title-") }
    }
    static let now = "2026-09-07T08:00:00-04:00"
    static func task(_ id: String, _ title: String, date: String? = nil,
                     time: String? = nil, stale: Bool = false) -> RuntimeTask {
        RuntimeTask(id: id, rawText: title, task: title, dueDate: date,
                    dueTime: time, status: "open",
                    createdAt: stale ? "2026-08-30T08:00:00-04:00" : now,
                    updatedAt: stale ? "2026-08-30T08:00:00-04:00" : now)
    }

    static var development: [MessageBenchmarkCase] {
        let report = task("a1", "Finish report")
        let plants = task("a2", "Water plants")
        var result: [MessageBenchmarkCase] = []
        result += [
            .init(id: "compound-capture-dates", category: "coordination", source: "audit regression", turns: [
                .init(message: "Buy milk tomorrow and call Sam on Friday", kinds: ["capture", "capture"],
                    expected: [.init(words: "milk", date: "2026-09-08"), .init(words: "Sam", date: "2026-09-11")])]),
            .init(id: "compound-capture-clocks", category: "coordination", source: "audit regression", turns: [
                .init(message: "Buy milk tomorrow at 6pm and call Sam Friday at 3pm", kinds: ["capture", "capture"],
                    expected: [.init(words: "milk", date: "2026-09-08", time: "18:00"), .init(words: "Sam", date: "2026-09-11", time: "15:00")])]),
            .init(id: "ongoing-capture", category: "review-context", source: "audit regression", turns: [
                .init(message: "Take my morning pill and keep it indefinitely", kinds: ["capture"],
                    expected: [.init(words: "pill", reviewPolicy: "never")])]),
            .init(id: "next-weekday-query", category: "query", source: "audit regression", turns: [
                .init(message: "Call Sam next Monday", kinds: ["capture"], expected: [.init(words: "Sam", date: "2026-09-14")]),
                .init(message: "What's on my schedule next Monday", kinds: ["query"], unchanged: true, replyContains: "Sam")]),
        ]
        let stale = task("a1", "Plan the birthday picnic", stale: true)
        for (titleIndex, title) in ["Stays", "Keep", "Done", "Move", "Not done", "Remove", "Tomorrow"].enumerated() {
            for (verbIndex, verb) in ["Remove", "Delete", "Drop"].enumerated() {
                for review in [false, true] {
                    let other = task("a1", "Plan the birthday picnic", stale: review)
                    result.append(.init(id: "command-title-\(titleIndex)-\(verbIndex)-\(review)", category: "command-title-boundary",
                        initial: [other, task("a2", title)], turns: [
                            .init(message: "\(verb) \(title)", kinds: ["drop"],
                                  expected: [.init(words: "picnic"), .init(words: title, status: "dropped")],
                                  targetID: "a2", replyExcludes: ["Keeping"])]))
                }
            }
        }
        for (index, reply) in ["Stays", "Stay", "Keep", "Keep please", "Yes, keep it please"].enumerated() {
            result.append(.init(id: "review-keep-\(index)", category: "review-context",
                initial: [stale, plants, task("a3", "Stays")], turns: [
                    .init(message: reply, kinds: ["keep"], expected: [.init(words: "picnic"), .init(words: "plants"), .init(words: "Stays")], targetID: stale.id)]))
        }
        for (index, reply) in ["Drop", "Remove please", "Delete it please"].enumerated() {
            result.append(.init(id: "review-drop-\(index)", category: "review-context", initial: [stale, plants], turns: [
                .init(message: reply, kinds: ["drop"], expected: [.init(words: "picnic", status: "dropped"), .init(words: "plants")])]))
        }
        result += [
            .init(id: "review-move", category: "review-context", initial: [stale, plants], turns: [
                .init(message: "Move to Friday", kinds: ["reschedule"], expected: [.init(words: "picnic", date: "2026-09-11"), .init(words: "plants")])]),
            .init(id: "review-move-question", category: "review-context", initial: [stale, plants], turns: [
                .init(message: "Move", unchanged: true, clarification: true),
                .init(message: "Friday", kinds: ["reschedule"], expected: [.init(words: "picnic", date: "2026-09-11"), .init(words: "plants")])]),
            .init(id: "review-no-context", category: "review-context", initial: [report, plants], turns: [
                .init(message: "Stays", unchanged: true, clarification: true)]),
            .init(id: "review-real-task", category: "review-context", initial: [stale, plants], turns: [
                .init(message: "Keep the receipts", kinds: ["capture"], expected: [.init(words: "picnic"), .init(words: "plants"), .init(words: "receipts")])]),
            .init(id: "ongoing-review-policy", category: "review-context",
                  source: "ongoing-item behavior specification", initial: [stale, plants], turns: [
                .init(message: "Keep it forever", kinds: ["revise"],
                      expected: [.init(words: "picnic", reviewPolicy: "never"), .init(words: "plants")],
                      replyContains: "without checking again", targetID: stale.id)]),
        ]
        // Paraphrase families check stable behavior under changes in politeness,
        // spelling, wording, and topic. Expectations are independent of parser code.
        for (index, message) in ["Eat bacon", "Return Amazon shit", "Make an apple gelea",
                                  "Plan a schedule", "Buy zero sugar soda", "call mom"].enumerated() {
            result.append(.init(id: "capture-\(index)", category: "capture",
                source: "Ollama evals and reported failures", turns: [
                    .init(message: message, kinds: ["capture"], expected: [.init(words: message)])
                ]))
        }
        for (index, message) in ["thanks bro", "Man I'm tired today", "I'm exhausted",
                                  "That was a rough day", "Nothing got done", "I didn't finish the report"].enumerated() {
            result.append(.init(id: "nonaction-\(index)", category: "nonaction",
                initial: [report, plants], turns: [.init(message: message, unchanged: true)]))
        }
        for (index, message) in ["I finished the report", "The report is done", "I did the report yesterday"].enumerated() {
            result.append(.init(id: "complete-\(index)", category: "completion",
                source: "Ollama completion family", initial: [report, plants], turns: [
                    .init(message: message, kinds: ["complete"], expected: [
                        .init(words: "report", status: "done"), .init(words: "plants")])
                ]))
        }
        result += [
            .init(id: "future-not-complete", category: "negation", initial: [report],
                  turns: [.init(message: "I'll finish the report later", unchanged: true)]),
            .init(id: "partial-not-complete", category: "progress", initial: [report],
                  turns: [.init(message: "I finished half the report", kinds: ["note"], expected: [.init(words: "report", note: "I finished half the report")])]),
            .init(id: "deadline", category: "dates", source: "reported cake failure", turns: [
                .init(message: "I gotta eat that cake before it goes bad tomorrow", kinds: ["capture"],
                      expected: [.init(words: "cake", deadline: "2026-09-08")])]),
            .init(id: "appointment", category: "dates", turns: [
                .init(message: "Dentist tomorrow at 4pm", kinds: ["capture"],
                      expected: [.init(words: "Dentist", date: "2026-09-08", time: "16:00")])]),
            .init(id: "recurring", category: "recurrence", source: "Ollama evals", turns: [
                .init(message: "Water the plants every Monday", kinds: ["capture"],
                      expected: [.init(words: "plants", date: "2026-09-07", recurrence: "week")])]),
            .init(id: "single-not-recurring", category: "recurrence", initial: [plants], turns: [
                .init(message: "test", kinds: ["capture"], expected: [.init(words: "plants"), .init(words: "test")])]),
            .init(id: "coordinated", category: "coordination", source: "reported respective-times failure", turns: [
                .init(message: "Meeting with Claude code and dev team at 230 and 330 respectively", kinds: ["capture", "capture"],
                      expected: [.init(words: "Claude", date: "2026-09-07", time: "14:30"), .init(words: "dev", date: "2026-09-07", time: "15:30")])]),
            .init(id: "query", category: "query", initial: [report, plants], turns: [
                .init(message: "How's it looking tomorrow", kinds: ["query"], unchanged: true)]),
            .init(id: "clear-time", category: "revision", initial: [task("a1", "buy anniversary gift", date: "2026-09-07", time: "09:00")], turns: [
                .init(message: "Buy an anniversary gift does not need a time", kinds: ["revise"],
                      expected: [.init(words: "anniversary", date: "2026-09-07")])]),
            .init(id: "priority-duration", category: "revision", initial: [report, plants], turns: [
                .init(message: "Make the report high priority and 90 minutes", kinds: ["revise"],
                      expected: [.init(words: "report", duration: 90, priority: "high"), .init(words: "plants")])]),
            .init(id: "explicit-plan", category: "planning", initial: [report, plants], turns: [
                .init(message: "Plan my day", kinds: ["replan"], unchanged: true, proposal: true)]),
            .init(id: "ambiguous-target", category: "clarification", initial: [task("a1", "Call Alex"), task("a2", "Call Sam")], turns: [
                .init(message: "The call is done", unchanged: true, clarification: true),
                .init(message: "Call Alex", kinds: ["complete"], expected: [.init(words: "Alex", status: "done"), .init(words: "Sam")])]),
            .init(id: "ambiguous-date", category: "clarification", source: "Ollama evals", turns: [
                .init(message: "Lunch with Sam Thursday or Friday", unchanged: true, clarification: true),
                .init(message: "Friday", kinds: ["capture"], expected: [.init(words: "Sam", date: "2026-09-11")])]),
            .init(id: "stale-chain", category: "conversation", initial: [task("a1", "Finish report", stale: true), plants], turns: [
                .init(message: "It stays", kinds: ["keep"], expected: [.init(words: "report"), .init(words: "plants")]),
                .init(message: "Actually move it to Friday", kinds: ["reschedule"], expected: [.init(words: "report", date: "2026-09-11"), .init(words: "plants")]),
                .init(message: "I finished it yesterday", kinds: ["complete"], expected: [.init(words: "report", status: "done", date: "2026-09-11"), .init(words: "plants")])]),
            .init(id: "capture-chain", category: "conversation", initial: [plants], turns: [
                .init(message: "Buy a sketchbook", kinds: ["capture"], expected: [.init(words: "plants"), .init(words: "sketchbook")]),
                .init(message: "Move it to tomorrow", kinds: ["reschedule"], expected: [.init(words: "plants"), .init(words: "sketchbook", date: "2026-09-08")]),
                .init(message: "thanks", unchanged: true),
                .init(message: "It's done", kinds: ["complete"], expected: [.init(words: "plants"), .init(words: "sketchbook", status: "done", date: "2026-09-08")])]),
        ]
        result += [
            .init(id: "notification-to-chat", category: "conversation", initial: [report, plants], notificationDoneTaskID: report.id, turns: [
                .init(message: "What got done today?", kinds: ["query"], unchanged: true, replyContains: "report"),
                .init(message: "The plants are done too", kinds: ["complete"], expected: [.init(words: "report", status: "done"), .init(words: "plants", status: "done")])]),
            .init(id: "undo-after-capture", category: "undo", source: "Ollama retraction flow", initial: [plants], turns: [
                .init(message: "Buy a sketchbook", kinds: ["capture"], expected: [.init(words: "plants"), .init(words: "sketchbook")]),
                .init(message: "I'm tired", unchanged: true),
                .init(message: "Undo that", kinds: ["undo"], expected: [.init(words: "plants")])]),
            .init(id: "physical-cancel", category: "capture", initial: [plants], turns: [
                .init(message: "Cancel the gym membership", kinds: ["capture"], expected: [.init(words: "plants"), .init(words: "gym membership")])]),
            .init(id: "physical-return", category: "capture", initial: [plants], turns: [
                .init(message: "Drop off the library books", kinds: ["capture"], expected: [.init(words: "plants"), .init(words: "library books")])]),
            .init(id: "polite-request", category: "capture", turns: [
                .init(message: "Can you remind me to call Mom tomorrow?", kinds: ["capture"], expected: [.init(words: "Mom", date: "2026-09-08")])]),
            .init(id: "weekday-contrast", category: "dates", initial: [report], turns: [
                .init(message: "Move the report to next Friday", kinds: ["reschedule"], expected: [.init(words: "report", date: "2026-09-18")])]),
            .init(id: "bulk-completion", category: "coordination", source: "Ollama evals", initial: [report, plants], turns: [
                .init(message: "I finished the report and watered the plants", kinds: ["complete", "complete"], expected: [.init(words: "report", status: "done"), .init(words: "plants", status: "done")])]),
        ]
        // A task-list reorder or unrelated distractor must not change a named
        // reference. These variants use the real controller's stable ID mapping.
        for (index, title) in ["Mail parcel", "Clean oven", "Pay invoice"].enumerated() {
            let item = task("z9", title)
            for (variant, initial) in [[item, plants], [report, item, plants]].enumerated() {
                result.append(.init(id: "target-\(index)-\(variant)", category: "target-invariance", initial: initial,
                    turns: [.init(message: "\(title) is done", kinds: ["complete"], expected: initial.map { value in
                        BenchmarkTask(words: value.task, status: value.id == item.id ? "done" : "open")
                    })]))
            }
        }
        return result
    }

    // Held-out topics and constructions. Once used to tune a fix, label that
    // report as development evidence and add fresh cases before the next release.
    static var challenge: [MessageBenchmarkCase] {
        let fern = task("a1", "Repot fern")
        let lens = task("a2", "Clean telescope lens")
        let cases: [MessageBenchmarkCase] = [
            .init(id: "novel-obligation", category: "capture", turns: [.init(message: "I need to reglaze the ramekins", kinds: ["capture"], expected: [.init(words: "reglaze the ramekins")])]),
            .init(id: "novel-imperative", category: "capture", turns: [.init(message: "Please mend the sailcloth", kinds: ["capture"], expected: [.init(words: "mend the sailcloth")])]),
            .init(id: "novel-typo", category: "capture", turns: [.init(message: "Pick up the embroidry hoop", kinds: ["capture"], expected: [.init(words: "hoop")])]),
            .init(id: "novel-feeling", category: "nonaction", initial: [fern, lens], turns: [.init(message: "Honestly I'm pretty overwhelmed this morning", unchanged: true)]),
            .init(id: "novel-negation", category: "negation", initial: [fern, lens], turns: [.init(message: "Haven't cleaned the telescope lens yet", unchanged: true)]),
            .init(id: "novel-completion", category: "completion", initial: [fern, lens], turns: [.init(message: "Took care of repotting the fern", kinds: ["complete"], expected: [.init(words: "fern", status: "done"), .init(words: "lens")])]),
            .init(id: "novel-query", category: "query", initial: [fern, lens], turns: [.init(message: "Anything on the books for tomorrow?", kinds: ["query"], unchanged: true)]),
            .init(id: "novel-ambiguous", category: "clarification", initial: [task("a1", "Repair bicycle wheel"), task("a2", "Repair pottery wheel")], turns: [.init(message: "Finished the wheel", unchanged: true, clarification: true)]),
            .init(id: "novel-drop", category: "drop", initial: [fern, lens], turns: [.init(message: "Remove the telescope lens task", kinds: ["drop"], expected: [.init(words: "fern"), .init(words: "lens", status: "dropped")])]),
            .init(id: "novel-clock", category: "dates", turns: [.init(message: "Violin lesson tomorrow at 11am", kinds: ["capture"], expected: [.init(words: "Violin", date: "2026-09-08", time: "11:00")])]),
            .init(id: "novel-deadline", category: "dates", turns: [.init(message: "Renew the archive pass by Friday", kinds: ["capture"], expected: [.init(words: "archive pass", deadline: "2026-09-11")])]),
            .init(id: "novel-chain", category: "conversation", initial: [lens], turns: [
                .init(message: "Order a new terrarium", kinds: ["capture"], expected: [.init(words: "lens"), .init(words: "terrarium")]),
                .init(message: "That can wait until Friday", kinds: ["reschedule"], expected: [.init(words: "lens"), .init(words: "terrarium", date: "2026-09-11")]),
                .init(message: "Actually drop it", kinds: ["drop"], expected: [.init(words: "lens"), .init(words: "terrarium", status: "dropped", date: "2026-09-11")])]),
        ]
        return cases.map { value in var value = value; value.split = "challenge"; return value }
    }

    static var freshChallenge: [MessageBenchmarkCase] {
        let items = [task("a1", "Send invitations"), task("a2", "Wash duvet")]
        let cases: [MessageBenchmarkCase] = [
            .init(id: "fresh-negative", category: "negation", initial: items, turns: [.init(message: "I have not washed the duvet", unchanged: true)]),
            .init(id: "fresh-past", category: "completion", initial: items, turns: [.init(message: "I sent the invitations", kinds: ["complete"], expected: [.init(words: "invitations", status: "done"), .init(words: "duvet")])]),
            .init(id: "fresh-obligation", category: "capture", initial: items, turns: [.init(message: "Remember to descale the espresso machine", kinds: ["capture"], expected: [.init(words: "invitations"), .init(words: "duvet"), .init(words: "espresso machine")])]),
            .init(id: "fresh-courtesy", category: "capture", turns: [.init(message: "Could you remind me to collect the kiln shelves tomorrow?", kinds: ["capture"], expected: [.init(words: "kiln shelves", date: "2026-09-08")])]),
            .init(id: "fresh-mood", category: "nonaction", initial: items, turns: [.init(message: "I'm anxious about those invitations", unchanged: true)]),
            .init(id: "fresh-pronoun", category: "clarification", initial: items, turns: [.init(message: "Move it to Friday", unchanged: true, clarification: true)]),
            .init(id: "fresh-work-topic", category: "capture", turns: [.init(message: "Organize a neighborhood potluck", kinds: ["capture"], expected: [.init(words: "neighborhood potluck")])]),
            .init(id: "fresh-deadline", category: "dates", turns: [.init(message: "Pick up the repaired accordion before tomorrow", kinds: ["capture"], expected: [.init(words: "accordion", deadline: "2026-09-08")])]),
        ]
        return cases.map { value in var value = value; value.split = "fresh"; return value }
    }
}
