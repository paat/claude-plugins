# Delivery Routing and Events

Load this reference only after a workflow's model-free probe finds work.

## Classify before dispatch

Keep task text and labels in temporary local files; never copy either into telemetry.

```bash
task_file="$(mktemp)"
labels_file="$(mktemp)"
printf '%s\n' "$delivery_task" > "$task_file"
printf '%s\n' "$delivery_labels_json" > "$labels_file"
route_rc=0
route_json="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-route.sh" classify \
  --mode autonomous --task-file "$task_file" --labels-file "$labels_file")" || route_rc=$?
rm -f "$task_file" "$labels_file"
```

- Exit 2 is a routing failure: stop before dispatch.
- Exit 20 is an accepted deep classification. Set `PROFILE=deep`; do not retry
  classification.
- On exit 0, read `PROFILE` from `.profile`. `mechanical` runs the named script with
  no worker. `light`, `standard`, and `deep` are worker profiles.
- `ROUTING_REASONS` is `.reasons | join(",")`; reasons are stable codes, never task
  excerpts.
- For autonomous work, `ui_touch:true` is never eligible for a light mutation even if
  a later containment check accepts bounded UI text/CSS. That broader result exists
  only for interactive `/tweak`.

## Record only privacy-safe events

Create one stable ID after classification and before the first worker:

```bash
RUN_ID="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)"
export SAAS_RUN_ID="$RUN_ID" SAAS_ROUTING_REASONS="$ROUTING_REASONS"
```

Do not emit a worker event on a no-op path. `codex-run-role.sh` records its own
started/incomplete and terminal event. Around Claude roles, call `agent-events.sh
append` with only stable command/phase codes, profile, writer ID, attempt, requested
and effective provider/model/effort, status codes, timestamps/token counts when known,
and terminal outcome. Unknown effective or token values remain null. Never pass task
text, issue content, filenames, paths, URLs, prompts, diffs, customer data, or project
identity.

Helpers accept optional `SAAS_PARENT_RUN_ID`. When present it must be a canonical
`^run-[0-9a-f]{32}$` root different from the child `SAAS_RUN_ID`, and every helper
event append includes `--parent-run-id "$SAAS_PARENT_RUN_ID"` through one shared local
argument array. Leave it absent only for a root or standalone unparented helper. A root
`pass-outcome` is authoritative: retrieve it with `terminal --run-id
"$RUN_ID"`, then record final wall duration and optional root token usage exactly once
with `account --run-id "$RUN_ID" --duration-ms "$DURATION_MS" [--total-tokens
"$TOTAL_TOKENS"]`. Never sum child tokens. Read all authoritative root outcomes with
`terminals`; it skips and reports incomplete root `pass-outcome` lifecycles while
still failing on malformed or conflicting records. A single-run `terminal` lookup
remains strict and fails when that requested root is incomplete.

`terminal` / `terminals` project a read-only `pass_disposition` on every root
`pass-outcome` (not stored; never append it). Outer coordinators such as
`/maintain-loop` continue only on `pass-complete` (issue #373):

| `pass_disposition` | From `outcome` / `terminal_reason` |
|---|---|
| `pass-complete` | `success` / null |
| `no-work` | `no-op` / null |
| `limit` | `skipped` / null, or `failure` / `budget_exhausted` |
| `pass-blocked` | `blocked` / any registered reason |
| `failure` | `failure` (other reasons), `escalated`, `cancelled` |
| `unknown` | anything else (fail closed) |

`terminal_reason` uses this finite privacy-safe registry:
`invalid_workflow_state`, `context_binding_violation`, `false_success`, `probe_failed`,
`triage_failed`, `delivery_failed`, `verification_failed`, `lease_conflict`,
`receipt_conflict`, `budget_exhausted`, `timeout`, `rate_limited`, `delivery_hold`,
`cancelled`, `escalated`, and `unknown_failure`. Any other supplied value normalizes to
`other`; arbitrary code-shaped strings are never exposed. Downstream recurrence logic
must ignore null and `other` terminal reasons. Harvesting recurrence is outside the
event library.

The event library and Codex launcher append directly to the canonical ignored runtime
paths. Do not write `.startup/runs/` directly or
invent a second buffering path. The default event path is always in the primary
checkout; an explicit `--events` path remains an override.

When invoking tribunal inline, set optional `TRIBUNAL_CALLER_PROVIDER`,
`TRIBUNAL_CALLER_MODEL`, and `TRIBUNAL_CALLER_EFFORT` from the actual calling context.
They are informational and never select an arbiter.

## Contain before external mutation

For a light implementation, stage only its intended files and run:

```bash
diff_rc=0
diff_route="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-route.sh" check-diff \
  --base "$BASE_SHA" --cached)" || diff_rc=$?
```

Exit 2 is a routing failure. Exit 20, or `ui_touch:true` on an autonomous light route,
requires one deep restart. Before restarting, write the workflow's escalation artifact,
close any opened PR, delete its remote branch, reset the worktree to the recorded base,
and preserve queue eligibility. A missing escalation artifact is a hard failure. Never
perform a second light-to-deep restart for the same work unit.
