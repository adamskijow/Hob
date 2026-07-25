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
PYTHON_PATH="$PROJECT_ROOT/.venv/bin/python"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }

bootstrap_agent() {
  local plist="$1"
  local attempt
  # launchd can hold a just-booted-out label for several seconds while its
  # minimum-runtime accounting settles. Bound the retry instead of reporting
  # the transient error 5 as a failed install.
  for attempt in {1..100}; do
    if launchctl bootstrap "$DOMAIN_TARGET" "$plist" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  launchctl bootstrap "$DOMAIN_TARGET" "$plist"
}

restart_agent() {
  local target="$1"
  local plist="$2"
  launchctl bootout "$target"
  bootstrap_agent "$plist"
}

wait_for_running_agent() {
  local target="$1"
  local label="$2"
  local attempt
  local current_pid=""
  local previous_pid=""
  local stable_checks=0
  local details
  for attempt in {1..60}; do
    details="$(launchctl print "$target" 2>/dev/null || true)"
    current_pid="$(
      printf '%s\n' "$details" |
        /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/ { print $3; exit }'
    )"
    if printf '%s\n' "$details" |
      /usr/bin/grep -q '^[[:space:]]*state = running$' &&
      [ -n "$current_pid" ]; then
      if [ "$current_pid" = "$previous_pid" ]; then
        stable_checks=$((stable_checks + 1))
      else
        stable_checks=1
        previous_pid="$current_pid"
      fi
      if [ "$stable_checks" -ge 4 ]; then
        return 0
      fi
    else
      stable_checks=0
      previous_pid=""
    fi
    sleep 0.5
  done
  printf 'hob: %s did not reach a stable running state\n' "$label" >&2
  return 1
}

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'hob: the native menu-bar installer requires macOS\n' >&2
  exit 2
fi
if [ -z "$UV_PATH" ]; then
  printf 'hob: uv is required; run scripts/setup.sh first\n' >&2
  exit 2
fi
if [ ! -x "$PYTHON_PATH" ]; then
  printf 'hob: the Python environment is missing; run scripts/setup.sh first\n' >&2
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

DAEMON_TEMPLATE="$PROJECT_ROOT/deploy/com.local.hob.plist"
if [ -f "$DAEMON_PLIST" ]; then
  DAEMON_TEMPLATE="$DAEMON_PLIST"
else
  say "Installing Hob's automatic background service"
fi
OWNER_ID="${HOB_ALLOWED_TELEGRAM_USER_ID:-}"
if [ -z "$OWNER_ID" ] && [ -f "$DAEMON_PLIST" ]; then
  OWNER_ID="$(
    plist_value EnvironmentVariables.HOB_ALLOWED_TELEGRAM_USER_ID "$DAEMON_PLIST"
  )"
fi
DAEMON_TEMP="$STAGE_DIR/com.local.hob.plist"
DAEMON_RENDER_ARGS=(
  daemon
  --template "$DAEMON_TEMPLATE"
  --output "$DAEMON_TEMP"
  --python-path "$PYTHON_PATH"
  --uv-path "$UV_PATH"
  --project-root "$PROJECT_ROOT"
  --model "$MODEL_NAME"
  --timezone "$TIMEZONE_NAME"
  --database-path "$DATABASE_PATH"
  --log-path "$APP_SUPPORT_DIR/hob.log"
)
if [ -n "$OWNER_ID" ]; then
  DAEMON_RENDER_ARGS+=(--allowed-telegram-user-id "$OWNER_ID")
fi
"$UV_PATH" run --directory "$PROJECT_ROOT" python \
  "$PROJECT_ROOT/scripts/render_macos_plists.py" \
  "${DAEMON_RENDER_ARGS[@]}"
plutil -lint "$DAEMON_TEMP"
if [ -f "$DAEMON_PLIST" ]; then
  cp "$DAEMON_PLIST" "$DAEMON_PLIST.previous"
fi
mv "$DAEMON_TEMP" "$DAEMON_PLIST"

say "Installing Hob's login menu"
MENU_TEMP="$STAGE_DIR/com.local.hob.menu.plist"
"$UV_PATH" run --directory "$PROJECT_ROOT" python \
  "$PROJECT_ROOT/scripts/render_macos_plists.py" menu \
  --template "$PROJECT_ROOT/deploy/com.local.hob.menu.plist" \
  --output "$MENU_TEMP" \
  --executable-path "$INSTALL_APP/Contents/MacOS/HobOpenLocalMenu" \
  --project-root "$PROJECT_ROOT" \
  --database-path "$DATABASE_PATH" \
  --uv-path "$UV_PATH" \
  --log-path "$APP_SUPPORT_DIR/hob.log" \
  --model "$MODEL_NAME" \
  --ollama-host "$OLLAMA_ENDPOINT" \
  --timezone "$TIMEZONE_NAME" \
  --menu-log-path "$USER_LOG_DIR/menu.log"
plutil -lint "$MENU_TEMP"

if [ -f "$MENU_PLIST" ]; then
  cp "$MENU_PLIST" "$MENU_PLIST.previous"
fi
mv "$MENU_TEMP" "$MENU_PLIST"

launchctl bootout "$MENU_TARGET" >/dev/null 2>&1 || true
bootstrap_agent "$MENU_PLIST"

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
  restart_agent "$DAEMON_TARGET" "$DAEMON_PLIST"
  wait_for_running_agent "$DAEMON_TARGET" "background delivery"
elif [ "$TOKEN_READY" = true ]; then
  say "Turning Hob on"
  bootstrap_agent "$DAEMON_PLIST"
  launchctl kickstart "$DAEMON_TARGET"
  wait_for_running_agent "$DAEMON_TARGET" "background delivery"
else
  warn "The menu bar is installed, but Hob is off until a Telegram token is saved."
  warn "Run: uv run --directory \"$PROJECT_ROOT\" python app.py token set"
  warn "Then choose Turn Hob On from the flame in the menu bar."
fi

printf '\nHob is installed. Look for the flame in the macOS menu bar.\n'
printf 'It starts at login and shows whether background delivery is running.\n'
