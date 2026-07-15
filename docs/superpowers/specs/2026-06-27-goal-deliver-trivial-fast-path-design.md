# Trivial Fast-Path Routing in `/goal-deliver`

**Date:** 2026-06-27
**Plugin:** saas-startup-team
**Status:** Design approved + Codex-reviewed, pending final spec review

## Problem

When `/maintain` or `/goal-deliver` picks up a GitHub issue, every `agent-fixable`
issue — even a one-line copy or CSS fix — runs the full heavyweight build cycle:
founder planning (Step 2) + `/improve` (business → tech → business-QA) + the
tribunal loop (Step 3). That burns tens of thousands of tokens and real wall-clock
time across multiple agent contexts on changes that need none of it.

`/tweak` already exists as a bare direct-edit fast path, but **the autonomous loop
never uses it** — there is no size dimension in the routing. The goal is to stop
wasting time and LLM tokens on trivial changes by routing them to a tweak-style
fast path.

## Core motivation

Time and token waste — nothing else. The fast path optimizes purely for skipping
the expensive agent dispatches on changes that don't need verification.

## Decision

Add a **trivial fast-path branch inside `/goal-deliver`**, gated by a conservative
tweak-eligibility rubric. Not triage-routing in `/maintain`, not "maintain calls
`/tweak` directly."

### Why inside `/goal-deliver` (one change point, all flows)

`/tweak` only does the front half of a delivery: edit → commit → open PR, then it
stops. It has an interactive scope-guard confirmation and opens its own branch/PR.
In the autonomous `/maintain` loop there is nobody to confirm, and a dangling open
PR is not "delivered to production."

The closure the loop needs lives in `/goal-deliver`: merge → watch the GH Actions
deploy → close the issue → continue. Routing `/maintain → /tweak` would force
re-implementing all of that in a second place — a second routing brain plus
duplicated delivery machinery — to save a small amount of context-load tokens.

The expensive thing was never the command file; it is the **agent dispatches**.
So the fast path is: **`/tweak`'s body (bare edit, no agents) + `/goal-deliver`'s
tail (merge / deploy / close).** Implemented as one branch inside `/goal-deliver`,
it covers every flow with a single implementation:

- the `/maintain` loop (which calls `/goal-deliver` inline),
- a direct `/goal-deliver #123` by hand.

A `trivial` hint from `/maintain`'s triage was considered and dropped: `/goal-deliver`
must re-validate before it bare-ships (it is the thing bypassing the gate; it
cannot trust a hint blindly), so the hint saves nothing. YAGNI.

## Eligibility precondition: single-issue deliveries only

The trivial path is considered **only when the delivery resolves to exactly one
GitHub issue** (`/goal-deliver #123`, or a single issue selected by `/maintain`).
Milestones, multiple `#` tokens, and markdown/free-text specs **always take the
normal gated path** — they bundle multiple requirements and are not whole-delivery
trivial. (Per-issue trivial routing inside a multi-issue delivery is the deferred
v2 work below.)

## Flow

```
/goal-deliver #123   (single issue, no --full flag)
  Step 1: Understand the issue              (cheap — gh issue view)
  ├─ CLASSIFY: tweak-eligible (rubric)? ──no──▶ NORMAL PATH (unchanged)
  │                                              Step 2: plan into chunks (founders)
  │                                              Step 3: /improve + tribunal → merge → close
  │                                              Step 4: deploy-watch
  └─ yes ──▶ TRIVIAL PATH
        1. set active_role = team-lead-tweak (bypass enforce-delegation hook)
        2. bare edit on tweak/<slug> branch  (no founders, no QA, no tribunal)
           - keep pre-commit hooks (NO --no-verify): lint/type-check still run
        3. POST-EDIT SELF-CHECK on the real diff (see Containment).
           Exceeds limits? → abort trivial path, restart on NORMAL PATH.
        4. commit + push + open PR with the same metadata contract as normal
           (PR body resolves the issue, e.g. "Fixes #123"); capture PR number.
        5. PRE-MERGE CI GATE: wait for required PR checks.
           - green  → hand the explicit PR number to Step 3.3 (merge/close)
           - red/failed → DO NOT merge. Fall back to NORMAL PATH (see Failure).
        6. Step 4 deploy-watch (post-merge), reused verbatim.
```

The trivial path replaces only Step 3.1–3.2 (`/improve` + tribunal). It reuses
Step 3.3 (`gh pr merge --squash --delete-branch`, close issues) and Step 4 (deploy
watch). The merge step is handed an **explicit PR number** — it never guesses the
PR from a branch name.

## Tweak-eligibility rubric (correctness-critical)

The chosen safety posture is **bare ship — no QA, no tribunal; CI (required PR
checks) is the only backstop, enforced before merge.** Misrouting a real change
*down* to the trivial path risks shipping a naive unreviewed edit. Therefore the
rubric is **conservative: when uncertain, take the gated path** — the reverse of
`/maintain`'s usual "default toward delivery" bias. A mis-route *up* only costs
tokens; a mis-route *down* costs a bad PR plus a revert.

This rubric is the inverse of `/tweak`'s existing scope guard, reusing the same
vocabulary rather than inventing a second one.

