// SPDX-License-Identifier: MIT
import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String]
    ) -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(
                exitCode: 127,
                standardError: "The service command could not be started."
            )
        }
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

public enum LocalServiceState: Equatable, Sendable {
    case checking
    case running(pid: Int?)
    case stopped
    case notInstalled
    case unavailable

    public var title: String {
        switch self {
        case .checking:
            return "Checking…"
        case .running:
            return "Hob is running"
        case .stopped:
            return "Hob is off"
        case .notInstalled:
            return "Hob needs setup"
        case .unavailable:
            return "Status unavailable"
        }
    }

    public var guidance: String {
        switch self {
        case .checking:
            return "Checking background delivery."
        case .running:
            return "Messages, digests, reminders, and plan nudges can arrive."
        case .stopped:
            return "Turn Hob on before relying on a digest or reminder."
        case .notInstalled:
            return "Run Hob's Mac installer once to enable automatic startup."
        case .unavailable:
            return "Hob could not read the macOS background-service state."
        }
    }

    public var symbolName: String {
        switch self {
        case .checking:
            return "hourglass"
        case .running:
            return "flame.fill"
        case .stopped:
            return "flame"
        case .notInstalled, .unavailable:
            return "exclamationmark.triangle"
        }
    }
}

public struct LocalServiceSnapshot: Equatable, Sendable {
    public let state: LocalServiceState
    public let isLoaded: Bool

    public init(state: LocalServiceState, isLoaded: Bool) {
        self.state = state
        self.isLoaded = isLoaded
    }
}

public struct ServiceActionResult: Equatable, Sendable {
    public let succeeded: Bool
    public let message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }
}

public struct LaunchdServiceClient<Runner: CommandRunning>: Sendable {
    public let label: String
    public let userID: UInt32
    public let launchAgentPath: String
    public let runner: Runner
    public let reloadAttempts: Int
    public let reloadRetryDelay: TimeInterval

    public init(
        label: String = "com.local.hob",
        userID: UInt32,
        launchAgentPath: String,
        runner: Runner,
        reloadAttempts: Int = 100,
        reloadRetryDelay: TimeInterval = 0.1
    ) {
        self.label = label
        self.userID = userID
        self.launchAgentPath = launchAgentPath
        self.runner = runner
        self.reloadAttempts = reloadAttempts
        self.reloadRetryDelay = reloadRetryDelay
    }

    public var serviceTarget: String {
        "gui/\(userID)/\(label)"
    }

    public var domainTarget: String {
        "gui/\(userID)"
    }

    public func status() -> LocalServiceSnapshot {
        let result = runner.run(
            executable: "/bin/launchctl",
            arguments: ["print", serviceTarget]
        )
        return Self.parseStatus(
            result,
            launchAgentExists: FileManager.default.fileExists(
                atPath: launchAgentPath
            )
        )
    }

    public func start() -> ServiceActionResult {
        let current = runner.run(
            executable: "/bin/launchctl",
            arguments: ["print", serviceTarget]
        )
        if current.exitCode == 0 {
            return action(
                arguments: ["kickstart", serviceTarget],
                success: "Hob is turning on."
            )
        }
        guard FileManager.default.fileExists(atPath: launchAgentPath) else {
            return ServiceActionResult(
                succeeded: false,
                message: "Hob's background service is not installed."
            )
        }
        let bootstrap = runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domainTarget, launchAgentPath]
        )
        guard bootstrap.exitCode == 0 else {
            return ServiceActionResult(
                succeeded: false,
                message: "macOS could not load Hob's background service."
            )
        }
        return action(
            arguments: ["kickstart", serviceTarget],
            success: "Hob is turning on."
        )
    }

    public func restart() -> ServiceActionResult {
        let current = runner.run(
            executable: "/bin/launchctl",
            arguments: ["print", serviceTarget]
        )
        if current.exitCode != 0 {
            return startAfterMissingPrint()
        }
        let stop = runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootout", serviceTarget]
        )
        guard stop.exitCode == 0 else {
            return ServiceActionResult(
                succeeded: false,
                message: "macOS could not stop Hob before restarting it."
            )
        }
        return bootstrapAfterStop(success: "Hob restarted.")
    }

    public static func parseStatus(
        _ result: CommandResult,
        launchAgentExists: Bool
    ) -> LocalServiceSnapshot {
        guard result.exitCode == 0 else {
            return LocalServiceSnapshot(
                state: launchAgentExists ? .stopped : .notInstalled,
                isLoaded: false
            )
        }
        let fields = parseLaunchctlFields(result.standardOutput)
        if fields["state"] == "running" {
            return LocalServiceSnapshot(
                state: .running(pid: fields["pid"].flatMap(Int.init)),
                isLoaded: true
            )
        }
        return LocalServiceSnapshot(state: .stopped, isLoaded: true)
    }

    private func startAfterMissingPrint() -> ServiceActionResult {
        guard FileManager.default.fileExists(atPath: launchAgentPath) else {
            return ServiceActionResult(
                succeeded: false,
                message: "Hob's background service is not installed."
            )
        }
        let bootstrap = runner.run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", domainTarget, launchAgentPath]
        )
        guard bootstrap.exitCode == 0 else {
            return ServiceActionResult(
                succeeded: false,
                message: "macOS could not load Hob's background service."
            )
        }
        return action(
            arguments: ["kickstart", serviceTarget],
            success: "Hob is turning on."
        )
    }

    private func bootstrapAfterStop(success: String) -> ServiceActionResult {
        for attempt in 0..<max(1, reloadAttempts) {
            let result = runner.run(
                executable: "/bin/launchctl",
                arguments: ["bootstrap", domainTarget, launchAgentPath]
            )
            if result.exitCode == 0 {
                return ServiceActionResult(succeeded: true, message: success)
            }
            if attempt + 1 < reloadAttempts && reloadRetryDelay > 0 {
                Thread.sleep(forTimeInterval: reloadRetryDelay)
            }
        }
        return ServiceActionResult(
            succeeded: false,
            message: "macOS could not reload Hob's background service."
        )
    }

    private func action(
        arguments: [String],
        success: String
    ) -> ServiceActionResult {
        let result = runner.run(
            executable: "/bin/launchctl",
            arguments: arguments
        )
        return ServiceActionResult(
            succeeded: result.exitCode == 0,
            message: result.exitCode == 0
                ? success
                : "macOS could not change Hob's background-service state."
        )
    }

    private static func parseLaunchctlFields(
        _ output: String
    ) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "state" || key == "pid" {
                fields[key] = value
            }
        }
        return fields
    }
}
