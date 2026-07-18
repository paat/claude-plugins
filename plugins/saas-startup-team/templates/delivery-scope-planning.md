# Direct Feature Planning

For a direct architecture or implementation request with a concrete outcome, apply this
section before business, legal, growth, or research expansion.

- Derive `Done`, `Preserve`, and `Out of Scope` from the request and existing repository behavior before proposing architecture.
- A concrete request plus existing repository behavior may establish the direct feature's `Why`; do not require a new research artifact or user confirmation merely to restate that known outcome.
- Use one targeted repository-discovery pass by the primary planner: inspect only the relevant architecture, existing workflows or rituals, entrypoints, and tests. Do not spawn workers by default; fan out only for an independent evidence gap whose answer can materially change `Done`.
- Infer safe, reversible choices from repository conventions and state them in the plan or brief. Ask only when a missing choice would materially change customer-visible behavior, an irreversible data or API contract, security, privacy, legal correctness, or deployment authority.
- Prefer adapting an existing ritual or component for scheduling, reporting, notification, delivery, and evidence. Add a new scheduler, delivery framework, evidence store, or control plane only when `Done` or a mandatory gate requires it.
- A topic-specific legal or market concern triggers only the evidence needed for the changed behavior or claim, not a product-wide audit.
