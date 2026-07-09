---
name: mission-status
description: Read-only view of mission-control state — slot occupancy, pool quotas and backoffs, cooldowns, pending admissions with veto deadlines, and recent dispatch outcomes. Usage: /mission-status [config-path]
user_invocable: true
---

# /mission-status — Portfolio Scheduler Status

Read-only. Locate the host's portfolio config: use the argument if given,
else `$MISSION_CONTROL_CONFIG`, else ask the user for the path. Then run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mission-control.sh" status --config "<path>"
```

Present the output as-is, then add one short interpretation line only when
something needs attention (a slot stuck RUNNING for hours, a pool in
backoff, a pending admission near its veto deadline). Do not paraphrase
healthy output. Never run `tick` or `arm` from this command; never modify
state. Token-frugal: this is one script call plus a short summary.
