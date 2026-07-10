# Merge policy — standing green-gate auto-merge

Canonical statement for `/maintain`, `/maintain-loop`, and `/goal-deliver`.

## Standing policy

There is **no hold tier**. Every PR that clears the green gate is merged
immediately — no per-run human approval. The green gate is: latest-HEAD tribunal
clearance (zero critical/high) + required CI checks + the recurrence/regression
gate.

## Carve-outs

The only exceptions. They gate *what may ship autonomously*, not the merge
mechanics:

- **Regulated/legal claims** needing human signoff, **pricing or customer-promise
  changes**, and **destructive/irreversible production migrations** stay
  `needs-human`: parked for a human decision, not auto-delivered. The boundary is
  *judgment*, not the surface — a well-specified, objectively-checkable code fix on
  a sensitive surface (payments, auth, a DB migration, money math, a stated
  compliance rule) is still delivered and merged like any other issue. Only work
  hinging on legal/compliance/tax/pricing **interpretation** is carved out.
- Work that states a hedged `docs/legal/*.md` verdict (frontmatter schema in
  `skills/lawyer/SKILL.md` "Analysis Workflow"; policy in its "Evidence-Tier
  Policy" section) as unconditional fact stays `needs-human`.
  `scripts/legal-verdict-gate.sh --enforce <doc>...` is the mechanical check.
- **UI-touching diffs** (per `scripts/ui-touch.sh`) must additionally carry
  `## Design-review: PASS` evidence in the PR body — the design-review leg's
  screenshot verdict — as part of the green gate.

## Obsolete: per-run auto-merge grants

Per-run auto-merge grant memories are **obsolete** — this standing policy
supersedes them. Ignore any "auto-merge granted for this run" memory; merge
eligibility is decided by the green gate, the carve-outs above, and each
workflow's own audits (closure audit, merge budget) — never by per-run grants.
