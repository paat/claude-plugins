# Research leg

Use `--mode research` for facts outside the repository. Prefer primary sources and spend the leg
only when its evidence can change the current decision.

Claude and Grok research legs are restricted at the tool layer; the Codex leg is prompt-bounded
only, despite its scratch working root. Prefer Claude or Grok when model constraints permit; Codex
is the fallback that preserves a grounding leg for Codex-pinned deployments.

## Discovery

Discovery starts with a goal and produces evidence-backed candidate tasks, not a per-item verdict.
File accepted tasks as tracker items, then stop when the goal has enough actionable work within the
brief's autonomy bounds or the evidence supports no work. The per-item triggers and **Do not
trigger** rules below do not gate Discovery.

## Triggers

When the routed provider cannot read the tree—Codex research runs from a scratch root—the
orchestrator MUST embed the minimal repo excerpts, or relevant paths and their needed contents,
directly in the research question. Otherwise comparative triggers MUST route to Claude or Grok,
whose research legs retain `Read`, `Glob`, and `Grep`.

| Trigger | Recognizable example |
|---|---|
| External authority decides correctness | Statutory payroll rounding; an annual-report rule amended after release |
| Deployment reality differs from the repo | The production image lacks `gh`; a plan quota differs from config |
| The item's premise is unverified | An asserted per-balance fee shape was contradicted by committed fixtures |
| A price, limit, or SLA is load-bearing now | A competitor's free tier invalidates a €19 SKU; a vendor costs €3.97/month |
| A reviewer is disputed on fact, not taste | An annual-report requirement the orchestrator was ready to dismiss |
| The decision is expensive to reverse | One brand versus a separate product; schema or irreversible migration |

## Do not trigger

- The answer is in the repo, tests, or git history.
- The item is well-specified and only HOW to implement it is unknown; use advise.
- The decision is reversible in one commit.
- It is taste with no external fact behind it.
- The handoff's ratified decisions or an existing research memo records the answer. A recorded memo
  suppresses a re-run exactly as a ratified decision suppresses re-litigation.

## Memo contract

The orchestrator writes the result to a tracked target-repo file: `docs/research/<slug>.md` or the
repo's existing decisions/research location. Every load-bearing claim carries its citation and tier:
A is a verbatim statute, official specification, or vendor API reference; B is an official
documentation page or technical specification; C is a practitioner or third-party report. Report
surviving unknowns as `UNKNOWN`, with the recommended default convention and its rationale. Cite the
memo path in the handoff.

## When to buy two legs

Use two independent research legs only when the decision is expensive to reverse or a human expert
would otherwise be escalated to. Require convergence, then re-verify the load-bearing quotes before
skipping the human. Otherwise use one leg.
