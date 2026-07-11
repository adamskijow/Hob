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
    assert (XCODE_PROJECT / "xcshareddata" / "xcschemes" / "Hob.xcscheme").is_file()
