// SPDX-License-Identifier: MIT
import AppKit
#if canImport(HobAppCore)
import HobAppCore
#endif
import SwiftUI

@main
struct HobMacShell: App {
    @StateObject private var backgroundService = BackgroundServiceController()

    private var readiness: AppReadiness {
        AppReadiness(
            edition: .appStore,
            modelBackend: .appleFoundationModels,
            ownerPaired: false,
            backgroundServiceApproved: backgroundService.isDeliveryReady,
            modelAvailable: false
        )
    }

    var body: some Scene {
        Window("Hob Setup", id: "setup") {
            SetupHomeView(
                readiness: readiness,
                backgroundService: backgroundService
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
                PrivacyView()
                    .tabItem { Label("Privacy", systemImage: "lock.shield") }
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

    var body: some View {
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
            BackgroundServiceView(controller: backgroundService)
            OnboardingView()
        }
        .padding(28)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                backgroundService.refresh()
            }
        }
    }
}

private struct BackgroundServiceView: View {
    @ObservedObject var controller: BackgroundServiceController

    var body: some View {
        Form {
            Section("Background delivery") {
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
        }
        .formStyle(.grouped)
        .onAppear { controller.refresh() }
    }

    @ViewBuilder
    private var serviceActions: some View {
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
            Section("App Store edition") {
                LabeledContent("Model", value: "Apple on-device")
                LabeledContent("Task storage", value: "This Mac")
                LabeledContent("Calendar", value: "Busy times only")
            }
            Section("Setup journey") {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Label(step.title, systemImage: "circle")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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
