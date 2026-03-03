#!/bin/bash
# check-duplicate-handoff.sh — PostToolUse hook for Write events
# Warns when a handoff file is written but one with the same number already exists
# from a different direction (e.g., 003-business-to-tech.md already exists when
# writing 003-tech-to-business.md is fine, but writing a second 003-business-to-tech.md
# means the agent is duplicating work).
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a handoff or no duplicate
# Exit 2: duplicate detected, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check handoff files
if [[ ! "$file_path" =~ \.startup/handoffs/[0-9]{3}-[a-z]+-to-[a-z]+\.md$ ]]; then
  exit 0
fi

filename=$(basename "$file_path")
handoff_dir=$(dirname "$file_path")

# Extract number and direction from this handoff
handoff_num=$(echo "$filename" | grep -oE '^[0-9]{3}')
direction=$(echo "$filename" | sed 's/^[0-9]*-//; s/\.md$//')

# Check if another handoff with the same number AND same direction already existed
# (the file we just wrote will exist, so count matches > 1 would mean duplicates,
# but since Write overwrites, check if there's a git history of the same file)
# Simpler approach: check if there are multiple files with the same handoff number
same_number_files=()
for f in "$handoff_dir/${handoff_num}-"*.md; do
  [ -e "$f" ] && same_number_files+=("$f")
done

# If there are 2+ files with the same handoff number, check if the same direction
# appears twice (which would indicate duplicate work)
same_direction_count=0
for f in "${same_number_files[@]}"; do
  fname=$(basename "$f")
  fdir=$(echo "$fname" | sed 's/^[0-9]*-//; s/\.md$//')
  if [ "$fdir" = "$direction" ]; then
    same_direction_count=$((same_direction_count + 1))
  fi
done

# If this exact file was just written, same_direction_count should be exactly 1.
# Check for a higher handoff with the same direction that suggests re-doing work.
# More useful: warn if this handoff number is LOWER than an existing one from the same author.
highest_existing=0
if [ "$direction" = "business-to-tech" ] || [ "$direction" = "tech-to-business" ]; then
  author_pattern="${direction}"
  for f in "$handoff_dir/"*"-${author_pattern}.md"; do
    if [ -e "$f" ]; then
      fname=$(basename "$f")
      num=$(echo "$fname" | grep -oE '^[0-9]+')
      num=$((10#$num))
      if [ "$num" -gt "$highest_existing" ]; then
        highest_existing=$num
      fi
    fi
  done
fi

current_num=$((10#$handoff_num))

# Warn if writing a handoff with a number lower than or equal to an already-existing
# higher-numbered handoff from the same direction (suggests re-doing completed work)
if [ "$highest_existing" -gt "$current_num" ]; then
  cat >&2 <<EOF
{"systemMessage":"Warning: You wrote handoff ${handoff_num} (${direction}), but handoff $(printf '%03d' $highest_existing) already exists for the same direction. This looks like duplicate work — check .startup/handoffs/ for existing handoffs before creating new ones. If this is intentional (e.g., a correction), proceed."}
EOF
  exit 2
fi

exit 0
