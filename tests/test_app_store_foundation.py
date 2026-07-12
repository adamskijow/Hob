# SPDX-License-Identifier: MIT
from pathlib import Path
import plistlib


ROOT = Path(__file__).parents[1]
FOUNDATION = ROOT / "native" / "HobAppFoundation"
XCODE_PROJECT = ROOT / "native" / "HobMacApp" / "HobMacApp.xcodeproj"


def test_app_store_entitlements_are_minimal_and_sandboxed():
    with (FOUNDATION / "AppStore" / "HobMacShell.entitlements").open("rb") as fh:
        entitlements = plistlib.load(fh)

    assert entitlements == {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.application-groups": ["group.com.josephadamski.hob"],
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
    assert "Contents/Library/LoginItems" in project
    assert "HobAgent.app in Embed Login Items" in project
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


def test_model_readiness_requires_a_bounded_correlated_generation_probe():
    controller = (
        FOUNDATION
        / "Sources"
        / "HobMacShell"
        / "FoundationModelController.swift"
    ).read_text(encoding="utf-8")

    assert '"command": "probe"' in controller
    assert "Date().addingTimeInterval(30)" in controller
    assert "data.count <= 100_000" in controller
    assert 'object["requestID"] as? String == requestID' in controller
    assert 'status == "available" ? .available : .unavailable' in controller


def test_portable_task_runtime_is_compiled_into_app_and_agent():
    project = (XCODE_PROJECT / "project.pbxproj").read_text(encoding="utf-8")
    runtime = (
        FOUNDATION / "Sources" / "HobAppCore" / "TaskRuntime.swift"
    ).read_text(encoding="utf-8")

    assert "TaskRuntime.swift in Sources" in project
    assert "TaskRuntime.swift in Agent Sources" in project
    assert "request.version == 1" in runtime
    assert "request.message.utf8.count <= 20_000" in runtime
    assert "actions.count <= 32" in runtime
    assert "undoSnapshots.count == 100" in runtime


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
    assert 'alert("Restore the previous copy?"' in shell
    assert "inspection.pipeline.pendingInbound" in shell
    assert "inspection.pipeline.pendingOutbound" in shell
    assert "recoverFromBackup()" in controller


def test_background_helper_is_sandboxed_and_shares_only_required_storage():
    with (FOUNDATION / "AppStore" / "HobAgent.entitlements").open("rb") as fh:
        entitlements = plistlib.load(fh)
    with (FOUNDATION / "AppStore" / "HobAgent-Info.plist").open("rb") as fh:
        info = plistlib.load(fh)

    assert entitlements == {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.application-groups": ["group.com.josephadamski.hob"],
        "com.apple.security.network.client": True,
    }
    assert info["CFBundleIdentifier"] == "com.josephadamski.hob.agent"
    assert info["LSBackgroundOnly"] is True
    assert "com.apple.security.network.server" not in entitlements


def test_service_registration_is_explicit_and_reversible():
    controller = (
        FOUNDATION
        / "Sources"
        / "HobMacShell"
        / "BackgroundServiceController.swift"
    ).read_text(encoding="utf-8")

    assert ".loginItem(identifier: helperIdentifier)" in controller
    assert "try service.register()" in controller
    assert "try service.unregister()" in controller
    assert "openSystemSettingsLoginItems" in controller
    assert "could not register" in controller
    assert "guard runtimeAvailable" in controller
    assert "runtimeAvailable: Bool = false" in controller
