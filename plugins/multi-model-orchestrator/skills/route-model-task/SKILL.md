---
name: route-model-task
description: "Choose a worker (Claude Code, Codex, Grok Build, Muse Code, Antigravity Gemini Flash, or local Qwen), model, and reasoning effort by task complexity, plan-limit headroom, and availability. Use when an orchestrator must assign tasks, when the user asks which coding model or effort to use, or when provider restrictions, latency, cost, risk, or independent-review needs affect routing."
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
4. Classify complexity into a tier (T1–T4, `references/routing.md`). Run
   `${CLAUDE_PLUGIN_ROOT}/scripts/pool.sh pick --tier <T>` with the restrictions as `--allow`/`--deny`;
   its first line is the route, and the rest are its fallbacks. An explicit model or effort pin
   skips the pool: select from the strict catalog directly.
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
- To execute, `pool.sh run` (same flags plus `--repo`, `--base` for review, and `--out`; prompt on
  stdin) falls through unavailable workers itself. With no worker left it exits 75 and prints the
  earliest plan reset: report that blocker.
- Runners refuse (exit 2) a checkout holding untracked `.env*` files, since a leg could send their
  values to its provider. Run the whole run from a `git worktree add` checkout without them
  (install dependencies there if tests need them). Legs get a scrubbed environment; pass a
  variable a packet's test needs with `MMO_LEG_ENV="DATABASE_URL"`, pointed at a dev/test
  database, never production.

## Emit a route card

Return one compact entry per task:

```text
Task: <bounded outcome>
Role: <plan|implement|investigate|review|verify>
Tier: <T1|T2|T3|T4, or pinned>
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
