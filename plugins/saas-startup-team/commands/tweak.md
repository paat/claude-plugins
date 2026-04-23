---
name: tweak
description: Direct-edit shortcut for trivial fixes on a completed product — typos, copy tweaks, small CSS nudges. Creates a branch, edits files directly (no agents), opens a PR. For anything needing QA, use /improve instead. Usage: /tweak [description]
user_invocable: true
---

# /tweak — Direct-Edit Shortcut

Skip the full `/improve` pipeline for trivial fixes. You (team lead) read the relevant files, make the change the investor described, commit, and open a PR. No business founder brief, no tech founder dispatch, no browser QA.

Use this for typos, copy changes, small CSS nudges, broken link fixes. For anything that could affect behavior, use `/improve`.

## Pre-Flight

1. Verify `.startup/` exists — if not:
   > Run `/startup` first to build the product.

2. Verify solution signoff exists:
   ```bash
   ls .startup/go-live/solution-signoff.md 2>/dev/null
   ```
   If not found:
   > The build loop hasn't completed yet. Use `/startup` to resume or `/nudge` to redirect. `/tweak` is for post-completion fixes.

3. Verify working tree is clean:
   ```bash
   git status --porcelain
   ```
   If not clean:
   > There are uncommitted changes. Commit or stash them before running `/tweak`.

## Capture Description

If the user provided arguments with the command, use them as the tweak description.

Otherwise ask:
> What do you want tweaked?

If the response is empty or fewer than 3 non-whitespace characters, refuse:
> Description too short — say what you want changed.

Abort without creating any branch, file, or state change.

## Scope Guard (advisory)

Assess the request. If it contains 3+ distinct changes, or mentions new features/integrations/data models, warn:

> This looks bigger than a tweak. `/improve` routes through the business founder for context enrichment and does browser QA — use it for anything needing verification. Proceed with `/tweak` anyway?

Proceed only on explicit confirmation. Otherwise suggest `/improve` and stop.

## Create Branch

Slugify the description into a branch-friendly name (lowercase, hyphens, max 40 chars). Examples:
- "Fix typo on pricing page" → `fix-typo-pricing-page`
- "Change CTA button text to 'Start free'" → `change-cta-button-text`

```bash
if git rev-parse --verify "tweak/${slug}" >/dev/null 2>&1; then
  echo "Branch tweak/${slug} already exists."
fi
git checkout -b "tweak/${slug}"
```

If the branch already exists, tell the investor and ask them to either pick a different description or confirm deletion (`git branch -D tweak/${slug}`).

## Set active_role

Overwrite `active_role` in `.startup/state.json` to `team-lead-tweak`. The `enforce-delegation` hook only blocks edits when `active_role == "team-lead"` exactly; any other value (including `team-lead-tweak`) passes through and lets the orchestrator edit implementation code for this flow.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "team-lead-tweak"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

## Make the Edit

You are the orchestrator, not an agent. Find the location to change and edit it directly.

Guidelines:
- Read the relevant files first. Don't guess at line numbers or text.
- Make the **minimal** edit that satisfies the investor's description.
- If the edit location is ambiguous (e.g. "fix the broken link on the about page" but multiple candidates exist), **ask the investor** which one. Don't guess.
- If, while making the edit, you realize the change is larger than a tweak (touches 3+ files, involves logic changes, needs theme token refactoring), stop and tell the investor:
  > This is larger than it looked. Consider aborting and running `/improve` instead. Abort `/tweak`? (will delete branch `tweak/${slug}`)
  On abort: `git checkout main && git branch -D tweak/${slug}`.

## Commit

Defensive commit — the plugin's `auto-commit.sh` hook may have already fired on an edit inside `docs/` and committed it with its own message:

```bash
git add -A
git diff --cached --quiet || git commit -m "tweak: ${description}"
```

**Do not pass `--no-verify`.** This is `/tweak`'s primary commit — project pre-commit hooks (prettier, eslint, type-check) should run. If a pre-commit hook fails, report the error to the investor:

> Pre-commit hook failed: `<error summary>`.
> The branch `tweak/${slug}` has the edit staged but not committed. Options:
> 1. Fix the issue and commit manually, then push.
> 2. Abort: `git checkout main && git branch -D tweak/${slug}` (loses the edit).

Then stop — do not proceed to push or PR.

## Open Pull Request

1. **Push the branch.** If push fails, report the error and stop. The branch and commit exist locally; the investor can retry by hand.
   ```bash
   git push -u origin HEAD
   ```

2. **Create the PR (non-draft):**
   ```bash
   diff_stat=$(git diff main...HEAD --stat)
   gh pr create --title "tweak: ${short_description}" --body "$(cat <<EOF
   ## What

   ${investor_description}

   ## Diff summary

   \`\`\`
   ${diff_stat}
   \`\`\`
   EOF
   )"
   ```

   If `gh pr create` fails, report the error. The branch is pushed — the investor can create the PR in the GitHub UI.

3. **Return to main branch:**
   ```bash
   git checkout main
   ```
   The `tweak/${slug}` branch persists until the PR is merged or deleted.

4. **Report to investor** with the PR URL and a one-line summary of what changed.

## What /tweak Does Not Do

- No browser QA — the investor reviews the PR diff themselves.
- No retry on failure — there's no pass/fail signal from an agent; the PR review is the feedback.
- No dev server start, no MCP calls, no `Task` dispatch.
- No writes to `.startup/handoffs/`, `reviews/`, `signoffs/`, or `go-live/`.

## Communication

Speak **English** to the investor. `/tweak` doesn't involve the business founder, so the Estonian-for-business-founder rule doesn't apply here.
