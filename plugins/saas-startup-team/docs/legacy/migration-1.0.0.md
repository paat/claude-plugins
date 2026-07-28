# Migration guide — saas-startup-team 1.0.0

**Major break.** Read before upgrading from 0.90.x.

## Removed commands and canonical replacements

| Removed / transitional | Use instead |
|------------------------|-------------|
| `/goal-deliver`, `/improve`, `/tweak` | `/saas-startup-team:goal-deliver` etc. → **`deliver` skill** (aliases remain) |
| Founder persona agents | Capability skills: `tech-founder`, `product-discovery`, `growth`, `lawyer`, `ux-review`, `operate` |
| `/maintain-loop` as control plane | Host cron/Automation → `/maintain --once` (or `maintain-v3.sh tick`) |
| `/pause`, `/nudge` | External scheduler backoff; re-invoke maintain/deliver with an explicit correction |
| `/harvest`, `/session-insights`, `/lessons-*`, `/learnings-*` | **No replacement** (see `migration-1.0-meta-removed.md`) |
| Auto-commit / handoff / tone hooks | Removed; agents commit deliberately |
| Browser-operator personas | Host browser capability + `ux-review` |
| Direct removed hook scripts | `hooks/dispatch.sh` + `scripts/gate.sh` |

## State-machine removal

- **Gone from normal execution:** `.startup/state.json` delivery machine,
  `active_role`, iteration counters, Stop/yield, numbered handoffs, claims,
  leases, guardians, primary-checkout ownership.
- **Not silently deleted:** existing `.startup` files remain on disk; the plugin
  does not reinterpret them as a live state machine.
- **Authoritative now:** Git branches, PRs, CI checks, deployments, and immutable
  terminal release facts (`maintain-v3` `release-facts`).

## External scheduling

Host (cron, systemd, CI schedule, Codex Automation) owns cadence:

```bash
# Example: one maintain tick per day (shadow first)
cd <repo> && bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" maintain \
  && bash "$PLUGIN_ROOT/scripts/maintain-v3.sh" tick --shadow \
       --repo-root "$(git rev-parse --show-toplevel)" --allow-linked-worktrees
```

Digest and monitor-nightly are likewise host-scheduled. The plugin does not install
cron or long-lived daemons.

## Worktree behavior

- Native linked worktrees are allowed; maintenance no longer resets or removes
  “foreign” worktrees.
- Per-issue short locks replace long global delivery leases.
- Isolation: `maintain-v3.sh isolate prepare|cleanup` for issue worktrees;
  serial-primary only with explicit `--allow-serial-primary`.

## Legacy import and drain

```bash
# Read-only inventory of useful pre-lifecycle artifacts
bash "$PLUGIN_ROOT/scripts/legacy-import.sh" --root "$(git rev-parse --show-toplevel)"

# Inventory / drain stranded maintain receipts (idempotent; sources left intact)
bash "$PLUGIN_ROOT/scripts/legacy-drain.sh" inventory --repo-root "$(git rev-parse --show-toplevel)" --json
bash "$PLUGIN_ROOT/scripts/legacy-drain.sh" drain --repo-root "$(git rev-parse --show-toplevel)" --apply
bash "$PLUGIN_ROOT/scripts/legacy-drain.sh" verify --repo-root "$(git rev-parse --show-toplevel)"
```

Unresolved receipts that cannot be recovered are parked as human tasks under
`docs/human-tasks.md` (or project equivalent). Do not invent silent success.

## Gates

```bash
bash "$PLUGIN_ROOT/scripts/gate.sh" schema|pii|legal|spend|regression|acceptance|release …
```

Thin shims (`check-ad-budget.sh`, `validate-json.sh`, …) remain for callers that
have not migrated. Legal verdict, acceptance packs, regression, and release
signoff backends still back `gate.sh`.

## Removed helper scripts

| Removed | Replacement |
|---------|-------------|
| `scripts/commit-artifact.sh` | None — unused dead path; use ordinary git commits for durable artifacts |
| Hook scripts listed in `migration-1.0-hooks-gates.md` | `hooks/dispatch.sh` + `scripts/gate.sh` |
| Meta/self-improvement scripts in `migration-1.0-meta-removed.md` | None in runtime |

## Domain references

Static skill knowledge lives under plugin-root `references/<domain>/` (lawyer,
ux-review, tech-founder, product-discovery, growth). Skills load these on demand.

## Rollback constraints

- **Do not** reintroduce 0.x orchestration (state.json machine, primary-only
  leases, auto-commit hooks, founder Stop loops) to “fix” a broken consumer.
- Downgrading the plugin package without draining legacy receipts can leave
  projects with mixed 0.x receipts and 1.0 engines; run `legacy-drain` first.
- Release facts and Git history remain valid across versions; conversational
  handoff archives do not regain authority on rollback.
- Marketplace and manifest must stay at the same version (plugin.json, Codex
  plugin.json, root marketplace entry).

## LOC budgets (post-1.0)

After 1.0.0, metrics may not grow above `current_ratchet`. `scripts_sh_loc`
release_target is **9200** (ceiling **9500**) per Sol ultra recalibration on
issue #392; other metrics keep original targets. Further thinning is ordinary
refactor work with behavior-equivalence tests—not a release gate rewrite.
