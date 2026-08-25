// SPDX-License-Identifier: MIT
import SwiftUI
#if canImport(HobAppCore)
import HobAppCore
#endif

enum HobTheme {
    static let gold = Color(red: 0.95, green: 0.66, blue: 0.27)
    static let copper = Color(red: 0.68, green: 0.29, blue: 0.08)

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.78, green: 0.38, blue: 0.12) : copper
    }

    static func base(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.045, green: 0.025, blue: 0.018)
            : Color(red: 0.98, green: 0.96, blue: 0.92)
    }

    static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.065)
            : Color(red: 0.34, green: 0.15, blue: 0.06).opacity(0.065)
    }

    static func border(for scheme: ColorScheme) -> Color {
        gold.opacity(scheme == .dark ? 0.20 : 0.14)
    }
}

struct HobAppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            HobTheme.base(for: colorScheme)
            RadialGradient(
                colors: [
                    HobTheme.copper.opacity(colorScheme == .dark ? 0.20 : 0.10),
                    HobTheme.gold.opacity(colorScheme == .dark ? 0.055 : 0.035),
                    .clear,
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 520
            )
        }
    }
}

public struct HobWorkspaceView: View {
    private enum WorkspaceTab: Hashable {
        case today
        case schedule
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var controller: HobWorkspaceController
    @AppStorage("hob.onboarding.completed.v1") private var onboardingCompleted = false
    @State private var showsOnboarding = false
    @State private var showsCalendarSettings = false
    @State private var selectedTab: WorkspaceTab = .today
    @State private var selectedDigestItem: RuntimeMorningDigestItem?
    @State private var editedDigestTitle = ""

    public init() {
        _controller = StateObject(wrappedValue: HobWorkspaceController())
    }

    public init(controller: HobWorkspaceController) {
        _controller = StateObject(wrappedValue: controller)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                workspaceScroll {
                    introduction
                    morningDigest
                    composer
                    feedback
                }
                .navigationTitle("Hob")
                .toolbar { workspaceToolbar }
            }
            .tabItem { Label("Today", systemImage: "sun.max.fill") }
            .tag(WorkspaceTab.today)

