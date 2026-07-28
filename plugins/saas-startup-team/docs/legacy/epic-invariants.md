# Epic delivery invariants (Phase 1)

Portable multi-issue epic train for any SaaS product repo. Complements — does
not replace — `deliver`, `maintain`, tribunal-review, or `issue-file`.

## Hard invariants

1. **Serial only.** `concurrency=1`. Never two mutating implementers on the
   epic branch. Tracks in an epic body are **ordering**, not parallel writers.
2. **One branch, one draft PR.** `epic/<n>-<slug>`. All children commit here.
   Per-child `deliver` **does not merge to main** and does not open a second PR.
3. **Epic transaction.** Close children + check epic boxes only **after** the
   epic PR merges to the default branch. No premature “child done = merged.”
4. **GH + git authority.** No `.startup` state machine, claims, or leases for
   epic orchestration. Resume evidence = PR marker + child commits / review notes.
5. **Tribunal hard-require for execution.** `/epic --plan` may run without
   tribunal-review. Mutation stops if tribunal-review is missing. Each child is
   reviewed on `base_sha..head_sha` only; re-review after critical fixes.
   Closing-tribunal runs on the full final epic diff before merge.
6. **Criticals same run.** Tribunal critical/high findings block the next child
   until fixed and re-reviewed.
7. **Residuals.** Use `issue-file`. Out-of-scope → GH only (no checklist change).
   In-scope → GH + append unchecked checklist line on the epic. Filing a residual
   is not completion of the parent child.
8. **Refuse empty checklists.** Zero parseable `- [ ] #N` children → stop
   (decompose is out of Phase 1).
9. **Cooperative active-epic guard.** While a marked epic PR is open, mutating
   `/improve`, `/maintain --mutate`, and ad-hoc `/deliver` on other work must
   refuse (read-only/shadow may continue). Not an atomic lock.
10. **Close gate.** Required CI + branch protection; merge only via the epic PR.
    UI/browser changes need ux-review / product acceptance when triggered — a
    free-form “proof track” does not replace gates. After merge: close children,
    update checkboxes, reconcile residuals, then close the epic.

## PR marker (machine-readable)

Whole-line HTML comment in the draft PR body (also produced by
`scripts/epic_active.py marker`):

```text
<!-- saas-epic: 1766 sha=BODYSHA children=1749,1748,1756,1755 -->
```

`BODYSHA` = sha256 of the epic issue body at plan time. On resume, re-fetch the
epic body; **halt on drift** (hash mismatch) or child-list mismatch.

## Parser (`scripts/epic_plan.py`)

- Input: epic issue body (file or stdin). **No network.**
- Accepts task lines whose payload **starts** with local `#N`.
- Preserves document order and checked state; captures nearest `Track …` heading.
- Ignores fenced code and HTML comments.
- Fail closed: zero children, duplicate `#N`, multiple `#` on one item,
  cross-repo `owner/repo#N`, invalid numbers, ambiguous issue-like tasks.

GitHub existence/open/label checks are **preflight** (orchestrator/`gh`), not the parser.

## Per-child loop (serial)

```text
for child in plan.children where not checked:
  assert concurrency 1 and branch == epic branch
  base_sha=$(git rev-parse HEAD)
  deliver in epic mode (commit/push to epic PR only)
  tribunal on base_sha..HEAD
  fix criticals + re-tribunal until clean or blocked
  record reviewed head SHA on PR (comment or checklist note)
  next child  # do not close GitHub issue yet
```

## Model / effort (advisory)

| Signal | Effort |
|--------|--------|
| accounting / money / identity | high; invariant map before code when epic requires |
| security / legal-review | high + lawyer gate when triggered |
| pure copy / CSS / docs | lower |
| default product bug | medium |

Routing is host-side; do not pin provider models in this plugin.

## Honest outcomes

| Result | Meaning |
|--------|---------|
| `complete` | Epic PR merged; children closed; checklist reconciled |
| `blocked` | Human gate, missing tribunal, body drift, or active-epic conflict |
| `incomplete` | Partial children landed on epic branch; not merged |
| `cancelled` | Human abort; leave branch/PR for resume |

Never claim success without merge + gate evidence.

## Out of Phase 1

Parallel writers, auto-decompose, `--pick` across epics, atomic distributed
locks, client-specific parser forks, reimplementing deliver/tribunal inside epic.
)
