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

# Map frontmatter from:/to: pair to canonical direction, or empty if no match.
infer_from_frontmatter() {
  local file="$1"
  local from to
  from=$(awk '/^from:/ {gsub(/"/,"",$0); sub(/^from:[[:space:]]*/,""); print; exit}' "$file" 2>/dev/null | tr -d '[:space:]')
  to=$(awk '/^to:/ {gsub(/"/,"",$0); sub(/^to:[[:space:]]*/,""); print; exit}' "$file" 2>/dev/null | tr -d '[:space:]')
  case "${from}→${to}" in
    business-founder→tech-founder) echo "business-to-tech" ;;
    tech-founder→business-founder) echo "tech-to-business" ;;
    business-founder→growth-hacker) echo "business-to-growth" ;;
    growth-hacker→business-founder) echo "growth-to-business" ;;
    *) echo "" ;;
  esac
}

# Map filename substring to canonical direction, or empty if none found.
# Longest match first so "business-to-growth" isn't shadowed by "business".
infer_from_filename() {
  local filename="$1"
  for d in business-to-growth growth-to-business business-to-tech tech-to-business; do
    case "$filename" in
      *"$d"*) echo "$d"; return ;;
    esac
  done
  echo ""
}

# Compute the maximum NNN prefix among canonical NNN-<direction>.md files
# in the handoff dir (0 if none). Non-canonical 3-digit-prefix names (e.g.
# timestamped files starting with 2026-...) are ignored on purpose.
max_canonical_nnn() {
  local dir="$1"
  ls "$dir" 2>/dev/null \
    | grep -E '^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$' \
    | grep -oE '^[0-9]{3}' \
    | sort -n \
    | tail -1 || echo "0"
}

# Buckets: arrays of "<source>|<dest>" strings
SKIP_COUNT=0
MOVE_SIGNOFFS=()
MOVE_REVIEWS=()
MOVE_ATTACH=()
RENAMES=()
RENAME_CANDIDATES=()
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

  # Rule 5: infer canonical direction
  direction=$(infer_from_frontmatter "$entry")
  if [ -z "$direction" ]; then
    direction=$(infer_from_filename "$filename")
  fi
  if [ -n "$direction" ]; then
    # Defer NNN assignment — collect into a rename candidate list with mtime
    mtime=$(stat -c '%Y' "$entry" 2>/dev/null || stat -f '%m' "$entry" 2>/dev/null || echo 0)
    RENAME_CANDIDATES+=("${mtime}|${entry}|${direction}")
    continue
  fi

  # Rule 6: manual review
  MANUAL+=("${entry}|no canonical direction in filename or frontmatter")
done
shopt -u nullglob dotglob

# Assign NNNs to rename candidates in mtime order, starting at max+1.
max_nnn=$(max_canonical_nnn "$HANDOFF_DIR")
max_nnn=$((10#${max_nnn:-0}))
if [ "${#RENAME_CANDIDATES[@]}" -gt 0 ]; then
  # Sort by mtime (ascending)
  IFS=$'\n' sorted=($(printf '%s\n' "${RENAME_CANDIDATES[@]}" | sort -t'|' -k1,1n))
  unset IFS
  for item in "${sorted[@]}"; do
    src="${item#*|}"; src="${src%%|*}"          # middle field
    direction="${item##*|}"
    max_nnn=$((max_nnn + 1))
    nnn=$(printf '%03d' "$max_nnn")
    RENAMES+=("${src}|${HANDOFF_DIR}/${nnn}-${direction}.md")
  done
fi

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

# --- Apply pass ---
if [ "$APPLY" -ne 1 ]; then
  exit 0
fi

mkdir -p "$SIGNOFFS_DIR" "$REVIEWS_DIR" "$ATTACH_DIR"

apply_move() {
  local src="$1" dest="$2"
  if [ -e "$dest" ]; then
    local ts
    ts=$(date +%Y%m%d%H%M%S)
    local base="${dest%.*}"
    local ext="${dest##*.}"
    if [ "$base" = "$dest" ]; then
      dest="${dest}-dup${ts}"
    else
      dest="${base}-dup${ts}.${ext}"
    fi
  fi
  mv "$src" "$dest"
}

for item in "${MOVE_SIGNOFFS[@]}"; do apply_move "${item%%|*}" "${item##*|}"; done
for item in "${MOVE_REVIEWS[@]}"; do apply_move "${item%%|*}" "${item##*|}"; done
for item in "${MOVE_ATTACH[@]}"; do apply_move "${item%%|*}" "${item##*|}"; done
for item in "${RENAMES[@]}"; do apply_move "${item%%|*}" "${item##*|}"; done

echo ""
echo "[DONE] Applied: ${#MOVE_SIGNOFFS[@]} signoffs, ${#MOVE_REVIEWS[@]} reviews, ${#MOVE_ATTACH[@]} attachments, ${#RENAMES[@]} renames."

# Regenerate INDEX.md to reflect the new state
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/backfill-handoff-index.sh" ]; then
  echo "Regenerating $HANDOFF_DIR/INDEX.md..."
  bash "$SCRIPT_DIR/backfill-handoff-index.sh" "$HANDOFF_DIR"
fi
