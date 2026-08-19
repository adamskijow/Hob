// SPDX-License-Identifier: MIT
import AppKit
#if canImport(HobAppCore)
import HobAppCore
#endif
#if canImport(HobAppStorage)
import HobAppStorage
#endif
#if canImport(HobAppExperience)
import HobAppExperience
#endif
import SwiftUI

@main
struct HobMacShell: App {
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @StateObject private var foundationModel = FoundationModelController()
    @StateObject private var taskStorage = TaskStorageController()

    private var readiness: AppReadiness {
        AppReadiness(
            edition: .appStore,
            modelBackend: .appleFoundationModels,
            ownerPaired: false,
            backgroundServiceApproved: true,
            modelAvailable: foundationModel.state.isReady,
            storageAvailable: [.new, .ready].contains(
                taskStorage.inspection.condition
            ),
            requiresOwnerPairing: false,
            requiresBackgroundService: false
        )
    }

    var body: some Scene {
        Window("Hob", id: "workspace") {
            HobWorkspaceView()
        }
        .defaultSize(width: 820, height: 760)

        Window("Hob Setup", id: "setup") {
            SetupHomeView(
                readiness: readiness,
                launchAtLogin: launchAtLogin,
                foundationModel: foundationModel,
                taskStorage: taskStorage
            )
        }
        .defaultSize(width: 680, height: 560)

        MenuBarExtra {
            HobMenu(readiness: readiness)
        } label: {
            HobTeapotIcon(filled: readiness.canRun)
                .frame(width: 18, height: 15)
                .accessibilityLabel("Hob")
        }

        Settings {
            TabView {
                OnboardingView()
                    .tabItem { Label("Setup", systemImage: "checklist") }
                ModelReadinessView(controller: foundationModel)
                    .tabItem { Label("Model", systemImage: "apple.intelligence") }
                PrivacyView()
                    .tabItem { Label("Privacy", systemImage: "lock.shield") }
                TaskStorageView(controller: taskStorage)
                    .tabItem { Label("Storage", systemImage: "externaldrive") }
                LaunchAtLoginView(controller: launchAtLogin)
                    .tabItem { Label("Startup", systemImage: "power") }
            }
            .frame(minWidth: 620, minHeight: 420)
        }
    }
}

private struct HobMenu: View {
    @Environment(\.openWindow) private var openWindow
    let readiness: AppReadiness

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hob")
                .font(.headline)
            if readiness.canRun {
                Label("Ready", systemImage: "checkmark.circle.fill")
            } else {
                ForEach(readiness.blockers, id: \.rawValue) { blocker in
                    Label(blocker.userMessage, systemImage: "circle")
                }
            }
            Divider()
            Button("Open Hob") {
                NSApplication.shared.activate()
                openWindow(id: "workspace")
            }
            SettingsLink {
                Text("Open Settings")
            }
            Button("Quit Hob") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 340)
    }
}

private struct SetupHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    let readiness: AppReadiness
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var foundationModel: FoundationModelController
    @ObservedObject var taskStorage: TaskStorageController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hob")
                        .font(.largeTitle.bold())
                    Text("Plan locally with Apple Intelligence and Calendar.")
                        .foregroundStyle(.secondary)
                }
                if readiness.canRun {
                    Label("Hob is ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Before Hob can run")
                            .font(.headline)
                        ForEach(readiness.blockers, id: \.rawValue) { blocker in
                            Label(blocker.userMessage, systemImage: "circle")
                        }
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                GroupBox("On-device intelligence") {
                    ModelReadinessContent(controller: foundationModel)
                }
                GroupBox("After a restart") {
                    LaunchAtLoginContent(controller: launchAtLogin)
                }
                GroupBox("Local task safety") {
                    TaskStorageContent(controller: taskStorage)
                }
                GroupBox("Setup journey") {
                    OnboardingContent()
                }
            }
            .padding(28)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                launchAtLogin.refresh()
                taskStorage.refresh()
            }
        }
    }
}

