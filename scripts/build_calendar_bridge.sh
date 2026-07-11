#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/native/HobCalendarBridge"
APP="$PACKAGE/.build/HobCalendarBridge.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "hob: EventKit calendar bridge is only available on macOS" >&2
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
# Command Line Tools upgrades can briefly leave the newest SDK one patch ahead
# of the Swift compiler. A retained 15.4 SDK is fully sufficient for EventKit.
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
ARCH="$(uname -m)"
MODULE_CACHE="$PACKAGE/.build/module-cache"
mkdir -p "$MODULE_CACHE" "$PACKAGE/.build/release"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swiftc \
  -sdk "$SDK" \
  -target "$ARCH-apple-macosx13.0" \
  -O \
  "$PACKAGE/Sources/HobCalendarBridge/main.swift" \
  -framework EventKit \
  -o "$PACKAGE/.build/release/HobCalendarBridge"
mkdir -p "$APP/Contents/MacOS"
cp "$PACKAGE/.build/release/HobCalendarBridge" "$APP/Contents/MacOS/HobCalendarBridge"
cp "$PACKAGE/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "hob: built $APP"
