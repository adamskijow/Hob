// SPDX-License-Identifier: MIT
import AppKit
#if canImport(HobAppCore)
import HobAppCore
#endif
import SwiftUI

@main
struct HobMacShell: App {
    @State private var readiness = AppReadiness(
        edition: .appStore,
        modelBackend: .appleFoundationModels,
        ownerPaired: false,
        backgroundServiceApproved: false,
        modelAvailable: false
    )

    var body: some Scene {
        Window("Hob Setup", id: "setup") {
            SetupHomeView(readiness: readiness)
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
    let readiness: AppReadiness

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
            OnboardingView()
        }
        .padding(28)
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
