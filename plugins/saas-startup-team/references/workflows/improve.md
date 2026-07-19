---
name: improve
description: One-shot improvements on a completed product — creates a branch and opens a PR when run from the default branch, or appends commits to the current branch when run on a feature branch with an open PR (review follow-up). Routes through business founder for context enrichment and browser QA. Usage: /improve [description of changes]
user_invocable: true
---

# /improve — One-Shot Improvement Playbook

Execute a single improvement cycle: dispatch business founder → tech founder → business founder QA, then either open a new PR (greenfield) or append commits to the in-flight PR branch (review follow-up).

Load `${CLAUDE_PLUGIN_ROOT}/references/workflows/routing-telemetry.md` after a concrete
improvement is selected. Reuse one run ID; the shared launcher records Codex phases and
the supervisor records privacy-safe Claude phase events.

## Branching Modes

`/improve` detects the operating context from the current branch and the open-PR state, and chooses one of two modes:

- **`new-branch` mode** — create `improve/<slug>` off the current branch, open a new PR at the end, return to the parent branch. This is the greenfield case (run on the default branch) and the "fork-off" variant of mode C below.
- **`stay` mode** — stay on the current branch, commit and push, do NOT open a new PR. If there is an open PR for this branch, report its URL. This is the review-follow-up case: fixes stack onto the in-flight PR so reviewers and CI re-evaluate the same branch.

The mode is selected automatically when unambiguous, and chosen by the investor when ambiguous. See **Detect Mode** below.

## Hard rule — primary checkout only (no improve worktree)

- **Primary working directory only.** No linked git worktrees.
  `assert-primary-only` fails closed if any extra worktree exists.
- **NEVER** set `core.worktree` on the primary checkout.
- If the primary tree is dirty or not on a branch you may use, stop and report —
  do not escape into a side tree.

## Pre-Flight

0. Run the reusable health preflight:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --check-sync
   ```
   In Codex, include `--require-codex` when a separate Codex worker may be used. Treat
   blocker findings as environment blockers; continue through warnings only when the
   affected capability is not needed for this improvement.

1. Verify `.startup/` exists — if not:
   > Run `/startup` first to build the product.

2. Verify solution signoff exists:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/solution-signoff-gate.sh" \
     --source-root "$(git rev-parse --show-toplevel)"
   ```
   If the executable gate fails:
   > The build loop hasn't completed yet. Use `/startup` to resume or `/nudge` to redirect. `/improve` is for post-completion tweaks.

3. Verify architecture doc exists:
   ```bash
   ls docs/architecture/architecture.md 2>/dev/null
   ```
   If not found:
   > No architecture doc found. The tech founder needs `docs/architecture/architecture.md` to know the stack and service URLs.

4. Verify working tree is clean:
   ```bash
   git status --porcelain
   ```
   If not clean:
   > There are uncommitted changes. Commit or stash them before running `/improve`.

## Capture Instructions

If the user provided arguments with the command, use them as the improvement description.

