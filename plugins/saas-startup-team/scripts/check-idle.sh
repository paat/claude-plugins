#!/bin/bash
# TeammateIdle hook: Validate that a founder wrote their handoff for the CURRENT
# iteration before going idle. Detects stuck-in-idle-loop patterns and escalates.
# Exits 2 to block idle if handoff is missing or agent is stuck.

set -euo pipefail

# Read stdin with timeout to avoid hanging (LOW-7)
INPUT=$(timeout 5 cat 2>/dev/null || echo '{}')
TEAMMATE_NAME=$(echo "$INPUT" | jq -r '.teammate_name // empty' 2>/dev/null || true)

# If we can't determine the teammate, allow idle (don't block on hook failure)
if [ -z "$TEAMMATE_NAME" ]; then
  exit 0
fi

# Resolve git root for absolute paths (MED-7)
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$GIT_ROOT" ]; then
  exit 0
fi

STARTUP_DIR="$GIT_ROOT/.startup"

# If .startup doesn't exist, allow idle (not initialized)
if [ ! -d "$STARTUP_DIR" ]; then
  exit 0
fi

# Get current iteration and phase from state.json
STATE_FILE="$STARTUP_DIR/state.json"
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

ITERATION=$(jq -r '.iteration // 0' "$STATE_FILE" 2>/dev/null || echo "0")
PHASE=$(jq -r '.phase // "research"' "$STATE_FILE" 2>/dev/null || echo "research")

# Determine handoff pattern for this teammate
if [ "$TEAMMATE_NAME" = "business-founder" ]; then
  PATTERN="$STARTUP_DIR/handoffs/*-business-to-tech.md"
elif [ "$TEAMMATE_NAME" = "tech-founder" ]; then
  PATTERN="$STARTUP_DIR/handoffs/*-tech-to-business.md"
else
  # Unknown teammate, allow idle
  exit 0
fi

# Find the highest-numbered handoff from this teammate
HIGHEST_HANDOFF=0
# shellcheck disable=SC2086
for f in $PATTERN; do
  if [ -e "$f" ]; then
    BASENAME=$(basename "$f")
    # Extract the leading number (e.g., "003" from "003-business-to-tech.md")
    NUM=$(echo "$BASENAME" | grep -oE '^[0-9]+' || echo "0")
    # Remove leading zeros for arithmetic
    NUM=$((10#$NUM))
    if [ "$NUM" -gt "$HIGHEST_HANDOFF" ]; then
      HIGHEST_HANDOFF=$NUM
    fi
  fi
done

# --- Idle loop detection (HIGH-7) ---
IDLE_COUNT_FILE="$STARTUP_DIR/.idle-count-$TEAMMATE_NAME"
IDLE_HANDOFF_COUNT_FILE="$STARTUP_DIR/.idle-handoff-snapshot-$TEAMMATE_NAME"

# Count total handoff files (all teammates) to detect any progress
TOTAL_HANDOFFS=0
for f in "$STARTUP_DIR/handoffs/"*.md; do
  [ -e "$f" ] && TOTAL_HANDOFFS=$((TOTAL_HANDOFFS + 1))
done

# Check if progress was made since last idle (new files appeared)
PREV_HANDOFF_COUNT=0
if [ -f "$IDLE_HANDOFF_COUNT_FILE" ]; then
  PREV_HANDOFF_COUNT=$(cat "$IDLE_HANDOFF_COUNT_FILE" 2>/dev/null || echo "0")
fi

if [ "$TOTAL_HANDOFFS" -gt "$PREV_HANDOFF_COUNT" ]; then
  # Progress was made — reset idle counter
  echo "0" > "$IDLE_COUNT_FILE"
fi

# Increment idle counter
CURRENT_IDLE=0
if [ -f "$IDLE_COUNT_FILE" ]; then
  CURRENT_IDLE=$(cat "$IDLE_COUNT_FILE" 2>/dev/null || echo "0")
fi
CURRENT_IDLE=$((CURRENT_IDLE + 1))
echo "$CURRENT_IDLE" > "$IDLE_COUNT_FILE"
echo "$TOTAL_HANDOFFS" > "$IDLE_HANDOFF_COUNT_FILE"

# If 3+ consecutive idles without progress, block and escalate
if [ "$CURRENT_IDLE" -ge 3 ]; then
  echo "ESCALATION: $TEAMMATE_NAME has gone idle $CURRENT_IDLE times without producing any new output."
  echo "This agent appears stuck in an idle loop. The team lead should:"
  echo "  1. Check if the agent is responsive (send a direct message)"
  echo "  2. If unresponsive, consider restarting the agent"
  echo "  3. Escalate to the investor if the problem persists"
  echo "Resetting idle counter. Next 3 consecutive idles will trigger again."
  echo "0" > "$IDLE_COUNT_FILE"
  exit 2
fi

# --- Iteration-aware handoff check (CRIT-3, HIGH-1) ---

# For iteration 0: only enforce if phase is past "research" (HIGH-1)
# During research phase at iteration 0, the business founder hasn't been asked
# to produce a handoff yet, so allow idle.
if [ "$ITERATION" -eq 0 ]; then
  if [ "$PHASE" = "research" ]; then
    exit 0
  fi
  # Phase is past research but iteration is still 0 — handoff expected
  if [ "$HIGHEST_HANDOFF" -lt 1 ]; then
    echo "You must write your first handoff before going idle. Phase is '$PHASE' but no handoff has been written."
    echo "Expected: $STARTUP_DIR/handoffs/001-*-to-*.md"
    exit 2
  fi
  exit 0
fi

# For iteration > 0: the highest handoff number must be >= current iteration (CRIT-3)
if [ "$HIGHEST_HANDOFF" -lt "$ITERATION" ]; then
  echo "You must write your handoff for iteration $ITERATION before going idle."
  echo "Latest handoff from $TEAMMATE_NAME is #$(printf '%03d' $HIGHEST_HANDOFF), but current iteration is $ITERATION."
  echo "Expected: $STARTUP_DIR/handoffs/$(printf '%03d' $ITERATION)-*-to-*.md"
  exit 2
fi

exit 0
