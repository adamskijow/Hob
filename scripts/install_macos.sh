#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Install or update the Open Local background service and native menu-bar
# companion. Safe to re-run: existing daemon configuration is preserved.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_HOME="${HOME:?Hob needs a macOS home directory}"
USER_ID="$(id -u)"
USER_NAME="$(id -un)"
APP_SUPPORT_DIR="$USER_HOME/Library/Application Support/Hob"
USER_APPS_DIR="$USER_HOME/Applications"
USER_AGENTS_DIR="$USER_HOME/Library/LaunchAgents"
USER_LOG_DIR="$USER_HOME/Library/Logs/Hob"
INSTALL_APP="$USER_APPS_DIR/Hob Local.app"
DAEMON_PLIST="$USER_AGENTS_DIR/com.local.hob.plist"
MENU_PLIST="$USER_AGENTS_DIR/com.local.hob.menu.plist"
DAEMON_TARGET="gui/$USER_ID/com.local.hob"
MENU_TARGET="gui/$USER_ID/com.local.hob.menu"
DOMAIN_TARGET="gui/$USER_ID"
DATABASE_PATH="${HOB_DB_PATH:-$APP_SUPPORT_DIR/hob.db}"
MODEL_NAME="${HOB_MODEL:-qwen2.5:7b-instruct}"
UV_PATH="$(command -v uv || true)"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'hob: the native menu-bar installer requires macOS\n' >&2
  exit 2
fi
if [ -z "$UV_PATH" ]; then
  printf 'hob: uv is required; run scripts/setup.sh first\n' >&2
  exit 2
fi
if ! command -v swift >/dev/null 2>&1; then
  printf 'hob: Xcode Command Line Tools are required to build the menu bar\n' >&2
  exit 2
fi

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  SWIFT_COMMAND=(xcrun swift)
else
  SWIFT_COMMAND=(swift)
fi

plist_value() {
  local key="$1"
  local file="$2"
  plutil -extract "$key" raw -o - "$file" 2>/dev/null || true
}

if [ -n "${HOB_DB_PATH:-}" ]; then
  DATABASE_PATH="$HOB_DB_PATH"
elif [ -f "$DAEMON_PLIST" ] &&
  [ -n "$(plist_value EnvironmentVariables.HOB_DB_PATH "$DAEMON_PLIST")" ]; then
  DATABASE_PATH="$(plist_value EnvironmentVariables.HOB_DB_PATH "$DAEMON_PLIST")"
elif [ -f "$PROJECT_ROOT/hob.db" ] && [ -f "$APP_SUPPORT_DIR/hob.db" ]; then
  printf 'hob: both legacy and app-data databases exist; set HOB_DB_PATH before installing\n' >&2
  exit 2
elif [ -f "$PROJECT_ROOT/hob.db" ]; then
  DATABASE_PATH="$PROJECT_ROOT/hob.db"
else
  DATABASE_PATH="$APP_SUPPORT_DIR/hob.db"
fi

if [ -n "${HOB_MODEL:-}" ]; then
  MODEL_NAME="$HOB_MODEL"
elif [ -f "$DAEMON_PLIST" ] &&
  [ -n "$(plist_value EnvironmentVariables.HOB_MODEL "$DAEMON_PLIST")" ]; then
  MODEL_NAME="$(plist_value EnvironmentVariables.HOB_MODEL "$DAEMON_PLIST")"
else
  MODEL_NAME="qwen2.5:7b-instruct"
fi

if [ -n "${HOB_OLLAMA_HOST:-}" ]; then
  OLLAMA_ENDPOINT="$HOB_OLLAMA_HOST"
elif [ -f "$DAEMON_PLIST" ] &&
  [ -n "$(plist_value EnvironmentVariables.HOB_OLLAMA_HOST "$DAEMON_PLIST")" ]; then
  OLLAMA_ENDPOINT="$(plist_value EnvironmentVariables.HOB_OLLAMA_HOST "$DAEMON_PLIST")"
