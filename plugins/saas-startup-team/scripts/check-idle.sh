#!/bin/bash
# TeammateIdle hook: Validate that a founder wrote their handoff before going idle.
# Reads teammate info from stdin JSON. Exits 2 to block idle if handoff is missing.

set -euo pipefail

# Read stdin JSON (provides teammate_name and other context)
INPUT=$(cat)
TEAMMATE_NAME=$(echo "$INPUT" | jq -r '.teammate_name // empty' 2>/dev/null || true)

# If we can't determine the teammate, allow idle (don't block on hook failure)
if [ -z "$TEAMMATE_NAME" ]; then
  exit 0
fi

# Check that .startup directory exists
if [ ! -d ".startup" ]; then
  exit 0
fi

# Get current iteration from state.json
ITERATION=$(jq -r '.iteration // 0' .startup/state.json 2>/dev/null || echo "0")

# Find the latest handoff from this teammate
if [ "$TEAMMATE_NAME" = "business-founder" ]; then
  PATTERN=".startup/handoffs/*-business-to-tech.md"
elif [ "$TEAMMATE_NAME" = "tech-founder" ]; then
  PATTERN=".startup/handoffs/*-tech-to-business.md"
else
  # Unknown teammate, allow idle
  exit 0
fi

# Check if at least one handoff exists from this teammate
# shellcheck disable=SC2086
# Count matching files (avoid pipefail issues with ls | wc || echo)
HANDOFF_COUNT=0
for f in $PATTERN; do
  [ -e "$f" ] && HANDOFF_COUNT=$((HANDOFF_COUNT + 1))
done

if [ "$HANDOFF_COUNT" -eq 0 ] && [ "$ITERATION" -gt 0 ]; then
  echo "You must write your handoff document before stopping. Create a file matching: $PATTERN"
  exit 2
fi

exit 0
