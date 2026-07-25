// SPDX-License-Identifier: MIT
import AppKit
import HobServiceControl
import SwiftUI

private struct LocalInstall: Sendable {
    let projectPath: String
    let databasePath: String
    let uvPath: String
    let logPath: String

    static func current() -> LocalInstall {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return LocalInstall(
            projectPath: environment["HOB_PROJECT_PATH"] ?? "",
            databasePath: environment["HOB_DB_PATH"]
                ?? "\(home)/Library/Application Support/Hob/hob.db",
            uvPath: environment["HOB_UV_PATH"] ?? "\(home)/.local/bin/uv",
            logPath: environment["HOB_LOG_PATH"]
                ?? "\(home)/Library/Application Support/Hob/hob.log"
        )
    }
}

private struct HealthCheckClient: Sendable {
    let install: LocalInstall

    func run() -> OperationalHealth {
        guard !install.projectPath.isEmpty,
              FileManager.default.fileExists(atPath: install.uvPath) else {
            return OperationalHealth(
                isReady: false,
                summary: "Health check is unavailable. Reinstall the menu-bar companion."
            )
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: install.uvPath)
        process.arguments = [
            "run",
            "--directory", install.projectPath,
            "python", "app.py", "status",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOB_DB_PATH"] = install.databasePath
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return OperationalHealth(
                isReady: false,
                summary: "Hob's health check could not start."
            )
        }
        let stdout = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderr = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return OperationalHealth.summarize(
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }
}

@MainActor
private final class HobMenuController: ObservableObject {
    @Published private(set) var snapshot = LocalServiceSnapshot(
        state: .checking,
        isLoaded: false
    )
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var health: OperationalHealth?

    private let service: LaunchdServiceClient<ProcessCommandRunner>
    private let healthClient: HealthCheckClient
    let install: LocalInstall

    init() {
        let install = LocalInstall.current()
        self.install = install
        self.service = LaunchdServiceClient(
            userID: getuid(),
            launchAgentPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/com.local.hob.plist")
                .path,
            runner: ProcessCommandRunner()
        )
        self.healthClient = HealthCheckClient(install: install)
        refresh()
    }

    func refresh() {
        guard !isWorking else { return }
        let service = service
        Task {
            let result = await Task.detached(priority: .utility) {
                service.status()
            }.value
            snapshot = result
        }
    }

    func start() {
        let service = service
        perform {
            service.start()
        }
    }

    func restart() {
        let service = service
        perform {
            service.restart()
        }
    }

    func checkHealth() {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        let healthClient = healthClient
        Task {
            let result = await Task.detached(priority: .utility) {
                healthClient.run()
            }.value
            health = result
            isWorking = false
            refresh()
        }
    }

    func openLog() {
        let url = URL(fileURLWithPath: install.logPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "Hob has not created a log yet."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openDataFolder() {
        let url = URL(fileURLWithPath: install.databasePath)
            .deletingLastPathComponent()
        NSWorkspace.shared.open(url)
    }

    private func perform(
        _ action: @escaping @Sendable () -> ServiceActionResult
    ) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        let service = service
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                action()
            }.value
            message = result.message
            try? await Task.sleep(for: .milliseconds(700))
            snapshot = await Task.detached(priority: .utility) {
                service.status()
            }.value
            isWorking = false
        }
    }
}

@main
private struct HobOpenLocalMenu: App {
    @StateObject private var controller = HobMenuController()

    var body: some Scene {
        MenuBarExtra {
            HobMenuView(controller: controller)
        } label: {
            Label("Hob", systemImage: controller.snapshot.state.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct HobMenuView: View {
    @ObservedObject var controller: HobMenuController
    private let refreshTimer = Timer.publish(
        every: 10,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: controller.snapshot.state.symbolName)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.snapshot.state.title)
                        .font(.headline)
                    Text("Open Local edition")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                }
            }

            Text(controller.snapshot.state.guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case let .running(pid) = controller.snapshot.state,
               let pid {
                LabeledContent("Background process", value: "Running · \(pid)")
                    .font(.caption)
            }

            if let message = controller.message {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let health = controller.health {
                Label(
                    health.summary,
                    systemImage: health.isReady
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(health.isReady ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            serviceAction

            Button("Check Health") {
                controller.checkHealth()
            }
            .disabled(controller.isWorking)

            Button("Open Hob Log") {
                controller.openLog()
            }

            Button("Show Hob Data Folder") {
                controller.openDataFolder()
            }

            Divider()

            HStack {
                Button("Refresh") {
                    controller.refresh()
                }
                .disabled(controller.isWorking)
                Spacer()
                Button("Quit Menu Bar (Hob Stays On)") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(18)
        .frame(width: 370)
        .onReceive(refreshTimer) { _ in
            controller.refresh()
        }
    }

    @ViewBuilder
    private var serviceAction: some View {
        switch controller.snapshot.state {
        case .running:
            Button("Restart Hob") {
                controller.restart()
            }
            .disabled(controller.isWorking)
            .keyboardShortcut("r")
        case .stopped:
            Button("Turn Hob On") {
                controller.start()
            }
            .disabled(controller.isWorking)
        case .notInstalled:
            Label(
                "Run scripts/install_macos.sh once from the Hob folder.",
                systemImage: "wrench.and.screwdriver"
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        case .checking, .unavailable:
            Button("Check Again") {
                controller.refresh()
            }
            .disabled(controller.isWorking)
        }
    }

    private var statusColor: Color {
        switch controller.snapshot.state {
        case .running:
            return .green
        case .checking:
            return .secondary
        case .stopped:
            return .orange
        case .notInstalled, .unavailable:
            return .red
        }
    }
}
