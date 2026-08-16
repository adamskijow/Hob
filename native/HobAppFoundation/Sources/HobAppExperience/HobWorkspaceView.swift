// SPDX-License-Identifier: MIT
import SwiftUI
#if canImport(HobAppCore)
import HobAppCore
#endif

public struct HobWorkspaceView: View {
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
                    composer
                    feedback
                    if let schedule = controller.adoptedSchedule {
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
                scheduleBlocks(adopted.proposal)
                Button("Cancel adopted schedule", role: .destructive) {
                    controller.cancelAdoptedSchedule()
                }
                .disabled(controller.isWorking)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
