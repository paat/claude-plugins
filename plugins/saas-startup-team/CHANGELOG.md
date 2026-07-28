# Changelog

## 1.2.2 — 2026-07-28

- `/epic` close-out: after merge, poll deploy on exact `merge_sha` and live-verify
  before closing children/epic (same unattended turn).

## 1.2.1 — 2026-07-28

- `/epic-compose`: scan → file focused epic → auto-run `/epic` (`--dry-run`/`--compose-only`).

## 1.1.1 — 2026-07-28

- epic_active: marker-only blockers; JSON fail-closed; check fixture tests.

## 1.1.0 — 2026-07-28

### Added

- **`epic` skill** (`/epic <n>`, `/epic --plan <n>`): serial multi-issue GitHub
  epic train for any SaaS product repo. One branch + one draft PR; per-child
  `deliver` without mid-train merge to main; tribunal hard-required for
  execution; children closed only after epic PR merge.
- `scripts/epic_plan.py` — checklist parser; `epic_active.py` — active-epic guard.
- `docs/legacy/epic-invariants.md`; deliver/maintain refuse when epic train active.
- Serial only (concurrency=1); no client pilot in 1.1.0 (human approval first).

## 1.0.0 — 2026-07-28

**Major version break.** Portable Plan → Build → Independent Review runtime with
bounded maintenance and deterministic gates. Orchestration state machines, founder
personas, and primary-only control plane are gone.

### Breaking

- Removed commands (no in-plugin replacement): `maintain-loop` as a scheduler
  product, `pause`, `nudge` (transitional skills remain as thin advisory aliases
  only), `harvest`, `session-insights`, `lessons-*`, `learnings-*`, Stop/yield
  control, auto-commit hooks, browser-operator personas.
- Canonical delivery is the `deliver` skill; `goal-deliver`, `improve`, and
  `tweak` are generated aliases into it.
- `startup` is a thin conditional lifecycle (`lifecycle` skill), not a founder loop.
- `maintain` is one bounded externally scheduled tick (`maintain-v3`); no
  primary-only leases, claims, or compatibility receipts.
- `.startup/state.json` delivery state machine, numbered handoffs, and active_role
  are not revived. Git/PR/CI/deployment facts are authoritative.
- Hooks collapse to one path-scoped dispatcher (`hooks/dispatch.sh`) +
  `scripts/gate.sh` (schema · PII · legal · spend · regression · acceptance · release).
- Self-improvement, custom telemetry, and evaluation tooling removed from runtime.

### Migration

See `docs/legacy/migration-1.0.0.md` for:

- Removed command → canonical replacement map
- State-machine removal and what remains under `.startup/`
- External scheduling for maintain/digest/monitor
- Worktree isolation behavior
- Legacy import (`legacy-import.sh`) and receipt drain (`legacy-drain.sh`)
- Rollback constraints (no silent re-hydration of 0.x orchestration)

### Budget

- LOC budgets enter **post-1.0** phase; `current_ratchet` = observed values.
- `scripts_sh_loc` release_target recalibrated to **9200** (hard ceiling **9500**)
  under one-shot `release_target_allow_raise` (issue #392, Sol ultra 2026-07-28):
  retained safety-gate scripts cannot hit the original 8000 estimate without
  behavior-dense rewrites. Prompt surface, wrappers, agents, and total surface
  meet or beat original targets.
- Skill domain references moved to plugin-root `references/<domain>/` (loaded on
  demand; not part of always-on skill prompt surface).
- Dead `scripts/commit-artifact.sh` removed.

### Preserved invariants

Legal evidence tiers, PII gates, spend envelopes, regression evidence, acceptance
packs, exact-head merge, deployment proof, issue close observation, crash recovery
via immutable release facts, and isolated worktree maintenance.

## 0.90.x

Pre-1.0 thinning train (#381–#391). See git history and
`docs/legacy/migration-1.0-*.md` for intermediate migration notes.
