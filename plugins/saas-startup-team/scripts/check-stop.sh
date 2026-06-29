#!/bin/bash
# Stop hook: Prevent premature session termination without solution signoff.
# Only enforces after iteration >= 2 to allow early testing/pausing.
# Exits 2 to block stop if conditions not met.

set -euo pipefail

# Read hook input (JSON on stdin). May be empty when invoked manually or from
# tests that don't pipe input.
HOOK_INPUT=$(timeout 2 cat 2>/dev/null || true)
TRANSCRIPT_PATH=""
if [ -n "$HOOK_INPUT" ]; then
  TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
fi

# Allow team members and subagents to stop — only block the main orchestrator.
# Team members are launched with --agent-id; the main session has no such flag.
# Walk up the process tree to detect if we're inside a team member agent.
# Uses /proc/PID/status (not /proc/PID/stat) because stat's comm field can
# contain spaces, breaking awk field numbering.
ppid_check=$PPID
for _ in 1 2 3 4 5; do
  [[ "$ppid_check" =~ ^[0-9]+$ ]] || break
  [ "$ppid_check" -le 1 ] && break
  if tr '\0' ' ' < /proc/"$ppid_check"/cmdline 2>/dev/null | grep -q -- '--agent-id'; then
    exit 0
  fi
  ppid_check=$(grep -m1 '^PPid:' /proc/"$ppid_check"/status 2>/dev/null | awk '{print $2}')
done

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
STATUS=$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null || true)

# Allow stop early — may be testing or initial setup (CRIT-2)
if [ "$ITERATION" -lt 2 ]; then
  exit 0
fi

# Explicit pause — the investor ran /pause to step away cleanly. Resume with
# /startup; while paused the Stop hook is inert.
if [ "$STATUS" = "paused" ]; then
  exit 0
fi

# If solution signoff exists, allow stop
if [ -f "$STARTUP_DIR/go-live/solution-signoff.md" ]; then
  exit 0
fi

# Transcript-aware bypass: when the orchestrator is using /loop +
# ScheduleWakeup to poll async subagents, every yield between wakeups lands
# here as a Stop event. Blocking it creates a runaway loop (observed: 742
# blocks in a single session). If the last assistant message scheduled a
# wakeup, it's yielding, not quitting — allow stop.
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  LAST_ASSISTANT_TOOLS=$(tail -n 200 "$TRANSCRIPT_PATH" 2>/dev/null \
    | jq -rs '[ .[] | select(.message.role=="assistant") ] | last | .message.content[]? | select(.type=="tool_use") | .name' 2>/dev/null \
    || true)
  if echo "$LAST_ASSISTANT_TOOLS" | grep -qx 'ScheduleWakeup'; then
    exit 0
  fi
fi

# Yield sentinel (issue #103): the transcript bypass above depends on the
# wakeup turn already being flushed to the transcript, which loses a flush race
# in the common case (the bypass then misses and the hook blocks every yield —
# the exact 742-block runaway). The ScheduleWakeup PostToolUse hook
# (mark-yield.sh) drops a self-expiring sentinel the moment the wakeup is
# scheduled, so this check does not depend on transcript timing. The sentinel
# holds an expiry epoch; while it is in the future the orchestrator is yielding,
# not quitting — allow stop. Once the wake fires the window passes and we resume
# blocking genuine premature quits (so a stale sentinel cannot disable the hook).
YIELD_SENTINEL="$STARTUP_DIR/.yielding"
if [ -f "$YIELD_SENTINEL" ]; then
  YIELD_EXPIRY=$(head -n1 "$YIELD_SENTINEL" 2>/dev/null || true)
  # Strict integer validation — a corrupt/garbage sentinel must not be coerced
  # into a bypass (don't strip non-digits; reject the whole value instead).
  case "$YIELD_EXPIRY" in
    ''|*[!0-9]*) YIELD_EXPIRY="" ;;
  esac
  if [ -n "$YIELD_EXPIRY" ]; then
    NOW=$(date +%s)
    if [ "$NOW" -lt "$YIELD_EXPIRY" ]; then
      exit 0
    fi
    # Expired: the yield window has passed. Remove the marker so it can't
    # linger, get committed, or confuse debugging — then fall through to block.
    rm -f "$YIELD_SENTINEL" 2>/dev/null || true
  fi
fi

# Block stop — session is mid-progress without signoff

# Show handoff count
HANDOFF_COUNT=0
for f in "$STARTUP_DIR/handoffs/"*.md; do
  [ -e "$f" ] && HANDOFF_COUNT=$((HANDOFF_COUNT + 1))
done

# Show signoff count
SIGNOFF_COUNT=0
for f in "$STARTUP_DIR/signoffs/"roundtrip-*.md; do
  [ -e "$f" ] && SIGNOFF_COUNT=$((SIGNOFF_COUNT + 1))
done

cat >&2 <<EOF
{"systemMessage":"Cannot stop: the startup loop is at iteration $ITERATION (phase: $PHASE) without a solution signoff. Handoffs written: $HANDOFF_COUNT. Features signed off: $SIGNOFF_COUNT. To exit cleanly: (1) Have the business founder write .startup/go-live/solution-signoff.md, or (2) reduce iteration to < 2 in .startup/state.json to bypass this check."}
EOF
exit 2
