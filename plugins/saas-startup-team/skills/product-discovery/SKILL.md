---
name: product-discovery
description: "Bounded product discovery — market/ICP evidence, requirements, and growth strategy artifacts only when they change Done."
---

# Product Discovery

Host-neutral capability. Not a founder persona. No colors, dialogue scripts, model pins,
or role-owned state. Technical delivery is `../deliver/SKILL.md`, not this skill.

## Triggers (only when one applies)

1. **New product or major pivot** — no material brief/research yet.
2. **Evidence gap that can change `Done`** — pricing, ICP, competitor gap, or legal/market
   constraint that would alter acceptance criteria.
3. **Growth strategy init** — first `docs/growth/{product-brief,strategy,brand}` write when
   missing and a live growth track needs them.
4. **Direct feature brief** — concrete request may establish Why from request + existing
   repository behavior; do **not** run unconditional market research.

Non-triggers: routine implementation, pure bug fix with clear repro, mechanical refactors.

## Inputs

- Investor/request text and existing `docs/business/brief.md` when present
- Existing research under `docs/research/`, legal under `docs/legal/`
- `../../templates/delivery-scope-planning.md` and `../../templates/delivery-scope-contract.md`
  (also `templates/delivery-scope-contract.md` from plugin root) before any implementation brief
- For growth init: lifecycle flag and optional market-scout output

## Mutation boundary

May write: triggered `docs/research|business|growth/*` strategy assets, task-designated
briefs, `docs/human-tasks.md`. Must not: product source/tests/workflow registry, commits,
PRs, merges, deploys, or `active_role`/state authority. Supervisor commits artifacts.

## Outputs

- Decision-first brief or research artifact that changes the next Done/Preserve/Out of Scope
- Explicit gaps and human-only tasks when evidence is incomplete
- For implementation briefs: English `Done`, `Preserve`, and `Out of Scope` filled; max 2
  features; proposed workflow-spec delta when routes/jobs/payments/state machines change
  (implementer writes the registry)
- Define the **customer value unit** separately from internal capability/source/model terms

## Procedure

Read scope contract; run discovery only when triggered. Full discovery: market, browsed
competition, customer language, pricing, Estonian legal as needed → `docs/research/`
(ASCII filenames; Estonian prose with diacritics). Legal Tier A → `lawyer` skill. Stop
when the decision has enough evidence; no product-wide audit by default.

## References (on demand)

- `../../references/product-discovery/market-research.md`
- `../../references/product-discovery/estonian-business.md`
- `../../references/product-discovery/saas-metrics.md`
- `../../references/triggered-saas-gates.md` when product class is touched