Otherwise run market scouting and select the top ranked candidate. The scout uses external
market evidence when configured and falls back to internal demand discovery when external
research is unavailable:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/market-scout.sh"
```

If `.startup/demand/market-scout.jsonl` contains a candidate, use its
`discovered_need`, `target_customer_segment`, evidence refs, desired customer outcome,
acceptance packs, non-goals, and rollout checks as the improvement description. If no
candidate is available, ask:
> What would you like improved? Describe the changes.

Whether the description is direct or scouted, a new public/indexable route triggers the
rendered `public_route_discoverability` acceptance pack.

## Semantic Route

Write the selected description and any source labels to temporary local files, then call
`delivery-route.sh classify --mode autonomous`. Exit 2 stops before dispatch; exit 20
sets `PROFILE=deep`. Read `PROFILE` and the comma-joined stable reason codes, remove the
temporary files, then mint/export `SAAS_RUN_ID` and `SAAS_ROUTING_REASONS` exactly as the
shared reference specifies. Never copy the description into an event.

`mechanical` may run only an exact existing repository script named by the request, with
no model worker. If its resulting diff is not the exact expected output, route it again
as standard/deep. For `light`, `standard`, and `deep`, continue through the founder
brief and verdict; the classified profile controls implementation. Standard and deep
Codex implementation remain Sol/high.

## Scope Guard

Before dispatching, assess the request. If it contains 3+ distinct features or requires significant new functionality (new pages, new integrations, new data models):

> This looks like a feature, not an improvement. Consider running `/startup` to resume the build loop for this scope. Want to proceed with `/improve` anyway?

This is advisory — proceed if the investor confirms.

## Detect Mode

Determine which mode to run in:

```bash
current=$(git rev-parse --abbrev-ref HEAD)
default=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/default-branch.sh")
pr_url=$(gh pr list --head "$current" --state open --json url --jq '.[0].url' 2>/dev/null)
```

Apply the rules:

1. **`current == default`** → **`new-branch` mode** (greenfield: branch off `${default}` and open a PR at the end).
2. **`current != default` AND `pr_url` is non-empty** → **`stay` mode** (review follow-up: append commits to the open PR's branch). Remember `pr_url` to report later.
3. **`current != default` AND `pr_url` is empty** → ambiguous. Ask the investor:
   > You're on `${current}` with no open PR. How should I apply this improvement?
   > 1. **Stay** on `${current}` and append commits (no new PR).
   > 2. **Branch off** `${current}` to `improve/<slug>` and open a new PR when done.

   Wait for their answer. Choice 1 → `stay` mode (with no `pr_url` to report). Choice 2 → `new-branch` mode (branched off `${current}` rather than `${default}`).

Record `mode`, `pr_url`, and the parent branch (`${default}` or `${current}`, depending on rule) for use in **Establish Branch** and **Finish**.

## Claim Work Unit

Slugify the improvement description into a branch-friendly name (lowercase, hyphens, max 40 chars). Used for the branch name in `new-branch` mode and for the catch-all commit message in both modes. Examples:
- "Fix header alignment on mobile" → `fix-header-alignment-mobile`
- "Add dark mode toggle" → `add-dark-mode-toggle`

Before changing a branch or `active_role`, capture the exact starting identity and claim
the work unit:

```bash
ORIGINAL_BRANCH=$(git branch --show-current)
ORIGINAL_HEAD=$(git rev-parse HEAD)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --acquire "improve:${slug}" --state-dir .startup/leases \
  --owner-file ".startup/leases/.owners/improve-${slug}.owner" --ttl-seconds 1800
IMPROVE_OWNER=$(sed -n '1p' ".startup/leases/.owners/improve-${slug}.owner")
IMPROVE_META=$(git rev-parse --git-path "saas-startup-team/improve-${slug}-${IMPROVE_OWNER}")
mkdir -p "$IMPROVE_META"
if [ -e .startup/state.json ]; then
  cp .startup/state.json "$IMPROVE_META/state.before"
  printf 'present\n' > "$IMPROVE_META/state-presence"
else
  printf 'absent\n' > "$IMPROVE_META/state-presence"
fi
```

If acquisition refuses, the branch and state are still untouched and no metadata
snapshot was created. Inspect the live owner's heartbeat/logs and completion artifact
instead of dispatching another worker.
Heartbeat after every founder phase with the same key and owner file.

## Establish Branch

**`stay` mode:** no branch operation — improvement commits land on the current branch.

**`new-branch` mode:**

```bash
if git rev-parse --verify "improve/${slug}" >/dev/null 2>&1; then
  echo "Branch improve/${slug} already exists."
else
  git checkout -b "improve/${slug}"
