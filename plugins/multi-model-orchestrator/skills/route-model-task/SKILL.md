---
name: route-model-task
description: "Choose a worker (Claude Code, Codex, Grok Build, Muse Code, Antigravity Gemini Flash/Argon, or local Qwen), model, and reasoning effort by task fit, complexity, plan-limit headroom, and availability. Use when an orchestrator must assign tasks, when the user asks which coding model or effort to use, or when provider restrictions, latency, cost, risk, or independent-review needs affect routing."
---

# Route Model Task

Choose one primary route per bounded task. Read `references/routing.md` and
`references/task-fit.md` before assigning a model or effort. Read only the relevant evidence
notes when explaining or revisiting a recommendation; do not re-research unchanged routes.

## Route in this order

1. Extract hard constraints: allowed or denied providers, pinned model or effort, budget, latency,
   tool access, edit authority, and required reviewer independence. Apply them before scoring.
2. Reject contradictions such as “Codex only” plus “do not use Codex.” Never substitute a denied
   provider. If no valid route remains, return the exact blocker.
3. Classify task family, role, ambiguity, scope/coupling, risk, validation, modality, and duration.
   Use `references/task-fit.md` to choose a candidate and effort separately. Check that its runner
   actually exposes the required tools; model capability alone is insufficient.
4. Classify complexity into a tier (T1–T4, `references/routing.md`). Run
   `${CLAUDE_PLUGIN_ROOT}/scripts/pool.sh pick --tier <T>` with restrictions as `--allow`/`--deny`
   and the task-fit candidate as `--prefer <exact-model>`. Its first line is the eligible route;
   preference never bypasses the tier, usage limits, restrictions, or review eligibility.
   Use table order when evidence does not distinguish candidates. User pins take precedence:
   validate catalog, restrictions and usage headroom before calling their runner directly.
5. Add another model only when independent evidence can change the result. Prefer a provider
   different from the implementer for high-risk review or contradictory diagnoses.

## Routing rules

- Preserve explicit provider, model, and effort requests when compatible with the strict catalog.
- Treat “only,” “must,” “do not use,” and provider allow/deny lists as hard constraints.
- When one provider is allowed, optimize within that provider's current models; do not complain
  that another provider would be better unless the allowed catalog cannot meet the task.
- Do not raise effort to compensate for a vague task packet, missing acceptance criteria, or
  unavailable validation.
- For a pool route, keep the same tier, mode, restrictions, usage snapshot, and `--prefer` in
  `pick` and `run`. If the task needs a different supported effort, first select an eligible
  candidate through `pick`, then call its runner with the recorded exact model and effort.
  On unavailability, reroute within the same constraints; never silently discard the effort
  decision or use direct dispatch to evade a tight window. Explicit user pins remain binding.
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
Task fit: <family; source-backed candidate or local evidence; uncertainty>
Route: <provider> / <exact model> / <effort or n/a>
Why: <why this model and this effort meet this task's acceptance>
Access: <read-only or edit; required tools>
Gate: <deterministic acceptance check>
Fallback: <allowed route and trigger, or none>
Dispatch: <pool arguments including preference, or runner/model/effort arguments>
```

If the request is routing-only, stop after the route cards. If an orchestrator invoked this skill,
pass the cards into its task ledger and dispatch only after its normal preflight.

## Calibrate

In the existing task ledger, record task family, actual served model (including local `default`),
effort, runner/version, tools, acceptance result, elapsed time, repair/retry count, and cost if
known. Separate provider/infra failures from task failures. Compare repeated representative
tasks with the same repository state, inputs, harness and tests; include review/repair time.
Vary effort while holding the model fixed. Change defaults only when that evidence improves
successful delivery; vendor benchmarks are candidate-selection hints, not a leaderboard.
