import ImageIO
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
        case upcoming
    }

    private enum ConversationAnchor {
        static let bottom = "conversation-bottom"
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var controller: HobWorkspaceController
    @AppStorage("hob.onboarding.completed.v1") private var onboardingCompleted = false
    @State private var showsSettings = false
    @State private var showsOnboarding = false
    @State private var showsCalendarSettings = false
    @State private var selectedTab: WorkspaceTab = .today
    @State private var selectedDigestItem: RuntimeMorningDigestItem?
    @State private var originalReminder: RuntimeTask?
    @State private var editedDigestTitle = ""
    @State private var editedNote = ""
    @State private var editedHasDate = false
    @State private var editedHasTime = false
    @State private var editedDate = Date()
    @State private var editedTime = Date()
    @State private var editedKeepIndefinitely = false
    @State private var dismissingForTaskAction = false
    @FocusState private var composerFocused: Bool

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
                    conversation
                    planningAnalysis
                    scheduleContent
                }
                .navigationTitle("")
                .toolbar { workspaceToolbar }
            }
            .tabItem { Label("Today", systemImage: "sun.max.fill") }
            .tag(WorkspaceTab.today)

            NavigationStack {
                workspaceScroll {
                    upcomingList
                }
                .navigationTitle("Upcoming")
                .toolbar { workspaceToolbar }
            }
            .tabItem { Label("Upcoming", systemImage: "calendar") }
            .tag(WorkspaceTab.upcoming)
        }
        .tint(HobTheme.accent(for: colorScheme))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.syncNow() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if scenePhase == .active { controller.refreshForDayChange() }
        }
        .onChange(of: selectedTab) { _, _ in
            composerFocused = false
        }
        .onChange(of: showsOnboarding) { _, isPresented in
            if isPresented { composerFocused = false }
        }
        .onChange(of: showsSettings) { _, isPresented in
            if isPresented { composerFocused = false }
        }
        .onChange(of: showsCalendarSettings) { _, isPresented in
            if isPresented { composerFocused = false }
        }
        .onChange(of: selectedDigestItem?.id) { _, taskID in
            if taskID != nil { composerFocused = false }
        }
        .onChange(of: controller.longRangeConfirmation) { _, confirmation in
            if confirmation != nil { composerFocused = false }
        }
        .onChange(of: controller.errorMessage) { _, error in
            if error != nil { composerFocused = true }
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
        .sheet(isPresented: $showsSettings) {
            settingsSheet
        }
        .sheet(item: $selectedDigestItem) { item in
            taskActionsSheet(item)
                .environment(\.timeZone, controller.reminderTimezone)
        }
        .alert(
            controller.longRangeConfirmation ?? "Check that date",
            isPresented: Binding(
                get: { controller.longRangeConfirmation != nil },
                set: { if !$0 { controller.cancelLongRangeSubmission() } }
            )
        ) {
            Button("Yes") { controller.confirmLongRangeSubmission() }
            Button("Cancel", role: .cancel) {
                controller.cancelLongRangeSubmission()
            }
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
            .contentShape(Rectangle())
            .onTapGesture {
                composerFocused = false
            }
        }
        .scrollDismissesKeyboard(.interactively)
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
            settingsButton
        }
    }

    @ViewBuilder private var scheduleContent: some View {
        if let schedule = controller.adoptedSchedule,
            let proposal = controller.proposal,
            let diff = controller.scheduleDiff
        {
            replanView(schedule, proposal: proposal, diff: diff)
        } else if let schedule = controller.adoptedSchedule {
            adopted(schedule)
        } else if let proposal = controller.proposal,
            !proposal.plannedUntimedTaskIDs.isEmpty
        {
            proposalView(proposal)
        }
    }

    private var settingsButton: some View {
        Button {
            showsSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Connections and setup")
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Check-ins") { checkInMenuItems }
                    .listRowBackground(HobTheme.surface(for: colorScheme))
                Section("Calendar") { calendarMenuItems }
                    .listRowBackground(HobTheme.surface(for: colorScheme))
                Section("Reminders") { reminderMenuItems }
                    .listRowBackground(HobTheme.surface(for: colorScheme))
                Section("iCloud") { syncMenuItems }
                    .listRowBackground(HobTheme.surface(for: colorScheme))
                Section {
                    Button("Review setup", systemImage: "slider.horizontal.3") {
                        showsSettings = false
                        Task { @MainActor in
                            await Task.yield()
                            showsOnboarding = true
                        }
                    }
                }
                .listRowBackground(HobTheme.surface(for: colorScheme))
            }
            .scrollContentBackground(.hidden)
            .background { HobAppBackground().ignoresSafeArea() }
            .navigationTitle("Settings")
            .modifier(HobSettingsToolbarBackground(colorScheme: colorScheme))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsSettings = false }
                }
            }
        }
        .tint(HobTheme.accent(for: colorScheme))
        .presentationBackground(HobTheme.base(for: colorScheme))
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showsCalendarSettings) {
            HobCalendarSettingsView(controller: controller)
        }
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
        Toggle(
            "Nightly “What got done?”",
            isOn: Binding(
                get: { controller.eveningRecapEnabled },
                set: { controller.setEveningRecapEnabled($0) }
            )
        )
        checkInTimeMenu(
            title: "Nightly time",
            selection: controller.eveningRecapTime,
            enabled: controller.eveningRecapEnabled,
            set: controller.setEveningRecapTime
        )
        if controller.morningDigestEnabled || controller.eveningRecapEnabled,
            controller.notificationAuthorization != .authorized
        {
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
            "Calendar availability",
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
        if controller.taskRemindersNeedAttention {
            Button("Retry task reminders") { controller.retryNotificationCleanup() }
        }
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
            Label(
                controller.syncAttentionMessage ?? "Couldn’t sync tasks",
                systemImage: "exclamationmark.triangle"
            )
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
        HStack(spacing: 12) {
            HobBrandArtwork()
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(HobTheme.border(for: colorScheme), lineWidth: 1)
                }
                .shadow(color: HobTheme.copper.opacity(0.28), radius: 8, y: 3)
            Text("Hob")
                .font(.system(size: 42, weight: .bold, design: .rounded))
        }
        .foregroundStyle(
            LinearGradient(
                colors: [HobTheme.gold, HobTheme.accent(for: colorScheme)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hob")
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
                    ForEach(Array(digest.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if let task = controller.task(taskID: item.taskID) { selectReminder(task) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, alignment: .trailing)
                                Text(item.summary)
                                    .font(.subheadline)
                                Spacer(minLength: 4)
                                if !item.allowsReview {
                                    Image(systemName: "infinity")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tint)
                                        .accessibilityLabel("Kept indefinitely")
                                        .accessibilityIdentifier("hob.today.ongoing.\(item.taskID)")
                                }
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
                }
                if let question = controller.reviewQuestion {
                    Text(question.text)
                        .accessibilityIdentifier("hob.question.taskReview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
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
        }
    }

    private func taskActionsSheet(_ item: RuntimeMorningDigestItem) -> some View {
        ScrollView {
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
                    .accessibilityIdentifier("hob.edit.title")
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Toggle("Date", isOn: $editedHasDate)
                    .accessibilityIdentifier("hob.edit.hasDate")
                if editedHasDate {
                    DatePicker("On", selection: $editedDate, displayedComponents: .date)
                    Toggle("Time", isOn: $editedHasTime)
                        .accessibilityIdentifier("hob.edit.hasTime")
                    if editedHasTime {
                        DatePicker("At", selection: $editedTime, displayedComponents: .hourAndMinute)
                    }
                }
                Toggle("Keep indefinitely", isOn: $editedKeepIndefinitely)
                    .accessibilityIdentifier("hob.edit.keepIndefinitely")
                Text("It stays available, and Hob won’t ask whether it still belongs on Today.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Note", text: $editedNote, axis: .vertical)
                    .accessibilityIdentifier("hob.edit.note")
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Mark Done", systemImage: "checkmark.circle.fill") {
                        dismissingForTaskAction = true
                        controller.markDone(taskID: item.taskID)
                        selectedDigestItem = nil
                    }
                    .buttonStyle(.bordered)
                }
                if let task = controller.task(taskID: item.taskID) {
                    if task.isWaiting {
                        Button("Return to Today") {
                            dismissingForTaskAction = true
                            controller.setWaiting(taskID: item.taskID, waiting: false)
                            selectedDigestItem = nil
                        }
                        .disabled(controller.isWorking)
                    }
                }
                if controller.task(taskID: item.taskID)?.recurrence != nil {
                    Divider()
                    HStack {
                        Button("Skip this occurrence", systemImage: "forward.end") {
                            dismissingForTaskAction = true
                            controller.skipOccurrence(taskID: item.taskID)
                            selectedDigestItem = nil
                        }
                        .disabled(controller.isWorking)
                        Spacer()
                        Button("Stop repeating", role: .destructive) {
                            dismissingForTaskAction = true
                            controller.stopRepeating(taskID: item.taskID)
                            selectedDigestItem = nil
                        }
                        .disabled(controller.isWorking)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
        }
        .presentationDetents([
            .large
        ])
        .presentationDragIndicator(.visible)
        .onDisappear {
            if !dismissingForTaskAction, let original = originalReminder,
                original.id == item.taskID
            {
                controller.autosaveReminder(
                    original: original,
                    title: editedDigestTitle,
                    date: editedHasDate
                        ? reminderFormatter("yyyy-MM-dd").string(from: editedDate) : nil,
                    time: editedHasDate && editedHasTime
                        ? reminderFormatter("HH:mm").string(from: editedTime) : nil,
                    keepIndefinitely: editedKeepIndefinitely,
                    note: editedNote)
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            conversationTranscript

            TextField(
                "Add a task or ask about your plan…",
                text: $controller.draft,
                axis: .vertical
            )
            .lineLimit(3...7)
            .accessibilityIdentifier("hob.composer")
            .textFieldStyle(.plain)
            .padding(12)
            .background(
                HobTheme.base(for: colorScheme).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(HobTheme.border(for: colorScheme), lineWidth: 1)
            }
            .focused($composerFocused)
            .onSubmit { submitDraft() }
            HStack {
                Spacer()
                Button {
                    submitDraft()
                } label: {
                    if controller.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Send", systemImage: "arrow.up.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canSubmit)
                .accessibilityIdentifier("hob.send")
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityHint("Interprets the message and applies the requested task changes")
            }
        }
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

    private func submitDraft() {
        composerFocused = false
        controller.submit()
    }

    private var conversationTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(controller.conversationMessages) { message in
                        conversationBubble(message)
                    }

                    transientConversationMessage

                    Color.clear
                        .frame(height: 1)
                        .id(ConversationAnchor.bottom)
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 320)
            .scrollIndicators(.visible)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: controller.conversationMessages.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(ConversationAnchor.bottom, anchor: .bottom)
                }
            }
            .onChange(of: controller.errorMessage) { _, _ in
                proxy.scrollTo(ConversationAnchor.bottom, anchor: .bottom)
            }
            .onChange(of: controller.notice) { _, _ in
                proxy.scrollTo(ConversationAnchor.bottom, anchor: .bottom)
            }
        }
    }

    @ViewBuilder private var transientConversationMessage: some View {
        if let error = controller.errorMessage,
            controller.conversationMessages.last?.text != error
        {
            conversationBubble(
                HobConversationMessage(
                    author: .hob,
                    text: error,
                    isError: true
                ))
        } else if let notice = controller.notice,
            controller.conversationMessages.last?.text != notice
        {
            conversationBubble(
                HobConversationMessage(
                    author: .hob,
                    text: notice
                ))
        }
    }

    @ViewBuilder private func conversationBubble(
        _ message: HobConversationMessage
    ) -> some View {
        if message.author == .user {
            HStack(alignment: .bottom) {
                Spacer(minLength: 48)
                Text(message.text)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        HobTheme.accent(for: colorScheme).opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(message.text)")
        } else {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        "Hob",
                        systemImage: message.isError
                            ? "exclamationmark.triangle.fill"
                            : "sparkles"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(message.isError ? Color.red : Color.accentColor)
                    Text(message.text)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(
                    message.isError
                        ? Color.red.opacity(0.10)
                        : HobTheme.accent(for: colorScheme).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                Spacer(minLength: 48)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                message.isError
                    ? "Hob error: \(message.text)"
                    : "Hob: \(message.text)"
            )
        }
    }

    @ViewBuilder private var planningAnalysis: some View {
        if let analysis = controller.planningAnalysis {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Planning check", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") {
                        controller.dismissPlanningAnalysis()
                    }
                    .labelStyle(.iconOnly)
                }
                Text(analysis.headline)
                    .font(.title3.bold())
                ForEach(analysis.details, id: \.self) { detail in
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("\(analysis.requiredMinutes)m needed")
                    Spacer()
                    Text("\(analysis.capacityMinutes)m available")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                if !analysis.assumptions.isEmpty {
                    DisclosureGroup("Assumptions") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(analysis.assumptions, id: \.self) { assumption in
                                Text(assumption)
                            }
                        }
                        .padding(.top, 5)
                    }
                    .font(.callout)
                }
                Label("Read-only — your tasks and schedule did not change.", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }

    private func proposalView(_ proposal: RuntimeScheduleProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            scheduleHeader("Schedule proposal", proposal: proposal)
            scheduleBlocks(proposal)
            Button {
                controller.adoptProposal()
            } label: {
                Label("Use schedule", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                proposal.blocks.isEmpty
                    || controller.isWorking
            )
            .accessibilityHint("Adopts the displayed schedule without changing Calendar")
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
                    Button("Update schedule") {
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
            return
                "\(change.previousStartAt.map(displayTime) ?? "Unscheduled") → \(change.proposedStartAt.map(displayTime) ?? "Unscheduled")"
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
            ForEach(
                proposal.blocks.filter { block in
                    controller.tasks.contains {
                        $0.id == block.taskID && $0.status == "open"
                            && proposal.taskVersions[$0.id] == $0.revision
                    }
                }
            ) { block in
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

    private var upcomingList: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Reminders for another day.")
                .foregroundStyle(.secondary)
            if controller.reminderList.upcoming.isEmpty {
                ContentUnavailableView(
                    "Nothing coming up", systemImage: "calendar",
                    description: Text("Add a reminder with a future date in chat. Untimed items stay in Today."))
            }
            ForEach(controller.reminderList.upcoming) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title).font(.title2.bold())
                    ForEach(group.tasks, id: \.id) { task in
                        Button {
                            selectReminder(task)
                        } label: {
                            reminderRow(task, history: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.isWorking)
                        .accessibilityIdentifier("hob.upcoming.\(task.id)")
                    }
                }
            }
            NavigationLink {
                workspaceScroll {
                    if controller.reminderList.history.isEmpty {
                        ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath")
                    } else {
                        Text("Completed, removed, missed, and paused reminders.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(controller.reminderList.history, id: \.id) { task in
                            if task.status == "open" {
                                Button {
                                    selectReminder(task)
                                } label: {
                                    reminderRow(task, history: true)
                                }
                                .buttonStyle(.plain)
                            } else {
                                reminderRow(task, history: true)
                            }
                        }
                    }
                }
                .navigationTitle("History")
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            .accessibilityIdentifier("hob.history")
        }
    }

    private func reminderRow(_ task: RuntimeTask, history: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.task)
                    .foregroundStyle(.primary)
                Text(reminderDetails(task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if history {
                Text(task.status == "open" && task.isWaiting ? "Paused" : controller.taskStatusLabel(task))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        controller.taskStatusLabel(task) == "Missed" ? .orange : .primary
                    )
            }
        }
        .padding(12)
        .background(
            HobTheme.surface(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func reminderFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = controller.reminderTimezone
        formatter.dateFormat = format
        return formatter
    }

    private func selectReminder(_ task: RuntimeTask) {
        originalReminder = task
        dismissingForTaskAction = false
        editedDigestTitle = task.task
        editedNote = task.note ?? ""
        editedHasDate = task.dueDate != nil
        editedHasTime = task.dueTime != nil
        editedDate = task.dueDate.flatMap { reminderFormatter("yyyy-MM-dd").date(from: $0) } ?? controller.reminderNow
        editedTime = task.dueTime.flatMap { reminderFormatter("HH:mm").date(from: $0) } ?? controller.reminderNow
        editedKeepIndefinitely = task.reviewPolicy == "never"
        selectedDigestItem = RuntimeMorningDigestItem(
            taskID: task.id, task: task.task, time: task.dueTime, isOverdue: false)
    }

    private func reminderDetails(_ task: RuntimeTask) -> String {
        var values: [String] = []
        if let due = task.dueDate, let date = reminderFormatter("yyyy-MM-dd").date(from: due) {
            values.append(reminderFormatter("EEE, MMM d, yyyy").string(from: date))
        }
        if let time = task.dueTime, let clock = reminderFormatter("HH:mm").date(from: time) {
            values.append(reminderFormatter("h:mm a").string(from: clock))
        }
        if let deadline = task.deadlineDate, let date = reminderFormatter("yyyy-MM-dd").date(from: deadline) {
            values.append("Due \(reminderFormatter("MMM d, yyyy").string(from: date))")
        }
        if let duration = task.durationMinutes { values.append("\(duration)m") }
        if let priority = task.priority, priority != "normal" { values.append(priority) }
        if let recurrence = task.recurrence { values.append(recurrenceLabel(recurrence)) }
        if task.note != nil { values.append("note") }
        return values.isEmpty ? "No date or time" : values.joined(separator: " · ")
    }

    private func recurrenceLabel(_ recurrence: RuntimeRecurrenceRule) -> String {
        let interval = recurrence.interval == 1 ? "" : " every \(recurrence.interval)"
        switch recurrence.frequency {
        case "day": return recurrence.interval == 1 ? "daily" : "every \(recurrence.interval) days"
        case "week":
            let days = recurrence.weekdays.map { $0.capitalized }.joined(separator: ", ")
            if !days.isEmpty { return recurrence.interval == 1 ? "weekly: \(days)" : "\(interval) weeks: \(days)" }
            return recurrence.interval == 1 ? "weekly" : "every \(recurrence.interval) weeks"
        case "month": return recurrence.interval == 1 ? "monthly" : "every \(recurrence.interval) months"
        case "year": return recurrence.interval == 1 ? "yearly" : "every \(recurrence.interval) years"
        default: return "repeating"
        }
    }

    private func timeRange(_ block: RuntimeScheduleBlock) -> String {
        guard let start = ISO8601DateFormatter().date(from: block.startAt),
            let end = ISO8601DateFormatter().date(from: block.endAt)
        else {
            return block.startAt
        }
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let startTime = start.formatted(date: .omitted, time: .shortened)
        let endTime = end.formatted(date: .omitted, time: .shortened)
        return "\(day), \(startTime)–\(endTime)"
    }
}

private struct HobBrandArtwork: View {
    var body: some View {
        if let artwork = appIconArtwork {
            Image(decorative: artwork, scale: 2)
                .resizable()
        } else {
            HobTeapotIcon()
                .foregroundStyle(HobTheme.gold)
        }
    }

    private var appIconArtwork: CGImage? {
        guard
            let url = Bundle.main.url(
                forResource: "AppIcon60x60@2x",
                withExtension: "png"
            ),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private struct HobSettingsToolbarBackground: ViewModifier {
    let colorScheme: ColorScheme

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
            content
                .toolbarBackground(HobTheme.base(for: colorScheme), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        #else
            content
        #endif
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
