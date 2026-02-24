#!/bin/bash
# TaskCompleted hook: Validate that a task has proper deliverables before marking complete.
# For implementation/feature tasks, checks that a handoff exists for the CURRENT iteration.
# For go-live tasks, checks that solution-signoff.md exists.
# Exits 2 to block completion if deliverables are missing.

set -euo pipefail

# Read stdin with timeout to avoid hanging
INPUT=$(timeout 5 cat 2>/dev/null || echo '{}')
TASK_SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // empty' 2>/dev/null || true)

# If we can't determine the task, allow completion
if [ -z "$TASK_SUBJECT" ]; then
  exit 0
fi

# Resolve git root for absolute paths (MED-7)
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$GIT_ROOT" ]; then
  exit 0
fi

STARTUP_DIR="$GIT_ROOT/.startup"

# If .startup doesn't exist, allow completion
if [ ! -d "$STARTUP_DIR" ]; then
  exit 0
fi

# Get current iteration from state.json
STATE_FILE="$STARTUP_DIR/state.json"
ITERATION=0
if [ -f "$STATE_FILE" ]; then
  ITERATION=$(jq -r '.iteration // 0' "$STATE_FILE" 2>/dev/null || echo "0")
fi

# For go-live tasks, check solution signoff exists
if echo "$TASK_SUBJECT" | grep -qi "go.live\|launch\|release\|ship"; then
  if [ ! -f "$STARTUP_DIR/go-live/solution-signoff.md" ]; then
    echo "Task cannot be completed: solution signoff not found at $STARTUP_DIR/go-live/solution-signoff.md"
    exit 2
  fi
  exit 0
fi

# For implementation/feature tasks, check that a handoff exists for the current iteration (HIGH-2, HIGH-3)
# Expanded keyword matching to reduce false negatives
if echo "$TASK_SUBJECT" | grep -qi "roundtrip\|feature\|implement\|build\|create\|add\|develop\|design\|code\|integrate\|deploy"; then
  # Find the highest handoff number across ALL handoffs
  HIGHEST_HANDOFF=0
  for f in "$STARTUP_DIR/handoffs/"*.md; do
    if [ -e "$f" ]; then
      BASENAME=$(basename "$f")
      NUM=$(echo "$BASENAME" | grep -oE '^[0-9]+' || echo "0")
      NUM=$((10#$NUM))
      if [ "$NUM" -gt "$HIGHEST_HANDOFF" ]; then
        HIGHEST_HANDOFF=$NUM
      fi
    fi
  done

  # The highest handoff number should be >= current iteration
  if [ "$HIGHEST_HANDOFF" -lt "$ITERATION" ] && [ "$ITERATION" -gt 0 ]; then
    echo "Task cannot be completed: no handoff found for iteration $ITERATION."
    echo "Latest handoff is #$(printf '%03d' $HIGHEST_HANDOFF), but current iteration is $ITERATION."
    echo "Write your handoff to $STARTUP_DIR/handoffs/ before completing this task."
    exit 2
  fi

  # Also check at least one handoff exists at all
  if [ "$HIGHEST_HANDOFF" -eq 0 ]; then
    echo "Task cannot be completed: no handoff documents found in $STARTUP_DIR/handoffs/"
    exit 2
  fi
fi

exit 0