else
  OLLAMA_ENDPOINT="http://localhost:11434"
fi

TIMEZONE_NAME="${HOB_TIMEZONE:-}"
if [ -z "$TIMEZONE_NAME" ] && [ -f "$DAEMON_PLIST" ]; then
  TIMEZONE_NAME="$(plist_value EnvironmentVariables.HOB_TIMEZONE "$DAEMON_PLIST")"
fi
if [ -z "$TIMEZONE_NAME" ]; then
  LOCALTIME_TARGET="$(readlink /etc/localtime 2>/dev/null || true)"
  case "$LOCALTIME_TARGET" in
    */zoneinfo/*) TIMEZONE_NAME="${LOCALTIME_TARGET##*/zoneinfo/}" ;;
    *) TIMEZONE_NAME="UTC" ;;
  esac
fi

mkdir -p \
  "$APP_SUPPORT_DIR" \
  "$USER_APPS_DIR" \
  "$USER_AGENTS_DIR" \
  "$USER_LOG_DIR"

say "Building Hob's native menu bar"
"${SWIFT_COMMAND[@]}" build \
  -c release \
  --package-path "$PROJECT_ROOT/native/HobOpenLocalMenu"
BIN_PATH="$("${SWIFT_COMMAND[@]}" build \
  -c release \
  --package-path "$PROJECT_ROOT/native/HobOpenLocalMenu" \
  --show-bin-path)"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hob-menu.XXXXXX")"
cleanup() {
  if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi
}
trap cleanup EXIT

STAGED_APP="$STAGE_DIR/Hob Local.app"
mkdir -p "$STAGED_APP/Contents/MacOS"
cp \
  "$BIN_PATH/HobOpenLocalMenu" \
  "$STAGED_APP/Contents/MacOS/HobOpenLocalMenu"
cp \
  "$PROJECT_ROOT/native/HobOpenLocalMenu/Resources/Info.plist" \
  "$STAGED_APP/Contents/Info.plist"
chmod 755 "$STAGED_APP/Contents/MacOS/HobOpenLocalMenu"
codesign --force --deep --sign - "$STAGED_APP" >/dev/null
codesign --verify --deep --strict "$STAGED_APP"

if [ -d "$INSTALL_APP" ]; then
  PREVIOUS_APP="$USER_APPS_DIR/Hob Local.previous-$(date +%Y%m%d%H%M%S).app"
  mv "$INSTALL_APP" "$PREVIOUS_APP"
fi
ditto "$STAGED_APP" "$INSTALL_APP"

if [ ! -f "$DAEMON_PLIST" ]; then
  say "Installing Hob's automatic background service"
  DAEMON_TEMP="$STAGE_DIR/com.local.hob.plist"
  cp "$PROJECT_ROOT/deploy/com.local.hob.plist" "$DAEMON_TEMP"
  plutil -replace ProgramArguments.0 -string "$UV_PATH" "$DAEMON_TEMP"
  plutil -replace ProgramArguments.3 -string "$PROJECT_ROOT" "$DAEMON_TEMP"
  plutil -replace WorkingDirectory -string "$PROJECT_ROOT" "$DAEMON_TEMP"
  plutil -replace EnvironmentVariables.HOB_MODEL -string "$MODEL_NAME" "$DAEMON_TEMP"
  plutil -replace EnvironmentVariables.HOB_TIMEZONE -string "$TIMEZONE_NAME" "$DAEMON_TEMP"
  plutil -replace EnvironmentVariables.HOB_DB_PATH -string "$DATABASE_PATH" "$DAEMON_TEMP"
  plutil -replace EnvironmentVariables.PATH -string \
    "$(dirname "$UV_PATH"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$DAEMON_TEMP"
  plutil -replace StandardOutPath -string "$APP_SUPPORT_DIR/hob.log" "$DAEMON_TEMP"
  plutil -replace StandardErrorPath -string "$APP_SUPPORT_DIR/hob.log" "$DAEMON_TEMP"
  if [ -n "${HOB_ALLOWED_TELEGRAM_USER_ID:-}" ]; then
    plutil -replace EnvironmentVariables.HOB_ALLOWED_TELEGRAM_USER_ID \
      -string "$HOB_ALLOWED_TELEGRAM_USER_ID" "$DAEMON_TEMP"
  else
    plutil -remove EnvironmentVariables.HOB_ALLOWED_TELEGRAM_USER_ID \
      "$DAEMON_TEMP"
  fi
  plutil -lint "$DAEMON_TEMP"
  mv "$DAEMON_TEMP" "$DAEMON_PLIST"
