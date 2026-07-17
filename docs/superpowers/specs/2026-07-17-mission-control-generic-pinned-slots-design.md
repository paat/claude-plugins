# Mission-control: generic pinned slots + per-project subscription pools

Date: 2026-07-17
Status: approved (investor session 2026-07-16/17)
Repo touched: this repo (mission-control plugin). Rollout config lives in the
steering repo (`/mnt/data/ai/steering/portfolio.json`) and is owner-edited,
not part of this change.

## Goal

Let the portfolio run more than one continuously-maintained project, each
optionally on its own dedicated engine subscription. Immediate driver:
est-biz-aruannik gets a dedicated Codex subscription and its own pinned slot,
while est-biz-vastav keeps Slot A on the Claude pool. Investor direction:
"each project, if revenue allows, will get a dedicated subscription" — so the
mechanism must be N-slot generic, not a hardcoded Slot C.

Division of labor (investor-specified): Claude orchestrates at the
mission-control/steering level only; inside a dispatched aruannik pass, all
saas-startup-team agents and orchestrators run on Codex via the plugin's
Codex-native skill surfaces (`skills/maintain-loop/SKILL.md` etc.).

## What already generalizes (no code change)

- **Engines/pools** are config-driven maps. A dedicated subscription is a new
  engine entry whose `cmd` prefixes `CODEX_HOME=<dir>` (errata 2026-07-17:
  `timeout` cannot exec an assignment-prefixed command — the wrapper now runs
  the rendered cmd through an inner `bash -c`; shipped with 0.6.0), plus a new
  pool with its own `daily_pass_quota`.
- **Governor** (reserve/report/strikes/backoff/daily roll) is keyed by
  engine/pool name — untouched.
- **Wrapper, slot locks, dispatch records** already take the slot name as a
  parameter (`slot-$X.lock`, `...-$slot-$name.{log,json}`).

## The code change: slot handling in `scripts/mission-control.sh`

Semantics: a slot object with a `pinned` field is a **pinned slot**
(continuous maintenance of that one project — today's Slot A behavior). A
slot object without `pinned` is a **ladder slot** (today's Slot B priority
ladder: live incidents > admitted pre-launch > validation > meta).

1. `pick_slot_a()` → `pick_pinned <slot>`: identical logic, slot key
   parameterized (`.slots[$slot].pinned`).
2. `pick_slot_b()` → `pick_ladder`: rung 1 (live incidents) excludes **all**
   pinned projects, not just Slot A's pin. Rungs 2–4 unchanged (stage-based,
   pinned projects are `live`/`meta` so no overlap in practice; cursor
   `rotate` state unchanged).
3. `cmd_tick`: replace `for slot in A B` with a walk of `.slots` keys —
   **pinned slots first (sorted), then ladder slots (sorted)** — preserving
   today's A-before-B pool-priority semantics exactly. Per-slot body
   unchanged: pinned slots use the single-candidate dispatch, ladder slots
   keep the re-walk-on-reserve-refusal loop (max 4 tries).
4. `cmd_arm` validation: every `.slots[].pinned` must name a project (today:
   A only); slot keys must match `^[A-Za-z0-9_-]+$` (they become lock-file
   names and dispatch-record basenames). No cap on slot count — pool quotas
   are the real budget guard.
5. `cmd_status`: iterate `.slots` keys instead of `for s in A B`.

Backward compatibility: a config with `{"A": {"pinned": ...}, "B": {}}`
behaves identically (same pick order, same exclusions, same log lines). No
state-file migration — slot names only appear in lock/dispatch
filenames, which are already per-name.

Explicitly supported but unused: multiple ladder slots (each walks the ladder
independently; shared rung cursors make them rotate through different
candidates). Not blocked, not tested beyond one smoke case.

## Rollout config (steering repo, owner edit, after plugin merge)

```json
"slots":   { "A": { "pinned": "est-biz-vastav" }, "B": {},
             "C": { "pinned": "est-biz-aruannik" } },
"engines": { "codex-aruannik": {
               "pool": "codex-aruannik",
               "cmd": "CODEX_HOME=/config/.codex-aruannik codex exec --dangerously-bypass-approvals-and-sandbox '{prompt}'" } },
"pools":   { "codex-aruannik": { "daily_pass_quota": 12 } }
```

plus `est-biz-aruannik.engine = "codex-aruannik"` (command stays
`/maintain-loop --once`; the Codex-native skill surface executes it).
Dispatch stays `container: "local"` (webtop) — dev-container dispatch remains
Phase 4.

Effects: aruannik passes stop consuming the claude pool entirely; aruannik
incidents are covered by its own pinned slot (rung 1 now excludes it); vastav
incidents keep rung-1 coverage as before.

## Auth provisioning (human step, staged one-liner)

The dedicated Codex subscription is authenticated inside the
`est-biz-aruannik-dev` container. A staged script copies its
`$CODEX_HOME/auth.json` (and config.toml if present) into webtop-side
`/config/.codex-aruannik/` (dir 0700, files 0600, owner abc), then verifies
with a `codex login status` (or equivalent) PASS/FAIL line. Agents do not
copy credentials themselves; the human runs the one line.

## Testing (TDD, existing harness style — `MC_LIB_ONLY=1` sourcing)

New `tests/slots-generic.tests.sh`:
- three-slot config: pinned A + ladder B + pinned C each dispatch their
  project on one tick (fake `probe_work`/dispatch as in core.tests.sh);
- rung-1 exclusion covers ALL pinned projects (C's pin never dispatches via B);
- pinned-first order: with quota 1, the pinned slot wins the last pool pass
  over the ladder;
- arm validation rejects unknown `pinned` on any slot and bad slot names;
- two-slot legacy config regression: logs/behavior unchanged.
Full existing suite must stay green (core, governor-*, admission, bus,
delivery-hold, digest-sections, exec-user).

## Delivery

Feature bump 0.5.9 → 0.6.0 (plugin.json). Branch + PR to this repo (flow as
PR #307), tests green, merge, fast-forward the webtop checkout (crontab runs
`scripts/mission-control.sh` from the checkout — merge + ff = live). Then the
steering-repo config edit + auth copy; next :00/:30 tick starts Slot C. No
re-arm needed (config is read every tick).

## Out of scope

- Dev-container dispatch (Phase 4), including its socket/auth/plugin setup.
- Per-project subscriptions for vastav/others — config-only once this ships.
- Steering-agent power to edit slots/engines (stays owner-only).
- Multi-ladder tuning beyond the smoke case.
