#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

hob_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$hob_root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
hob_mode="${1:-smoke}"
hob_reports="${HOB_MESSAGE_REPORT_DIR:-/tmp/hob-message-check-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$hob_reports"
export HOB_BENCHMARK_REVISION="$(git rev-parse HEAD)"
git diff --binary HEAD -- native/HobAppFoundation > "$hob_reports/worktree.patch"
# Include new benchmark sources in the evidence fingerprint too.
git ls-files --others --exclude-standard native/HobAppFoundation > "$hob_reports/untracked.txt"
git ls-files -co --exclude-standard native/HobAppFoundation native/HobAppleApps scripts/check_messages.sh |
  sort -u | while IFS= read -r path; do
    if [[ -f "$path" ]]; then shasum -a 256 "$path"; fi
  done > "$hob_reports/source-sha256.txt"

case "$hob_mode" in
  smoke) export HOB_BENCHMARK_SPLIT=development HOB_BENCHMARK_REPEATS=1 ;;
  challenge) export HOB_BENCHMARK_SPLIT=challenge HOB_BENCHMARK_REPEATS=2 ;;
  release)
    export HOB_FAULT_REPORT="$hob_reports/faults.json"
    export HOB_INTERACTION_INVENTORY="$hob_reports/inventory.json"
    swift test --package-path native/HobAppFoundation --skip 'FoundationModelInterpreterLiveTests|MessageBenchmarkTests' > "$hob_reports/deterministic.log" 2>&1
    HOB_LIVE_TESTS=1 swift test --package-path native/HobAppFoundation --filter FoundationModelInterpreterLiveTests > "$hob_reports/historical-live.log" 2>&1
    export HOB_BENCHMARK_SPLIT=all HOB_BENCHMARK_REPEATS=3
    ;;
  *) printf '%s\n' 'Usage: bash scripts/check_messages.sh [smoke|challenge|release]' >&2; exit 2 ;;
esac

export HOB_MESSAGE_BENCHMARK=1
export HOB_BENCHMARK_REPORT="$hob_reports/benchmark.json"
rm -f "$HOB_BENCHMARK_REPORT"
printf 'Running %s message checks. Evidence: %s\n' "$hob_mode" "$hob_reports"
hob_result=0
swift test --package-path native/HobAppFoundation --filter MessageBenchmarkTests > "$hob_reports/live.log" 2>&1 || hob_result=$?
rg 'BENCHMARK|LIVE MODEL|error:|Release gate' "$hob_reports/live.log" || true
if [[ "$hob_result" -ne 0 || ! -f "$HOB_BENCHMARK_REPORT" ]]; then
  printf '%s\n' 'Message gate FAILED or model unavailable. Do not treat this as a tested build.' >&2
  exit 1
fi
if [[ "$hob_mode" == release ]]; then
  hob_ui_result="$hob_reports/ui-$(date +%Y%m%d-%H%M%S).xcresult"
  xcodebuild -quiet -project native/HobAppleApps/HobAppleApps.xcodeproj -scheme HobiOSUI \
    -destination "${HOB_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" \
    -derivedDataPath "${HOB_UI_DERIVED_DATA:-/tmp/HobInteractionUI}" CODE_SIGNING_ALLOWED=NO \
    -resultBundlePath "$hob_ui_result" test > "$hob_reports/ui.log" 2>&1
  "$DEVELOPER_DIR/usr/bin/xcresulttool" get test-results tests --path "$hob_ui_result" > "$hob_reports/ui-tests.json"
  python3 scripts/check_interaction_coverage.py "$hob_reports"
fi
printf 'Message gate passed. Report: %s\n' "$HOB_BENCHMARK_REPORT"