fi
```

If the branch already exists, tell the investor and ask them to either pick a different description or confirm deletion of the old branch (`git branch -D improve/${slug}`).
Until they confirm, do not change `active_role`; release the lease and remove only
`$IMPROVE_META`. After confirmation, restart **Claim Work Unit** so deletion and branch
creation occur under a fresh acquired lease.

## Reset active_role

Before dispatching any subagent, overwrite `active_role` in `.startup/state.json` to clear any stale value left over from a prior `/startup` session. The `enforce-delegation` hook fires only when `active_role=="team-lead"`; if a prior orchestrator session wrote that value, it will block this flow's subagents. Reset unconditionally — `/improve` is never a team-lead context.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "business-founder-maintain"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

On every handled early stop, and after final push/PR handling, release the lease with:
`single-flight.sh --release "improve:${slug}" --state-dir .startup/leases --owner-file
".startup/leases/.owners/improve-${slug}.owner"`.

**Refusal restoration is exact.** If the investor declines after the branch or state
change (including declining a business-founder pushback), first restore `state.json`
byte-for-byte from `$IMPROVE_META/state.before`, or remove it when
`state-presence` says it was originally absent. In `new-branch` mode, return to
`$ORIGINAL_BRANCH` and delete only `improve/${slug}`, but only after verifying that
`HEAD == $ORIGINAL_HEAD` and no product diff or product commit exists. In `stay` mode,
verify the current branch is still `$ORIGINAL_BRANCH`; do not switch it. If either
verification fails, stop and report the unexpected mutation instead of resetting or
deleting it. Finally release the lease and remove `$IMPROVE_META`. Refusal never leaves
`business-founder-maintain` in state or the investor on a newly-created branch.

```bash
if [ "$(cat "$IMPROVE_META/state-presence")" = present ]; then
  cp "$IMPROVE_META/state.before" .startup/state.json.tmp
  mv .startup/state.json.tmp .startup/state.json
else
  rm -f .startup/state.json
fi
if [ "$mode" = new-branch ]; then
  test "$(git branch --show-current)" = "improve/${slug}"
  test "$(git rev-parse HEAD)" = "$ORIGINAL_HEAD"
  test -z "$(git status --porcelain)"
  git checkout "$ORIGINAL_BRANCH"
  git branch -d "improve/${slug}"
else
  test "$(git branch --show-current)" = "$ORIGINAL_BRANCH"
fi
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --release "improve:${slug}" --state-dir .startup/leases \
  --owner-file ".startup/leases/.owners/improve-${slug}.owner"
