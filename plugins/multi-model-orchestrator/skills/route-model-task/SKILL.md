---
name: route-model-task
description: "Choose a Claude Code, Codex, or Grok Build model and reasoning effort for implementation, planning, investigation, review, or verification. Use when an orchestrator must assign tasks, when the user asks which coding model or effort to use, or when provider restrictions, latency, cost, risk, or independent-review needs affect routing."
---

# Route Model Task

Choose one primary route per bounded task. Read `references/routing.md` before assigning a model
or effort. Use the evidence notes only when explaining or revisiting the policy.

## Route in this order

1. Extract hard constraints: allowed or denied providers, pinned model or effort, budget, latency,
   tool access, edit authority, and required reviewer independence. Apply them before scoring.
2. Reject contradictions such as “Codex only” plus “do not use Codex.” Never substitute a denied
   provider. If no valid route remains, return the exact blocker.
3. Classify the task by role, ambiguity, scope/coupling, risk, determinism of validation, modality,
   and expected duration.
4. Select the model from the strict catalog in `references/routing.md`, then select the cheapest
   sufficient supported effort. Model choice and effort are separate decisions.
5. Add another model only when independent evidence can change the result. Prefer a provider
   different from the implementer for high-risk review or contradictory diagnoses.

## Routing rules

- Preserve explicit provider, model, and effort requests when compatible with the strict catalog.
- Treat “only,” “must,” “do not use,” and provider allow/deny lists as hard constraints.
- When one provider is allowed, optimize within that provider's current models; do not complain
  that another provider would be better unless the allowed catalog cannot meet the task.
- Do not raise effort to compensate for a vague task packet, missing acceptance criteria, or
  unavailable validation.
- Default to one pass. Parallelize only disjoint work or independent read-only investigations.
- Route a repeated scope violation, stalled tool loop, or contradictory diagnosis to another
  allowed provider before blindly increasing effort.
- Keep a model's testimony advisory. Tests, rendered output, and repository evidence decide Done.
- Query installed CLI versions and model availability when a route will actually execute. If the
  chosen CLI is unavailable or unsigned-in, use only an allowed fallback or report the blocker.

## Emit a route card

Return one compact entry per task:

```text
Task: <bounded outcome>
Role: <plan|implement|investigate|review|verify>
Route: <provider> / <exact model> / <effort or n/a>
Why: <task evidence that justifies this route>
Access: <read-only or edit; required tools>
Gate: <deterministic acceptance check>
Fallback: <allowed route and trigger, or none>
```

If the request is routing-only, stop after the route cards. If an orchestrator invoked this skill,
pass the cards into its task ledger and dispatch only after its normal preflight.

## Calibrate

Record effective provider, model, effort, completion, latency, tool-loop count, scope violations,
and gate result. Change defaults only from repeated local task evidence; vendor benchmarks and
community reports are starting hypotheses, not a permanent leaderboard.
