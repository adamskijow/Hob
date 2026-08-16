<!-- SPDX-License-Identifier: MIT -->
# Development

Install the locked environment and run the Python suite:

```
uv sync --locked
uv run pytest
```

On macOS, test the native core and build both app surfaces:

```
swift test --package-path native/HobAppFoundation
xcodebuild -project native/HobMacApp/HobMacApp.xcodeproj -scheme Hob CODE_SIGNING_ALLOWED=NO build
xcodebuild -project native/HobAppleApps/HobAppleApps.xcodeproj -scheme HobiOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Build and smoke-test Calendar separately:

```
scripts/build_calendar_bridge.sh
uv run python app.py calendar status
```

Calendar authorization requires a local user action:

```
uv run python app.py calendar authorize
```

Tests use a fake clock, in-memory store, and fake LLM. Recovery tests inject
failures, reopen databases, and migrate released schema fixtures. CI checks the
lockfile, frozen dependencies, Python runtime, native packages, EventKit bridge,
App Store shell, and test suite on Ubuntu and macOS.

After interpreter or prompt changes, run the real-model corpus:

```
HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.interpreter_eval
```

The analysis gate checks planning explanation, a what-if, and unchanged durable
state:

```
HOB_MODEL=qwen2.5:14b-instruct uv run python -m evals.analysis_eval
```

`tzdata` installs only on Windows through its platform marker.
