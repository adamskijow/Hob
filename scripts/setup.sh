#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# One-command setup for Hob. Installs uv and Ollama through Homebrew if missing, syncs deps,
# pulls the model, and runs the preflight so you know it is ready. Idempotent:
# safe to run again any time.
#
#   scripts/setup.sh
#
# Honors HOB_MODEL, HOB_OLLAMA_HOST, and HOB_ALLOW_REMOTE_OLLAMA.
set -euo pipefail

MODEL="${HOB_MODEL:-qwen2.5:7b-instruct}"
OLLAMA_HOST="${HOB_OLLAMA_HOST:-http://localhost:11434}"
ALLOW_REMOTE_OLLAMA="${HOB_ALLOW_REMOTE_OLLAMA:-0}"
REMOTE_OLLAMA=false
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
ollama_up() { curl -fsS -m 3 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; }

[ "$(uname -s)" = "Darwin" ] || warn "Hob targets macOS; the daemon and launchd setup assume it."

# --- uv -----------------------------------------------------------------------
if ! have uv; then
  if have brew; then
    say "Installing uv (Homebrew)"
    brew install uv
  else
    warn "uv is missing and Homebrew is unavailable."
    warn "Install uv from https://docs.astral.sh/uv/getting-started/installation/ and re-run."
    exit 1
  fi
fi
have uv || { warn "uv is installed but not on PATH; open a new terminal and re-run."; exit 1; }
say "uv $(uv --version)"

# --- dependencies -------------------------------------------------------------
say "Installing locked dependencies (uv sync --locked)"
uv sync --locked
if ! REMOTE_OLLAMA="$(
  HOB_SETUP_OLLAMA_HOST="$OLLAMA_HOST" \
  HOB_SETUP_ALLOW_REMOTE="$ALLOW_REMOTE_OLLAMA" \
  uv run python -c '
import os
from adapters.ollama_safety import is_loopback_ollama_host, validate_ollama_host
allow = os.environ["HOB_SETUP_ALLOW_REMOTE"].strip().lower() in {"1", "true", "yes", "on"}
host = validate_ollama_host(os.environ["HOB_SETUP_OLLAMA_HOST"], allow_remote=allow)
print("false" if is_loopback_ollama_host(host) else "true")
'
)"; then
  warn "Ollama endpoint failed Hob privacy validation."
  exit 2
fi

# --- calendar bridge ----------------------------------------------------------
# Build the read-only EventKit edge, but never request private-data permission
# during unattended setup. The user grants that explicitly afterward.
if [ "$(uname -s)" = "Darwin" ] && have swiftc; then
  say "Building calendar availability bridge"
  scripts/build_calendar_bridge.sh || warn "Calendar bridge build failed; planning will use working hours only."
fi

# --- Ollama -------------------------------------------------------------------
if [ "$REMOTE_OLLAMA" = false ] && ! have ollama; then
  if have brew; then
    say "Installing Ollama (Homebrew)"
    brew install ollama
  else
    warn "Ollama is not installed and Homebrew is unavailable."
    warn "Install it from https://ollama.com/download and run this again."
    exit 1
  fi
fi

# The model pull needs a running server. If nothing is serving, start one for
# now; a durable setup lets Hearth/launchd own it (see docs/deployment.md).
if [ "$REMOTE_OLLAMA" = false ] && ! ollama_up; then
  say "Starting Ollama"
  nohup ollama serve >/tmp/hob-ollama-setup.log 2>&1 &
  for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
  ollama_up || { warn "Ollama did not come up; see /tmp/hob-ollama-setup.log"; exit 1; }
fi

# --- model --------------------------------------------------------------------
# Capture the list and match with case (no pipe): "ollama list | grep -q" trips
# SIGPIPE under pipefail and would re-pull an already-present model every run.
if [ "$REMOTE_OLLAMA" = true ]; then
  say "Using trusted remote Ollama over HTTPS (task text leaves this Mac)"
  ollama_up || { warn "Remote Ollama is not reachable: $OLLAMA_HOST"; exit 1; }
else
  installed="$(ollama list 2>/dev/null || true)"
  case "$installed" in
    *"$MODEL"*) say "Model already present: $MODEL" ;;
    *) say "Pulling model: $MODEL (several GB; this is the slow part)"; ollama pull "$MODEL" ;;
  esac
fi

# --- local app data -----------------------------------------------------------
mkdir -p "$HOME/Library/Application Support/Hob"
chmod 700 "$HOME/Library/Application Support/Hob"

# --- Telegram token (cannot be automated; guide it) ---------------------------
if [ -z "${HOB_TELEGRAM_TOKEN:-}" ]; then
  cat <<'EOF'

Create your Telegram bot (about a minute):
  1. In Telegram, message @BotFather and send /newbot
  2. Run: uv run python app.py token set
  3. On macOS, click Turn Hob On under the teapot in the menu bar, then privately
     send the new bot /start. Hob replies with your Telegram user ID.
  4. In this folder run: scripts/hobctl pair THAT_ID
  5. Send /start again to begin setup. Telegram contact alone cannot claim Hob;
     other users and group chats are silently rejected.

For unattended deployment, also set HOB_ALLOWED_TELEGRAM_USER_ID explicitly.

EOF
fi

# --- preflight ----------------------------------------------------------------
say "Preflight (app.py doctor)"
HOB_MODEL="$MODEL" uv run python app.py doctor || true

if [ "$(uname -s)" = "Darwin" ] && have swift; then
  say "Installing automatic startup and the Hob menu bar"
  HOB_MODEL="$MODEL" scripts/install_macos.sh ||
    warn "Native controls were not installed; run scripts/install_macos.sh after fixing the error."
fi

say "Setup complete"
if [ "$(uname -s)" = "Darwin" ]; then
  echo "Use the teapot in the menu bar to check health, turn Hob on, or restart it."
else
  echo "Start Hob with:  uv run python app.py"
fi
