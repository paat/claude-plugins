#!/bin/bash
# PostToolUse hook (matcher: ScheduleWakeup).
#
# When the /startup orchestrator yields control via ScheduleWakeup to poll an
# async subagent, the upcoming turn-end fires the Stop hook (check-stop.sh).
# check-stop has a transcript-aware bypass, but it depends on the wakeup turn
# already being flushed to the transcript — and under a flush/ordering race it
# is not, so the bypass misses and the hook blocks every yield (issue #103,
# "observed: 742 blocks in a single session").
#
# This hook drops a self-expiring sentinel the moment the wakeup is scheduled,
# giving check-stop an authoritative signal that does not depend on transcript
# timing. The sentinel records an expiry epoch (now + delaySeconds); once the
# wake fires that window passes and the Stop hook resumes blocking genuine
# premature quits.

set -euo pipefail

# Read hook input (JSON on stdin). May be empty when invoked manually.
HOOK_INPUT=$(timeout 2 cat 2>/dev/null || true)

# Only the main orchestrator's yields matter: team members (launched with
# --agent-id) are exempt from the Stop block entirely, so they must not write
# the orchestrator's yield sentinel. Walk up the process tree to detect them.
ppid_check=$PPID
for _ in 1 2 3 4 5; do
  [[ "$ppid_check" =~ ^[0-9]+$ ]] || break
  [ "$ppid_check" -le 1 ] && break
  if tr '\0' ' ' < /proc/"$ppid_check"/cmdline 2>/dev/null | grep -q -- '--agent-id'; then
    exit 0
  fi
  ppid_check=$(grep -m1 '^PPid:' /proc/"$ppid_check"/status 2>/dev/null | awk '{print $2}')
done

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$GIT_ROOT" ] || exit 0

STARTUP_DIR="$GIT_ROOT/.startup"
# No-op outside an initialized startup project.
[ -d "$STARTUP_DIR" ] || exit 0

# Extract the scheduled delay; default to the documented 270s poll window
# (rounded to 300 for headroom) when absent or non-numeric.
DELAY=""
if [ -n "$HOOK_INPUT" ]; then
  DELAY=$(echo "$HOOK_INPUT" | jq -r '.tool_input.delaySeconds // empty' 2>/dev/null || true)
fi
case "$DELAY" in
  ''|*[!0-9]*) DELAY=300 ;;
esac
# Clamp to a sane window. The sentinel only needs to cover the single turn-end
# that fires immediately after this wakeup, so a short span suffices; the cap
# bounds how long a stale sentinel can linger and stops a malformed/hostile
# payload (e.g. delaySeconds: 999999999) from disabling the Stop block.
[ "$DELAY" -lt 60 ] && DELAY=60
[ "$DELAY" -gt 600 ] && DELAY=600

NOW=$(date +%s)
EXPIRY=$((NOW + DELAY))
printf '%s\n' "$EXPIRY" > "$STARTUP_DIR/.yielding" 2>/dev/null || true
exit 0
