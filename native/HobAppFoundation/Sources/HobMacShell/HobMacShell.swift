// SPDX-License-Identifier: MIT
import AppKit
#if canImport(HobAppCore)
import HobAppCore
#endif
#if canImport(HobAppStorage)
import HobAppStorage
#endif
import SwiftUI

@main
struct HobMacShell: App {
    @StateObject private var backgroundService = BackgroundServiceController()
    @StateObject private var foundationModel = FoundationModelController()
    @StateObject private var taskStorage = TaskStorageController()

    private var readiness: AppReadiness {
        AppReadiness(
            edition: .appStore,
            modelBackend: .appleFoundationModels,
            ownerPaired: false,
            backgroundServiceApproved: backgroundService.isDeliveryReady,
            modelAvailable: foundationModel.state.isReady,
            storageAvailable: [.new, .ready].contains(
                taskStorage.inspection.condition
            )
        )
    }

    var body: some Scene {
        Window("Hob Setup", id: "setup") {
            SetupHomeView(
                readiness: readiness,
                backgroundService: backgroundService,
                foundationModel: foundationModel,
                taskStorage: taskStorage
            )
        }
        .defaultSize(width: 680, height: 560)

        MenuBarExtra("Hob", systemImage: "sparkles") {
            HobMenu(readiness: readiness)
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
                BackgroundServiceView(controller: backgroundService)
                    .tabItem { Label("Background", systemImage: "clock.arrow.circlepath") }
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
                openWindow(id: "setup")
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
    @ObservedObject var backgroundService: BackgroundServiceController
    @ObservedObject var foundationModel: FoundationModelController
    @ObservedObject var taskStorage: TaskStorageController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A realistic day, renegotiated in chat")
                        .font(.largeTitle.bold())
                    Text("Set up Hob without Terminal. Nothing runs in the background until you approve it.")
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
                GroupBox("Background delivery") {
                    BackgroundServiceContent(controller: backgroundService)
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
                backgroundService.refresh()
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

private struct BackgroundServiceView: View {
    @ObservedObject var controller: BackgroundServiceController

    var body: some View {
        Form {
            Section("Background delivery") {
                BackgroundServiceContent(controller: controller)
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.refresh() }
    }

}

private struct BackgroundServiceContent: View {
    @ObservedObject var controller: BackgroundServiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Status", value: controller.state.title)
            Text(controller.state.guidance)
                .foregroundStyle(.secondary)
            Text("Hob runs in the background only after you choose Turn On. You can turn it off here or in System Settings at any time.")
                .font(.callout)
            if !controller.runtimeAvailable {
                Label(
                    "The signed helper is bundled, but background delivery stays locked until the Hob task runtime is connected.",
                    systemImage: "hammer"
                )
                .foregroundStyle(.secondary)
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            serviceActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var serviceActions: some View {
        switch controller.state {
        case .notRegistered:
            Button("Turn On Background Delivery") { controller.enable() }
                .disabled(!controller.runtimeAvailable)
        case .enabled:
            Button("Turn Off Background Delivery", role: .destructive) {
                controller.disable()
            }
        case .requiresApproval:
            Button("Open Login Items Settings") { controller.openApprovalSettings() }
            Button("Cancel Background Registration", role: .destructive) {
                controller.disable()
            }
        case .notFound:
            Button("Check Again") { controller.refresh() }
        case .unknown:
            Button("Refresh Status") { controller.refresh() }
        }
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
            LabeledContent("Task storage", value: "This Mac")
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
                Text("Tasks, plans, model prompts, and Calendar busy-time calculations stay on this Mac.")
            }
            Section("What leaves this Mac") {
                Text("Messages sent through Telegram transit Telegram's service. Hob never sends Calendar titles to Telegram or the model.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
