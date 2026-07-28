# Epic compose — scan issues → focused epic

Upstream of `/epic`. Produces **one** GitHub epic issue with a parseable child
checklist. Implementation is always `/epic <n>` (serial train) with the parent
session as **meta-orchestrator** (conductor only — workers implement product
code; see `epic-invariants.md` conductor contract).

## Focus rules (hard)

| Rule | Bound |
|------|-------|
| Children | **2–12** open leaf issues (default target **3–8**) |
| Theme | One coherent outcome / invariant (not “misc backlog”) |
| Exclude | `epic`, `needs-human`, `wontfix`, `duplicate`, `invalid` |
| Exclude | Issues already on an **open** epic checklist |
| Order | Dependency / risk first; tracks = ordering, not parallel writers |
| Size | Prefer shippable in one focused train (days, not multi-month) |

If the only coherent group has 1 issue → do **not** file an epic; use `/deliver`
or `/improve` on that issue.

If many themes compete → file **one** epic for the highest-impact group; leave
others for a later compose pass (do not mega-epic the whole backlog).

## Body template (must parse with `epic_plan.py`)

```markdown
# Epic: <short outcome title>

## Why this epic
<1 short paragraph: customer/trust impact + shared invariant>

## Done when / acceptance
- <measurable outcomes>
- Each child closed with locking regression where applicable
- Epic PR merged; children closed after merge only (via /epic)

## Out of scope
- <explicit non-goals>

## Delivery order

### Track A — <name>
- [ ] #N — <one-line child title from issue>
- [ ] #M — …

### Track B — <name>   <!-- optional; serial within track -->
- [ ] #P — …
```

Child lines **must** start with `#N` after the checkbox (see `epic_plan.py`).

## Pipeline

```text
epic_scan.py → (agent clusters for focus) → draft body
  → epic_compose_validate.py → gh issue create (label: epic)
  → /epic <new>   # default: auto-invoke in the same run
```

## Modes

| Mode | Mutation |
|------|----------|
| `--dry-run` | Scan + draft + validate only; print body |
| default (file + meta-orchestrate) | Create epic, then run `/epic <n>` immediately as conductor |
| `--compose-only` | Create epic only; do not start `/epic` |

Product implementation, merge, post-merge deploy poll, live verify, and leaf
closes happen only inside `/epic` (not in the compose drafting steps). Default
compose still lands product changes via `/epic` workers — the parent must not
implement them itself.