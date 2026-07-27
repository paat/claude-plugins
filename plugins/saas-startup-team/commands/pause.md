---
name: pause
description: "Record an intentional pause for a legacy session or cancel an in-flight lifecycle lease. Usage: /pause [reason]"
user_invocable: true
transitional: true
---

# /pause

New lifecycle runs do not use Stop-hook control. Prefer ending with an honest
`cancelled` or `incomplete` outcome and releasing the startup lease:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --release "startup:${PWD}" --state-dir .startup/leases \
  --owner-file .startup/leases/.owners/startup.owner
```

## Legacy session only

If `.startup/state.json` exists from a pre-lifecycle project and the human wants
it marked paused for operators:

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

If no state file and no live lease: report nothing to pause. Resume work with
`/startup` (lifecycle) rather than rehydrating loop counters.
