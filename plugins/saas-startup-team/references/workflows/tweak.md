---
name: tweak
description: Trapped shortcut for trivial fixes on a completed product — typos, copy tweaks, small CSS nudges. Applies one contained patch without agents. On main, creates a tweak/ branch and opens a PR; on a feature branch, commits to that branch and pushes. Usage: /tweak [description]
user_invocable: true
---

# /tweak — Trapped Tweak Playbook

Skip the full `/improve` pipeline for trivial fixes. The team lead prepares one minimal
patch; the trapped helper applies, contains, commits, and pushes it. No founder or QA.

Use this for typos, copy changes, small CSS nudges, broken link fixes. For anything that could affect behavior, use `/improve`.

Load `${CLAUDE_PLUGIN_ROOT}/references/workflows/routing-telemetry.md` before routing
or mutation. Reuse one `SAAS_RUN_ID` for this delivery.

## Pre-Flight

0. Run the reusable health preflight:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --check-sync
   ```

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

Set `route_mode=interactive-tweak`. If the user provided arguments with the command, use
them as the explicitly requested tweak description.

Otherwise run internal demand discovery. If it returns a candidate, use its description
and set `route_mode=autonomous`; the autonomous classifier, not the broader tweak
exception, decides whether it qualifies. If no candidate exists, ask:
> What do you want tweaked?

A direct answer to that question is explicit user input, so keep
`route_mode=interactive-tweak`.

If the response is empty or fewer than 3 non-whitespace characters, refuse:
> Description too short — say what you want changed.

Abort without creating any branch, file, or state change.

## Scope Guard (mandatory)

Write the description to a temporary task file outside the repository and classify it:

```bash
route_file="$(mktemp)"
task_file="$(mktemp)"
printf '%s\n' "$description" > "$task_file"
route_rc=0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-route.sh" classify \
  --mode "$route_mode" --task-file "$task_file" > "$route_file" || route_rc=$?
```

Exit 2 is a routing failure: remove both temporary files and stop. Exit 20, a profile
other than `light`, or three or more distinct requested changes routes to `/improve`.
Sensitive, behavioral, ambiguous, or judgment-bearing work cannot be confirmed back
into `/tweak`. Export the accepted context for the helper, then remove the route file:

```bash
export SAAS_RUN_ID="${SAAS_RUN_ID:-$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-events.sh" new-run-id)}"
export SAAS_COMMAND=tweak
export SAAS_ROUTING_REASONS="$(jq -r '.reasons | join(",")' "$route_file")"
rm -f "$route_file" "$task_file"
```

## Determine Branch Mode

Read the current branch and resolve the repo's default branch:

```bash
current_branch=$(git rev-parse --abbrev-ref HEAD)
default=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/default-branch.sh")
```

- **`current_branch` equals `${default}`** → **new-branch mode**: create a `tweak/<slug>` branch, open a PR, return to `${default}` (the original `/tweak` flow).
- **Anything else** (you're on a feature branch) → **on-branch mode**: commit the tweak to the current branch and push it. Reuse its open PR or create one; do not merge it.

## Prepare and Apply the Tweak

Read the relevant file(s), resolve ambiguity before mutation, and prepare one minimal
unified diff in a temporary file outside the repository. Do not edit product files
directly. Slugify the description (lowercase hyphens, max 40 characters).

Apply, contain, commit, and push through the executable lifecycle helper:

```bash
patch_file="$(mktemp)" # write the prepared unified diff here
helper_rc=0
if [ "$current_branch" = "$default" ]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/tweak-run.sh" \
    --routing-mode "$route_mode" \
    --patch "$patch_file" --message "tweak: ${description}" \
    --mode new-branch --branch "tweak/${slug}" --parent "$default" --push || helper_rc=$?
else
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/tweak-run.sh" \
    --routing-mode "$route_mode" \
    --patch "$patch_file" --message "tweak: ${description}" --mode current --push || helper_rc=$?
fi
rm -f "$patch_file"
helper_outcome=success
case "$helper_rc" in
  0) ;;
  20) helper_outcome=escalated ;;
  *) helper_outcome=failure ;;
esac
```

When `helper_rc` is nonzero, append the terminal delivery event before doing anything
else. For `20`, route to `/improve` and stop this playbook before PR handling. For any
other value, stop with that original status. Never let temporary-file cleanup replace
the helper status.

The helper sets `active_role=team-lead-tweak` only for its mutation window and restores
the exact prior value through an EXIT/signal trap on success, containment rejection,
commit-hook failure, and push failure. It stages the patch, runs the staged-size and
shared post-diff containment gates (≤3 files, ≤15 changed lines, no sensitive paths), commits
with project hooks enabled, and pushes. Exit 20 means the diff exceeded tweak scope:
in new-branch mode return to `${default}`, delete only the unpushed local tweak branch,
then route to `/improve`. Any other failure stops before PR handling.
Before either failure exits the command, append a separate `delivery` terminal event
with `pr=not_created` and `outcome=escalated|failure`; the helper event covers only its
mutation subphase.

**On-branch mode:** find an open PR whose head is `current_branch`. If none exists,
open a non-draft PR against `${default}`. Report that PR URL and the commit summary.
Never merge it from `/tweak`.

**New-branch mode** continues to Open Pull Request below.

## Open Pull Request — new-branch mode only

1. **Create the PR (non-draft):**
   ```bash
   diff_stat=$(git diff "${default}"...HEAD --stat)
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

2. **Return to the default branch:**
   ```bash
   git checkout "${default}"
   ```
   The `tweak/${slug}` branch persists until the PR is merged or deleted.

3. **Report to investor** with the PR URL and a one-line summary of what changed.

Never merge the tweak PR. Reviewable PR evidence is the completion condition.
After an existing or new PR URL is verified, append the command-level terminal event
with `pr=open`, `checks=not_run`, and `outcome=success`. A local commit/push without that
PR evidence is never recorded as a successful tweak delivery.

## What /tweak Does Not Do

- No browser QA — the investor reviews the diff themselves in a PR.
- No retry on failure — there's no pass/fail signal from an agent; the PR review is the feedback.
- No dev server start, no MCP calls, no `Task` dispatch.
- No writes to `.startup/handoffs/`, `reviews/`, `signoffs/`, or `go-live/`.
- On a feature branch (on-branch mode): no new branch or branch switch; create a PR only when the branch has none.

## Communication

Speak **English** to the investor. `/tweak` doesn't involve the business founder, so the Estonian-for-business-founder rule doesn't apply here.
