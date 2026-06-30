# Workflows and Business Rules

Use this playbook for multi-step flows, business rules, state transitions, imports/exports, background jobs, and checkout/payment paths.

## Workflow Testing

1. Main session parses the workflow steps and expected states.
2. Browser executor performs each mechanical step with complete context.
3. Main session evaluates each step, state transition, and terminal condition.

Pass prior result JSON into later browser calls. Do not rely on session memory.

## Business Rules

For each rule:

1. design positive and negative cases;
2. execute the mechanical browser steps;
3. classify as `ENFORCED`, `NOT_ENFORCED`, or `PARTIALLY_ENFORCED`;
4. record evidence and severity.

## Async Flows

For long-running work, capture the in-progress state, completion state, failure state, and timeout/still-working behavior. Load `evidence-reporting.md` when the user requested a persistent QA artifact.
