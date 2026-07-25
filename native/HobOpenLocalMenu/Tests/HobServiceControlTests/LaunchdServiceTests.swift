// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobServiceControl

@Test func launchctlRunningOutputReportsPID() {
    let result = CommandResult(
        exitCode: 0,
        standardOutput: """
        gui/501/com.local.hob = {
            state = running
            pid = 774
        }
        """
    )

    #expect(
        LaunchdServiceClient<StubRunner>.parseStatus(
            result,
            launchAgentExists: true
        )
        == LocalServiceSnapshot(state: .running(pid: 774), isLoaded: true)
    )
}

@Test func loadedButIdleServiceIsStopped() {
    let result = CommandResult(
        exitCode: 0,
        standardOutput: "state = waiting\n"
    )

    #expect(
        LaunchdServiceClient<StubRunner>.parseStatus(
            result,
            launchAgentExists: true
        )
        == LocalServiceSnapshot(state: .stopped, isLoaded: true)
    )
}

@Test func missingLoadedJobDistinguishesStoppedFromNotInstalled() {
    let result = CommandResult(exitCode: 113)

    #expect(
        LaunchdServiceClient<StubRunner>.parseStatus(
            result,
            launchAgentExists: true
        ).state == .stopped
    )
    #expect(
        LaunchdServiceClient<StubRunner>.parseStatus(
            result,
            launchAgentExists: false
        ).state == .notInstalled
    )
}

@Test func restartUsesForcedKickstartForLoadedService() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let plist = directory.appendingPathComponent("com.local.hob.plist")
    try Data().write(to: plist)
    let runner = StubRunner(responses: [
        CommandResult(exitCode: 0, standardOutput: "state = running\n"),
        CommandResult(exitCode: 0),
    ])
    let client = LaunchdServiceClient(
        userID: 501,
        launchAgentPath: plist.path,
        runner: runner
    )

    #expect(client.restart().succeeded)
    #expect(runner.invocations == [
        Invocation(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/501/com.local.hob"]
        ),
        Invocation(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", "gui/501/com.local.hob"]
        ),
    ])
}

@Test func startBootstrapsAnInstalledButUnloadedService() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let plist = directory.appendingPathComponent("com.local.hob.plist")
    try Data().write(to: plist)
    let runner = StubRunner(responses: [
        CommandResult(exitCode: 113),
        CommandResult(exitCode: 0),
        CommandResult(exitCode: 0),
    ])
    let client = LaunchdServiceClient(
        userID: 501,
        launchAgentPath: plist.path,
        runner: runner
    )

    #expect(client.start().succeeded)
    #expect(runner.invocations.map(\.arguments) == [
        ["print", "gui/501/com.local.hob"],
        ["bootstrap", "gui/501", plist.path],
        ["kickstart", "gui/501/com.local.hob"],
    ])
}

@Test func healthRequiresTelegramCredentialAndPairing() {
    #expect(
        OperationalHealth.summarize(
            exitCode: 0,
            standardOutput: "INFO Telegram: token=none owner=unpaired\n",
            standardError: ""
        ).summary == "Telegram needs a bot token before Hob can deliver."
    )
    #expect(
        OperationalHealth.summarize(
            exitCode: 0,
            standardOutput: "INFO Telegram: token=keychain owner=unpaired\n",
            standardError: ""
        ).summary == "Telegram is not paired yet. Send the bot /start."
    )
}

@Test func healthCallsOutDurableQueuedWork() {
    let health = OperationalHealth.summarize(
        exitCode: 0,
        standardOutput: "WARN queues: inbound=1 outbound=0 failed=0\n",
        standardError: ""
    )

    #expect(!health.isReady)
    #expect(health.summary.contains("durable work waiting"))
}

@Test func healthSurfacesSpecificFailureWithoutPrivateContent() {
    let health = OperationalHealth.summarize(
        exitCode: 1,
        standardOutput: "FAIL model: Ollama unavailable at localhost\n",
        standardError: ""
    )

    #expect(!health.isReady)
    #expect(health.summary == "FAIL model: Ollama unavailable at localhost")
}

@Test func completeOperationalStatusIsReady() {
    let health = OperationalHealth.summarize(
        exitCode: 0,
        standardOutput: """
        OK database: schema 10
        OK queues: inbound=0 outbound=0 failed=0
        INFO Telegram: token=keychain owner=paired
        OK model: qwen
        """,
        standardError: ""
    )

    #expect(health.isReady)
    #expect(health.summary.contains("Telegram"))
}

private struct Invocation: Equatable {
    let executable: String
    let arguments: [String]
}

private final class StubRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [CommandResult]
    private(set) var invocations: [Invocation] = []

    init(responses: [CommandResult] = []) {
        self.responses = responses
    }

    func run(executable: String, arguments: [String]) -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(
            Invocation(executable: executable, arguments: arguments)
        )
        return responses.isEmpty
            ? CommandResult(exitCode: 127)
            : responses.removeFirst()
    }
}
