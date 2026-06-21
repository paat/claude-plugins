#!/usr/bin/env bash
# Thin wrapper around the i18n-parity engine for check.sh / CI / git hooks.
# Forwards all args to the Python engine and propagates its exit code.
set -u

SELF="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SELF/i18n-parity.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "i18n-parity: python3 not found on PATH (required)." >&2
  exit 2
fi
if [ ! -f "$ENGINE" ]; then
  echo "i18n-parity: engine not found at $ENGINE" >&2
  exit 2
fi

exec python3 "$ENGINE" "$@"
