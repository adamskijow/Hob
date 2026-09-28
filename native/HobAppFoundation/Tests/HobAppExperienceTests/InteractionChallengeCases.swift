// SPDX-License-Identifier: MIT
import HobAppCore

// Frozen before running against the explicit-context implementation. This set
// tests interaction families, not substitutions of nouns in the prompt examples.
// If a failure informs a fix, its first-run report remains discovery evidence;
// subsequent runs are regressions, never described as unseen validation.
extension MessageBenchmarkCorpus {
    static var interactionChallenge: [MessageBenchmarkCase] {
        let old = task("a1", "Plan the picnic", stale: true)
        let other = task("a2", "Water plants")
        return [
            .init(id: "family-query-break", category: "context-priority", split: "interaction", initial: [old, task("a2", "Dentist", date: "2026-09-08")], turns: [
                .init(message: "How's it looking tomorrow", kinds: ["query"], unchanged: true, replyContains: "Dentist"),
                .init(message: "Move it to Friday", unchanged: true, clarification: true, questionKind: .chooseTask)]),
            .init(id: "family-restart-question", category: "restart", split: "interaction", initial: [old, other], turns: [
                .init(message: "Moves", unchanged: true, clarification: true, questionKind: .chooseDate),
                .init(message: "Thanks", unchanged: true),
                .init(message: "Friday", kinds: ["reschedule"], expected: [.init(words: "picnic", date: "2026-09-11"), .init(words: "plants")], restartBefore: true)]),
            .init(id: "family-focus-competition", category: "context-priority", split: "interaction", initial: [old], turns: [
                .init(message: "Buy a notebook", kinds: ["capture"], expected: [.init(words: "picnic"), .init(words: "notebook")]),
                .init(message: "Move it to tomorrow", kinds: ["reschedule"], expected: [.init(words: "picnic"), .init(words: "notebook", date: "2026-09-08")])]),
            .init(id: "family-topic-switch", category: "context-priority", split: "interaction", initial: [old], turns: [
                .init(message: "Move", unchanged: true, clarification: true, questionKind: .chooseDate),
                .init(message: "Buy a raincoat", kinds: ["capture"], expected: [.init(words: "picnic"), .init(words: "raincoat")]),
                .init(message: "It's done", kinds: ["complete"], expected: [.init(words: "picnic"), .init(words: "raincoat", status: "done")])]),
            .init(id: "family-cancel-question", category: "cancellation", split: "interaction", initial: [old], turns: [
                .init(message: "Move", unchanged: true, clarification: true, questionKind: .chooseDate),
                .init(message: "Cancel", unchanged: true),
                .init(message: "Buy milk", kinds: ["capture"], expected: [.init(words: "picnic"), .init(words: "milk")])]),
            .init(id: "family-double-send", category: "duplicate-submit", split: "interaction", turns: [
                .init(message: "Clean the kettle", kinds: ["capture"], expected: [.init(words: "kettle")], duplicateSubmission: true)]),
            .init(id: "family-negative-progress", category: "meaning-boundary", split: "interaction", initial: [task("a1", "Clean the kettle")], turns: [
                .init(message: "The kettle is not done", unchanged: true),
                .init(message: "The kettle is almost done", kinds: ["note"], expected: [.init(words: "kettle", note: "The kettle is almost done")]),
                .init(message: "The kettle is done", kinds: ["complete"], expected: [.init(words: "kettle", status: "done", note: "The kettle is almost done")])]),
            .init(id: "family-no-context-restart", category: "restart", split: "interaction", initial: [other], turns: [
                .init(message: "Buy envelopes", kinds: ["capture"], expected: [.init(words: "plants"), .init(words: "envelopes")]),
                .init(message: "It is done", kinds: ["complete"], expected: [.init(words: "plants"), .init(words: "envelopes", status: "done")], restartBefore: true)]),
        ]
    }
}
