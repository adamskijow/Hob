// SPDX-License-Identifier: MIT
import Foundation

public protocol RuntimeMessageInterpreting: Sendable {
    func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask]
    ) async throws -> [RuntimeAction]
}

public enum RuntimeInterpretationError: Error, Equatable, Sendable {
    case modelUnavailable
    case unsupportedMessage
    case invalidOutput
}
