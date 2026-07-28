# Deliver

Canonical delivery capability. `/improve`, `/goal-deliver`, `/tweak`, and startup
implementation resolve here. Commands are transitional aliases only — no delivery
policy lives in `commands/`.

Host-neutral: Claude Code and Codex share this skill. Host differences are limited to
how an implementation or review worker is launched (Task/Agent vs skill /
`codex-cast.sh`). The graph, gates, and outcomes are identical.

**Authority.** Git issues, branches, PRs, CI, deployments, and immutable terminal release
facts are authoritative. Delivery does **not** require founder personas, `.startup/state.json`, `active_role`, or numbered conversational handoffs.
**Never write `active_role: "team-lead"`** if a host still mutates optional state files —
that value breaks later entrypoints via `enforce-delegation`.

Load once per invocation (on demand only):

| File | When |
|------|------|
| `${CLAUDE_PLUGIN_ROOT}/references/deliver/entrypoints.md` | Always — select entrypoint config |
| `../../templates/delivery-scope-contract.md` | Always — Done / Preserve / Out of Scope |
| `../../templates/delivery-scope-planning.md` | Plan phase |
| `../workflows/routing-telemetry.md` | After concrete work is selected |
| `../workflows/mutation-ownership.md` | Before any worker mutation |
| `../triggered-saas-gates.md` | When a product class is touched |
| `../../templates/merge-policy.md` | Before any merge |
| `${CLAUDE_PLUGIN_ROOT}/references/deliver/light-path.md` | Profile `light` or entrypoint `tweak` |
| `${CLAUDE_PLUGIN_ROOT}/references/deliver/multi-unit.md` | Entrypoint `goal-deliver` (chunking, tribunal, deploy) |
| `../workflows/goal-deliver-maintain-receipts.md` | Only when `SAAS_EMBEDDED_CALLER=maintain` |

Set `SAAS_DELIVER_ENTRYPOINT` to `improve` | `goal-deliver` | `tweak` | `startup-impl`
before the graph. Reuse one `SAAS_RUN_ID` per delivery attempt.

## Delivery graph (mandatory order)

```
Preflight → Plan → Isolated Build → Independent Review → Release → Report
```

Every entrypoint uses this same phase order. Entrypoint config may bound or skip a
phase (for example no merge on improve/tweak, no solution-signoff on startup-impl) —
it never invents a parallel pipeline.

### 0. Preflight

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --check-sync
```

In Codex, add `--require-codex` when a separate Codex worker may be used. Missing
Codex CLI/auth is a blocker for Codex surfaces that need it; do not route to Claude
as a fallback.

Post-completion entrypoints (`improve`, `goal-deliver`, `tweak`) require a valid
solution signoff:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/solution-signoff-gate.sh" \
  --source-root "$(git rev-parse --show-toplevel)"
```

If the gate fails, stop and direct the investor to `/startup`. `startup-impl` skips
this gate (the product is still being built).

