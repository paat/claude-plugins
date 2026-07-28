# Maintain v3 contract

Binding product contract for the thin maintenance tick (`scripts/maintain-v3.sh`,
`skills/maintain/SKILL.md`). Supersedes primary-only claim orchestration for
**new** ticks. Legacy claim/receipt engine remains until #389 for shadow compare
and nonterminal recovery only.

## Tick

1. Acquire **scheduler** lock (≤120s).
2. Model-free inventory (WIP + queue). Emit stable JSON.
3. Select one unit: dirty → WIP resume → WIP delete → queue issue → no-op.
4. Release scheduler lock.
5. `--shadow` (default): print selection JSON; stop. No mutation.
6. `--mutate`: acquire **issue** lock → prepare isolation → release issue lock →
   invoke `deliver` in worktree/clone → **release** lock only for
   exact-head merge / deploy proof / close observation.

## Locks

| Kind | When held | TTL default |
|------|-----------|------------:|
| scheduler | inventory + select only | 120s |
| issue | isolation bind only | 300s |
| release | merge/deploy/close mutations only | 600s |

No whole-pass lease. No lock across model/review/network waits.
Do **not** use `maintain-leases.sh` for v3 normal operation.

## Isolation

Order: native `git worktree` → disposable local clone → explicit serial primary
(`--allow-serial-primary`). Never silent primary-checkout mutation.

## Stable JSON

Tick / inventory / selection cover:

- inventory (wip, queue, human_gates)
- selection (disposition, kind, issue, pr_number, branch, action, check_status)
- dedup: empty `claims` / `compatibility_receipts` always for v3
- human carve-outs (park from maintain-human-gate)
- proof / release facts (`release-facts` records)
- immutable terminal fields: `merge_sha`, `head_sha`, `deploy_run_id`, `recovery_step`

## Release recovery steps (idempotent)

```
selected → revalidate_head → authorize_merge → merge_sha_pinned
  → record_merge → deploy_proof → close_issue → observe_closed → done
```

Crash at any step: re-read facts, resume `next_step`, never repeat an irreversible
transition with different SHA identity. Conflicting `merge_sha` fails closed.

## Shadow parity vs legacy

| Concern | Parity |
|---------|--------|
| WIP-first order | Match |
| Human park / epic exclude | Match (same maintain-human-gate) |
| PR identity / check_status | Match when present on selection |
| Release disposition sequence | Match step names; storage is terminal facts not claims |
| Claims / compatibility receipts | **Intentional diff:** v3 never creates them |
| Isolation | **Intentional diff:** worktree/clone preferred |
| Locks | **Intentional diff:** short three locks only |
| Default mode | **Intentional diff:** shadow (no mutation) |
| Parked WIP resume | **Intentional diff:** open PR/branch resume is the lock; human park filters **queue greenfield only** (same as legacy WIP-first). Parked queue issues never greenfield. |

## Forbidden in normal v3

- `maintain:claimed` labels or claim comments
- Compatibility schema-v1/v2 receipt begin for new work
- Whole-pass primary-only lease + ptrace guardian for the tick
- Holding locks during deliver model work
