# fleet-propagate

Idempotent config propagation across a development fleet: the host, every
dev/webtop container, container init scripts, and container-creator skills.
Replaces the recurring manual workflow of mapping 8–10 targets by hand, where
each occurrence re-derives the same steps and occasionally misses one — and
bakes changes into creator skills so future containers inherit them (drift
elimination at the source).

## What it provides

- **`skills/fleet-propagate`** — the workflow: one content file + one stable
  block id, enumerate targets from the manifest, apply the managed block per
  target, verify each (plus a behavior probe for semantic changes), and report
  a per-target `applied | verified | notes` matrix where unreachable targets
  are flagged, never omitted.
- **`scripts/managed-block.sh`** — the idempotency primitive: marker-delimited
  block apply/verify/remove in any text file (`# FLEET-BLOCK BEGIN/END <id>`,
  comment prefix configurable). Applying identical content prints `unchanged`;
  changed content replaces exactly the managed block; `verify` proves the
  on-disk block matches the intent.
- **`scripts/fleet-targets.sh`** — target discovery from the per-host manifest
  (`~/.config/fleet-propagate/fleet.json`): host, running containers matching
  the configured docker filters (dedup + excludes, optional `docker exec -u`
  user), and file targets (init-script and creator-skill globs). Docker being
  unreachable is a loud incomplete-list error, not a silently shorter list.

## Requirements

- bash 4+, `jq`, `awk`; `docker` CLI for container targets.

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install fleet-propagate@paat-plugins`
- **Install for all collaborators on this repository** (project scope) —
  committed to the repo and shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this
  repository, via `.claude/settings.local.json`.

## Configuration

Per-host manifest at `~/.config/fleet-propagate/fleet.json` (see the skill for
the schema). It is deliberately outside any repo: the fleet layout is host
infrastructure, not project code. Other tooling can reuse it as the shared
target inventory.

## Testing

```bash
bash plugins/fleet-propagate/tests/run.sh
```