private struct TaskStorageView: View {
    @ObservedObject var controller: TaskStorageController

    var body: some View {
        Form {
            Section("Local task safety") {
                TaskStorageContent(controller: controller)
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.refresh() }
    }
}

private struct TaskStorageContent: View {
    @ObservedObject var controller: TaskStorageController
    @State private var confirmsRecovery = false

    private var inspection: TaskStorageInspection { controller.inspection }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: inspection.condition.title)
            Text(inspection.condition.guidance)
                .foregroundStyle(.secondary)
            if [.new, .ready].contains(inspection.condition) {
                LabeledContent(
                    "Waiting to process",
                    value: "\(inspection.pipeline.pendingInbound)"
                )
                LabeledContent(
                    "Waiting to send",
                    value: "\(inspection.pipeline.pendingOutbound)"
                )
                if inspection.pipeline.quarantinedInbound > 0 {
                    Label(
                        "\(inspection.pipeline.quarantinedInbound) message(s) are safely held for review.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                if inspection.pipeline.failedDeliveryAttempts > 0 {
                    Label(
                        "\(inspection.pipeline.failedDeliveryAttempts) delivery attempt(s) need retry.",
                        systemImage: "arrow.clockwise"
                    )
                    .foregroundStyle(.orange)
                }
            }
            if inspection.backupAvailable && inspection.condition == .ready {
                Label("A verified previous copy is available.", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }
            if controller.canRecover {
                Button("Restore Previous Copy", role: .destructive) {
                    confirmsRecovery = true
                }
                .accessibilityHint("Asks for confirmation before replacing unreadable task state")
            }
            if let result = controller.lastResult {
                Text(result)
                    .font(.callout)
            }
            Button("Check Storage Again") { controller.refresh() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .alert("Restore the previous copy?", isPresented: $confirmsRecovery) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Previous Copy", role: .destructive) {
                controller.recoverPreviousCopy()
            }
        } message: {
            Text("This replaces the unreadable task state with Hob's last verified local copy. It cannot recover changes made after that copy.")
        }
    }
}

private struct ModelReadinessView: View {
    @ObservedObject var controller: FoundationModelController

    var body: some View {
        Form {
            Section("On-device intelligence") {
                ModelReadinessContent(controller: controller)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelReadinessContent: View {
    @ObservedObject var controller: FoundationModelController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: controller.state.title)
            Text(controller.state.guidance)
                .foregroundStyle(.secondary)
            Text("The readiness check sends only a built-in test phrase to Apple's on-device model. It does not include your tasks, messages, or Calendar data.")
                .font(.callout)
            if controller.state == .checking {
                ProgressView("Checking Apple Intelligence")
            } else {
                Button(
                    controller.state == .notChecked ? "Check On-Device Model" : "Check Again"
                ) {
                    controller.check()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct LaunchAtLoginView: View {
    @ObservedObject var controller: LaunchAtLoginController

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginContent(controller: controller)
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.refresh() }
    }

}

private struct LaunchAtLoginContent: View {
    @ObservedObject var controller: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "Open Hob at login",
                isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                )
            )
            Text(controller.guidance)
                .foregroundStyle(.secondary)
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if controller.status == .requiresApproval {
                Button("Open Login Items Settings") { controller.openSettings() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

}

private struct OnboardingView: View {
    var body: some View {
        Form {
            Section("Setup journey") {
                OnboardingContent()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct OnboardingContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Model", value: "Apple on-device")
            LabeledContent("Task storage", value: "Private app storage")
            LabeledContent("Storage health", value: "Visible in Storage settings")
            LabeledContent("Calendar", value: "Busy times only")
            Divider()
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Label(step.title, systemImage: "circle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

private struct PrivacyView: View {
    var body: some View {
        Form {
            Section("What stays local") {
                Text("Model prompts and Calendar details stay on this device.")
            }
            Section("iCloud") {
                Text("Tasks sync privately through your iCloud account.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
