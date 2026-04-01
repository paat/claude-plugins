---
name: improve
description: One-shot improvements on a completed product — runs in an isolated git worktree and opens a PR when done. Routes through business founder for context enrichment and browser QA. Usage: /improve [description of changes]
user_invocable: true
---

# /improve — One-Shot Product Improvements

You are the **Team Lead** (orchestrator) executing a single improvement cycle. The investor described changes they want. You create an isolated git worktree, dispatch business founder → tech founder → business founder QA, then open a PR.

Each `/improve` runs in its own worktree, so the investor can launch multiple improvements in parallel.

## Pre-Flight

Run these checks in the **current directory** (before entering the worktree):

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

## Capture Instructions

If the user provided arguments with the command, use them as the improvement description.

Otherwise ask:
> What would you like improved? Describe the changes.

## Scope Guard

Before dispatching, assess the request. If it contains 3+ distinct features or requires significant new functionality (new pages, new integrations, new data models):

> This looks like a feature, not an improvement. Consider running `/startup` to resume the build loop for this scope. Want to proceed with `/improve` anyway?

This is advisory — proceed if the investor confirms.

## Enter Worktree

Slugify the improvement description into a branch-friendly name (lowercase, hyphens, max 40 chars). Examples:
- "Fix header alignment on mobile" → `fix-header-alignment-mobile`
- "Add dark mode toggle" → `add-dark-mode-toggle`

Call **EnterWorktree** with name `improve/{slug}`.

> This creates an isolated copy of the repo on a new branch. All agent work from this point happens in the worktree — the main branch stays clean.

After entering the worktree, initialize the improvements directory (gitignored, so absent from fresh worktree):
```bash
mkdir -p .startup/improvements
```

The improvement number is always `001` (each worktree starts fresh):
```bash
next_num="001"
```

## Step 1: Dispatch Business Founder (Brief)

Spawn business founder via Task tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
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
> **Before writing the brief**, evaluate the investor's request against your research and legal findings. If the change conflicts with legal compliance, undermines the business strategy, or risks hurting sales/conversion — push back to the team lead with a clear, evidence-based explanation (cite specific docs). The investor may not have had time to analyze the implications.
>
> If the request is sound, write a brief to `.startup/improvements/${next_num}-brief.md` that includes:
> - What to change (specific, actionable)
> - Why (context the tech founder needs)
> - Acceptance criteria (what "done" looks like)
> - Any related concerns (responsive behavior, i18n, accessibility)
>
> Do NOT use the full handoff template — keep it concise. This is a targeted improvement, not a feature.
>
> After writing, message the team lead: "Improvement brief ${next_num} ready for tech founder."

## Step 2: Dispatch Tech Founder (Implementation)

Spawn tech founder via Task tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder.md` for your identity and tools.
>
> **Improvement task: Implement changes from brief.**
>
> Read `.startup/improvements/${next_num}-brief.md` for what to change.
> Read `docs/architecture/architecture.md` for stack and service URLs.
>
> Start the dev server using the command in `docs/architecture/architecture.md` — it is not running from a previous session.
>
> Implement the changes. Write a summary of what you changed to `.startup/improvements/${next_num}-implementation.md`:
> - Files modified
> - What was changed and why
> - How to verify (localhost URL, specific page/action)
>
> Set 10s timeouts on all HTTP calls.
>
> After completing, message the team lead: "Implementation ${next_num} complete."

## Step 3: Dispatch Business Founder (QA)

Read `.startup/improvements/${next_num}-implementation.md` to extract the localhost URL and verification instructions.

Spawn business founder via Task tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
>
> **QA task: Verify improvement implementation.**
>
> Read `.startup/improvements/${next_num}-brief.md` for what was requested.
> Read `.startup/improvements/${next_num}-implementation.md` for what was changed.
>
> Open browser to `{localhost URL from implementation summary}` and verify:
> - Does the change meet the acceptance criteria from the brief?
> - Any visual regressions on the affected pages?
> - Does it work on mobile viewport (375px)?
>
> Write your QA result to `.startup/improvements/${next_num}-qa.md`:
> - PASS or FAIL
> - What you verified
> - Screenshots or observations
> - If FAIL: specific issues found
>
> After writing, message the team lead: "QA ${next_num} complete."

## Step 4: Handle QA Result

Read `.startup/improvements/${next_num}-qa.md`.

**If PASS:** Proceed to **Open Pull Request**.

**If FAIL (first attempt):**

Set `fix_num="002"`.

Dispatch tech founder:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder.md` for your identity and tools.
>
> **Fix task: Address QA findings.**
>
> Read `.startup/improvements/${next_num}-qa.md` for what failed.
> Read `.startup/improvements/${next_num}-brief.md` for original requirements.
> Read `.startup/improvements/${next_num}-implementation.md` for what was done.
>
> Fix the issues. Write updated summary to `.startup/improvements/${fix_num}-implementation.md`.
>
> After completing, message the team lead: "Fix ${fix_num} complete."

Then dispatch business founder for re-QA with the same pattern as Step 3, using `${fix_num}`.

**If FAIL (second attempt):** Proceed to **Open Pull Request** anyway — mark as draft so the investor can review and decide.

## Open Pull Request

After the improvement cycle completes (QA passed or max retries reached):

1. **Stage and commit any remaining changes** (auto-commit hook handles most, but catch stragglers):
   ```bash
   git add -A docs/ backend/ frontend/ CLAUDE.md
   git diff --cached --quiet || git commit -m "improve: ${slug}" --no-verify
   ```

2. **Push the branch:**
   ```bash
   git push -u origin HEAD
   ```

3. **Create the PR:**

   Read the QA result to determine if it passed. Build the PR:

   If QA passed:
   ```bash
   gh pr create \
     --title "improve: [short description]" \
     --body "$(cat <<'EOF'
   ## What

   [investor's improvement description]

   ## Changes

   [summary from implementation file — files modified, what changed]

   ## QA: PASS

   [key observations from QA file]
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

   [summary from implementation file]

   ## QA: NEEDS REVIEW

   [issues from QA file — what failed and why]
   EOF
   )"
   ```

4. **Report to investor** with the PR URL and QA status.

5. **Exit worktree:**

   Call **ExitWorktree** with action `keep`.

   > The worktree and branch are preserved until the PR is merged or closed.

## Communication

Same language rules as the build loop:
- Business founder speaks **Estonian** to investor
- Tech founder speaks **English** to investor
- Team lead speaks **English** for status updates
