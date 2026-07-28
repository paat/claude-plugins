---
name: product-acceptance
description: "Independent product acceptance — browser QA, product gates, PASS/FAIL review, solution signoff. Never the implementer."
---

# Product Acceptance

Host-neutral capability. Independent of the implementation worker whenever triggered.
Not a founder persona. No colors, dialogue scripts, model pins, or role-owned state.

## Triggers

1. Post-implementation **QA / roundtrip review** for a delivered unit.
2. **Go-live / solution signoff** when the product is claimed customer-ready.
3. **Pre-merge design-review** when `ui-touch.sh` reports UI (shared leg with `ux-review`).
4. Maintain deep **product** verdict when the human gate emits `delegate-fable` for
   judgment / production-signoff / customer-communication kinds (not pure legal).

Non-triggers: implementation; pure legal/compliance Tier-A claims (`lawyer` skill —
maintain routes `delegate-fable:legal` there); pure a11y audits (`ux-review`).

## Inputs

Scope contract context: `../../templates/delivery-scope-contract.md` when judging completeness.

Verify against the unit's accepted `Done`, `Preserve`, and `Out of Scope` (from the brief/scope contract — do not invent scope).

- Implementation handoff or PR description with URL(s) and test notes
- Supervisor-provided review path (e.g. `$QA_REVIEW`)
- Workflow specs referenced by the change; acceptance packs when selected
- `../../references/coherence-pass.md`, `../../references/triggered-saas-gates.md`
- `../../references/ux-review/design-review-leg.md` for browser transport recovery and
  pre-merge design-review format

## Mutation boundary

| May write | Must not write |
|-----------|----------------|
| Single review artifact at the designated path | Product source, tests, workflow-spec registry |
| Solution signoff under `.startup/go-live/` only when criteria met | Implementation handoffs during QA |
| Design-review PASS/FAIL block for PR body when asked | Commits, merges, deploys, `active_role` |

Review-only: never “fix while reviewing.” FAIL feedback becomes a **separate**
discovery/brief phase after the supervisor materializes state.

## Outputs

- Explicit `PASS` or `FAIL` (or `tool-unavailable` on browser transport loss after one
  fresh-session retry — never a product verdict from a broken transport)
- Evidence: desktop + mobile (375px), primary flow, console errors, screenshots under
  `.startup/reviews/`
- For public/indexable routes: entry-surface click-through evidence per locale (destination-only navigation cannot PASS)
- For computed outputs: at least one independent source spot-check (hand calc / reference doc — not in-app green alone). When a change touches a business rule, check whether the same rule lives in another layer that may now be desynced
- Solution signoff only if you would pay for the product as a customer and go-live gates pass

## Product gates (when surface exists)

Apply `triggered-saas-gates.md` and coherence-pass. In particular:

- Async paid-flow UX (payment-confirmed, progress, ETA/honest indeterminate, close-browser, DONE/FAILED)
- Checkout CTA proximity on desktop and mobile
- Customer copy / value-unit (no internal implementation nouns, raw enums, `undefined`/`null`)
- Compliance/risk claim taxonomy (fact vs signal vs needs-review; no overstatement)
- CI/CD readiness before solution signoff when relevant

## Browser evidence

Playwright for customer experience — not curl. Browser Evidence Contract from
`../ux-review/SKILL.md` (literal output; retain only its tool-provided path/link;
never a retyped or inline tree; missing/pending/zero browser tools → tool-unavailable;
never a product verdict from broken transport). Use host browser tools when available for
mechanical legs only; judgment stays here. Codex: drive browser in-process.

## Independence

Never accept a review written by the same worker that implemented the change. Supervisor
dispatches this capability as a separate phase or process from Build. Maintain deep
verdicts post GH `fable:decision:` before park/de-gate.

