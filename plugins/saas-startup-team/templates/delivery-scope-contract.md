# Delivery Scope Contract

- The accepted requirements and mandatory triggered gates define `Done`.
- `Preserve` covers named invariants and all existing behavior not changed by `Done`; `Out of Scope` covers every unrelated change.
- Use the smallest complete change consistent with the existing architecture. Do not add features, dependencies, abstractions, refactors, fallbacks, or generalized edge-case machinery unless `Done` requires them.
- Deliver a finished production product operated by one founder, never an MVP. Prefer boring, managed architecture one person can deploy, understand, debug, and recover alone. Do not add enterprise machinery such as service splits, self-operated brokers, SSO/SAML/SCIM, organization/RBAC hierarchies, HA/multi-region, or heavyweight observability stacks unless `Done` or a concrete documented security, legal, reliability, or operability need requires it. Use managed background jobs, error capture, and critical-workflow alerts when they are the simplest safe production design. KISS trims operational complexity, never product completeness, authentication, validation, payment/data correctness, backups/recovery, or honest failure states.
- Expand scope only when a reproduced failure, log, or test proves an adjacent issue causally blocks `Done`. Otherwise list it under `Not Addressed`; do not investigate or fix it.
- Validate changed and affected paths plus mandatory existing gates. Fix failures caused by the diff; report unrelated or pre-existing failures without changing unrelated code.
- Do not begin a general or recursive audit. Once `Done` and mandatory gates pass, stop product investigation and mutation; complete the required handoff or report, then exit.
