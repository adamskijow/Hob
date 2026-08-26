# SPDX-License-Identifier: MIT
from pathlib import Path
import plistlib


ROOT = Path(__file__).parents[1]
FOUNDATION = ROOT / "native" / "HobAppFoundation"
XCODE_PROJECT = ROOT / "native" / "HobMacApp" / "HobMacApp.xcodeproj"
IOS_PROJECT = ROOT / "native" / "HobAppleApps"


def test_app_store_entitlements_are_minimal_and_sandboxed():
    with (FOUNDATION / "AppStore" / "HobMacShell.entitlements").open("rb") as fh:
        entitlements = plistlib.load(fh)

    assert entitlements == {
        "com.apple.security.app-sandbox": True,
        "com.apple.developer.ubiquity-kvstore-identifier": (
            "$(TeamIdentifierPrefix)com.josephadamski.hob"
        ),
        "com.apple.security.network.client": True,
        "com.apple.security.personal-information.calendars": True,
    }
    assert "com.apple.security.network.server" not in entitlements


def test_app_store_calendar_disclosure_names_actual_privacy_boundary():
    with (FOUNDATION / "AppStore" / "Info.plist").open("rb") as fh:
        info = plistlib.load(fh)

    disclosure = info["NSCalendarsFullAccessUsageDescription"]
    assert "busy times" in disclosure
    assert "Event titles never leave EventKit" in disclosure
    assert info["LSUIElement"] is True
    assert info["LSMinimumSystemVersion"] == "26.0"


def test_store_native_sources_do_not_depend_on_open_local_installation():
    forbidden = ("homebrew", "launchctl", "uv run", "subprocess")
    source = "\n".join(
        path.read_text(encoding="utf-8").lower()
        for path in (FOUNDATION / "Sources").rglob("*.swift")
    )

    for token in forbidden:
        assert token not in source

    store_targets = "\n".join(
        path.read_text(encoding="utf-8").lower()
        for target in ("HobMacShell", "HobFoundationBridge")
        for path in (FOUNDATION / "Sources" / target).rglob("*.swift")
    )
    assert "ollama" not in store_targets


def test_native_package_exposes_shell_core_and_model_adapter():
    manifest = (FOUNDATION / "Package.swift").read_text(encoding="utf-8")

    assert 'name: "HobAppCore"' in manifest
    assert 'name: "HobMacShell"' in manifest
    assert 'name: "HobAgent"' in manifest
    assert 'name: "HobFoundationBridge"' in manifest
    assert 'name: "HobAppleIntelligence"' in manifest
    assert 'name: "HobAppExperience"' in manifest
    assert 'name: "HobCalendar"' in manifest
    assert 'name: "HobNotifications"' in manifest
    assert '.iOS("26.0")' in manifest

    bridge = (
        FOUNDATION / "Sources" / "HobFoundationBridge" / "main.swift"
    ).read_text(encoding="utf-8")
    assert 'request.command == "probe"' in bridge
    assert '"reported_available"' in bridge
    assert "read(upToCount: 200_001)" in bridge
    assert "prompt.utf8.count + instructions.utf8.count <= 100_000" in bridge
    assert "error.userInfo" not in bridge


def test_xcode_shell_consumes_store_bundle_and_sandbox_configuration():
    project = (XCODE_PROJECT / "project.pbxproj").read_text(encoding="utf-8")

    assert 'productType = "com.apple.product-type.application"' in project
    assert "MACOSX_DEPLOYMENT_TARGET = 26.0" in project
    assert "ENABLE_APP_SANDBOX = YES" in project
    assert "HobMacShell.entitlements" in project
    assert "HobAppFoundation/AppStore/Info.plist" in project
    assert "Assets.xcassets in Resources" in project
    assert "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon" in project
    assert (
        ROOT
        / "native"
        / "HobMacApp"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
        / "Contents.json"
    ).is_file()
    app_target = project.split("/* Hob */ = {", 1)[1].split("};", 1)[0]
    assert "Embed Login Items" not in app_target
    assert "HobAgent" not in app_target
    assert (XCODE_PROJECT / "xcshareddata" / "xcschemes" / "Hob.xcscheme").is_file()


