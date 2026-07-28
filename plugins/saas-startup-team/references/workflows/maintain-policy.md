# Maintain policy

Sole short maintenance policy. Canonical skill: `skills/maintain/SKILL.md`.
Implementation: `scripts/maintain-v3.sh`. Historical protocol: `docs/legacy/maintain-protocol.md`.

## Tick

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --shadow \
  --repo-root "$(git rev-parse --show-toplevel)" --allow-linked-worktrees
# Opt-in mutation after agreement:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --mutate \
  --repo-root "$(git rev-parse --show-toplevel)" --allow-linked-worktrees
```

1. Short **scheduler** lock (≤120s) → model-free inventory → select one unit → release lock
2. Selection order: dirty → WIP resume → WIP delete leftovers → one queue issue → no-op
3. `--shadow` (default): print selection JSON; stop. `--mutate`: **issue** lock → isolate →
   deliver in worktree/clone → **release** lock only for exact-head merge / deploy / close
4. Native worktrees preferred; never silent primary-checkout mutation
5. No claims, `maintain:claimed`, whole-pass leases, guardians, or ptrace
6. Release facts via `maintain-v3.sh release-facts` (immutable terminal fields only)
7. Human park: `maintain-human-gate.sh evaluate` → unresolved → `docs/human-tasks.md`
8. Product verdicts: `skills/product-acceptance` when a product signoff is required

## Probe

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh" maintain \
  --root "$(git rev-parse --show-toplevel)"
# 0 = work available; 3 = no-op; 4 = blocked host
```

External scheduler owns cadence/backoff. `--once` = at most one child tick.

## Release recovery (idempotent)

```
selected → revalidate_head → authorize_merge → merge_sha_pinned
  → record_merge → deploy_proof → close_issue → observe_closed → done
```

Crash: re-read facts, resume `next_step`, never repeat irreversible transitions with a
different SHA. Conflicting `merge_sha` fails closed.

## Legacy drain (explicit, isolated)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/legacy-drain.sh" drain \
  --repo-root "$(git rev-parse --show-toplevel)" --apply
```

Do not invent claims. Source `.startup` files stay until verify.

Auto-merge when gates pass (exact-head + CI green + tribunal zero critical/high). Resume re-proves current-head gates before merge.
Active merge atomically pins the reviewed PR head SHA.
WIP-first contract rejects claim ownership.

Compatibility receipts and claim ownership were removed in #389.

## Characterization anchors
- Native `git worktree` preferred; never hard-reset or clean the primary on cancel.
- No claims / claim comments as ownership.
- exit 3 is `no-op`. `--once` launches at most one child.
- Unresolved human work → `docs/human-tasks.md`.
- Source `.startup` files stay intact until verify.
- Do not trust an earlier green check after head advances; re-prove current-head gates.
- Never open a replacement PR for the same issue WIP while an open PR exists.
- Active merge uses `gh pr merge --match-head-commit` to pin the reviewed head.
- WIP-first contract rejects claim ownership.

Intentional diff

memory-gc.sh

design-review-leg.md

Short locks only
