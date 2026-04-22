#!/bin/bash
# compact-state.sh — move historical keys out of .startup/state.json into
# .startup/state-archive.json so state.json stays small in long-running projects.
#
# Behaviour:
#   - Missing state.json → exit 0 silently.
#   - Corrupt state.json → exit 1 with error on stderr, file untouched.
#   - Anything outside the inline allowlist (and not matching growth_*, and not a
#     recent handoff) is eligible for archival. Compaction runs whenever ≥1 key
#     is eligible — handoff count need not exceed the window for historical cruft
#     (signoff_vN, iterationN_signoff, legacy_* etc.) to be swept.
#   - Handoff keys handoff_NNN_* are archived only when count > window, and only
#     those with N ≤ (latest - window).
#   - Sets schema_version=2, archived_through, latest_handoff on the inline state.
#   - Writes to archive are append-only. A corrupt archive file is renamed to
#     state-archive.json.corrupt-<timestamp> and a fresh archive started, with a
#     warning on stderr (never silently overwritten).
#   - flock guards the entire read-compute-write cycle, so concurrent invocations
#     serialize and the later runs see already-compacted state (idempotent).
#
# Usage:
#   compact-state.sh [--dry-run] [--state-file PATH] [--archive-file PATH] [--window N]
#
# Env:
#   STARTUP_INLINE_HANDOFFS — default window size (must be positive integer; default 10).

set -euo pipefail

DRY_RUN=0
WINDOW="${STARTUP_INLINE_HANDOFFS:-10}"
STATE_FILE=""
ARCHIVE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --window)        WINDOW="$2"; shift 2 ;;
    --state-file)    STATE_FILE="$2"; shift 2 ;;
    --archive-file)  ARCHIVE_FILE="$2"; shift 2 ;;
    *) echo "compact-state: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --window / STARTUP_INLINE_HANDOFFS must be a positive integer.
if ! [[ "$WINDOW" =~ ^[1-9][0-9]*$ ]]; then
  echo "compact-state: invalid --window value '$WINDOW' (must be a positive integer)" >&2
  exit 2
fi

if [ -z "$STATE_FILE" ]; then
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$GIT_ROOT" ] && GIT_ROOT="$PWD"
  STATE_FILE="$GIT_ROOT/.startup/state.json"
fi
[ -z "$ARCHIVE_FILE" ] && ARCHIVE_FILE="$(dirname "$STATE_FILE")/state-archive.json"

[ -f "$STATE_FILE" ] || exit 0

if ! command -v jq &>/dev/null; then
  echo "compact-state: jq not found" >&2
  exit 1
fi
if ! jq empty "$STATE_FILE" 2>/dev/null; then
  echo "compact-state: $STATE_FILE is not valid JSON" >&2
  exit 1
fi

# --- jq filters (used both pre-lock for dry-run preview and inside the lock) --

JQ_SELECT_ARCHIVE='
  with_entries(
    .key as $k |
    select(
      if ($k | test("^(schema_version|max_iterations|status|started|resumed|iteration|phase|active_role|agent_handoffs|archived_through|latest_handoff)$")) then false
      elif ($k | startswith("growth_")) then false
      elif ($k | test("^handoff_[0-9]+_")) then
        ($k | capture("^handoff_(?<n>[0-9]+)_") | .n | tonumber) <= $cutoff
      else
        true
      end
    )
  )
'

JQ_SELECT_INLINE='
  with_entries(
    .key as $k |
    select(
      ($k | test("^(schema_version|max_iterations|status|started|resumed|iteration|phase|active_role|agent_handoffs|archived_through|latest_handoff)$"))
      or ($k | startswith("growth_"))
      or (
        ($k | test("^handoff_[0-9]+_"))
        and (($k | capture("^handoff_(?<n>[0-9]+)_") | .n | tonumber) > $cutoff)
      )
    )
  )
  | . + { schema_version: 2, archived_through: $cutoff, latest_handoff: $latest }
'