def test_foundation_model_tool_inherits_the_parent_sandbox_only():
    with (
        FOUNDATION / "AppStore" / "HobFoundationBridge.entitlements"
    ).open("rb") as fh:
        entitlements = plistlib.load(fh)

    assert entitlements == {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.inherit": True,
    }

    project = (XCODE_PROJECT / "project.pbxproj").read_text(encoding="utf-8")
    assert 'productType = "com.apple.product-type.tool"' in project
    assert "HobFoundationBridge in Embed Model Tool" in project
    assert "CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO" in project
    assert 'OTHER_CODE_SIGN_FLAGS = "$(inherited) -i $(PRODUCT_BUNDLE_IDENTIFIER)"' in project
    assert "SKIP_INSTALL = YES" in project


def test_model_readiness_uses_a_real_in_process_generation_probe():
    controller = (
        FOUNDATION
        / "Sources"
        / "HobMacShell"
        / "FoundationModelController.swift"
    ).read_text(encoding="utf-8")

    assert "AppleFoundationInterpreter" in controller
    assert "await interpreter.probe()" in controller
    assert "interpreter.isAvailable" in controller
    assert "Process()" not in controller


def test_portable_task_runtime_is_compiled_into_app_and_agent():
    project = (XCODE_PROJECT / "project.pbxproj").read_text(encoding="utf-8")
    runtime = (
        FOUNDATION / "Sources" / "HobAppCore" / "TaskRuntime.swift"
    ).read_text(encoding="utf-8")

    assert "TaskRuntime.swift in Sources" in project
    assert "TaskRuntime.swift in Agent Sources" in project
    assert "ScheduleRuntime.swift in Sources" in project
    assert "ScheduleRuntime.swift in Agent Sources" in project
    assert "TaskQueries.swift in Sources" in project
    assert "SnoozeSequence.swift in Sources" in project
    assert "CalendarScheduling.swift in Sources" in project
    assert "EventKitScheduleStore.swift in Sources" in project
    assert "NotificationScheduling.swift in Sources" in project
    assert "NotificationScheduling.swift in Agent Sources" in project
    assert "LocalNotificationScheduler.swift in Sources" in project
    assert "request.version == 1" in runtime
    assert "request.message.utf8.count <= 20_000" in runtime
    assert "actions.count <= 32" in runtime
    assert "undoSnapshots.count == 100" in runtime


def test_adopted_plans_have_actionable_durable_start_reminders():
    notifications = (
        FOUNDATION
        / "Sources"
        / "HobNotifications"
        / "LocalNotificationScheduler.swift"
    ).read_text(encoding="utf-8")
    storage = (
        FOUNDATION / "Sources" / "HobAppStorage" / "TaskStateStore.swift"
    ).read_text(encoding="utf-8")

    assert 'title: "Done"' in notifications
    assert 'title: "Snooze longer"' in notifications
    assert 'title: "Replan"' in notifications
    assert "UNCalendarNotificationTrigger" in notifications
    assert "enqueueNotificationResponse" in storage
    assert "notificationCleanupIDs" in storage


def test_replanning_keeps_calendar_stable_until_the_diff_is_accepted():
    schedule = (
        FOUNDATION / "Sources" / "HobAppCore" / "ScheduleRuntime.swift"
    ).read_text(encoding="utf-8")
    workspace = (
        FOUNDATION
        / "Sources"
        / "HobAppExperience"
        / "HobWorkspaceView.swift"
    ).read_text(encoding="utf-8")

    assert "RuntimeScheduleDiff" in schedule
    assert 'Label("Review schedule changes"' in workspace
    assert 'Text("The current schedule stays unchanged until you accept.")' in workspace
    assert 'Button("Update schedule")' in workspace
    assert "Update Calendar" not in workspace
    assert 'Button("Keep current schedule")' in workspace


