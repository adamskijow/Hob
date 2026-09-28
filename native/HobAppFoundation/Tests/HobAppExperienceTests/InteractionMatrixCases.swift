// SPDX-License-Identifier: MIT
import HobAppCore

extension MessageBenchmarkCorpus {
    static var interactionMatrix: [MessageBenchmarkCase] {
        var cases: [MessageBenchmarkCase] = []
        let boundaries = [
            ("year", "2026-12-31T23:50:00-05:00", "America/New_York", "2027-01-01"),
            ("leap", "2028-02-28T08:00:00-05:00", "America/New_York", "2028-02-29"),
            ("dst-us", "2026-03-07T08:00:00-05:00", "America/New_York", "2026-03-08"),
            ("dst-uk", "2026-10-24T08:00:00+01:00", "Europe/London", "2026-10-25"),
        ]
        for (id, now, timezone, tomorrow) in boundaries {
            cases.append(.init(id: "matrix-clock-\(id)", category: "calendar-boundary", split: "matrix", now: now, timezone: timezone, turns: [
                .init(message: "Dentist tomorrow at 4pm", kinds: ["capture"], expected: [.init(words: "Dentist", date: tomorrow, time: "16:00")])]))
            let today = String(now.prefix(10))
            let timed = RuntimeTask(id: "a1", rawText: "Dentist", task: "Dentist", dueDate: today, dueTime: "16:00", status: "open", createdAt: now, updatedAt: now)
            let untimed = RuntimeTask(id: "a2", rawText: "Buy soap", task: "Buy soap", dueDate: nil, dueTime: nil, status: "open", createdAt: now, updatedAt: now)
            cases.append(.init(id: "matrix-rollover-\(id)", category: "rollover", split: "matrix", initial: [timed, untimed], now: now, timezone: timezone, turns: [
                .init(message: "What's on deck today?", kinds: ["query"], unchanged: true, replyContains: "Buy soap", advanceDaysBefore: 1, replyExcludes: ["Dentist"])]))
        }
        for (index, title) in ["Clean oven", "Mail parcel", "Pay invoice"].enumerated() {
            let target = task("z9", title)
            let others = [task("a1", "Read book"), task("a2", "Wash towels")]
            for (variation, initial) in [[target], [target] + others, others + [target]].enumerated() {
                cases.append(.init(id: "matrix-negation-\(index)-\(variation)", category: "meaning-and-state", split: "matrix", initial: initial, turns: [
                    .init(message: "\(title) is not done", unchanged: true),
                    .init(message: "\(title) is done", kinds: ["complete"], expected: initial.map { .init(words: $0.task, status: $0.id == target.id ? "done" : "open") }, targetID: target.id)]))
            }
        }
        return cases
    }
}