# Compute handoff metadata + archive cutoff from a state.json path.
# Sets: LATEST_HANDOFF, ARCHIVE_CUTOFF, ARCHIVED_KEY_COUNT, to_archive_json.
compute_plan() {
  local file="$1"
  local handoff_nums count
  handoff_nums=$(jq -r 'keys[] | select(test("^handoff_[0-9]+_")) | capture("^handoff_(?<n>[0-9]+)_") | .n' "$file" \
    | sort -un)
  count=0
  [ -n "$handoff_nums" ] && count=$(echo "$handoff_nums" | grep -c .)

  if [ "$count" -gt 0 ]; then
    LATEST_HANDOFF=$((10#$(echo "$handoff_nums" | tail -n 1)))
  else
    LATEST_HANDOFF=0
  fi

  if [ "$count" -gt "$WINDOW" ]; then
    local keep_from=$((10#$(echo "$handoff_nums" | tail -n "$WINDOW" | head -n 1)))
    ARCHIVE_CUTOFF=$((keep_from - 1))
  else
    # No handoffs archived — but historical cruft still eligible.
    ARCHIVE_CUTOFF=-1
  fi

  to_archive_json=$(jq --argjson cutoff "$ARCHIVE_CUTOFF" "$JQ_SELECT_ARCHIVE" "$file")
  ARCHIVED_KEY_COUNT=$(echo "$to_archive_json" | jq 'length')
}

compute_plan "$STATE_FILE"

# Nothing eligible for archival → no-op. We do NOT silently promote stale v1
# state to v2 here; that belongs to migrate-state.sh or /startup init.
if [ "$ARCHIVED_KEY_COUNT" -eq 0 ]; then
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY RUN] compact-state would archive $ARCHIVED_KEY_COUNT key(s) through handoff #$(printf '%03d' "$ARCHIVE_CUTOFF")"
  echo "[DRY RUN] state.json: $STATE_FILE"
  echo "[DRY RUN] archive:    $ARCHIVE_FILE"
  exit 0
fi

# --- Locked section: re-read, re-compute, write. -----------------------------

LOCK_FILE="$STATE_FILE.lock"
exec 9>"$LOCK_FILE"
flock 9

# Re-read inside the lock — another process may have compacted ahead of us.
if ! jq empty "$STATE_FILE" 2>/dev/null; then
  echo "compact-state: $STATE_FILE is not valid JSON (after lock)" >&2
  exit 1
fi
compute_plan "$STATE_FILE"

# If another process already did the work while we were waiting, exit cleanly.
if [ "$ARCHIVED_KEY_COUNT" -eq 0 ]; then
  exit 0
fi

# Write a new archive entry, handling corrupt archive defensively.
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ -f "$ARCHIVE_FILE" ]; then
  if jq empty "$ARCHIVE_FILE" 2>/dev/null; then
    existing_archive=$(cat "$ARCHIVE_FILE")
  else
    CORRUPT_SUFFIX=$(date -u +%Y%m%dT%H%M%SZ)
    mv "$ARCHIVE_FILE" "$ARCHIVE_FILE.corrupt-$CORRUPT_SUFFIX"
    echo "compact-state: WARNING: $ARCHIVE_FILE was not valid JSON; preserved as $ARCHIVE_FILE.corrupt-$CORRUPT_SUFFIX and starting a fresh archive" >&2
    existing_archive='{"schema_version": 2, "entries": []}'
  fi
else
  existing_archive='{"schema_version": 2, "entries": []}'
fi

new_entry=$(jq -n \
  --arg at "$NOW_ISO" \
  --argjson cutoff "$ARCHIVE_CUTOFF" \
  --argjson keys "$to_archive_json" \
  '{archived_at: $at, archived_through_handoff: $cutoff, keys: $keys}')

updated_archive=$(echo "$existing_archive" | jq --argjson entry "$new_entry" '.entries += [$entry]')

archive_tmp=$(mktemp "$ARCHIVE_FILE.tmp.XXXXXX")
echo "$updated_archive" > "$archive_tmp"
mv "$archive_tmp" "$ARCHIVE_FILE"

# Rewrite state.json: drop archived keys, stamp metadata.
new_state=$(jq \
  --argjson cutoff "$ARCHIVE_CUTOFF" \
  --argjson latest "$LATEST_HANDOFF" \
  "$JQ_SELECT_INLINE" \
  "$STATE_FILE")

state_tmp=$(mktemp "$STATE_FILE.tmp.XXXXXX")
echo "$new_state" > "$state_tmp"
mv "$state_tmp" "$STATE_FILE"

echo "compact-state: archived $ARCHIVED_KEY_COUNT key(s) through handoff #$(printf '%03d' "$ARCHIVE_CUTOFF"); latest #$(printf '%03d' "$LATEST_HANDOFF")"