def test_workspace_keeps_connection_status_in_the_gear_menu():
    workspace = (
        FOUNDATION
        / "Sources"
        / "HobAppExperience"
        / "HobWorkspaceView.swift"
    ).read_text(encoding="utf-8")

    assert 'Section("Calendar")' in workspace
    assert 'Section("Reminders")' in workspace
    assert 'Section("iCloud")' in workspace
    assert '.accessibilityLabel("Connections and setup")' in workspace
    assert "Calendar connected" not in workspace
    assert "Start reminders enabled" not in workspace
    assert "Tasks sync with iCloud" not in workspace
    assert "struct HobAppBackground" in workspace
    assert "HobTheme.gold" in workspace
    assert "HobTheme.surface(for: colorScheme)" in workspace

    controller = (
        FOUNDATION
        / "Sources"
        / "HobAppExperience"
        / "HobWorkspaceController.swift"
    ).read_text(encoding="utf-8")
    assert "Tasks synced with iCloud." not in controller
    assert 'self.notice = "Tasks updated from iCloud."' in controller


def test_iphone_app_uses_the_same_native_workspace_and_local_model():
    spec = (IOS_PROJECT / "project.yml").read_text(encoding="utf-8")
    app = (IOS_PROJECT / "Sources" / "HobPhoneApp.swift").read_text(
        encoding="utf-8"
    )
    project = (
        IOS_PROJECT / "HobAppleApps.xcodeproj" / "project.pbxproj"
    ).read_text(encoding="utf-8")
    interpreter = (
        FOUNDATION
        / "Sources"
        / "HobAppleIntelligence"
        / "FoundationModelInterpreter.swift"
    ).read_text(encoding="utf-8")
    onboarding = (
        FOUNDATION
        / "Sources"
        / "HobAppExperience"
        / "HobFirstRunView.swift"
    ).read_text(encoding="utf-8")

    assert "platform: iOS" in spec
    assert "product: HobAppExperience" in spec
    assert "TARGETED_DEVICE_FAMILY: \"1\"" in spec
    assert "Assets.xcassets" in spec
    assert "HobWorkspaceView()" in app
    assert "HobAppFoundation" in project
    assert "SystemLanguageModel.default" in interpreter
    assert "LanguageModelSession" in interpreter
    assert 'let name = "complete_task"' in interpreter
    assert 'let name = "drop_task"' in interpreter
    assert 'let name = "move_task"' in interpreter
    assert 'let name = "edit_task_text"' in interpreter
    assert 'let name = "replan_schedule"' in interpreter
    assert 'RuntimeAction(type: "replan")' in interpreter
    assert 'Label("Connected", systemImage: "checkmark.circle.fill")' in onboarding
    assert 'Button("Check iCloud")' in onboarding
    assert "if let notice = controller.notice" in onboarding
    assert "Already use Open Local?" not in onboarding
    assert "Import Open Local Export" not in onboarding
    assert (
        IOS_PROJECT / "Assets.xcassets" / "AppIcon.appiconset" / "Hob.png"
    ).is_file()

    with (IOS_PROJECT / "Info.plist").open("rb") as fh:
        info = plistlib.load(fh)
    with (IOS_PROJECT / "Hob.entitlements").open("rb") as fh:
        entitlements = plistlib.load(fh)
    assert "adds only schedules you adopt" in info[
        "NSCalendarsFullAccessUsageDescription"
    ]
    assert entitlements == {
        "com.apple.developer.ubiquity-kvstore-identifier": (
            "$(TeamIdentifierPrefix)com.josephadamski.hob"
        )
    }


