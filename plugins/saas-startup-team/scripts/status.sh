#!/bin/bash
# Status script: Report current state of the startup loop.
# Reads .startup/state.json and summarizes handoffs, signoffs, and human tasks.

set -euo pipefail

STARTUP_DIR=".startup"

if [ ! -d "$STARTUP_DIR" ]; then
  echo "No active startup session found. Run /saas-startup-team:startup to begin."
  exit 0
fi

echo "=== SaaS Startup Team Status ==="
echo ""

# State
if [ -f "$STARTUP_DIR/state.json" ]; then
  echo "--- Loop State ---"
  jq '.' "$STARTUP_DIR/state.json"
  echo ""
fi

# Handoffs
echo "--- Handoffs ---"
HANDOFF_COUNT=0
for f in "$STARTUP_DIR/handoffs/"*.md; do
  [ -e "$f" ] && HANDOFF_COUNT=$((HANDOFF_COUNT + 1))
done
echo "Total handoffs: $HANDOFF_COUNT"
if [ "$HANDOFF_COUNT" -gt 0 ]; then
  for f in "$STARTUP_DIR/handoffs/"*.md; do
    [ -e "$f" ] && echo "  $(basename "$f")"
  done
fi
echo ""

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
