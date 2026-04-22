#!/bin/bash
# migrate-state.sh — one-shot migration wrapper around compact-state.sh for
# existing projects whose .startup/state.json has grown unboundedly.
#
# Defaults to --dry-run. Only mutates files when --yes is passed, in which case
# a timestamped backup is created alongside state.json first.
#
# Usage:
#   migrate-state.sh               # dry-run, no changes
#   migrate-state.sh --dry-run     # explicit dry-run
#   migrate-state.sh --yes         # back up then compact
#   migrate-state.sh --yes --window 20 --state-file ...

set -euo pipefail

DRY_RUN=1
WINDOW=""
STATE_FILE=""
ARCHIVE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --yes)           DRY_RUN=0; shift ;;
    --window)        WINDOW="$2"; shift 2 ;;
    --state-file)    STATE_FILE="$2"; shift 2 ;;
    --archive-file)  ARCHIVE_FILE="$2"; shift 2 ;;
    *) echo "migrate-state: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$STATE_FILE" ]; then
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$GIT_ROOT" ] && GIT_ROOT="$PWD"
  STATE_FILE="$GIT_ROOT/.startup/state.json"
fi
[ -z "$ARCHIVE_FILE" ] && ARCHIVE_FILE="$(dirname "$STATE_FILE")/state-archive.json"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPACT="$SCRIPT_DIR/compact-state.sh"

if [ ! -x "$COMPACT" ]; then
  echo "migrate-state: compact-state.sh not found at $COMPACT" >&2
  exit 1
fi

compact_args=(--state-file "$STATE_FILE" --archive-file "$ARCHIVE_FILE")
[ -n "$WINDOW" ] && compact_args+=(--window "$WINDOW")

if [ "$DRY_RUN" -eq 1 ]; then
  compact_args=(--dry-run "${compact_args[@]}")
  exec "$COMPACT" "${compact_args[@]}"
fi

# --yes path: figure out whether compaction will do anything; only back up if so.
dry_output=$("$COMPACT" --dry-run "${compact_args[@]}" 2>&1 || true)
if ! echo "$dry_output" | grep -q '^\[DRY RUN\] compact-state'; then
  # No-op migration — nothing to back up, nothing to do.
  exit 0
fi

if [ -f "$STATE_FILE" ]; then
  TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
  BACKUP="$STATE_FILE.bak-$TIMESTAMP"
  cp "$STATE_FILE" "$BACKUP"
  echo "migrate-state: backed up state.json to $BACKUP"
fi

exec "$COMPACT" "${compact_args[@]}"