Prefer isolated worktrees/clones for build (#389). Native linked worktrees coexist.
Never set `core.worktree` on the primary checkout. Dirty primary or wrong branch: stop
and report — do not hard-reset or `clean` the primary on cancel.

Resolve the default branch only via `scripts/default-branch.sh` — never guess `main`.

No whole-pass single-flight leases. Short maintain-v3 locks cover scheduler/issue/release
only when invoked from maintain.

### 1. Plan

Before reading product or research docs, read and apply
`templates/delivery-scope-planning.md` and `templates/delivery-scope-contract.md`.
Derive **`Done`**, **`Preserve`**, and **`Out of Scope`** from the request and existing
repository behavior before proposing architecture.

- The accepted requirements and mandatory triggered gates define `Done`.
- `Preserve` covers named invariants and all existing behavior not changed by `Done`.
- `Out of Scope` covers every unrelated change.
- Expand scope only when a reproduced failure, log, or test proves an adjacent issue
  causally blocks `Done`. Otherwise list it under `Not Addressed`.
- Do not begin a general or recursive audit. Once `Done` and mandatory gates pass, stop.

The supervisor is the primary planner and makes one targeted repository-discovery pass.
**Do not dispatch a planning role by default.** Add exactly one specialist only when an
independent business, legal, or technical evidence gap can materially change `Done`.

Classify before mutation. Keep task text in temporary files; never copy it into events:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-route.sh" classify \
  --mode "$route_mode" --task-file "$task_file" [--labels-file "$labels_file"]
```

- Exit 2 → routing failure; stop.
- Exit 20 → sensitive-surface risk floor; set `PROFILE=deep` and pin a high-effort model.
- Exit 0 → not elevated (`.profile` is `standard`, or `mechanical` only for empty post-diff).
- Model/effort selection is caller/harness policy — not regex routing.

Attach acceptance packs via `scripts/acceptance-packs.sh --render` / `--select`. A new
public/indexable route must include `public_route_discoverability`.

When no arguments: run `market-scout.sh` and take the top candidate; if none, ask once.

### 2. Isolated Build

Workers edit product source, tests, and workflow specs but **do not commit**. Set
non-empty `SAAS_PHASE` so hooks pause (`mutation-ownership.md`). After return:

1. `delivery-route.sh check-diff --base "$BASE_SHA"`
2. Optional mechanical firewall
3. `supervisor-commit.sh --message TEXT --check ./check.sh` (hooks enabled; excludes
   `.startup/**`)
4. Assert the new commit's parent is the expected base

**Profiles:**

| Profile | Mutation path |
|---------|----------------|
| `mechanical` | Exact named repository script only; no model worker. Objective output required or escalate to standard. |
| `light` | Load `${CLAUDE_PLUGIN_ROOT}/references/deliver/light-path.md`. `tweak-run.sh` containment (≤3 files, ≤15 lines, no sensitive paths). Exit 20 escalates once to deep. |
| `standard` / `deep` | Host-native implementation worker. Claude: Task/Agent. Codex: `tech-founder` skill or `scripts/codex-cast.sh` with explicit `--worktree`, `--mode implement`, `--model`, `--effort`, `--timeout`. Never invent founder persona agents (#385); nested Codex controllers removed (#387). |

Before implementation: identify the **root-cause/recurrence class** and fix the class,
with **red-before/green-after proof**. For bug/monitor/customer/accounting/replay/
incident work, add a **mechanical regression guard** that fails on the old behavior;
if no durable guard is possible, split/file the gap or use `Refs` instead of silently
closing it.

**Test evidence (mandatory):** run `./check.sh` — the canonical full-suite entrypoint.
Fix candidate-caused failures; report unrelated pre-existing failures as blockers without
changing unrelated code. State which checks ran and that they passed. For triggered SaaS
gates (`references/triggered-saas-gates.md`), verify the smallest relevant evidence
(workflow spec, slow async paid state, display-label fallback, mobile checkout, malformed
LLM output, inconclusive compliance claim).

When `.startup/workflows/registry.md` exists and the change touches routes, jobs, states,
webhooks, checkout/payment, LLM pipelines, support intake, operator flows, or handoff
contracts, update the affected `WORKFLOW-*.md` specs.

Use the repository's documented test/dev target. If unavailable, make one repair
using only documented setup/start commands before classifying the target as externally
blocked.

### 3. Independent Review

Independent of the implementer (product-acceptance and/or ux-review capabilities). Review-only: write only the review artifact; never modify
source, tests, workflow specs, or state.

- Verify acceptance criteria, mobile viewport (375px), and triggered product gates.
- Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui-touch.sh" --range "${default}...HEAD"`.
  Unless it prints exactly `no-ui`, run the pre-merge leg in
  `skills/ux-review/references/design-review-leg.md`; its
  `## Design-review: PASS|FAIL` verdict block (with Pages/Shots) must land in the PR body.
- If `public_route_discoverability` is selected, run
  `acceptance-packs.sh --verify-public-route "$QA_REVIEW"`; destination-only evidence
  cannot PASS.
- If any consumed `docs/legal/*.md` is hedged, run
  `legal-verdict-gate.sh` and FAIL if the diff states the hedged claim as unconditional fact.
- One fix attempt on FAIL; second FAIL → draft PR / escalate (entrypoint-specific).

**Tribunal** (merge paths — see `../../references/deliver/multi-unit.md`): load
`tribunal-review:closing-tribunal-loop` / `tribunal-loop`. Gate closes only on
**zero critical and zero high**. Round 5 is the ceiling. Include the material promise
question when the PR uses `Closes`/`Fixes`/`Resolves`.

### 4. Release

When the entrypoint merges (goal-deliver standalone; maintain embed via receipt adapter):

1. **Issue-closure audit** before merge when closing keywords present:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue-closure-audit.sh" --pr "<pr url>"
   ```
2. **Fresh check revalidation** on latest HEAD after updating from current default.
3. **Exact PR/head binding:** bind `BOUND_SHA` to local HEAD; require freshly fetched PR
   `headRefOid` equals it. **latest-HEAD gates** must pass.
4. **SHA-pinned merge:**
   ```bash
   gh pr merge "<pr url>" --match-head-commit "$BOUND_SHA" --squash --delete-branch
   ```
   Any **default/head advance restarts final validation**.
5. **Deployment/live proof:** pin `merge_sha` from that PR's `mergeCommit`; poll with
   `poll-gate.sh --deploy-sha "$merge_sha" --branch "${default}"` (optional
   `--workflow`). Never treat "latest run" as proof. Fail closed after budget.
6. **Close observation:** close issues only after verified merge (standalone) or after
   release proof (maintain embed). Use non-closing `Refs #N` under maintain embed.
7. **Idempotent post-merge recovery:** crash between merge/deploy/close resumes from
   immutable receipt/PR facts; never repeat an irreversible transition; never fabricate
   success.

Standing green-gate auto-merge follows `templates/merge-policy.md` (legal/pricing/
destructive carve-outs; UI-touch requires Design-review PASS).

Entrypoints that only open a PR (`improve`, `tweak`) stop after push/PR evidence —
reviewable PR evidence is completion; never merge from those entrypoints.

### 5. Report and honest outcomes

Every handled path records an explicit terminal outcome. Never leave an interrupted run
looking successful. A light helper success never masks a later CI/deploy failure.

| Outcome | When |
|---------|------|
| `success` | Done verified; required PR/merge/deploy evidence present |
| `blocked` | External blocker (secrets, spend, legal judgment, env) |
| `failure` | Verification or delivery failed |
| `escalated` | Needs investor after ceiling / hard conflict |
| `cancelled` | Investor cancelled |
| `no-op` | No work |

Incomplete/blocked work reports what shipped, what did not, why, and residual risk.
Every completed run includes a **completion artifact**: need addressed, what changed,
how verified, acceptance packs, remaining risks, follow-ups filed.

Ask the investor only for true blockers: missing secrets, paid access, destructive
production action, legal/regulated signoff, or ambiguity that changes customer promise
or pricing. Otherwise park into daily digest and continue.

## Entrypoint summary

See `${CLAUDE_PLUGIN_ROOT}/references/deliver/entrypoints.md` for full config. Short form:

| Entrypoint | Units | Merge | Deploy | Fast path |
|------------|-------|-------|--------|-----------|
| `improve` | one | no | no | light may use containment; still opens PR |
| `goal-deliver` | many (PR-sized) | yes (after tribunal) | yes | autonomous light single-issue only |
| `tweak` | one, light-only | no | no | **only** path; escalate non-light to improve |
| `startup-impl` | one (handoff unit) | no | no | same build/review gates; no solution-signoff |

## Communication

Investor-communication language: `templates/communication.md` (team lead English for
status). Token-frugal: read only what the task needs, targeted ranges, never re-read
content already in context.
