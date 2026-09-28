// SPDX-License-Identifier: MIT
#if DEBUG
  import Foundation
  import SwiftUI
  import HobAppCore
  import HobAppStorage
  import HobAppExperience

  /// UI tests run the real view/controller with an explicit parser fixture. Model
  /// quality is measured separately by the device benchmark, never by this stub.
  struct HobUITestWorkspace: View {
    private let defaults: UserDefaults
    private let controller: HobWorkspaceController
    init() {
      let env = ProcessInfo.processInfo.environment
      let session = UUID(uuidString: env["HOB_UI_TEST_SESSION"] ?? "") ?? UUID()
      let suite = "hob-ui-test-\(session)"
      defaults = UserDefaults(suiteName: suite)!
      if env["HOB_UI_TEST_SCENARIO"] != "setup-check-ins" {
        defaults.set(true, forKey: "hob.onboarding.completed.v1")
      }
      let store = TaskStateStore(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
      let titles: [String] =
        switch env["HOB_UI_TEST_SCENARIO"] {
        case "chooseTask": ["Call Alex", "Call Sam"]
        case "ongoing": ["Take my morning pill"]
        default: ["Plan picnic"]
        }
      if !defaults.bool(forKey: "seeded") {
        var tasks = titles.enumerated().map { index, title in
          RuntimeTask(
            id: "a\(index + 1)", rawText: title, task: title, dueDate: nil, dueTime: nil,
            status: "open", createdAt: "2026-08-30T08:00:00-04:00",
            updatedAt: "2026-08-30T08:00:00-04:00")
        }
        if env["HOB_UI_TEST_SCENARIO"] == "upcoming" {
          func reminder(
            _ id: String, _ title: String, _ date: String?, _ time: String? = nil,
            _ status: String = "open"
          ) -> RuntimeTask {
            RuntimeTask(
              id: id, rawText: title, task: title, dueDate: date, dueTime: time,
              status: status, createdAt: "2026-09-07T08:00:00-04:00",
              updatedAt: "2026-09-07T08:00:00-04:00")
          }
          tasks = [
            reminder("today", "Buy soap", nil), reminder("tomorrow", "Book haircut", "2026-09-08"),
            reminder("week", "Dentist", "2026-09-09", "14:30"),
            reminder("later", "Renew passport", "2026-10-01"),
            reminder("done", "Finished errand", "2026-09-06", nil, "done"),
            reminder("missed", "Missed appointment", "2026-09-06", "09:00"),
          ]
        } else if env["HOB_UI_TEST_SCENARIO"] == "upcoming-empty" {
          tasks = []
        }
        try! store.save(RuntimePersistentState(tasks: tasks, undoSnapshots: []))
        defaults.set(true, forKey: "seeded")
      }
      controller = HobWorkspaceController(
        store: store, interpreter: UIParser(), calendarStore: UICalendar(),
        notificationStore: UINotifications(), syncStore: UISync(), defaults: defaults,
        timezone: TimeZone(identifier: "America/New_York")!,
        now: { ISO8601DateFormatter().date(from: "2026-09-07T08:00:00-04:00")! })
    }
    var body: some View { HobWorkspaceView(controller: controller).defaultAppStorage(defaults) }
  }

  private struct UIParser: RuntimeMessageInterpreting {
    func interpret(message: String, now: String, timezone: String, tasks: [RuntimeTask])
      async throws -> [RuntimeAction]
    { [] }
    func interpret(
      message: String, now: String, timezone: String, tasks: [RuntimeTask],
      context: RuntimeConversationContext
    ) async throws -> [RuntimeAction] {
      let open = tasks.filter { $0.status == "open" }.sorted { $0.id < $1.id }
      let target = context.focusedTaskIDs.first.flatMap { id in open.firstIndex { $0.id == id } }
        .map { String($0 + 1) }
      switch message.lowercased() {
      case "stays":
        return target.map { [.init(type: "keep", target: $0)] } ?? [
          .init(type: "capture", task: message, raw: message)
        ]
      case "move":
        throw RuntimeInterpretationError.question(
          .init(
            kind: .chooseDate, text: RuntimeInteraction.moveDateQuestion,
            taskIDs: context.focusedTaskIDs))
      case "friday" where context.pendingQuestion?.kind == .chooseDate:
        return [
          .init(
            type: "reschedule", target: target,
            when: .init(kind: "weekday", which: "this", day: "fri"))
        ]
      case "the call is done":
        throw RuntimeInterpretationError.question(
          .init(
            kind: .chooseTask, text: "Do you mean Call Alex or Call Sam?", taskIDs: open.map(\.id)))
      case "call alex" where context.pendingQuestion?.kind == .chooseTask:
        return [.init(type: "complete", target: "1")]
      case "thanks": return [.init(type: "social", reply: "Anytime.")]
      default: return [.init(type: "capture", task: message, raw: message)]
      }
    }
  }
  @MainActor private final class UICalendar: RuntimeCalendarScheduling {
    let authorization = RuntimeCalendarAuthorization.notDetermined
    func requestAccess() async throws -> RuntimeCalendarAuthorization { authorization }
    func calendars() throws -> [RuntimeCalendarDescriptor] { [] }
    func busyIntervals(
      from: Date, to: Date, timezone: TimeZone, calendarIDs: Set<String>?, blockAllDayEvents: Bool,
      excludingProposalID: String?
    ) throws -> [RuntimeBusyInterval] { [] }
    func remove(eventIDs: [String]) throws {}
  }
  @MainActor private final class UISync: RuntimeTaskSyncing {
    let availability = RuntimeTaskSyncAvailability.unavailable
    func refreshAvailability() async -> RuntimeTaskSyncAvailability { availability }
    func exchange(localOperations: [RuntimeTaskOperation]) async throws -> [RuntimeTaskOperation] {
      []
    }
  }
  @MainActor private final class UINotifications: RuntimeNotificationScheduling {
    func replaceTaskReminders(_ reminders: [RuntimeTaskReminder], now: Date) async throws {}
    let authorization = RuntimeNotificationAuthorization.notDetermined
    func refreshAuthorization() async -> RuntimeNotificationAuthorization { authorization }
    func requestAccess() async throws -> RuntimeNotificationAuthorization { authorization }
    func schedule(proposal: RuntimeScheduleProposal, now: Date) async throws -> [String] { [] }
    func replaceMorningDigests(_ digests: [RuntimeMorningDigest], time: String, now: Date)
      async throws
    {}
    func cancelMorningDigests() async {}
    func replaceEveningRecaps(_ digests: [RuntimeMorningDigest], time: String, now: Date)
      async throws
    {}
    func cancelEveningRecaps() async {}
    func snooze(response: RuntimeNotificationResponse, minutes: Int) async throws {}
    func cancel(notificationIDs: [String]) {}
    func setActionHandler(
      _ handler: @escaping @MainActor @Sendable (RuntimeNotificationResponse) async -> Void
    ) {}
  }
#endif