fi

say "Installing Hob's login menu"
MENU_TEMP="$STAGE_DIR/com.local.hob.menu.plist"
cp "$PROJECT_ROOT/deploy/com.local.hob.menu.plist" "$MENU_TEMP"
plutil -replace ProgramArguments.0 \
  -string "$INSTALL_APP/Contents/MacOS/HobOpenLocalMenu" "$MENU_TEMP"
plutil -replace EnvironmentVariables.HOB_PROJECT_PATH \
  -string "$PROJECT_ROOT" "$MENU_TEMP"
plutil -replace EnvironmentVariables.HOB_DB_PATH \
  -string "$DATABASE_PATH" "$MENU_TEMP"
plutil -replace EnvironmentVariables.HOB_UV_PATH \
  -string "$UV_PATH" "$MENU_TEMP"
plutil -replace EnvironmentVariables.HOB_LOG_PATH \
  -string "$APP_SUPPORT_DIR/hob.log" "$MENU_TEMP"
plutil -replace EnvironmentVariables.HOB_MODEL \
  -string "$MODEL_NAME" "$MENU_TEMP"
plutil -replace EnvironmentVariables.HOB_OLLAMA_HOST \
  -string "$OLLAMA_ENDPOINT" "$MENU_TEMP"
plutil -replace EnvironmentVariables.HOB_TIMEZONE \
  -string "$TIMEZONE_NAME" "$MENU_TEMP"
plutil -replace StandardOutPath \
  -string "$USER_LOG_DIR/menu.log" "$MENU_TEMP"
plutil -replace StandardErrorPath \
  -string "$USER_LOG_DIR/menu.log" "$MENU_TEMP"
plutil -lint "$MENU_TEMP"

if [ -f "$MENU_PLIST" ]; then
  cp "$MENU_PLIST" "$MENU_PLIST.previous"
fi
mv "$MENU_TEMP" "$MENU_PLIST"

launchctl bootout "$MENU_TARGET" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN_TARGET" "$MENU_PLIST"

TOKEN_READY=false
if [ -n "${HOB_TELEGRAM_TOKEN:-}" ]; then
  TOKEN_READY=true
elif /usr/bin/security find-generic-password \
  -s com.local.hob.telegram \
  -a "$USER_NAME" >/dev/null 2>&1; then
  TOKEN_READY=true
fi

if launchctl print "$DAEMON_TARGET" >/dev/null 2>&1; then
  say "Restarting Hob on the installed release"
  launchctl kickstart -k "$DAEMON_TARGET"
elif [ "$TOKEN_READY" = true ]; then
  say "Turning Hob on"
  launchctl bootstrap "$DOMAIN_TARGET" "$DAEMON_PLIST"
  launchctl kickstart "$DAEMON_TARGET"
else
  warn "The menu bar is installed, but Hob is off until a Telegram token is saved."
  warn "Run: uv run --directory \"$PROJECT_ROOT\" python app.py token set"
  warn "Then choose Turn Hob On from the flame in the menu bar."
fi

printf '\nHob is installed. Look for the flame in the macOS menu bar.\n'
printf 'It starts at login and shows whether background delivery is running.\n'
