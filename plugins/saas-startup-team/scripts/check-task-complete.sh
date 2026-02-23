#!/bin/bash
# TaskCompleted hook: Validate that a task has proper deliverables before marking complete.
# For roundtrip tasks, checks that both an implementation handoff and roundtrip signoff exist.
# Exits 2 to block completion if deliverables are missing.

set -euo pipefail

# Read stdin JSON
INPUT=$(cat)
TASK_SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // empty' 2>/dev/null || true)

# If we can't determine the task, allow completion
if [ -z "$TASK_SUBJECT" ]; then
  exit 0
fi

# Check that .startup directory exists
if [ ! -d ".startup" ]; then
  exit 0
fi

# For roundtrip tasks, check that signoff exists
if echo "$TASK_SUBJECT" | grep -qi "roundtrip\|feature\|implement"; then
  SIGNOFF_COUNT=$(ls .startup/signoffs/roundtrip-*.md 2>/dev/null | wc -l || echo "0")
  HANDOFF_COUNT=$(ls .startup/handoffs/ 2>/dev/null | wc -l || echo "0")

  if [ "$HANDOFF_COUNT" -eq 0 ]; then
    echo "Task cannot be completed: no handoff documents found in .startup/handoffs/"
    exit 2
  fi
fi

# For go-live tasks, check solution signoff exists
if echo "$TASK_SUBJECT" | grep -qi "go.live\|launch\|release\|ship"; then
  if [ ! -f ".startup/go-live/solution-signoff.md" ]; then
    echo "Task cannot be completed: solution signoff not found at .startup/go-live/solution-signoff.md"
    exit 2
  fi
fi

exit 0