**Tweak-eligible (→ trivial path) — ALL must hold:**

- Pure copy/text, CSS/visual styling, **non-sensitive presentation/product-copy
  constants**, or docs/comments
- No logic or behavior change, no new dependency, no data-model/migration change
- The exact change is objectively specified in the issue (no design judgment)
- Passes the Containment limits below once the edit is made

**Always gated — regardless of apparent size (label OR path/content denylist):**

- **Labels** (or repo-specific equivalents): `bug`, `monitor`, `customer-issue`,
  and any of `security`, `auth`, `payment`/`billing`, `data`/`migration`,
  `regression`, `hotfix`, `incident`, `production`. The incident labels
  (`bug`/`monitor`/`customer-issue`) are additionally blocked by `/goal-deliver`'s
  regression-test gate (Step 3.3), which the bare path cannot satisfy.
- **Paths / file types:** anything under auth, payments/billing, security,
  PII/data-model, migrations, or API-contract surfaces; `.env*`, CI/deploy/build
  config (`.github/`, Dockerfiles, build scripts), dependency manifests and
  lockfiles (`package.json`, `*.lock`, etc.), generated or binary files.

When any single condition fails — at classification time **or** at the post-edit
self-check — the **whole delivery** takes the normal gated path.

## Containment (mechanical post-edit self-check)

Classification from issue text is a guess; the real diff is the truth. After the
edit, before opening the PR, verify the actual `git diff` against hard limits and
abort to the gated path if any are exceeded:

- Max changed files: small (e.g. ≤ 3) — tunable.
- Max changed lines: small (e.g. ≤ ~15) — tunable.
- No file matches the path/file-type denylist above.
- No lockfile / dependency-manifest / generated / binary change.

The exact thresholds are set in the plan; the principle is a cheap mechanical
backstop that catches a misclassified "trivial" change after the edit reveals its
true blast radius.

## Failure behavior (two distinct modes)

- **Red required PR checks (pre-merge):** main was never touched. Do **not** merge.
  Close (or convert) the trivial PR, then re-deliver the issue on the **normal
  gated path** (`/improve` + tribunal). Ensure `/maintain`'s cooldown does **not**
  suppress this immediate corrective gated attempt — a failed trivial attempt must
  not look like a delivery that should cool down.
- **Red deploy (post-merge):** the change is already on main. This is exactly
  `/goal-deliver`'s existing Step 4 deploy-fix handling (dispatch tech founder on a
  `deploy-fix/<slug>` branch → tribunal → merge → re-watch). No new behavior.

## Interactive escape hatch

For direct human use, the trivial path is non-blocking but visible:

- Announce the routing decision in one line: *"Issue #123 classified as trivial —
  taking the fast path (bare edit, CI-gated, no agents)."*
- A `--full` flag on `/goal-deliver` forces the normal gated path, skipping
  classification. (Autonomous `/maintain` never passes it.)

No interactive confirmation prompt — that would defeat the autonomy the fast path
exists to serve.

## Scope

**In (v1):**
- Single-issue whole-delivery trivial detection in `/goal-deliver`.
- The trivial build branch (bare edit + pre-commit hooks + PR) with explicit
  PR-number hand-off to the reused merge/deploy tail.
- Conservative rubric aligned with `/tweak`'s scope-guard wording.
- Label + path/file-type denylist.
- Containment post-edit self-check.
- Pre-merge CI gate and the two-mode failure handling above.
- `--full` escape hatch + routing announcement.

**Deferred (YAGNI / v2):**
- Per-issue (or per-chunk) trivial routing inside a multi-issue / milestone
  delivery. Until then, any multi-issue delivery takes the gated path — the safe
  default.

**Required by repo rules:**
- Version bump in BOTH `plugins/saas-startup-team/.claude-plugin/plugin.json`
  (currently `0.63.0`) AND the root `.claude-plugin/marketplace.json`, kept in sync.

## Implementation-plan process note

Per the investor's instruction: **each stage of the implementation plan is reviewed
with Codex before it is locked.** The review runs as
`codex exec --dangerously-bypass-approvals-and-sandbox -` inside the development
container, with the stage (or its diff) piped on stdin as one stream.

## Codex spec-review disposition

Codex reviewed this spec and confirmed the architecture (branch inside
`/goal-deliver`, whole-delivery-only) is sound. Accepted and folded in: explicit
pre-merge CI gate, two-mode failure handling, post-edit self-check + mechanical
containment, narrowed "config/constant", broadened label+path denylist,
single-issue-only precondition, explicit PR-number/metadata contract, fallback
state handling + cooldown carve-out, and the `--full` escape hatch.

## Open implementation details (for the plan, not the design)

- Whether the trivial path **inlines** a bare edit or **shells out to `/tweak`** for
  the edit body. Leaning inline for autonomous cleanliness (avoids `/tweak`'s
  interactive scope guard and self-opened-PR coordination), while referencing
  `/tweak`'s scope-guard wording as the shared rubric definition.
- Exact Containment thresholds (file/line caps) and the canonical denylist path
  globs for the target product repos.
- Whether the rubric check is a short inline reasoning step or a tiny dispatched
  classification (must stay far cheaper than founder planning either way).
