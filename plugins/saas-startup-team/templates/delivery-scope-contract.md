# Delivery Scope Contract

## Direct Feature Planning

For a direct architecture or implementation request with a concrete outcome, apply this
section before business, legal, growth, or research expansion.

- Derive `Done`, `Preserve`, and `Out of Scope` from the request and existing repository behavior before proposing architecture.
- A concrete request plus existing repository behavior may establish the direct feature's `Why`; do not require a new research artifact or user confirmation merely to restate that known outcome.
- Use one targeted repository-discovery pass by the primary planner: inspect only the relevant architecture, existing workflows or rituals, entrypoints, and tests. Do not spawn workers by default; fan out only for an independent evidence gap whose answer can materially change `Done`.
- Infer safe, reversible choices from repository conventions and state them in the plan or brief. Ask only when a missing choice would materially change customer-visible behavior, an irreversible data or API contract, security, privacy, legal correctness, or deployment authority.
- Prefer adapting an existing ritual or component for scheduling, reporting, notification, delivery, and evidence. Add a new scheduler, delivery framework, evidence store, or control plane only when `Done` or a mandatory gate requires it.
- A topic-specific legal or market concern triggers only the evidence needed for the changed behavior or claim, not a product-wide audit.

- The accepted requirements and mandatory triggered gates define `Done`.
- `Preserve` covers named invariants and all existing behavior not changed by `Done`; `Out of Scope` covers every unrelated change.
- Use the smallest complete change consistent with the existing architecture. Do not add features, dependencies, abstractions, refactors, fallbacks, or generalized edge-case machinery unless `Done` requires them.
- Deliver a finished production product operated by one founder, never an MVP. Prefer boring, managed architecture one person can deploy, understand, debug, and recover alone. Do not add enterprise machinery such as service splits, self-operated brokers, SSO/SAML/SCIM, organization/RBAC hierarchies, HA/multi-region, or heavyweight observability stacks unless `Done` or a concrete documented security, legal, reliability, or operability need requires it. Use managed background jobs, error capture, and critical-workflow alerts when they are the simplest safe production design. KISS trims operational complexity, never product completeness, authentication, validation, payment/data correctness, backups/recovery, or honest failure states.
- Expand scope only when a reproduced failure, log, or test proves an adjacent issue causally blocks `Done`. Otherwise list it under `Not Addressed`; do not investigate or fix it.
- Validate changed and affected paths plus mandatory existing gates. Fix failures caused by the diff; report unrelated or pre-existing failures without changing unrelated code.
- Do not begin a general or recursive audit. Once `Done` and mandatory gates pass, stop product investigation and mutation; complete the required handoff or report, then exit.
