#!/bin/bash
# migrate-handoff-names.sh — one-time cleanup of .startup/handoffs/ to enforce
# the canonical NNN-<direction>.md filename convention.
#
# Moves misplaced signoffs to .startup/signoffs/, reviews to .startup/reviews/,
# binaries and directories to .startup/attachments/, and renames residual
# topic-slug handoffs to NNN-<direction>.md with next-available numbers.
#
# Usage:
#   bash migrate-handoff-names.sh                  # dry-run against git root
#   bash migrate-handoff-names.sh --apply          # execute
#   bash migrate-handoff-names.sh <handoff-dir>    # dry-run on explicit dir
#   bash migrate-handoff-names.sh --apply <dir>    # execute on explicit dir

set -uo pipefail

APPLY=0
HANDOFF_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0 ;;
    *) HANDOFF_DIR="$1" ;;
  esac
  shift
done

if [ -z "$HANDOFF_DIR" ]; then
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "Not in a git repo and no dir argument supplied." >&2
    exit 1
  }
  HANDOFF_DIR="$GIT_ROOT/.startup/handoffs"
fi

if [ ! -d "$HANDOFF_DIR" ]; then
  echo "Handoff dir not found: $HANDOFF_DIR" >&2
  exit 1
fi

STARTUP_DIR=$(dirname "$HANDOFF_DIR")
SIGNOFFS_DIR="$STARTUP_DIR/signoffs"
REVIEWS_DIR="$STARTUP_DIR/reviews"
ATTACH_DIR="$STARTUP_DIR/attachments"

CANONICAL_RE='^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$'

# Buckets: arrays of "<source>|<dest>" strings
SKIP_COUNT=0
MOVE_SIGNOFFS=()
MOVE_REVIEWS=()
MOVE_ATTACH=()
RENAMES=()
MANUAL=()

# --- Scan pass ---
shopt -s nullglob dotglob
for entry in "$HANDOFF_DIR"/*; do
  [ "$(basename "$entry")" = "INDEX.md" ] && { SKIP_COUNT=$((SKIP_COUNT + 1)); continue; }
  filename=$(basename "$entry")

  if [[ "$filename" =~ $CANONICAL_RE ]] && [ -f "$entry" ]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Rules 2-5 will be added in later tasks. For now, anything non-canonical
  # goes to MANUAL so the skeleton produces correct counts on mixed dirs.
  MANUAL+=("${entry}|(rules not yet implemented)")
done
shopt -u nullglob dotglob

# --- Output ---
echo "=== Handoff migration plan for ${HANDOFF_DIR} ==="
echo ""
echo "Skipping (already canonical): ${SKIP_COUNT}"
echo ""

if [ "${#MANUAL[@]}" -gt 0 ]; then
  echo "Manual review needed (${#MANUAL[@]} files, left in place):"
  for item in "${MANUAL[@]}"; do
    src="${item%%|*}"
    reason="${item##*|}"
    echo "  $(basename "$src")    (reason: ${reason})"
  done
  echo ""
fi

echo "Summary: skip ${SKIP_COUNT}, move $((${#MOVE_SIGNOFFS[@]} + ${#MOVE_REVIEWS[@]} + ${#MOVE_ATTACH[@]})), rename ${#RENAMES[@]}, manual ${#MANUAL[@]}"

if [ "$APPLY" -eq 0 ]; then
  echo "Dry-run — re-run with --apply to perform changes."
fi
