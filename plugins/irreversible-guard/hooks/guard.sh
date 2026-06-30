#!/usr/bin/env bash
# irreversible-guard PreToolUse wrapper. Fails OPEN (exit 0) if python3 is absent
# so a missing interpreter never bricks every Bash tool call. exec preserves the
# matcher's exit code (2 = block).
set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "[irreversible-guard] python3 not found; guard disabled (fail-open)" >&2
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HOOK_DIR/irreversible-guard.py"
