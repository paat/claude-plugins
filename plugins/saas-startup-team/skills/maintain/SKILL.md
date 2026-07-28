---
name: maintain
description: "One bounded maintenance tick — short lock, WIP-first select, isolated deliver. Default shadow."
---

# Maintain (v3)

One externally scheduled tick. Not a long-running coordinator, claim system, or
primary-only control plane. Host-neutral. Uses `deliver` for implementation.

```
Scheduler lock → inventory → WIP-first select → release lock
  → (shadow: emit JSON and stop)
  → (mutate: per-issue lock → isolate worktree → release lock → deliver)
  → release-mutation lock only for exact-head merge/deploy/close
```

## Invoke

```bash
# Default: shadow (selection + facts only; no mutation)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --shadow \
  --repo-root "$(git rev-parse --show-toplevel)" \
  --allow-linked-worktrees

# Opt-in mutation after shadow agreement
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --mutate \
  --repo-root "$(git rev-parse --show-toplevel)" \
  --allow-linked-worktrees
```

Fixture / offline:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --shadow \
  --fixture-dir "${CLAUDE_PLUGIN_ROOT}/tests/maintain-v3/fixtures/wip-resume"
```

Contract: `../../references/workflows/maintain-v3.md`.

## Tick rules

1. **Short locks only:** `scheduler` (≤120s around inventory+select), `issue`
   (bind isolation only), `release` (exact-head merge/deploy/close only).
   Never hold a lock across model, review, or network wait.
2. **WIP-first:** dirty primary → resume PR/branch → mechanical delete leftovers
   → else one eligible queue issue. Never greenfield while resume WIP exists.
3. **Human carve-outs:** reuse `maintain-human-gate.sh`; parked issues are skipped.
4. **Isolation:** native worktree preferred; else disposable local clone; else
   explicit `--allow-serial-primary`. Never silent primary mutation.
5. **Deliver:** on mutate + deliverable selection, load `../deliver/SKILL.md` with
   `SAAS_DELIVER_ENTRYPOINT=goal-deliver` in the isolation path. No claims,
   `maintain:claimed` labels, or compatibility receipts.
6. **Release:** exact-head re-fetch, SHA-pinned merge, deploy/live proof, close
   observation, idempotent recovery via `maintain-v3.sh release-facts`.
   Immutable terminal facts only (no claim lifecycle).

## Modes

| Flag | Behavior |
|------|----------|
| `--shadow` (default) | Inventory + select JSON; no git/GitHub mutation |
| `--mutate` | Isolate + hand off to deliver; release facts without claims |

## Legacy

Legacy `/maintain` + `maintain-delivery.sh` claim/receipt path remains for shadow
comparison and recovery until #389 drains it. Prefer this skill for new ticks.
Do not dual-write claims from v3.
