#!/bin/bash
# enforce-handoff-naming.sh — PreToolUse hook for Write.
# Blocks Writes under .startup/handoffs/ unless the filename is INDEX.md or
# matches the canonical NNN-<direction>.md pattern. Exit 2 with systemMessage
# on block; exit 0 otherwise (pass through).
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a handoff path, or canonical name
# Exit 2: blocked, systemMessage on stderr

set -uo pipefail

input=$(cat || true)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -z "$file_path" ] && exit 0

# Only act on writes under .startup/handoffs/
case "$file_path" in
  */.startup/handoffs/*) ;;
  *) exit 0 ;;
esac

filename=$(basename "$file_path")
[ "$filename" = "INDEX.md" ] && exit 0

# Canonical format
if [[ "$filename" =~ ^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$ ]]; then
  exit 0
fi

# Compute next available NNN for the error message. Filter to canonical names
# so pre-migration timestamp-prefixed files (e.g. 2026-04-16T...) don't poison
# the max with their year prefix.
handoff_dir=$(dirname "$file_path")
next_nnn="001"
if [ -d "$handoff_dir" ]; then
  max=$(ls "$handoff_dir" 2>/dev/null \
    | grep -E '^[0-9]{3}-(business-to-tech|tech-to-business|business-to-growth|growth-to-business)\.md$' \
    | grep -oE '^[0-9]{3}' | sort -n | tail -1 || true)
  if [ -n "$max" ]; then
    next_nnn=$(printf '%03d' $((10#$max + 1)))
  fi
fi

msg="Handoff filename '${filename}' is not valid. Handoffs must be named NNN-<direction>.md where NNN is a zero-padded 3-digit number and <direction> is one of: business-to-tech, tech-to-business, business-to-growth, growth-to-business. Next available NNN: ${next_nnn}. Binaries (.pdf, .png) belong in .startup/attachments/; signoffs in .startup/signoffs/; reviews in .startup/reviews/."

jq -n --arg msg "$msg" '{systemMessage: $msg}' >&2
exit 2
