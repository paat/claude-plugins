---
name: pause
description: Pause an active /startup loop so you can exit the session cleanly without completing the product. Resume with /startup. Usage: /pause [reason]
user_invocable: true
---

# /pause — Pause the /startup Loop

Mark the current `/startup` session as paused so the investor can exit without finishing the product and without hacking `state.json`. While paused, the Stop hook (`check-stop.sh`) is inert; `/startup` detects the paused status on resume and continues where it left off.

## Pre-Flight

1. Verify `.startup/state.json` exists — if not:
   > No `/startup` session found. Nothing to pause. Run `/startup` to begin a new one.

2. Read current status from `state.json`. If already `"paused"`:
   > Already paused. Run `/startup` to resume.

## Set paused status

Overwrite `status` in `.startup/state.json`. If the investor passed a reason with the command, also record it under `paused_reason`; otherwise leave that field out.

```bash
if [ -n "${PAUSE_REASON:-}" ]; then
  jq --arg r "$PAUSE_REASON" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status = "paused" | .paused_at = $t | .paused_reason = $r' \
    .startup/state.json > .startup/state.json.tmp \
    && mv .startup/state.json.tmp .startup/state.json
else
  jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status = "paused" | .paused_at = $t | del(.paused_reason)' \
    .startup/state.json > .startup/state.json.tmp \
    && mv .startup/state.json.tmp .startup/state.json
fi
```

## Report

Read the current state and report to the investor (English) with the iteration, phase, handoff count, and how to resume:

```bash
ITER=$(jq -r '.iteration' .startup/state.json)
PHASE=$(jq -r '.phase' .startup/state.json)
HANDOFFS=$(ls .startup/handoffs/*.md 2>/dev/null | wc -l)
```

> Paused at iteration N (phase: X, handoffs: H). State.json status = paused. Exit freely — the Stop hook is inert while paused. Resume with `/startup`.

## Notes

- `/pause` does not kill subagents. If you have an Agent running in the background, finish or abort it before walking away so the handoff isn't lost.
- The auto-commit hook still runs on Writes during `/pause`; nothing is lost.
- `/pause` is for the investor. The orchestrator yielding between `ScheduleWakeup` polls is handled automatically by the Stop hook's transcript-aware bypass — the investor does not need to `/pause` just to let Claude wait for a subagent.
