# Decision #207 — lessons-review 72h veto window for low-risk lesson classes

**Decision: KEEP the mandatory human `/lessons-review` gate unchanged. No veto
window, no implementation.** Revisit only if a material volume of truly
inert-surface lessons (see below) accumulates in the queue.

## Data (epic #192 delivery, 2026-07-09/10 — 9 merged PRs, every one through an
independent review-before-merge gate)

- Every single delivery's independent review surfaced at least one **real,
  accepted** correctness finding; four were critical/high fail-open paths
  (poll-gate reading unknown CI states as green, #215; a capless spend envelope
  authorizing PAUSED→live ads, #219; grant-retirement deleting durable rules,
  #218; a UI-review gate skippable via classifier error, #217).
- The decisive evidence for THIS decision: **three of those real findings were
  in markdown-only diffs.** #212's "solely by the green gate" wording would
  have licensed autonomous agents to skip the closure audit; #217's verdict
  block was satisfiable without evidence; the leg trigger was skippable. For
  LLM-executed plugins, prompt wording IS behavior — the issue's proposed
  "docs/prompt hygiene, no behavior change" class is close to empty for any
  file a session loads (commands/, skills/, agents/, templates/, hooks/).
- The genuinely inert class (README/docs-directory-only diffs, never loaded
  into sessions) produced 0 lesson candidates in the observed window. A veto
  flow for an empty class is mechanism without payoff.
- Approval overhead is already amortized: `/lessons-review` runs at digest
  cadence and one batch labeled all epic children in a single sitting. The
  human-turn cost the veto window would save is ~0 against the epic's <80
  turns/2wk target; the slop-guard it would weaken is the repo's only
  remaining human gate.

## Boundary restated

The human gate governs **what enters the queue** (`lesson-approved`). It does
not govern delivery correctness — that is the loop's mechanical firewall +
independent review + tests + CI, which this epic's data shows carrying the
correctness load. Keeping approval mandatory costs one digest-cadence batch
action; dropping it for a near-empty class buys nothing measurable.
