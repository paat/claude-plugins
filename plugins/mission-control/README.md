# mission-control

Portfolio supervisor for autonomous SaaS loops: at most two 24/7 loop slots
(lockfile-enforced), armed by one human-installed cron line, spending zero
LLM tokens on scheduling. Slot A continuously maintains a pinned live
product; Slot B rotates by priority ladder: live incidents > pre-launch
delivery > demand validation > lessons-deliver. A budget governor (quotas,
rate-limit backoff, pass envelopes) guards two subscription pools.

Design: `docs/superpowers/specs/2026-07-09-mission-control-scheduler-design.md`
and `...-governor-design.md` in this repository.

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
- `gh` CLI authenticated *inside each project container* (probes run there)

## Configuration

Copy `examples/portfolio.example.json` to a host path of your choice (e.g.
`~/.config/mission-control/portfolio.json`) and edit. The file is per-host
and never committed to this repo. Schema: see the design spec table. State
lives in a sibling `state/` directory (override with `state_dir`).

## Engine routing

Stated once, here: Codex is the default `engine` for every product entry;
`claude-opus` is reserved for `meta` (lessons-deliver) and entries the owner
marks for architecture, UX, or Estonian-language judgment. Slots and pools
are decoupled — the governor charges each pass to the pool of the engine
that actually ran.

## Commands

- `/mission-status` — read-only view of slots, quotas, backoffs, admissions,
  and recent dispatch outcomes.

## Scripts

- `scripts/mission-control.sh {tick|arm|status} --config <path> [--dry-run]`
- `scripts/governor.sh` — budget policy library sourced by the dispatcher
- `scripts/notify.sh <ENV_VAR_NAME> <title>` — minimal push sender, body on
  stdin; no-op when the env var is unset
