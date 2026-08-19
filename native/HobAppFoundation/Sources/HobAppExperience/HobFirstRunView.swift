// SPDX-License-Identifier: MIT
import SwiftUI
import UniformTypeIdentifiers
#if canImport(HobAppCore)
import HobAppCore
#endif

struct HobFirstRunView: View {
    @ObservedObject var controller: HobWorkspaceController
    let finish: () -> Void

    @State private var step = 0
    @State private var workHours = "09:00|17:30"
    @State private var workDays = "weekdays"
    @State private var defaultDuration = 30
    @State private var transition = 0
    @State private var importsFile = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: connections
                    case 2: rhythm
                    case 3: migration
                    default: ready
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack {
                    if step > 0 { Button("Back") { step -= 1 } }
                    Spacer()
                    Button(step == 4 ? "Start using Hob" : "Continue") {
                        if step == 2 { saveRhythm() }
                        if step == 4 { finish() } else { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        controller.isWorking
                            || (step == 4 && !controller.modelReadiness.isReady)
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 560, maxHeight: .infinity)
            .navigationTitle("Set up Hob")
            .onAppear { loadRhythm() }
            .fileImporter(
                isPresented: $importsFile,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let url = urls.first {
                    controller.importOpenLocal(from: url)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("A plan you can actually follow").font(.largeTitle.bold())
            Text("Describe the work. Hob uses Apple Intelligence on this device, finds room around your Calendar, and lets you approve every schedule change.")
            Label("Messages and Calendar details stay on this device.", systemImage: "lock.shield")
            Label("Tasks sync privately through your iCloud account.", systemImage: "icloud")
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect the parts you want").font(.title.bold())
            setupRow(
                title: "Apple Intelligence",
                detail: controller.modelReadiness.isReady
                    ? "Ready" : controller.modelReadiness.guidance,
                symbol: "apple.intelligence"
            ) {
                if !controller.modelReadiness.isReady {
                    Button(controller.modelReadiness == .notChecked ? "Check" : "Check again") {
                        controller.checkModelReadiness()
                    }
                }
            }
            setupRow(title: "iCloud", detail: syncDetail, symbol: "icloud") {
                Button("Check") { controller.syncNow() }
            }
            setupRow(
                title: "Calendar",
                detail: controller.calendarAuthorization == .fullAccess
                    ? "Connected" : "Avoid busy time and add approved plans",
                symbol: "calendar"
            ) {
                if controller.calendarAuthorization == .notDetermined {
                    Button("Connect") { controller.requestCalendarAccess() }
                }
            }
            setupRow(
                title: "Reminders",
                detail: controller.notificationAuthorization == .authorized
                    ? "Enabled" : "Optional start alerts with Done, Snooze, and Replan",
                symbol: "bell"
            ) {
                if controller.notificationAuthorization == .notDetermined {
                    Button("Enable") { controller.requestNotificationAccess() }
                }
            }
            Text("You can continue without Calendar or reminders.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var rhythm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("When should Hob plan work?").font(.title.bold())
            Picker("Hours", selection: $workHours) {
                Text("8:00–4:00").tag("08:00|16:00")
                Text("9:00–5:30").tag("09:00|17:30")
                Text("10:00–6:00").tag("10:00|18:00")
            }
            Picker("Days", selection: $workDays) {
                Text("Monday–Friday").tag("weekdays")
                Text("Every day").tag("everyday")
            }
            Picker("Default task length", selection: $defaultDuration) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("60 minutes").tag(60)
            }
            Picker("Space between tasks", selection: $transition) {
                Text("None").tag(0)
                Text("5 minutes").tag(5)
                Text("10 minutes").tag(10)
                Text("15 minutes").tag(15)
            }
            Text("Specific times and effort in your message override these defaults.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var migration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Already use Open Local?").font(.title.bold())
            Text("In the Open Local teapot menu, choose Export for Apple App. Import that JSON here before adding native tasks.")
            Button("Import Open Local Export", systemImage: "square.and.arrow.down") {
                importsFile = true
            }
            .buttonStyle(.bordered)
            .disabled(!controller.tasks.isEmpty || controller.isWorking)
            if !controller.tasks.isEmpty && controller.importReport == nil {
                Text("Import is unavailable because this app already has tasks.")
                    .foregroundStyle(.secondary)
            }
            if let report = controller.importReport {
                Label("Imported \(report.tasks.count) tasks", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if report.preservedDetailCount > 0 {
                    Text("\(report.preservedDetailCount) advanced detail(s) are preserved with the tasks. Open Local remains unchanged.")
                        .font(.callout)
                }
            }
            Text("Task history and adopted Open Local plans stay in the export. Keep that file until you have checked the Apple app.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Ready").font(.largeTitle.bold())
            Text("Try: “Finish taxes by Friday, high priority, about 90 minutes.”")
            Text("Hob proposes a timeline first. Your Calendar changes only when you approve it.")
                .foregroundStyle(.secondary)
            if !controller.modelReadiness.isReady {
                Label("Apple Intelligence must be ready before Hob can interpret tasks.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func setupRow<Actions: View>(
        title: String,
        detail: String,
        symbol: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).frame(width: 24)
                Text(title).fontWeight(.semibold)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
            actions()
        }
        .accessibilityElement(children: .contain)
    }

    private var syncDetail: String {
        switch controller.syncAvailability {
        case .available: return "Private task sync is ready"
        case .noAccount: return "Sign in to iCloud to sync devices"
        case .restricted: return "Restricted on this device"
        case .unavailable: return "Unavailable right now"
        }
    }

    private func loadRhythm() {
        let value = controller.planningPreferences
        let pair = "\(value.workStart)|\(value.workEnd)"
        if ["08:00|16:00", "09:00|17:30", "10:00|18:00"].contains(pair) {
            workHours = pair
        }
        workDays = value.workDays == Array(1...7) ? "everyday" : "weekdays"
        if [15, 30, 60].contains(value.defaultDurationMinutes) {
            defaultDuration = value.defaultDurationMinutes
        }
        if [0, 5, 10, 15].contains(value.transitionBufferMinutes) {
            transition = value.transitionBufferMinutes
        }
    }

    private func saveRhythm() {
        let hours = workHours.split(separator: "|").map(String.init)
        guard hours.count == 2 else { return }
        controller.updatePlanningPreferences(
            workStart: hours[0],
            workEnd: hours[1],
            workDays: workDays == "everyday" ? Array(1...7) : Array(1...5),
            defaultDurationMinutes: defaultDuration,
            transitionBufferMinutes: transition
        )
    }
}
