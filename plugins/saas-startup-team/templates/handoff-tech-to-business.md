---
from: tech-founder
to: business-founder
iteration: {{ITERATION}}
date: {{DATE}}
type: implementation | clarification-request
---

## Summary

One paragraph overview of what was built or what clarification is needed.

## What Was Built

### Changes Made

- File: `path/to/file` — what changed and why
- File: `path/to/file` — what changed and why

### Architecture Decisions

Key technical decisions made and their rationale.

### Workflow Registry Updates

- Affected `.startup/workflows/WORKFLOW-<slug>.md` files:
- Route/job/state/handoff-contract changes:
- Missing workflow specs discovered:

### How It Works

Brief explanation of the implementation for non-technical review.

## What the Customer Will Experience

Step-by-step description of the user journey:
1. Customer opens...
2. Customer sees...
3. Customer clicks...
4. Result: ...

## How to Test

### Quick Verification
```bash
# Commands to start/verify the implementation
```

### Browser Testing Checklist
- [ ] Page loads correctly at `http://localhost:PORT/path`
- [ ] Primary workflow completes end-to-end
- [ ] Error states handled gracefully
- [ ] Mobile responsive (if applicable)
- [ ] Triggered SaaS gates covered where relevant: async paid-flow wait/terminal states, checkout required-field/CTA proximity, customer copy/value-unit scan, structured-result raw-value scan, LLM pipeline fallback/parse evidence, compliance claim taxonomy, public-route discoverability, and workflow registry QA cases.

### Triggered Gate Evidence

State "not applicable" for gates that do not apply.

- Async paid-flow UX gate:
- Checkout CTA proximity gate:
- Customer copy/value-unit gate:
- Structured-result raw-value scan:
- LLM pipeline quality gate:
- Compliance/risk claim taxonomy:
- CI/CD readiness:
- Public-route discoverability (entry surface, click path, locales, exception/noindex, reachability test):

## Questions for Business Founder

Items where the "why" was unclear or business input is needed.

## UX Costs of Technical Decisions

Any place where a technical / correctness / legal constraint forced a UX compromise — a deliberately-excluded behavior, a separate step the user won't expect, an input that can't be safely auto-filled. State the constraint AND the experience cost, so product can design around it or escalate. Do NOT bury these in code comments — a correct-but-degrading scoping decision is a flag-to-product event, not a silent implementation choice. Write "none" if no constraint affected UX this round.

## Known Limitations

What's not yet implemented and why.

### Not Addressed

Adjacent findings outside the accepted scope. List them without investigating or changing them; write `none` when empty.

## Next Expected Action

Business founder reviews implementation via browser, validates against requirements, writes roundtrip signoff or feedback.
