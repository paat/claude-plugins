---
name: lifecycle
description: "Thin conditional lifecycle — brief intake, discovery only on evidence gaps, specialists on triggers, then deliver. Entrypoint: /startup."
---

# Lifecycle

Host-neutral conductor for `/startup`. Replaces founder-loop orchestration.
Does **not** read or write `active_role`, iteration counters, numbered handoffs,
Stop/yield signoff, or conversational mirror state. Prefer Git issue/PR/CI facts
and skill outputs over `.startup/state.json`.

Optional presentation: nontechnical users may be addressed as a silent observer
("silent investor" language only) — never as a control-plane role.

## Phases

```
Intake → Conditional discovery → Triggered specialists → Deliver → Report
```

### 1. Intake

1. Health preflight: `scripts/health-preflight.sh --require-gh --check-sync`
   (Codex: add `--require-codex`). Blockers stop; unrelated warnings may continue.
2. Claim session lease only while mutating project state:
   `scripts/single-flight.sh --acquire "startup:${PWD}" --state-dir .startup/leases
   --owner-file .startup/leases/.owners/startup.owner --ttl-seconds 1800`.
   Heartbeat after durable writes; `--release` on terminal complete/cancel/fail.
   Do not hold the lease across unbounded human waits.
3. Capture goal from `$ARGUMENTS`, existing `docs/business/brief.md`, or
   `scripts/market-scout.sh` when no concrete need exists. Ask the human only
   when no demand evidence exists.
4. Idempotent scaffold when missing: `/bootstrap`, ensure git root, ensure
   engineering principles via `scripts/ensure-engineering-principles.sh --root .`.
5. Legacy context (read-only): `scripts/legacy-import.sh` — brief, workflows,
   signoffs, research paths. Never rehydrate a delivery state machine from import.

### 2. Scope and path selection

Apply `../../templates/delivery-scope-planning.md` and
`../../templates/delivery-scope-contract.md`. Fill `Done`, `Preserve`,
`Out of Scope` before research or specialists.

Classify with the deterministic helper (do not invent a state machine):

```bash
bash scripts/lifecycle-path.sh [--concrete] [--evidence-gap] [--has-goal] [--has-brief] [--scout-empty]
# prints: fast | discovery | blocked
```

| Path | When | Action |
|------|------|--------|
| **Fast** | Concrete feature/fix with clear outcome; existing repo behavior establishes Why | Skip broad market research; go to Plan under deliver |
| **Discovery** | Material evidence gap that can change `Done` (ICP, pricing, competitor, legal constraint, greenfield product) | Load `../product-discovery/SKILL.md` only for that gap |
| **Blocked intake** | No idea and scout empty | Honest incomplete; release lease; stop |

Small scoped work **always** prefers Fast. Do not force founder research phases.

### 3. Specialist triggers (objective only)

Load a specialist skill only when its own Triggers fire. Never load all by default.

| Skill | Load when |
|-------|-----------|
| `product-discovery` | Evidence gap or growth strategy assets missing under discovery path |
| `lawyer` | Tier-A legal/compliance claim or Estonian/EU legal risk on the changed surface |
| `ux-review` | UI audit request or pre-merge UI design-review |
| `product-acceptance` | Independent post-build QA / go-live judgment (never the implementer) |
| `growth` | Explicit growth objective after product exists (or prelive staging) |

Technical implementation is always `../deliver/SKILL.md` with
`SAAS_DELIVER_ENTRYPOINT=startup-impl` (or `improve`/`goal-deliver`/`tweak` when
those entrypoints invoke deliver directly).

### 4. Deliver

Delegate Plan → isolated Build → Independent Review → Release per
`../deliver/SKILL.md` and `../../references/deliver/graph.md`.
Supervisor owns commits, PR/merge, and release gates. Workers do not write loop
state.

### 5. Terminal outcomes (honest)

| Outcome | Report |
|---------|--------|
| `complete` | Done met; required gates passed; evidence paths named |
| `incomplete` | What shipped, what remains, why stopped mid-path |
| `blocked` | Environment/human/authority blocker with remediation |
| `cancelled` | Explicit cancel; release lease; no false success |
| `budget_exhausted` | Token/iteration/time budget hit; partial result + next step |

Never claim success without gate evidence. Never invent customer validation.

## Hard bans

- No `active_role`, iteration counters, phase enums, or numbered conversational handoffs
- No Stop-hook / ScheduleWakeup / yield-sentinel control
- No founder personas, colors, prescribed dialogue, or model pins in this skill
- No unconditional product-wide market or legal audit
- Do not delete or silently reinterpret existing `.startup/*` files

## Host notes

- Claude Code: one-shot Task/Agent workers with capability skills; no TeamCreate
- Codex: skill load or `scripts/codex-cast.sh` with explicit worktree/mode/model/effort
- Cancellation: on user cancel or lease refusal, release leases and report `cancelled`
- Budget: if context or wall budget is exhausted mid-delivery, stop with
  `budget_exhausted` and the last verified artifact paths
