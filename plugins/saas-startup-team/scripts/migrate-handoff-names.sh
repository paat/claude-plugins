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
  filename=$(basename "$entry")
  [ "$filename" = "INDEX.md" ] && { SKIP_COUNT=$((SKIP_COUNT + 1)); continue; }

  # Canonical file — skip
  if [ -f "$entry" ] && [[ "$filename" =~ $CANONICAL_RE ]]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  # Rule 2: signoffs → .startup/signoffs/
  case "$filename" in
    *roundtrip-signoff*.md|*-signoff.md|signoff-*.md)
      MOVE_SIGNOFFS+=("${entry}|${SIGNOFFS_DIR}/${filename}")
      continue ;;
  esac

  # Rule 3: review artifacts → .startup/reviews/
  # Match a range of review-like patterns. Rename .lawyer.md / .QA-PASS.md
  # variants into cleaner names on the way out.
  dest_name="$filename"
  matched_review=0
  case "$filename" in
    *.lawyer.md)
      base="${filename%.lawyer.md}"
      dest_name="lawyer-${base}.md"
      matched_review=1 ;;
    *.QA-PASS.md)
      base="${filename%.QA-PASS.md}"
      dest_name="qa-pass-${base}.md"
      matched_review=1 ;;
    *-qa-review.md|*-qa-pass.md) matched_review=1 ;;
    *-business-review*.md|business-review-*.md) matched_review=1 ;;
    *-business-qa*.md|business-qa-*.md) matched_review=1 ;;
    *-regression-tests-*.md|*-regression-results-*.md) matched_review=1 ;;
    *ux-audit*.md|*ux-fixes*.md) matched_review=1 ;;
    tribunal-*-to-tech*.md|*-tribunal-to-tech*.md|*-tribunal-review-to-tech*.md) matched_review=1 ;;
    *-tech-review-fixes*.md|*-tech-fixes*.md) matched_review=1 ;;
    *-business-verification*.md) matched_review=1 ;;
  esac
  if [ "$matched_review" = "1" ]; then
    MOVE_REVIEWS+=("${entry}|${REVIEWS_DIR}/${dest_name}")
    continue
  fi

  # Rule 4: non-.md or directory → .startup/attachments/
  if [ -d "$entry" ]; then
    MOVE_ATTACH+=("${entry}|${ATTACH_DIR}/${filename}")
    continue
  fi
  case "$filename" in
    *.md) ;;
    *)
      MOVE_ATTACH+=("${entry}|${ATTACH_DIR}/${filename}")
      continue ;;
  esac

  # Fallthrough — leave unresolved for now; rules 5–6 added in later task
  MANUAL+=("${entry}|(rules 5-6 not yet implemented)")
done
shopt -u nullglob dotglob

# --- Output ---
echo "=== Handoff migration plan for ${HANDOFF_DIR} ==="
echo ""
echo "Skipping (already canonical): ${SKIP_COUNT}"
echo ""

print_move_section() {
  local title="$1"
  shift
  local items=("$@")
  [ "${#items[@]}" -eq 0 ] && return
  echo "${title} (${#items[@]} files):"
  for item in "${items[@]}"; do
    src="${item%%|*}"
    dest="${item##*|}"
    echo "  $(basename "$src") → ${dest}"
  done
  echo ""
}

print_move_section "Move to .startup/signoffs/" "${MOVE_SIGNOFFS[@]}"
print_move_section "Move to .startup/reviews/" "${MOVE_REVIEWS[@]}"
print_move_section "Move to .startup/attachments/" "${MOVE_ATTACH[@]}"

if [ "${#RENAMES[@]}" -gt 0 ]; then
  echo "Rename (${#RENAMES[@]} files):"
  for item in "${RENAMES[@]}"; do
    src="${item%%|*}"
    dest="${item##*|}"
    echo "  $(basename "$src") → $(basename "$dest")"
  done
  echo ""
fi

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
