---
name: tweak
description: Direct-edit shortcut for trivial fixes on a completed product — typos, copy tweaks, small CSS nudges. Edits files directly (no agents). On main, creates a tweak/ branch and opens a PR; on a feature branch, commits to that branch and pushes (no new PR). For anything needing QA, use /improve instead. Usage: /tweak [description]
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

## Determine Branch Mode

Read the current branch:

```bash
current_branch=$(git rev-parse --abbrev-ref HEAD)
```

- **`current_branch` is `main`** → **new-branch mode**: create a `tweak/<slug>` branch, open a PR, return to `main` (the original `/tweak` flow).
- **Anything else** (you're on a feature branch) → **on-branch mode**: commit the tweak to the current branch and push it. No new branch, no PR, no branch switch.

This flow assumes `main` is the repo's default branch (consistent with the rest of the command). If a product repo uses a different default branch name, run `/tweak` from a feature branch.

## Create Branch — new-branch mode only

Skip this step in on-branch mode; the edit lands directly on `current_branch`.

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
- If, while making the edit, you realize the change is larger than a tweak (touches 3+ files, involves logic changes, needs theme token refactoring), stop, tell the investor, and offer to abort:
  > This is larger than it looked. Consider aborting and running `/improve` instead. Abort `/tweak`?

  On abort:
  - **New-branch mode:** `git checkout main && git branch -D tweak/${slug}` (deletes the tweak branch and the edit).
  - **On-branch mode:** discard the uncommitted edit with `git restore .` and stay on `current_branch`. Do not delete the branch.

## Commit

Defensive commit — the plugin's `auto-commit.sh` hook may have already fired on an edit inside `docs/` and committed it with its own message:

```bash
git add -A
# Guard the catch-all `git add -A`: abort if a dependency tree, package store, or >50 MB blob got
# staged (e.g. a build artifact produced by the edit), which would make the push fail and require a
# history rewrite. Actionable message on failure; STARTUP_MAX_STAGED_MB overrides the limit.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-staged-size.sh" || {
  echo "Aborting: staged tree has oversized/ignored files (see above). Fix .gitignore + git rm -r --cached, then retry." >&2
  exit 1
}
git diff --cached --quiet || git commit -m "tweak: ${description}"
```

**Do not pass `--no-verify`.** This is `/tweak`'s primary commit — project pre-commit hooks (prettier, eslint, type-check) should run. If a pre-commit hook fails, report the error to the investor:

> Pre-commit hook failed: `<error summary>`.
> The edit is staged on `current_branch` but not committed. Options:
> 1. Fix the issue and commit manually, then push.
> 2. Abort (loses the edit):
>    - **New-branch mode:** `git checkout main && git branch -D tweak/${slug}`
>    - **On-branch mode:** `git restore --staged . && git restore .` (stays on `current_branch`)

Then stop — do not proceed to push or PR.

## Push (both modes)

**Push the current branch.** If push fails, report the error and stop. The branch and commit exist locally; the investor can retry by hand.

```bash
git push -u origin HEAD
```

**On-branch mode stops here.** Do **not** open a PR and do **not** switch branches — the tweak commit rides on the feature branch and is covered by that branch's existing (or eventual) PR. **Report to investor:** the tweak is committed to `current_branch` and pushed, with a one-line summary of what changed.

**New-branch mode** continues to Open Pull Request below.

## Open Pull Request — new-branch mode only

1. **Create the PR (non-draft):**
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

2. **Return to main branch:**
   ```bash
   git checkout main
   ```
   The `tweak/${slug}` branch persists until the PR is merged or deleted.

3. **Report to investor** with the PR URL and a one-line summary of what changed.

## What /tweak Does Not Do

- No browser QA — the investor reviews the diff themselves (in the new PR, or in the feature branch's PR when in on-branch mode).
- No retry on failure — there's no pass/fail signal from an agent; the PR review is the feedback.
- No dev server start, no MCP calls, no `Task` dispatch.
- No writes to `.startup/handoffs/`, `reviews/`, `signoffs/`, or `go-live/`.
- On a feature branch (on-branch mode): no new branch, no new PR, and no branch switch — the tweak commit stays on the current branch.

## Communication

Speak **English** to the investor. `/tweak` doesn't involve the business founder, so the Estonian-for-business-founder rule doesn't apply here.