rm -rf "$IMPROVE_META"
```

## Step 1: Business Founder — Brief

Before dispatch, read `mutation-ownership.md` and open a business role guard whose
allowlist contains only the exact expected brief/handoff artifact. Verify it immediately
after return. Product, workflow-spec, Git, and state mutations reject the phase. On a
successful verification, the supervisor must replay `index-handoff.sh` for that exact
handoff, run `compact-state.sh`, and persist any verified durable `docs/` artifact with
`commit-artifact.sh` before dispatching the tech phase.

Spawn business founder via Agent tool with `subagent_type: "saas-startup-team:business-founder-maintain"`:

Immediately before and after this Claude phase, append `business-brief` started and
terminal events for Fable/high. Use only stable status codes; leave unavailable token
fields null.

> Be token-frugal: read only what the task needs, in targeted ranges (not whole-file dumps), and never re-read content already in your context.
>
> **Improvement task: Write a brief for the tech founder.**
>
> The investor wants these changes: [investor's instructions]
> Selected acceptance packs, if any: [pack ids + rendered gates from `scripts/acceptance-packs.sh --render`]. A new public/indexable route MUST include `public_route_discoverability`, with its fields explicit in this brief rather than inferred from a sitemap or catalog registration.
>
> Before reading product or research docs, read and apply `${CLAUDE_PLUGIN_ROOT}/templates/delivery-scope-planning.md` and `${CLAUDE_PLUGIN_ROOT}/templates/delivery-scope-contract.md`. Treat a concrete improvement as direct feature planning: make one targeted repository-discovery pass, infer safe choices from existing conventions, and ask only about a missing choice that materially changes `Done`.
>
> Read `docs/architecture/architecture.md` for current stack and service URLs.
> Read `docs/business/brief.md` for product context.
> Read `.startup/workflows/registry.md` if it exists. If this improvement changes routes, jobs, states, webhooks, checkout/payment, LLM pipelines, support intake, operator flows, or handoff contracts, describe the proposed workflow-spec delta in the brief; do not edit the specs or registry.
> Read relevant `docs/research/` files if the improvement touches areas you researched.
> Read `docs/legal/` if the change could have compliance implications. If the brief draws on any `docs/legal/*.md` analysis, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/legal-verdict-gate.sh" <doc>...` on those docs and copy each JSON verdict line into the brief verbatim.
>
> **Before writing the brief**, evaluate the investor's request against your research and legal findings. If the change conflicts with legal compliance, undermines the business strategy, or risks hurting sales/conversion — push back with a clear, evidence-based explanation (cite specific docs). The investor may not have had time to analyze the implications.
>
> If the request is sound, write a handoff to the tech founder following your standard handoff protocol. Keep it concise — this is a targeted improvement, not a full feature.

If the business founder pushes back, relay their concerns to the investor. Proceed only if the investor confirms.

## Step 2: Tech Founder — Implementation

Before dispatch, execute both preflights in `mutation-ownership.md`: create a tech role
guard from the brief's exact source/test/workflow-spec/handoff scope, and snapshot
`COMMIT_TRUST` for this HEAD. Verify the role guard before containment or commit.

Use the host-native implementation path:

- **Claude Code surface:** pick the maintenance engine per the startup-orchestration
  guidance (Codex for spec-complete/backend/test-heavy/plumbing work; Claude for work
  that genuinely needs its frontend, architecture, or surgical-edit strengths), then
  spawn the tech founder via Agent tool with exactly one registered type:
  `saas-startup-team:tech-founder-claude-maintain` or
  `saas-startup-team:tech-founder-codex-maintain`. Include `Execution profile:
  <light|standard|deep>` in the task; the Codex controller passes it unchanged to
  `codex-implement.sh`.
- **Codex surface:** do not route to `tech-founder-claude*` or invoke Claude Code
  primitives. Use the `tech-founder` skill in the current session, or launch a separate
  worker with `scripts/codex-run-role.sh --role tech-founder --profile "$PROFILE"`
  and a task file.

Record Claude tech phases using the registered agent's actual frontmatter: Opus/xhigh
for the Claude writer or Sonnet/medium for the Codex controller. The controller event is
distinct from the automatic Codex implementation event and must not claim it wrote code.

Claude Code agent prompt:

> Be token-frugal: read only what the task needs, in targeted ranges (not whole-file dumps), and never re-read content already in your context.
> Follow the worker reliability rules in `${CLAUDE_PLUGIN_ROOT}/templates/worker-reliability.md` (re-resolve absolute paths after any checkout/worktree switch; retry a stale read once before re-editing).
>
> **Improvement task: Implement the latest handoff from the business founder.**
> Execution profile: [PROFILE].
>
> Read `docs/architecture/architecture.md` for stack and service URLs.
> Read any `.startup/workflows/WORKFLOW-*.md` files referenced by the business-founder brief and update them if route/job/state/handoff-contract behavior changes.
> Start the dev server using the command in the architecture doc — it is not running from a previous session.
>
> Implement the changes and write your handoff back to the business founder following your standard handoff protocol.
>
> **Before writing your handoff, self-verify the change at the code level** — browser QA in the next step does not catch type errors, failing units, or parse/enum bugs:
> - Run `./check.sh` — the canonical full-suite entrypoint (recorded in `docs/architecture/architecture.md`; it runs every suite: build, unit, lint, typecheck, golden/E2E). Fix candidate-caused failures. If unrelated or pre-existing failures keep the gate red, report the blocker without changing unrelated code; do not hand off red.
> - Re-read your own diff for the bug classes that slip past visual QA: enum/string parsing, off-by-one and boundary cases, null/undefined handling, and untested error paths.
> - For triggered SaaS gates, verify the smallest relevant evidence: workflow spec update, slow async paid state, missing display-label fallback, mobile checkout field/CTA flow, malformed LLM output, or inconclusive compliance claim fixture.
> - For `public_route_discoverability`, add a reachability test when the repository has a route/catalog test pattern, and repeat the entry surfaces, click paths, locale behavior, and any unlisted/noindex exception in your handoff.
> - In your handoff, state explicitly which checks you ran and that they passed. If a check could not be run, say so and why.
>
> Set 10s timeouts on all HTTP calls.

Codex role phases use the same task body. The pinned launcher owns model/effort and
records requested/effective values; only an explicit Terra-unavailable error may use its
one Sol/medium fallback.

The supervisor now owns the product commit. After the tech phase returns, stage the
delivery, run the canonical gate, and commit the exact checked tree with hooks enabled:

For a `light` attempt, inspect the guarded working tree with shared `check-diff --base
"$ATTEMPT_BASE"` before committing. Continue
only when it remains `profile=light` and, because this route is autonomous,
`ui_touch=false`. Otherwise write a versioned escalation artifact, discard only this
clean-start attempt, and rerun the tech phase once at deep. A missing artifact or second
light-to-deep transition is a hard failure.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/supervisor-commit.sh" \
  --message "improve: ${slug}" --check ./check.sh \
  --trust-receipt "$COMMIT_TRUST" --auth-stdin <<<"$MUTATION_AUTH"
QA_AUTH=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutation-auth-token.sh")
QA_GUARD="$(git rev-parse --git-path "saas-startup-team/qa-${slug}.json")"
QA_REVIEW=".startup/reviews/improve-${slug}-${run_id}.md"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-mutation-guard.sh" \
  --snapshot "$QA_GUARD" --auth-stdin --allow "$QA_REVIEW" <<<"$QA_AUTH"
```

If the check or commit fails, do not dispatch QA and do not push.
After the commit succeeds, the supervisor must replay `index-handoff.sh` for the exact
tech handoff and run `compact-state.sh` before opening the QA guard.

## Step 3: Business Founder — QA

Spawn business founder via Agent tool with `subagent_type: "saas-startup-team:business-founder-maintain"`:

Record this review-only Fable/high phase as `business-qa`; its terminal event includes
the `qa` status code. The mutation guard result is a separate supervisor progress event.

> Be token-frugal: read only what the task needs, in targeted ranges (not whole-file dumps), and never re-read content already in your context.
>
> **QA task: Verify the tech founder's latest implementation.**
>
> Read the tech founder's latest handoff for what was changed and how to verify.
>
> Open browser to the localhost URL from the handoff and verify:
> - Does the change meet the acceptance criteria?
> - Any visual regressions on the affected pages?
> - Does it work on mobile viewport (375px)?
> - If `public_route_discoverability` is selected, start at each named existing entry surface and click through in every locale. Direct navigation to the destination cannot PASS; record the structured discoverability evidence from the design-review leg.
> - If the change touched a workflow spec, do the QA cases in `.startup/workflows/WORKFLOW-*.md` pass or need registry follow-up?
> - If relevant, are async paid-flow states, checkout CTA proximity, customer copy/value units, structured-result labels, LLM quality evidence, and compliance claim boundaries acceptable?
> - Does the new element cohere with its *rendered* neighbors (alignment, width, spacing, hierarchy) in the state that will actually ship — judged independently of whether the brief said to reuse existing tokens/patterns?
> - Success is not "matches the brief" — a brief can specify a defect. Judge the shipped design independently against the coherence pass and triggered product gates in your agent file, wherever the diff touches their surfaces.
> - Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui-touch.sh" --range "${default}...HEAD"`. Unless it prints exactly `no-ui`, you MUST run the pre-merge leg in `${CLAUDE_PLUGIN_ROOT}/skills/ux-tester/references/design-review-leg.md` and its `## Design-review: PASS|FAIL` verdict block (with the Pages/Shots evidence line) must land in the PR body — you cannot return PASS while the design-review is FAIL.
> - If any consumed `docs/legal/*.md` analysis is hedged, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/legal-verdict-gate.sh" <doc>...` (mechanical, not from memory) and FAIL the diff if it states the hedged claim as unconditional fact in code/copy/prompts, or adds tests asserting the hedged value as fact — conditional wording only.
>
> Write your review to the exact supervisor-provided `$QA_REVIEW` path following your
> standard review process. Do not create, replace, or delete any other review.
> This is a review-only phase: read product code as needed, but write only the review artifact. Never modify source, tests, workflow specs, or state.

Immediately after QA returns, enforce the boundary before reading its verdict:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-mutation-guard.sh" \
  --verify "$QA_GUARD" --auth-stdin <<<"$QA_AUTH"
```

Any non-zero guard result is an unauthorized QA mutation: stop, report the changed
paths, and do not commit or push them.

If the selected packs include `public_route_discoverability`, run
`acceptance-packs.sh --verify-public-route "$QA_REVIEW"`. A nonzero result makes QA
FAIL; destination-only evidence cannot be accepted.

## Step 4: Handle QA Result

Read the business founder's review.

**If PASS:** Proceed to **Finish**.

**If FAIL (first attempt):**

Dispatch tech founder to fix using the same host-native split as Step 2:

> Use `subagent_type: "saas-startup-team:tech-founder-claude-maintain"` or `subagent_type: "saas-startup-team:tech-founder-codex-maintain"` — match the engine to the fix per the engine-selection guidance.
>
> **Fix task: Address the business founder's QA findings.**
>
> Read the business founder's latest review for what failed.
> Read the original handoff for the requirements.
>
> Fix the issues, then re-run `./check.sh` (the canonical full-suite entrypoint) and confirm it passes before handing off. Write an updated handoff back to the business founder stating that check.sh passed.

In Codex, load the `tech-founder` skill in the current session or use
`codex-run-role.sh --role tech-founder --profile "$PROFILE"` with a focused fix task;
never read a `tech-founder-claude*` agent file or launch an unpinned worker.

Before the fix writer, the supervisor creates a fresh tech role guard and a fresh
`COMMIT_TRUST` from the current committed HEAD. It verifies the role guard, repeats
`supervisor-commit.sh --trust-receipt "$COMMIT_TRUST" --auth-stdin <<<"$MUTATION_AUTH"`,
refreshes `$QA_GUARD` with a fresh `$QA_AUTH`, then
dispatches business founder for re-QA following Step 3 and verifies the guard again.

**If FAIL (second attempt):** Proceed to **Finish** anyway — mark as draft so the investor can review and decide.

## Finish

1. **Require the supervisor-gated product commit.** Product changes were committed
   before each QA attempt. Do not catch stragglers or bypass hooks here:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-mutation-guard.sh" \
     --verify "$QA_GUARD" --auth-stdin <<<"$QA_AUTH"
   ```

2. **Draft failed stay-mode PR, then push.** If the second QA attempt failed in
   `stay` mode and `$pr_url` exists, convert that PR to draft before pushing/reporting:
   ```bash
   if [ "$mode" = "stay" ] && [ "$qa_status" = "failed" ] && [ -n "$pr_url" ]; then
     gh pr ready --undo "$pr_url"
   fi
   ```
   If draft conversion or push fails, report the error and do not proceed.

   `new-branch` mode (first push of a freshly created branch):
   ```bash
   git push -u origin HEAD
   ```

   `stay` mode (push appended commits to the existing remote branch):
   ```bash
   git push origin HEAD
   ```

3. **PR handling — depends on mode.**

   **`stay` mode:** do NOT call `gh pr create`. Skip to step 4.

   **`new-branch` mode:** create the PR.

   If the improvement resolves a reported incident/issue (a GitHub issue or a Plane work item — e.g. anything the nightly monitor filed), the fix MUST include a regression test (see the tech founder's Bug Fix Protocol), and the PR body MUST link the issue (`Closes #<n>` for GitHub, or `Plane-Item: <id|url>` for Plane) and describe the test in a `## Regression test` section. An incident-linked PR with no test in its diff is **blocked at merge** by the regression-test gate; override only with `Regression-Test: none — <reason>` in the body.

   If the PR body/title uses a GitHub closing keyword (`Closes`, `Fixes`, or `Resolves`),
   run the closure audit before the PR is considered ready:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue-closure-audit.sh" --pr "<pr-url-or-number>"
   ```
   If it flags an issue surface named in the original issue/comments that the PR did not
   touch, do one of three things before merge: implement that surface, add a `## Closure
   audit` explanation with a follow-up issue for the remaining acceptance, or change the
   closing keyword to `Refs #<n>`.

   If QA passed:
   ```bash
   gh pr create \
     --title "improve: [short description]" \
     --body "$(cat <<'EOF'
   ## What

   [investor's improvement description]

   ## Changes

   [summary from tech founder's handoff — files modified, what changed]

   ## Regression test

   [if this resolves an incident/issue: test file path + what it reproduces, and `Closes #<n>` / `Plane-Item: <id|url>`. Otherwise: "n/a — not an incident fix".]

   ## Closure audit

   [if this PR uses `Closes`/`Fixes`/`Resolves`: state whether the PR satisfies every material promise in the full issue body and comments. If any named surface is intentionally not touched, link the follow-up issue or explain why that acceptance is no longer relevant. Otherwise: "n/a — no closing keyword".]

   [if any `docs/legal/*.md` analysis informed this change, add one `Legal-Verdict: <verdict> — <path>` line per consumed doc, from the gate's JSON output.]

   ## QA: PASS

   [key observations from business founder's review; when the diff is UI-touching, include the `## Design-review: PASS` verdict block]
   EOF
   )"
   ```

   If QA failed after retries — add `--draft`:
   ```bash
   gh pr create --draft \
     --title "improve: [short description]" \
     --body "$(cat <<'EOF'
   ## What

   [investor's improvement description]

   ## Changes

   [summary from tech founder's handoff]

   [if any `docs/legal/*.md` analysis informed this change, add one `Legal-Verdict: <verdict> — <path>` line per consumed doc, from the gate's JSON output.]

   ## QA: NEEDS REVIEW

   [issues from business founder's review — what failed and why]
   EOF
   )"
   ```

4. **Return to parent branch — `new-branch` mode only.**
   ```bash
   git checkout "${parent}"
   ```
   where `${parent}` is the branch that was current when `/improve` started (`${default}` for greenfield, or the feature branch chosen in mode-C "branch off"). The `improve/${slug}` branch persists until the PR is merged or the investor deletes it.

   **`stay` mode:** do not switch branches. The investor stays on the current branch so they can continue reviewing or stack additional fixes.

5. **Report to investor.**

   - `new-branch` mode: report the new PR URL and QA status.
   - `stay` mode: report a one-line summary of what changed and the existing PR URL (if `pr_url` was captured in **Detect Mode**); if there was no open PR (mode-C "stay"), report just the branch state and QA status.

   Append the command-level terminal event with check, QA, PR, and outcome status codes.
   On every handled early stop, append an explicit failure/blocked/cancelled outcome;
   never leave an interrupted run looking successful.

6. **Release the lease** after success or the handled draft outcome:
   ```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
     --release "improve:${slug}" --state-dir .startup/leases \
     --owner-file ".startup/leases/.owners/improve-${slug}.owner"
rm -rf "$IMPROVE_META"
   ```

## Communication

Investor-communication language: see `${CLAUDE_PLUGIN_ROOT}/templates/communication.md`.
