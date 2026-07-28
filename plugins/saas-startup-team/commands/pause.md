---
name: pause
description: "Record an intentional pause for a legacy session. Usage: /pause [reason]"
user_invocable: true
transitional: true
---

# /pause

New lifecycle runs do not use Stop-hook control or whole-pass leases. Prefer ending
with an honest `cancelled` or `incomplete` outcome. Do not hard-reset or clean the
primary checkout on cancel.

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

If no state file: report nothing to pause. Resume with `/startup` (lifecycle).

Leftover pre-0.90.22 files under `.startup/leases/` are inert after #389 (single-flight
removed); they do not block work. Operators may delete that directory; do not invent a
new lease runtime.
