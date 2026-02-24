#!/bin/bash
# Stop hook: Prevent premature session termination without solution signoff.
# Only enforces after iteration >= 2 to allow early testing/pausing.
# Exits 2 to block stop if conditions not met.

set -euo pipefail

# Resolve git root for absolute paths (MED-7)
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$GIT_ROOT" ]; then
  # Not in a git repo — allow stop
  exit 0
fi

STARTUP_DIR="$GIT_ROOT/.startup"

# If .startup doesn't exist, allow stop (not initialized)
if [ ! -d "$STARTUP_DIR" ]; then
  exit 0
fi

STATE_FILE="$STARTUP_DIR/state.json"

# If no state file, allow stop
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

ITERATION=$(jq -r '.iteration // 0' "$STATE_FILE" 2>/dev/null || echo "0")
PHASE=$(jq -r '.phase // "research"' "$STATE_FILE" 2>/dev/null || echo "research")

# Allow stop early — may be testing or initial setup (CRIT-2)
if [ "$ITERATION" -lt 2 ]; then
  exit 0
fi

# If solution signoff exists, allow stop
if [ -f "$STARTUP_DIR/go-live/solution-signoff.md" ]; then
  exit 0
fi

# Block stop — session is mid-progress without signoff
echo "Cannot stop: the startup loop is at iteration $ITERATION (phase: $PHASE) without a solution signoff."
echo ""
echo "Current progress:"

# Show handoff count
HANDOFF_COUNT=0
for f in "$STARTUP_DIR/handoffs/"*.md; do
  [ -e "$f" ] && HANDOFF_COUNT=$((HANDOFF_COUNT + 1))
done
echo "  Handoffs written: $HANDOFF_COUNT"

# Show signoff count
SIGNOFF_COUNT=0
for f in "$STARTUP_DIR/signoffs/"roundtrip-*.md; do
  [ -e "$f" ] && SIGNOFF_COUNT=$((SIGNOFF_COUNT + 1))
done
echo "  Features signed off: $SIGNOFF_COUNT"

echo ""
echo "To exit cleanly:"
echo "  1. Have the business founder write .startup/go-live/solution-signoff.md"
echo "  2. Or reduce iteration to < 2 in .startup/state.json to bypass this check"
exit 2
