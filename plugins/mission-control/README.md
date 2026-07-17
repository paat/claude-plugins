# mission-control

Portfolio supervisor for autonomous SaaS loops: N concurrent loop slots
(lockfile-enforced), armed by one human-installed cron line, spending zero
LLM tokens on scheduling. A slot with a `pinned` project continuously
maintains it, optionally on a dedicated engine subscription; slots without a
pin rotate by priority ladder: live incidents > pre-launch delivery > demand
validation > lessons-deliver. A budget governor (quotas, rate-limit backoff,
pass envelopes) guards the per-pool subscription budgets.

Design: `docs/superpowers/specs/2026-07-09-mission-control-scheduler-design.md`
and `...-governor-design.md`,
`...2026-07-17-mission-control-generic-pinned-slots-design.md` in this repository.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install mission-control@paat-plugins`
- **Install for all collaborators on this repository** (project scope) —
  commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in
  `.claude/settings.local.json`.

The scheduler itself runs from cron, not from a Claude session: see
`docs/runbook.md` for the one-time arming procedure.

## Dependencies

- bash 4+, `jq`, `flock` (util-linux), GNU `date`, `curl` (push notifications)
- `docker` CLI reaching the project dev containers (set `docker_cmd` to
  `sudo docker` if the cron user lacks docker socket group membership)
- `gh` CLI authenticated *inside each project container* (probes run there),
  reachable **as the exec user**. If the container's agent toolchain lives under
  a non-root user reached via SSH login (so `docker exec` defaults to root and
  sees no auth), set `docker_exec_user` (e.g. `"dev"`) to run `docker exec -u`.
- For maintain/goal-deliver dispatches, the selected engine CLI must report one
  enabled `saas-startup-team@paat-plugins` install via `plugin list --json`
  (Claude uses the user-scope install). A failed helper preflight is recorded as
  an error without launching the model.

## Configuration

Copy `examples/portfolio.example.json` to a host path of your choice (e.g.
`~/.config/mission-control/portfolio.json`) and edit. The file is per-host
and never committed to this repo. Schema: see the design spec table. State
lives in a sibling `state/` directory (override with `state_dir`).

For the normal dev-container policy, leave `delivery_hold` absent (or false):
Mission Control launches the agent unrestricted and SSH remains the operator
control plane. The legacy opt-in hold wrapper remains available only when an
owner explicitly requests it; it is separate from `hold`, which vetoes
scheduling entirely. Codex engine templates must use
`--dangerously-bypass-approvals-and-sandbox` without `--ephemeral`, because a
maintain-loop coordinator needs durable child identities. The dev container is
the security boundary, as shown in the example Codex and Claude commands.

## Engine routing

Stated once, here: Codex is the default `engine` for every product entry;
`claude-opus` is reserved for `meta` (lessons-deliver) and entries the owner
marks for architecture, UX, or Estonian-language judgment. Slots and pools
are decoupled — the governor charges each pass to the pool of the engine
that actually ran.

## Budget governor

Behavioral, not a ledger (remaining subscription quota is not reliably
readable): per-pool daily pass quotas (`pools.<name>.daily_pass_quota`,
absent = unlimited), per-pass wall-clock envelopes
(`pass_timeout_minutes` on engine or project, default 90), rate-limit
backoff (parsed reset time when the CLI prints one, else exponential
30m/1h/2h/4h) with clean resume on the next tick, and a 3-strike 24h
per-project cooldown. A daily digest lands in `state/digests/<date>.md`
(pushed via `notify_env`, copied to `digest_export_path` if set) with a
Spend & pass summary computed from dispatch outcome records. Passes are
never asked to economize — an over-budget pass is simply not dispatched.

## Blocked passes (pivot, don't idle)

A dispatched pass that finds its remaining work **structurally blocked** on an
external dependency (a soak window, a broken CI runner, a human verification
gate) must not idle, retry, or report failure. It prints one sentinel line and
exits:

```
MC-BLOCKED recheck_after=<minutes> reason=<free text>
```

The governor records the pass outcome as `blocked` — a valid terminal state,
not a failure: no error strike, no pool backoff. The project is skipped by
both slots until the recheck window expires (default
`blocked_default_recheck_minutes`, 360; clamped to 5m–7d), so the ladder
pivots to the next project with runnable work instead of burning passes. The
next successful pass clears the block. Blocked projects appear in the daily
digest and `/mission-status` with their reason and recheck time.

For schema-v2 workflow terminals, the structured `blocked` outcome and registered
terminal reason remain authoritative. An exactly anchored sentinel with
`recheck_after=N` may supply only the bounded recheck duration; prose or a malformed
sentinel cannot override either structured field.

The same vocabulary applies inside loop-style commands (maintain,
lessons-deliver): a completion gate or Stop hook must accept
`blocked(<unblock condition>, <recheck-after>)` as a valid outcome for an
item, park the item (the label-based work probes already exclude
`needs-human`/`maintain:blocked` issues), and move to the next
tree-independent item rather than idling on the dependency.

## Commands

- `/mission-status` — read-only view of slots, quotas, backoffs, admissions,
  and recent dispatch outcomes.

## Scripts

- `scripts/mission-control.sh {tick|arm|status} --config <path> [--dry-run]`
- `scripts/governor.sh` — budget policy library sourced by the dispatcher
- `scripts/notify.sh <ENV_VAR_NAME> <title>` — minimal push sender, body on
  stdin; no-op when the env var is unset
- `scripts/bus.sh {send|poll|wait|gc}` — cross-container handoff bus over a
  shared-mount dir (`bus_dir`/`bus_path`); see `docs/runbook.md`
