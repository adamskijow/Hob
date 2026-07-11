// SPDX-License-Identifier: MIT
import AppKit
import HobAppCore
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
        MenuBarExtra("Hob", systemImage: "sparkles") {
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
                SettingsLink {
                    Text("Open Settings")
                }
                Button("Quit Hob") { NSApplication.shared.terminate(nil) }
            }
            .padding()
            .frame(width: 340)
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
