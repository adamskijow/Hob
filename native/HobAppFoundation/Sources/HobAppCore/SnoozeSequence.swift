// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimeSnoozeStep: Equatable, Sendable {
    public let minutes: Int?
    public let label: String
    public let nextLabel: String?

    public init(minutes: Int?, label: String, nextLabel: String?) {
        self.minutes = minutes
        self.label = label
        self.nextLabel = nextLabel
    }
}

public enum RuntimeSnoozeSequence {
    private static let intervals = [15, 60, 240, 720]

    public static func step(after priorSnoozes: Int) -> RuntimeSnoozeStep {
        let index = max(0, priorSnoozes)
        guard index < intervals.count else {
            return RuntimeSnoozeStep(
                minutes: nil,
                label: "indefinitely",
                nextLabel: nil
            )
        }
        let minutes = intervals[index]
        let next = index + 1 < intervals.count
            ? label(for: intervals[index + 1]) : "indefinitely"
        return RuntimeSnoozeStep(
            minutes: minutes,
            label: label(for: minutes),
            nextLabel: next
        )
    }

    private static func label(for minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return "\(hours) \(hours == 1 ? "hour" : "hours")"
    }
}
