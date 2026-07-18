# Brief Acceptance Gate

Before implementing any requirement, verify all four. If ANY fails, STOP and message the business founder naming the specific gaps — do not invent material decisions.

1. **Why** — the "Why (Business Justification)" explains why this matters. For direct feature delivery, the concrete request plus existing repository behavior is valid evidence and does not require a new research document. Discovery-originated work cites the relevant existing research docs (`docs/research/`, `docs/business/`, `docs/legal/`).
2. **Testable acceptance criteria** — each feature states concrete, checkable outcomes ("user sees X after Y"), not aspirations ("improve the flow").
3. **No material guessing** — infer safe, reversible choices from repository conventions. Do not decide a missing material business question yourself (pricing, customer-facing wording, tier boundaries, or customer-visible edge-case behavior).
4. **Internally consistent** — requirements do not contradict each other, the referenced research, or the existing product.

Also run the **Scope check**: count features in the handoff. If 3 or more, STOP and ask the business founder to split (max 2 features per handoff). A 3+ feature handoff burns context and loses detail mid-build.
