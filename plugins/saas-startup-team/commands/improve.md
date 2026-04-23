---
name: improve
description: One-shot improvements on a completed product — creates a branch and opens a PR when done. Routes through business founder for context enrichment and browser QA. Usage: /improve [description of changes]
user_invocable: true
---

# /improve — One-Shot Product Improvements

Execute a single improvement cycle: create a feature branch, dispatch business founder → tech founder → business founder QA, open a PR, return to main.

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

## Create Branch

Slugify the improvement description into a branch-friendly name (lowercase, hyphens, max 40 chars). Examples:
- "Fix header alignment on mobile" → `fix-header-alignment-mobile`
- "Add dark mode toggle" → `add-dark-mode-toggle`

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

**If PASS:** Proceed to **Open Pull Request**.

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

**If FAIL (second attempt):** Proceed to **Open Pull Request** anyway — mark as draft so the investor can review and decide.

## Open Pull Request

1. **Stage and commit any remaining changes** (auto-commit hook handles most, but catch stragglers):
   ```bash
   git add -A
   git diff --cached --quiet || git commit -m "improve: ${slug}" --no-verify
   ```
   Note: `--no-verify` is intentional — the auto-commit hook would otherwise re-trigger on this catch-all commit.

2. **Push the branch.** If push fails, report the error to the investor and do NOT proceed to PR creation.
   ```bash
   git push -u origin HEAD
   ```

3. **Create the PR:**

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

4. **Return to main branch:**
   ```bash
   git checkout main
   ```
   The `improve/${slug}` branch persists until the PR is merged or the investor deletes it.

5. **Report to investor** with the PR URL and QA status.

## Communication

Same language rules as the build loop:
- Business founder speaks **Estonian** to investor
- Tech founder speaks **English** to investor
