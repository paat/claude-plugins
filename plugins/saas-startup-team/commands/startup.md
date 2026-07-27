---
name: startup
description: "Thin conditional lifecycle — intake, discovery only on evidence gaps, specialists on triggers, then deliver. Usage: /startup [goal]"
user_invocable: true
transitional: true
---

# /startup

Be token-frugal. Load the lifecycle skill once and follow it with `$ARGUMENTS`:

```
Skill('saas-startup-team:lifecycle')
```

or read `${CLAUDE_PLUGIN_ROOT}/skills/lifecycle/SKILL.md`.

The skill owns Intake → Conditional discovery → Triggered specialists → Deliver →
Report. Do not restate its phases here.

## Minimal host glue

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --check-sync
```

Codex: add `--require-codex`. Claim/release the startup lease only while mutating
project state (see lifecycle skill). For legacy brief/workflow/signoff context:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/legacy-import.sh" --json
```

Implementation resolves to `skills/deliver/SKILL.md` with
`SAAS_DELIVER_ENTRYPOINT=startup-impl`. Product discovery, legal, growth, UX, and
product-acceptance load only when their objective triggers fire.

## Hard bans for this entrypoint

- Do **not** initialize or update `.startup/state.json` `active_role`, iteration,
  phase, or numbered conversational handoffs for new runs
- Do **not** use Stop-hook / yield / ScheduleWakeup loop control
- Do **not** force broad market research for small scoped work
- Existing `.startup/*` files are never deleted or silently reinterpreted;
  `legacy-import.sh` is read-only

Optional presentation: address nontechnical users as a silent observer if helpful.
That language is not a control plane.
