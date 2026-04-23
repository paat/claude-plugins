# `/tweak` — Direct-Edit Command for Trivial Fixes

**Date:** 2026-04-23
**Plugin:** `saas-startup-team`
**Status:** Design approved; pending implementation plan.

## Problem

`/improve` runs the full business-founder brief → tech-founder implementation → browser-QA pipeline. That's correct for anything with behavioral risk, but overkill for trivial fixes (typos, copy tweaks, CSS nudges). The investor is forced to spin up three agent dispatches and a browser QA cycle for a one-line change.

## Solution

A new slash command `/tweak <description>` that bypasses the agent loop entirely: the team-lead orchestrator edits files directly, commits, and opens a PR. No briefs, no agents, no QA.

## Flow

1. **Pre-flight:**
   - `.startup/` exists (else: "run `/startup` first").
   - `.startup/go-live/solution-signoff.md` exists (else: "`/tweak` is for post-completion fixes; run `/startup` or `/improve` for in-progress work").
   - Working tree is clean (else: "commit or stash before running `/tweak`").
2. **Capture description.** If no argument, prompt: "What do you want tweaked?"
3. **Scope guard (advisory, non-blocking).** If the description contains 3+ distinct items or mentions new features/integrations/data models, warn:
   > This looks bigger than a tweak. Consider `/improve` for anything needing QA. Proceed with `/tweak` anyway?
   Proceed on confirmation.
4. **Branch.** Slugify the description (lowercase, hyphens, max 40 chars) → `tweak/<slug>`. If the branch exists, prompt for a different slug or `git branch -D`.
5. **Set `active_role = "team-lead-tweak"`** in `.startup/state.json`.
6. **Edit directly.** Team lead reads the relevant files and makes the changes the investor described. No `Task` dispatch.
7. **Commit.** `git add -A && git commit -m "tweak: <description>" --no-verify`. (`--no-verify` is intentional — same pattern as `/improve`'s catch-all commit.)
8. **Push + PR (non-draft).**
   ```bash
   git push -u origin HEAD
   gh pr create --title "tweak: <short desc>" --body "$(cat <<'EOF'
   ## What
   <investor's description>

   ## Diff summary
   <git diff --stat output>
   EOF
   )"
   ```
9. **Return to main.** `git checkout main`.
10. **Report to investor** with the PR URL.

## `enforce-delegation.sh` — No Change Needed

The hook at `scripts/enforce-delegation.sh:46` already short-circuits on any `active_role` that isn't exactly `"team-lead"`:

```bash
if [ "$active_role" != "team-lead" ]; then
  exit 0
fi
```

Setting `active_role = "team-lead-tweak"` in Step 5 falls through this check and the orchestrator's edits are allowed. No hook modification required. This matches how `/improve` already uses `"business-founder-maintain"` as its role string to avoid the block.

## What `/tweak` Explicitly Does Not Do

- **No browser QA.** Trust the investor that the fix is trivial.
- **No retry loop.** There's no pass/fail signal — the PR review is the feedback mechanism.
- **No dev-server interaction.** Nothing is tested at runtime.
- **No `Task` dispatch.** Zero agent calls.
- **No handoff / review / signoff files.** Nothing written under `.startup/handoffs/`, `reviews/`, or `signoffs/`.

## Files Touched in the Plugin

- **New:** `plugins/saas-startup-team/commands/tweak.md` (command definition, ~40 lines).
- **Modified:** `plugins/saas-startup-team/.claude-plugin/plugin.json` — version bump.
- **Modified:** `.claude-plugin/marketplace.json` — version bump (must stay in sync per CLAUDE.md).

## Non-Goals

- Worktree isolation for parallel tweaks. Single working tree; `/tweak` is serial.
- Supporting tweaks before solution signoff. Pre-launch flow stays in `/startup`.
- Any behavior change to `/improve`.

## Risks

- **Scope creep:** investor uses `/tweak` for non-trivial changes because it's faster. The advisory scope guard is the only defense; the investor can override. Acceptable given the "speed over safety" preference.
- **Skipped QA misses a regression:** the investor is now responsible for spotting visual/behavioral regressions via the PR diff instead of Playwright. Acceptable for the command's trivial-fix scope.
- **`active_role` sprawl:** another role string (`team-lead-tweak`) added to the informal set. Not really a risk — the enforce-delegation check is a safelist of one (`"team-lead"`) and every other string passes. Just noting the growing list of role values floating around.
