---
name: improve
description: One-shot improvements on a completed product — creates a branch and opens a PR when run from the default branch, or appends commits to the current branch when run on a feature branch with an open PR (review follow-up). Routes through business founder for context enrichment and browser QA. Usage: /improve [description of changes]
user_invocable: true
---

# /improve — One-Shot Product Improvements

Execute a single improvement cycle: dispatch business founder → tech founder → business founder QA, then either open a new PR (greenfield) or append commits to the in-flight PR branch (review follow-up).

## Branching Modes

`/improve` detects the operating context from the current branch and the open-PR state, and chooses one of two modes:

- **`new-branch` mode** — create `improve/<slug>` off the current branch, open a new PR at the end, return to the parent branch. This is the greenfield case (run on the default branch) and the "fork-off" variant of mode C below.
- **`stay` mode** — stay on the current branch, commit and push, do NOT open a new PR. If there is an open PR for this branch, report its URL. This is the review-follow-up case: fixes stack onto the in-flight PR so reviewers and CI re-evaluate the same branch.

The mode is selected automatically when unambiguous, and chosen by the investor when ambiguous. See **Detect Mode** below.

## Pre-Flight

1. Verify `.startup/` exists — if not:
   > Run `/startup` first to build the product.

2. Verify solution signoff exists:
   ```bash
   ls .startup/go-live/solution-signoff.md 2>/dev/null
   ```
   If not found:
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

Otherwise ask:
> What would you like improved? Describe the changes.

## Scope Guard

Before dispatching, assess the request. If it contains 3+ distinct features or requires significant new functionality (new pages, new integrations, new data models):

> This looks like a feature, not an improvement. Consider running `/startup` to resume the build loop for this scope. Want to proceed with `/improve` anyway?

This is advisory — proceed if the investor confirms.

## Detect Mode

Determine which mode to run in:

```bash
current=$(git rev-parse --abbrev-ref HEAD)
default=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
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

## Establish Branch

Slugify the improvement description into a branch-friendly name (lowercase, hyphens, max 40 chars). Used for the branch name in `new-branch` mode and for the catch-all commit message in both modes. Examples:
- "Fix header alignment on mobile" → `fix-header-alignment-mobile`
- "Add dark mode toggle" → `add-dark-mode-toggle`

**`stay` mode:** no branch operation — improvement commits land on the current branch.

**`new-branch` mode:**

```bash
if git rev-parse --verify "improve/${slug}" >/dev/null 2>&1; then
  echo "Branch improve/${slug} already exists."
fi
git checkout -b "improve/${slug}"
```

If the branch already exists, tell the investor and ask them to either pick a different description or confirm deletion of the old branch (`git branch -D improve/${slug}`).

## Reset active_role

Before dispatching any subagent, overwrite `active_role` in `.startup/state.json` to clear any stale value left over from a prior `/startup` session. The `enforce-delegation` hook fires only when `active_role=="team-lead"`; if a prior orchestrator session wrote that value, it will block this flow's subagents. Reset unconditionally — `/improve` is never a team-lead context.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "business-founder-maintain"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

## Step 1: Business Founder — Brief

Spawn business founder via Agent tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder-maintain.md` for your identity and tools.
>
> **Improvement task: Write a brief for the tech founder.**
>
> The investor wants these changes: [investor's instructions]
>
> Read `docs/architecture/architecture.md` for current stack and service URLs.
> Read `docs/business/brief.md` for product context.
> Read relevant `docs/research/` files if the improvement touches areas you researched.
> Read `docs/legal/` if the change could have compliance implications.
>
> **Before writing the brief**, evaluate the investor's request against your research and legal findings. If the change conflicts with legal compliance, undermines the business strategy, or risks hurting sales/conversion — push back with a clear, evidence-based explanation (cite specific docs). The investor may not have had time to analyze the implications.
>
> If the request is sound, write a handoff to the tech founder following your standard handoff protocol. Keep it concise — this is a targeted improvement, not a full feature.

If the business founder pushes back, relay their concerns to the investor. Proceed only if the investor confirms.

## Step 2: Tech Founder — Implementation

Spawn tech founder via Agent tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder-maintain.md` for your identity and tools.
>
> **Improvement task: Implement the latest handoff from the business founder.**
>
> Read `docs/architecture/architecture.md` for stack and service URLs.
> Start the dev server using the command in the architecture doc — it is not running from a previous session.
>
> Implement the changes and write your handoff back to the business founder following your standard handoff protocol.
>
> Set 10s timeouts on all HTTP calls.

## Step 3: Business Founder — QA

Spawn business founder via Agent tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder-maintain.md` for your identity and tools.
>
> **QA task: Verify the tech founder's latest implementation.**
>
> Read the tech founder's latest handoff for what was changed and how to verify.
>
> Open browser to the localhost URL from the handoff and verify:
> - Does the change meet the acceptance criteria?
> - Any visual regressions on the affected pages?
> - Does it work on mobile viewport (375px)?
>
> Write your review following your standard review process.

## Step 4: Handle QA Result

Read the business founder's review.

**If PASS:** Proceed to **Finish**.

**If FAIL (first attempt):**

Dispatch tech founder to fix:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder-maintain.md` for your identity and tools.
>
> **Fix task: Address the business founder's QA findings.**
>
> Read the business founder's latest review for what failed.
> Read the original handoff for the requirements.
>
> Fix the issues and write an updated handoff back to the business founder.

Then dispatch business founder for re-QA following the same pattern as Step 3.

**If FAIL (second attempt):** Proceed to **Finish** anyway — mark as draft so the investor can review and decide.

## Finish

1. **Stage and commit any remaining changes** (auto-commit hook handles most, but catch stragglers). Used in both modes:
   ```bash
   git add -A
   git diff --cached --quiet || git commit -m "improve: ${slug}" --no-verify
   ```
   Note: `--no-verify` is intentional — the auto-commit hook would otherwise re-trigger on this catch-all commit.

2. **Push.** If push fails, report the error to the investor and do NOT proceed.

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

   If QA passed:
   ```bash
   gh pr create \
     --title "improve: [short description]" \
     --body "$(cat <<'EOF'
   ## What

   [investor's improvement description]

   ## Changes

   [summary from tech founder's handoff — files modified, what changed]

   ## QA: PASS

   [key observations from business founder's review]
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

## Communication

Same language rules as the build loop:
- Business founder speaks **Estonian** to investor
- Tech founder speaks **English** to investor
