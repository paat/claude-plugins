---
from: business-founder
to: tech-founder
iteration: {{ITERATION}}
date: {{DATE}}
type: requirements | review | feedback
---

## Summary

One paragraph overview of what is needed. **Max 2 features per handoff** — if you have more, split into multiple sequential handoffs.

## Why (Business Justification)

Why this matters to the customer, operator, or business. For a direct feature, ground the
outcome in the concrete request and existing repository behavior. For work originating in
product discovery, include the relevant customer pain, competition, market, international,
or revenue evidence; do not require unrelated research sections.

## What's Needed

### Done / Feature Requirements (max 2 features per handoff)

- [ ] Feature 1 — acceptance criteria
- [ ] Feature 2 — acceptance criteria

These accepted requirements and the mandatory triggered gates define `Done`.

### Preserve

Existing behavior and invariants that must remain unchanged.

### Out of Scope

Explicit exclusions. Unlisted existing behavior is preserved by default.

### Workflow Registry Impact

Affected specs in `.startup/workflows/`:
- `WORKFLOW-<slug>.md` — Active | Missing | Not applicable

If this introduces or changes a route, webhook, background job, checkout/payment flow, LLM pipeline, support intake, operator workflow, state machine, or handoff contract, update `registry.md` and the affected spec before handing off.

### UX Expectations

How should this look and feel from the customer's perspective?

Triggered gates to apply if relevant:
- Async paid-flow UX gate — progress, ETA or honest indeterminate copy, close-browser behavior, terminal states, slow-job path.
- Checkout CTA proximity gate — required fields near the payment action on desktop/mobile.
- Customer copy/value-unit gate — paid value unit vs internal capability/source/model/data layer.
- Structured-result raw-value scan — labels/fallbacks for user-visible enums/statuses/categories.
- LLM pipeline quality gate — fallback metadata, parse-failure evidence, intended model tier.
- Compliance/risk claim taxonomy — fact/signal/finding/violation/recommendation/needs-review boundaries.
- Go-live CI/CD readiness gate — deploy runner, approvals, secrets, logs, recovery docs.
- Public-route discoverability — existing entry surface, customer click path, locale behavior, intentional unlisted/noindex exception, and reachability test.

### Technical Constraints (if any)

Any constraints discovered during research (API limitations, legal requirements, etc.)

## Research References (if used)

Links to relevant working documents in `docs/`:
- Market research: `docs/research/turu-uurimine.md`
- Customer feedback: `docs/research/kliendi-tagasiside.md`
- Competition analysis: `docs/research/konkurentsianaluus.md`
- International analysis: `docs/research/rahvusvaheline-analuus.md`

## Blockers / Questions

Items that need resolution before proceeding.

## Human Tasks (if any)

Reference items added to `docs/human-tasks.md`

## Next Expected Action

Tech founder implements the requirements and writes a handoff back with implementation report.