            NavigationStack {
                workspaceScroll {
                    scheduleContent
                    taskList
                }
                .navigationTitle("Schedule")
                .toolbar { workspaceToolbar }
            }
            .tabItem { Label("Schedule", systemImage: "calendar") }
            .tag(WorkspaceTab.schedule)
        }
        .tint(HobTheme.accent(for: colorScheme))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.syncNow() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
            )
        ) { _ in
            controller.syncNow()
        }
        .onAppear {
            if !onboardingCompleted { showsOnboarding = true }
        }
        .sheet(isPresented: $showsOnboarding) {
            HobFirstRunView(
                controller: controller,
                reviewingExistingSetup: onboardingCompleted
            ) {
                onboardingCompleted = true
                showsOnboarding = false
            }
        }
        .sheet(isPresented: $showsCalendarSettings) {
            HobCalendarSettingsView(controller: controller)
        }
    }

    private func workspaceScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
        }
        .background { HobAppBackground().ignoresSafeArea() }
    }

    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup {
            if !controller.tasks.isEmpty {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    controller.undoLastChange()
                }
                .disabled(controller.isWorking)
            }
            connectionsMenu
        }
    }

    @ViewBuilder private var scheduleContent: some View {
        if let schedule = controller.adoptedSchedule,
           let proposal = controller.proposal,
           let diff = controller.scheduleDiff {
            replanView(schedule, proposal: proposal, diff: diff)
        } else if let schedule = controller.adoptedSchedule {
            adopted(schedule)
        } else if let proposal = controller.proposal {
            proposalView(proposal)
        } else {
            ContentUnavailableView(
                "No schedule yet",
                systemImage: "calendar",
                description: Text("Add work from Today and Hob will plan it here.")
            )
        }
    }

    private var connectionsMenu: some View {
        Menu {
            Section("Check-ins") { checkInMenuItems }
            Section("Calendar") { calendarMenuItems }
            Section("Reminders") { reminderMenuItems }
            Section("iCloud") { syncMenuItems }
            Divider()
            Button("Review setup", systemImage: "slider.horizontal.3") {
                showsOnboarding = true
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Connections and setup")
    }

    @ViewBuilder private var checkInMenuItems: some View {
        Toggle(
            "Daily digest",
            isOn: Binding(
                get: { controller.morningDigestEnabled },
                set: { controller.setMorningDigestEnabled($0) }
            )
        )
        checkInTimeMenu(
            title: "Digest time",
            selection: controller.morningDigestTime,
            enabled: controller.morningDigestEnabled,
            set: controller.setMorningDigestTime
        )
        Divider()
        Toggle(
            "Evening recap",
            isOn: Binding(
                get: { controller.eveningRecapEnabled },
                set: { controller.setEveningRecapEnabled($0) }
            )
        )
        checkInTimeMenu(
            title: "Recap time",
            selection: controller.eveningRecapTime,
            enabled: controller.eveningRecapEnabled,
            set: controller.setEveningRecapTime
        )
        if (controller.morningDigestEnabled || controller.eveningRecapEnabled),
           controller.notificationAuthorization != .authorized {
            Label("Enable notifications below", systemImage: "bell.slash")
        } else {
            if controller.morningDigestNeedsAttention {
                Label("Digest needs attention", systemImage: "exclamationmark.triangle")
            }
            if controller.eveningRecapNeedsAttention {
                Label("Recap needs attention", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func checkInTimeMenu(
        title: String,
        selection: String,
        enabled: Bool,
        set: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(HobWorkspaceController.validMorningDigestTimes, id: \.self) { time in
                Button {
                    set(time)
                } label: {
                    if time == selection {
                        Label(
                            HobWorkspaceController.morningDigestTimeLabel(time),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(HobWorkspaceController.morningDigestTimeLabel(time))
                    }
                }
            }
        } label: {
            Label(
                "\(title): \(HobWorkspaceController.morningDigestTimeLabel(selection))",
                systemImage: "clock"
            )
        }
        .disabled(!enabled)
    }

    @ViewBuilder private var calendarMenuItems: some View {
        Toggle(
            "Calendar integration",
            isOn: Binding(
                get: { controller.calendarIntegrationEnabled },
                set: { controller.setCalendarIntegrationEnabled($0) }
            )
        )
        if controller.calendarIntegrationEnabled {
            switch controller.calendarAuthorization {
            case .fullAccess:
                Button("Plans around: \(controller.inputCalendarSummary)") {
                    showsCalendarSettings = true
                }
                Button("Adds to: \(controller.outputCalendarSummary)") {
                    showsCalendarSettings = true
                }
            case .notDetermined:
                Label("Waiting for access", systemImage: "calendar.badge.plus")
            case .denied, .restricted:
                Label("Needs access in Settings", systemImage: "exclamationmark.triangle")
            }
        }
        if controller.calendarCleanupPending {
            Button("Remove old Hob blocks") {
                controller.retryCalendarCleanup()
            }
            .disabled(controller.isWorking)
        }
    }

    @ViewBuilder private var reminderMenuItems: some View {
        switch controller.notificationAuthorization {
        case .authorized:
            Label("Enabled", systemImage: "checkmark.circle.fill")
        case .notDetermined:
            Button("Enable", systemImage: "bell.badge") {
                controller.requestNotificationAccess()
            }
        case .denied:
            Label("Needs access in Settings", systemImage: "exclamationmark.triangle")
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

    @ViewBuilder private var syncMenuItems: some View {
        switch controller.syncAvailability {
        case .available where controller.syncNeedsAttention:
            Label("Needs attention", systemImage: "exclamationmark.triangle")
        case .available:
            Label("Connected", systemImage: "checkmark.circle.fill")
        case .noAccount:
            Label("Sign in to iCloud", systemImage: "icloud.slash")
        case .restricted:
            Label("Restricted", systemImage: "icloud.slash")
        case .unavailable:
            Label("Unavailable", systemImage: "icloud.slash")
        }
        Button("Sync now", systemImage: "arrow.clockwise") {
            controller.syncNow()
        }
        .disabled(controller.isWorking)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [HobTheme.gold, HobTheme.copper],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 46, height: 5)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text("What needs to get done?")
                .font(.largeTitle.bold())
            Text("Include deadlines, priority, and effort naturally. Hob will turn them into a realistic timeline.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var morningDigest: some View {
        if let digest = controller.morningDigest {
            VStack(alignment: .leading, spacing: 8) {
                Label("Morning. Here is today:", systemImage: "sunrise.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                if digest.items.isEmpty {
                    Text("Nothing on deck today.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(digest.items.prefix(6).enumerated()), id: \.element.id) { index, item in
                        Button {
                            editedDigestTitle = item.task
                            selectedDigestItem = item
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, alignment: .trailing)
                                Text(item.summary)
                                    .font(.subheadline)
                                Spacer(minLength: 4)
                                Image(systemName: "ellipsis.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.isWorking)
                        .accessibilityHint("Shows task actions")
                    }
                    if digest.items.count > 6 {
                        Text("+\(digest.items.count - 6) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                HobTheme.surface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(HobTheme.border(for: colorScheme), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .sheet(item: $selectedDigestItem) { item in
                taskActionsSheet(item)
            }
        }
    }

    private func taskActionsSheet(_ item: RuntimeMorningDigestItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Task")
                    .font(.title2.bold())
                Spacer()
                Button("Close", systemImage: "xmark") {
                    selectedDigestItem = nil
                }
                .labelStyle(.iconOnly)
            }
            TextField("Task", text: $editedDigestTitle, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Mark Done", systemImage: "checkmark.circle.fill") {
                    controller.markDone(taskID: item.taskID)
                    selectedDigestItem = nil
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    controller.renameTask(taskID: item.taskID, to: editedDigestTitle)
                    selectedDigestItem = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    editedDigestTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || editedDigestTitle.trimmingCharacters(in: .whitespacesAndNewlines) == item.task
                        || controller.isWorking
                )
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .presentationDetents([.height(230)])
        .presentationDragIndicator(.visible)
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextField(
                "Finish taxes by Friday, high priority, about 90 minutes…",
                text: $controller.draft,
                axis: .vertical
            )
            .lineLimit(3...7)
            .textFieldStyle(.plain)
            .padding(16)
            .background(
                HobTheme.surface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(HobTheme.border(for: colorScheme), lineWidth: 1)
            }
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
            .keyboardShortcut(.return, modifiers: [.command])
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
        VStack(alignment: .leading, spacing: 10) {
            scheduleHeader("Schedule", proposal: proposal)
            scheduleBlocks(proposal)
            Button {
                controller.adoptProposal()
            } label: {
                Label(
                    controller.calendarIntegrationEnabled ? "Add to Calendar" : "Use schedule",
                    systemImage: controller.calendarIntegrationEnabled
                        ? "calendar.badge.plus" : "checkmark.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                proposal.blocks.isEmpty
                    || controller.isWorking
                    || (controller.calendarIntegrationEnabled
                        && controller.calendarAuthorization != .fullAccess)
            )
            .accessibilityHint(
                controller.calendarIntegrationEnabled
                    ? "Adds every displayed time block to your chosen calendar"
                    : "Adopts the displayed schedule without changing Calendar"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            HobTheme.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(HobTheme.border(for: colorScheme), lineWidth: 1)
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
                Text("The current schedule stays unchanged until you accept.")
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
                    Button(
                        controller.calendarIntegrationEnabled
                            ? "Update Calendar" : "Update schedule"
                    ) {
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
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            Text(scheduleSummary(proposal))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func scheduleSummary(_ proposal: RuntimeScheduleProposal) -> String {
        let blocks = "\(proposal.blocks.count) \(proposal.blocks.count == 1 ? "block" : "blocks")"
        guard !proposal.unscheduled.isEmpty else { return blocks }
        let open = "\(proposal.unscheduled.count) unscheduled"
        return "\(blocks) · \(open)"
    }

    private func scheduleBlocks(_ proposal: RuntimeScheduleProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(proposal.blocks) { block in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.task)
                            .font(.subheadline.weight(.semibold))
                        Text("\(timeRange(block)) · \(block.durationMinutes)m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    priorityIcon(block)
                }
                .padding(9)
                .background(
                    HobTheme.surface(for: colorScheme).opacity(0.75),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityElement(children: .combine)
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

    @ViewBuilder private func priorityIcon(_ block: RuntimeScheduleBlock) -> some View {
        if block.priority == "high" {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("High priority")
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
                .padding(12)
                .background(
                    HobTheme.surface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
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
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let startTime = start.formatted(date: .omitted, time: .shortened)
        let endTime = end.formatted(date: .omitted, time: .shortened)
        return "\(day), \(startTime)–\(endTime)"
    }
}

private struct HobCalendarSettingsView: View {
    @ObservedObject var controller: HobWorkspaceController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        "All calendars",
                        isOn: Binding(
                            get: { controller.usesAllInputCalendars },
                            set: { controller.setUsesAllInputCalendars($0) }
                        )
                    )
                    if !controller.usesAllInputCalendars {
                        ForEach(controller.calendars) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: {
                                        controller.inputCalendarIDs?.contains(calendar.id) == true
                                    },
                                    set: {
                                        controller.setInputCalendar(calendar.id, included: $0)
                                    }
                                )
                            ) {
                                calendarLabel(calendar)
                            }
                        }
                        if controller.unavailableInputCalendarCount > 0 {
                            Button(
                                "Remove unavailable calendars",
                                systemImage: "exclamationmark.triangle"
                            ) {
                                controller.removeUnavailableInputCalendars()
                            }
                            .foregroundStyle(.orange)
                        }
                    }
                    Toggle(
                        "All-day events block time",
                        isOn: Binding(
                            get: { controller.blockAllDayEvents },
                            set: { controller.setBlockAllDayEvents($0) }
                        )
                    )
                } header: {
                    Text("Plans around")
                } footer: {
                    Text("Hob uses event times, not titles, while planning.")
                }

                Section {
                    Picker(
                        "Calendar",
                        selection: Binding<String?>(
                            get: { controller.outputCalendarID },
                            set: { controller.setOutputCalendar($0) }
                        )
                    ) {
                        Text("Apple default").tag(Optional<String>.none)
                        if let selected = controller.outputCalendarID,
                           !controller.calendars.contains(where: { $0.id == selected }) {
                            Text("Unavailable calendar").tag(Optional(selected))
                        }
                        ForEach(controller.calendars.filter(\.allowsContentModifications)) { calendar in
                            Text("\(calendar.title) — \(calendar.sourceTitle)")
                                .tag(Optional(calendar.id))
                        }
                    }
                    Button("Create Hob calendar", systemImage: "calendar.badge.plus") {
                        controller.createHobCalendar()
                    }
                    .disabled(controller.isWorking)
                } header: {
                    Text("Adds schedules to")
                } footer: {
                    Text("The Hob calendar uses the same account as your Apple default calendar.")
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(controller.isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(controller.isWorking)
        .onDisappear { controller.applyCalendarSettings() }
    }

    private func calendarLabel(
        _ calendar: RuntimeCalendarDescriptor
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(calendar.title)
            Text(calendar.sourceTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