def test_private_icloud_sync_uses_a_bounded_validated_operation_journal():
    package = (FOUNDATION / "Package.swift").read_text(encoding="utf-8")
    sync = (
        FOUNDATION
        / "Sources"
        / "HobCloudSync"
        / "ICloudTaskSyncStore.swift"
    ).read_text(encoding="utf-8")
    core = (
        FOUNDATION / "Sources" / "HobAppCore" / "TaskSync.swift"
    ).read_text(encoding="utf-8")
    project = (XCODE_PROJECT / "project.pbxproj").read_text(encoding="utf-8")
    workspace = (
        FOUNDATION
        / "Sources"
        / "HobAppExperience"
        / "HobWorkspaceView.swift"
    ).read_text(encoding="utf-8")

    assert 'name: "HobCloudSync"' in package
    assert "NSUbiquitousKeyValueStore.default" in sync
    assert 'keyPrefix = "hob.task-operations.v1."' in sync
    assert "maximumShardBytes = 400_000" in sync
    assert "maximumTotalBytes = 900_000" in sync
    assert "maximumShards = 16" in sync
    assert "RuntimeTaskOperationMerge.merge" in sync
    assert "RuntimeTaskOperationMerge" in core
    assert "TaskSync.swift in Sources" in project
    assert "TaskSync.swift in Agent Sources" in project
    assert "ICloudTaskSyncStore.swift in Sources" in project
    assert "NSUbiquitousKeyValueStore.didChangeExternallyNotification" in workspace


def test_agent_uses_fail_closed_private_durable_task_storage():
    project = (XCODE_PROJECT / "project.pbxproj").read_text(encoding="utf-8")
    storage = (
        FOUNDATION / "Sources" / "HobAppStorage" / "TaskStateStore.swift"
    ).read_text(encoding="utf-8")
    agent = (
        FOUNDATION / "Sources" / "HobAgent" / "HobAgent.swift"
    ).read_text(encoding="utf-8")

    assert "TaskStateStore.swift in Agent Sources" in project
    assert "TaskStateStore(directoryURL: try storage.taskStateDirectory())" in agent
    assert "maximumBytes = 10_000_000" in storage
    assert ".posixPermissions: 0o600" in storage
    assert ".posixPermissions: 0o700" in storage
    assert "destinationOfSymbolicLink" in storage
    assert "try store.save(receiptState)" in storage
    assert "try store.save(candidateState)" in storage
    assert "return try completePending(requestID: request.requestID)" in storage
    assert "runtime = candidate" in storage
    assert "state = candidateState" in storage


def test_store_app_exposes_content_free_health_and_confirmed_recovery():
    project = (XCODE_PROJECT / "project.pbxproj").read_text(encoding="utf-8")
    shell = (
        FOUNDATION / "Sources" / "HobMacShell" / "HobMacShell.swift"
    ).read_text(encoding="utf-8")
    controller = (
        FOUNDATION
        / "Sources"
        / "HobMacShell"
        / "TaskStorageController.swift"
    ).read_text(encoding="utf-8")

    assert "TaskStateStore.swift in Sources" in project
    assert "TaskStorageController.swift in Sources" in project
    assert 'Label("Storage", systemImage: "externaldrive")' in shell
    assert "HobTeapotIcon" in shell
    assert 'systemImage: "sparkles"' not in shell
    assert 'alert("Restore the previous copy?"' in shell
    assert "inspection.pipeline.pendingInbound" in shell
    assert "inspection.pipeline.pendingOutbound" in shell
    assert "recoverFromBackup()" in controller


def test_native_app_does_not_embed_the_retired_background_helper():
    project = (XCODE_PROJECT / "project.pbxproj").read_text(encoding="utf-8")
    app_target = project.split("/* Hob */ = {", 1)[1].split("};", 1)[0]

    assert "HobAgent" not in app_target
    assert "Embed Login Items" not in app_target


def test_native_app_startup_is_automatic_and_reversible():
    controller = (
        FOUNDATION
        / "Sources"
        / "HobMacShell"
        / "LaunchAtLoginController.swift"
    ).read_text(encoding="utf-8")

    assert "SMAppService = .mainApp" in controller
    assert "if status == .notRegistered { enable() }" in controller
    assert "try service.register()" in controller
    assert "try service.unregister()" in controller
    assert "openSystemSettingsLoginItems" in controller
    assert "could not turn on startup" in controller
