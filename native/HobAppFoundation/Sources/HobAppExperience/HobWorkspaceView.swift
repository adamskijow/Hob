// SPDX-License-Identifier: MIT
import SwiftUI
#if canImport(HobAppCore)
import HobAppCore
#endif

public struct HobWorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: HobWorkspaceController

    public init() {
        _controller = StateObject(wrappedValue: HobWorkspaceController())
    }

    public init(controller: HobWorkspaceController) {
        _controller = StateObject(wrappedValue: controller)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction
                    calendarSetup
                    notificationSetup
                    syncSetup
                    composer
                    feedback
                    if let schedule = controller.adoptedSchedule,
                       let proposal = controller.proposal,
                       let diff = controller.scheduleDiff {
                        replanView(schedule, proposal: proposal, diff: diff)
                    } else if let schedule = controller.adoptedSchedule {
                        adopted(schedule)
                    } else if let proposal = controller.proposal {
                        proposalView(proposal)
                    }
                    taskList
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("Hob")
            .toolbar {
                if !controller.tasks.isEmpty {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        controller.undoLastChange()
                    }
                    .disabled(controller.isWorking)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { controller.syncNow() }
            }
        }
    }

    private var calendarSetup: some View {
        HStack(spacing: 10) {
            switch controller.calendarAuthorization {
            case .fullAccess:
                Label("Calendar connected", systemImage: "calendar.badge.checkmark")
                    .foregroundStyle(.secondary)
            case .notDetermined:
                Button("Connect Calendar", systemImage: "calendar.badge.plus") {
                    controller.requestCalendarAccess()
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Lets Hob avoid busy times and add adopted schedules")
            case .denied, .restricted:
                Label("Enable full Calendar access in Settings", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if controller.calendarCleanupPending {
                Button("Remove old Hob blocks") {
                    controller.retryCalendarCleanup()
                }
                .disabled(controller.isWorking)
            }
        }
    }

    private var notificationSetup: some View {
        HStack(spacing: 10) {
            switch controller.notificationAuthorization {
            case .authorized:
                Label("Start reminders enabled", systemImage: "bell.badge.fill")
                    .foregroundStyle(.secondary)
            case .notDetermined:
                Button("Enable start reminders", systemImage: "bell.badge") {
                    controller.requestNotificationAccess()
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Adds Done, Snooze, and Replan actions at scheduled start times")
            case .denied:
                Label("Enable notifications in Settings", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
            }
            if controller.notificationCleanupPending {
                Button("Remove old reminders") {
                    controller.retryNotificationCleanup()
                }
                .disabled(controller.isWorking)
            }
            if controller.notificationActionsPending {
                Button("Finish reminder action") {
                    controller.processNotificationResponses()
                }
                .disabled(controller.isWorking)
            }
        }
    }

    private var syncSetup: some View {
        HStack(spacing: 10) {
            switch controller.syncAvailability {
            case .available:
                Label(
                    controller.syncNeedsAttention
                        ? "iCloud sync needs attention"
                        : "Tasks sync with iCloud",
                    systemImage: controller.syncNeedsAttention
                        ? "icloud.slash"
                        : "icloud.and.arrow.up"
                )
                .foregroundStyle(
                    controller.syncNeedsAttention ? Color.orange : Color.secondary
                )
            case .noAccount:
                Label("Sign in to iCloud to sync", systemImage: "icloud.slash")
                    .foregroundStyle(.orange)
            case .restricted:
                Label("iCloud sync is restricted", systemImage: "icloud.slash")
                    .foregroundStyle(.orange)
            case .unavailable:
                Label("iCloud sync unavailable", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
            Button("Sync now") {
                controller.syncNow()
            }
            .disabled(controller.isWorking)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What needs to get done?")
                .font(.largeTitle.bold())
            Text("Include deadlines, priority, and effort naturally. Hob will turn them into a realistic timeline.")
                .foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextField(
                "Finish taxes by Friday, high priority, about 90 minutes…",
                text: $controller.draft,
                axis: .vertical
            )
            .lineLimit(3...7)
            .textFieldStyle(.roundedBorder)
            .onSubmit { controller.submit() }
            Button {
                controller.submit()
            } label: {
                if controller.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Plan it", systemImage: "arrow.up.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canSubmit)
            .accessibilityHint("Interprets the message, saves its tasks, and builds a schedule proposal")
        }
    }

    @ViewBuilder private var feedback: some View {
        if let error = controller.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Error: \(error)")
        } else if let notice = controller.notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private func proposalView(_ proposal: RuntimeScheduleProposal) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                scheduleHeader("Proposed schedule", proposal: proposal)
                scheduleBlocks(proposal)
                Button("Add to Calendar") {
                    controller.adoptProposal()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    proposal.blocks.isEmpty
                        || controller.isWorking
                        || controller.calendarAuthorization != .fullAccess
                )
                .accessibilityHint("Adds every displayed time block to your default calendar")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func adopted(_ adopted: RuntimeAdoptedSchedule) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Adopted schedule", systemImage: "checkmark.seal.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                if !adopted.notificationIDs.isEmpty {
                    Label("Done, Snooze, and Replan are available at each start time.", systemImage: "bell.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                scheduleBlocks(adopted.proposal)
                Button("Cancel adopted schedule", role: .destructive) {
                    controller.cancelAdoptedSchedule()
                }
                .disabled(controller.isWorking)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func replanView(
        _ adopted: RuntimeAdoptedSchedule,
        proposal: RuntimeScheduleProposal,
        diff: RuntimeScheduleDiff
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Review schedule changes", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.title2.bold())
                Text("Your Calendar stays unchanged until you accept.")
                    .foregroundStyle(.secondary)
                ForEach(diff.changes) { change in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: changeIcon(change.kind))
                            .foregroundStyle(changeColor(change.kind))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(changeLabel(change.kind)): \(change.task)")
                                .fontWeight(.semibold)
                            Text(changeDetail(change))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Update Calendar") {
                        controller.adoptProposal()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isWorking)
                    Button("Keep current schedule") {
                        controller.keepAdoptedSchedule()
                    }
                    .disabled(controller.isWorking)
                }
                DisclosureGroup("Proposed schedule") {
                    scheduleBlocks(proposal)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func changeLabel(_ kind: RuntimeScheduleChangeKind) -> String {
        switch kind {
        case .stays: return "Stays"
        case .moves: return "Moves"
        case .added: return "Adds"
        case .removed: return "Removes"
        case .unscheduled: return "Needs room"
        }
    }

    private func changeIcon(_ kind: RuntimeScheduleChangeKind) -> String {
        switch kind {
        case .stays: return "equal.circle.fill"
        case .moves: return "arrow.right.circle.fill"
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .unscheduled: return "exclamationmark.circle.fill"
        }
    }

    private func changeColor(_ kind: RuntimeScheduleChangeKind) -> Color {
        switch kind {
        case .stays: return .secondary
        case .moves, .added: return .blue
        case .removed: return .secondary
        case .unscheduled: return .orange
        }
    }

    private func changeDetail(_ change: RuntimeScheduleChange) -> String {
        switch change.kind {
        case .stays:
            return change.proposedStartAt.map(displayTime) ?? "Same time"
        case .moves:
            return "\(change.previousStartAt.map(displayTime) ?? "Unscheduled") → \(change.proposedStartAt.map(displayTime) ?? "Unscheduled")"
        case .added:
            return change.proposedStartAt.map(displayTime) ?? "Added to the plan"
        case .removed:
            return change.previousStartAt.map(displayTime) ?? "Removed from the plan"
        case .unscheduled:
            return change.reason ?? "No open block fits"
        }
    }

    private func displayTime(_ timestamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else {
            return timestamp
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func scheduleHeader(
        _ title: String,
        proposal: RuntimeScheduleProposal
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text("\(proposal.blocks.count) block(s) · \(proposal.unscheduled.count) left unscheduled")
                .foregroundStyle(.secondary)
        }
    }

    private func scheduleBlocks(_ proposal: RuntimeScheduleProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(proposal.blocks) { block in
                HStack(alignment: .top, spacing: 12) {
                    Text(timeRange(block))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(width: 145, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.task).fontWeight(.semibold)
                        Text("\(block.durationMinutes) minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if block.priority == "high" {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("High priority")
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(proposal.unscheduled) { task in
                Label("\(task.task): \(task.reason)", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if !proposal.assumptions.isEmpty {
                DisclosureGroup("Assumptions") {
                    ForEach(proposal.assumptions, id: \.self) { assumption in
                        Text(assumption)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tasks").font(.title2.bold())
            if controller.tasks.isEmpty {
                Text("Nothing captured yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.tasks, id: \.id) { task in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.task)
                        Text(details(task))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(task.status.capitalized)
                        .font(.caption.weight(.semibold))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func details(_ task: RuntimeTask) -> String {
        var values: [String] = []
        if let due = task.dueDate { values.append("scheduled \(due)") }
        if let deadline = task.deadlineDate { values.append("due \(deadline)") }
        if let duration = task.durationMinutes { values.append("\(duration)m") }
        if let priority = task.priority, priority != "normal" { values.append(priority) }
        return values.isEmpty ? "No stated constraints" : values.joined(separator: " · ")
    }

    private func timeRange(_ block: RuntimeScheduleBlock) -> String {
        guard let start = ISO8601DateFormatter().date(from: block.startAt),
              let end = ISO8601DateFormatter().date(from: block.endAt) else {
            return block.startAt
        }
        let day = DateFormatter()
        day.dateFormat = "EEE"
        let time = DateFormatter()
        time.timeStyle = .short
        return "\(day.string(from: start)) \(time.string(from: start))–\(time.string(from: end))"
    }
}
