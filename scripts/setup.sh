#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# One-command setup for Hob. Installs uv and Ollama if missing, syncs deps,
# pulls the model, and runs the preflight so you know it is ready. Idempotent:
# safe to run again any time.
#
#   scripts/setup.sh
#
# Honors HOB_MODEL (default qwen2.5:7b-instruct) and HOB_OLLAMA_HOST.
set -euo pipefail

MODEL="${HOB_MODEL:-qwen2.5:7b-instruct}"
OLLAMA_HOST="${HOB_OLLAMA_HOST:-http://localhost:11434}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
ollama_up() { curl -fsS -m 3 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; }

[ "$(uname -s)" = "Darwin" ] || warn "Hob targets macOS; the daemon and launchd setup assume it."

# --- uv -----------------------------------------------------------------------
if ! have uv; then
  say "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # The installer drops uv in ~/.local/bin, not yet on this shell's PATH.
  [ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env" || export PATH="$HOME/.local/bin:$PATH"
fi
have uv || { warn "uv is installed but not on PATH; open a new terminal and re-run."; exit 1; }
say "uv $(uv --version)"

# --- dependencies -------------------------------------------------------------
say "Installing dependencies (uv sync)"
uv sync

# --- calendar bridge ----------------------------------------------------------
# Build the read-only EventKit edge, but never request private-data permission
# during unattended setup. The user grants that explicitly afterward.
if [ "$(uname -s)" = "Darwin" ] && have swiftc; then
  say "Building calendar availability bridge"
  scripts/build_calendar_bridge.sh || warn "Calendar bridge build failed; planning will use working hours only."
fi

# --- Ollama -------------------------------------------------------------------
if ! have ollama; then
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
if ! ollama_up; then
  say "Starting Ollama"
  nohup ollama serve >/tmp/hob-ollama-setup.log 2>&1 &
  for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
  ollama_up || { warn "Ollama did not come up; see /tmp/hob-ollama-setup.log"; exit 1; }
fi

# --- model --------------------------------------------------------------------
# Capture the list and match with case (no pipe): "ollama list | grep -q" trips
# SIGPIPE under pipefail and would re-pull an already-present model every run.
installed="$(ollama list 2>/dev/null || true)"
case "$installed" in
  *"$MODEL"*) say "Model already present: $MODEL" ;;
  *) say "Pulling model: $MODEL (several GB; this is the slow part)"; ollama pull "$MODEL" ;;
esac

# --- local app data -----------------------------------------------------------
mkdir -p "$HOME/Library/Application Support/Hob"

# --- Telegram token (cannot be automated; guide it) ---------------------------
if [ -z "${HOB_TELEGRAM_TOKEN:-}" ]; then
  cat <<'EOF'

Create your Telegram bot (about a minute):
  1. In Telegram, message @BotFather and send /newbot
  2. Run: uv run python app.py token set
  3. Start Hob and privately send the new bot /start. That first /start pairs
     Hob to your Telegram user; other users and group chats are rejected.

For unattended deployment, also set HOB_ALLOWED_TELEGRAM_USER_ID explicitly.

EOF
fi

# --- preflight ----------------------------------------------------------------
say "Preflight (app.py doctor)"
HOB_MODEL="$MODEL" uv run python app.py doctor || true

say "Setup complete. Start Hob with:  uv run python app.py"
echo "For a durable install that survives reboot and sleep, see docs/deployment.md"
