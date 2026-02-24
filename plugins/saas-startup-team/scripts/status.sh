#!/bin/bash
# Status script: Report current state of the startup loop.
# Reads .startup/state.json and summarizes handoffs, signoffs, and human tasks.
# Includes state/handoff consistency validation (MED-8).

set -euo pipefail

# Resolve git root for absolute paths (MED-7)
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$GIT_ROOT" ]; then
  echo "Not in a git repository. Cannot determine project root."
  exit 1
fi

STARTUP_DIR="$GIT_ROOT/.startup"

if [ ! -d "$STARTUP_DIR" ]; then
  echo "No active startup session found. Run /saas-startup-team:startup to begin."
  exit 0
fi

echo "=== SaaS Startup Team Status ==="
echo ""

# State
ITERATION=0
if [ -f "$STARTUP_DIR/state.json" ]; then
  echo "--- Loop State ---"
  jq '.' "$STARTUP_DIR/state.json"
  ITERATION=$(jq -r '.iteration // 0' "$STARTUP_DIR/state.json" 2>/dev/null || echo "0")
  echo ""
fi

# Handoffs
echo "--- Handoffs ---"
HANDOFF_COUNT=0
HIGHEST_HANDOFF=0
for f in "$STARTUP_DIR/handoffs/"*.md; do
  if [ -e "$f" ]; then
    HANDOFF_COUNT=$((HANDOFF_COUNT + 1))
    BASENAME=$(basename "$f")
    NUM=$(echo "$BASENAME" | grep -oE '^[0-9]+' || echo "0")
    NUM=$((10#$NUM))
    if [ "$NUM" -gt "$HIGHEST_HANDOFF" ]; then
      HIGHEST_HANDOFF=$NUM
    fi
  fi
done
echo "Total handoffs: $HANDOFF_COUNT"
if [ "$HANDOFF_COUNT" -gt 0 ]; then
  for f in "$STARTUP_DIR/handoffs/"*.md; do
    [ -e "$f" ] && echo "  $(basename "$f")"
  done
fi
echo ""

# State/handoff consistency check (MED-8)
if [ "$ITERATION" -gt 0 ] && [ "$HANDOFF_COUNT" -gt 0 ]; then
  if [ "$HIGHEST_HANDOFF" -lt "$ITERATION" ]; then
    echo "WARNING: state.json says iteration $ITERATION but highest handoff is #$(printf '%03d' $HIGHEST_HANDOFF)."
    echo "  State may be out of sync with actual handoff progress."
    echo ""
  fi
  # Check for gaps in handoff numbering
  EXPECTED_SEQUENCE=""
  ACTUAL_NUMBERS=""
  for f in "$STARTUP_DIR/handoffs/"*.md; do
    if [ -e "$f" ]; then
      BASENAME=$(basename "$f")
      NUM=$(echo "$BASENAME" | grep -oE '^[0-9]+' || true)
      if [ -n "$NUM" ]; then
        ACTUAL_NUMBERS="$ACTUAL_NUMBERS $((10#$NUM))"
      fi
    fi
  done
  # Sort and check for duplicates
  SORTED=$(echo "$ACTUAL_NUMBERS" | tr ' ' '\n' | sort -n | uniq)
  DUPES=$(echo "$ACTUAL_NUMBERS" | tr ' ' '\n' | sort -n | uniq -d)
  if [ -n "$DUPES" ]; then
    echo "WARNING: Duplicate handoff numbers detected: $DUPES"
    echo ""
  fi
fi

# Signoffs
echo "--- Roundtrip Signoffs ---"
SIGNOFF_COUNT=0
for f in "$STARTUP_DIR/signoffs/"roundtrip-*.md; do
  [ -e "$f" ] && SIGNOFF_COUNT=$((SIGNOFF_COUNT + 1))
done
echo "Features signed off: $SIGNOFF_COUNT"
if [ "$SIGNOFF_COUNT" -gt 0 ]; then
  for f in "$STARTUP_DIR/signoffs/"roundtrip-*.md; do
    [ -e "$f" ] && echo "  $(basename "$f")"
  done
fi
echo ""

# Go-live
echo "--- Go-Live Status ---"
if [ -f "$STARTUP_DIR/go-live/solution-signoff.md" ]; then
  echo "SOLUTION SIGNOFF: EXISTS - Ready for go-live!"
else
  echo "SOLUTION SIGNOFF: Not yet written"
fi
echo ""

# Human tasks
echo "--- Human Tasks ---"
if [ -f "$STARTUP_DIR/human-tasks.md" ]; then
  PENDING=$(grep -c '^\- \[ \]' "$STARTUP_DIR/human-tasks.md" 2>/dev/null || echo "0")
  COMPLETED=$(grep -c '^\- \[x\]' "$STARTUP_DIR/human-tasks.md" 2>/dev/null || echo "0")
  echo "Pending: $PENDING | Completed: $COMPLETED"
else
  echo "No human tasks file found"
fi
echo ""

# Research docs
echo "--- Research Documents ---"
if [ -d "$STARTUP_DIR/docs" ]; then
  DOC_COUNT=0
  for f in "$STARTUP_DIR/docs/"*.md; do
    [ -e "$f" ] && { echo "  $(basename "$f")"; DOC_COUNT=$((DOC_COUNT + 1)); }
  done
  [ "$DOC_COUNT" -eq 0 ] && echo "  (none)"
else
  echo "No research docs yet"
fi

# Idle loop tracking
echo ""
echo "--- Agent Health ---"
for TEAMMATE in business-founder tech-founder; do
  IDLE_FILE="$STARTUP_DIR/.idle-count-$TEAMMATE"
  if [ -f "$IDLE_FILE" ]; then
    IDLE_COUNT=$(cat "$IDLE_FILE" 2>/dev/null || echo "0")
    if [ "$IDLE_COUNT" -gt 0 ]; then
      echo "  $TEAMMATE: $IDLE_COUNT consecutive idle(s) without progress"
    else
      echo "  $TEAMMATE: healthy"
    fi
  else
    echo "  $TEAMMATE: no idle data"
  fi
done
