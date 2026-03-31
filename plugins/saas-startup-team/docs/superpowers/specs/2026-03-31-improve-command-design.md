# `/improve` Command Design Spec

## Problem

After the build loop ends (solution signoff written), the investor has no lightweight way to request minor improvements. The only options are:

- **`/startup`** — overkill, wants to re-initialize or resume a full loop
- **`/nudge`** — designed for mid-loop course correction, not post-completion work
- **Typing instructions** — works mid-loop, but post-signoff there's no loaded orchestration context

The product is live, the investor spots issues or wants small changes, and there's no clean path to get them done.

## Solution

A new `/improve` command that runs **one full build cycle** (business founder brief → tech founder implementation → business founder browser QA) without loop machinery. One-shot: execute and done.

## Design Decisions

### Always route through business founder

Every improvement goes through the full cycle: business founder → tech founder → business founder QA. No "direct to tech" shortcut. Reasons:

1. **Tech founder has no browser.** Cannot verify visual changes. Even "simple" CSS fixes can break responsive layouts or cause text overflow with Estonian characters (ö, ü, õ are wider).
2. **Business founder enriches instructions.** She accumulated product context during the build loop — market research, competitor UX patterns, Estonian nuances, accessibility considerations. "Fix the padding" becomes "fix the padding, also the mobile breakpoint at 375px overflows with Estonian text."
3. **Deterministic routing.** No fragile judgment call on whether something "needs research." Always the same flow.
4. **QA catches regressions.** Playwright-based browser verification on every change, same as the build loop.

### No loop state changes

`/improve` does not touch `.startup/state.json`. The build loop state stays frozen. No iteration counter, no phase tracking, no active_role changes.

### Free exit

No Stop hook enforcement. The check-stop script already allows exit when solution signoff exists (line 53). `/improve` doesn't change this.

### Deliverables in `.startup/improvements/`

Separate directory from `handoffs/` to avoid confusing the build loop's numbering scheme. Files:

- `NNN-brief.md` — business founder's enriched brief (based on investor instructions)
- `NNN-implementation.md` — tech founder's change summary
- `NNN-qa.md` — business founder's QA result

Numbering auto-increments based on existing files in the directory (count `*-brief.md` files, next = count + 1). Directory is gitignored (same as rest of `.startup/`).

### Max 2 roundtrips

1. Business founder writes brief → tech implements → business founder QA
2. If QA fails: tech founder gets one fix attempt → business founder re-QAs
3. If still failing after 2nd QA: report to investor with findings, let them decide

This prevents infinite fix loops while giving one chance to correct mistakes.

### Scope guard

If the investor's request contains 3+ distinct features or requires significant new functionality (new pages, new integrations, new data models), the team lead should flag it:

> This looks like a feature, not an improvement. Consider running `/startup` to resume the build loop for this scope. Want to proceed with `/improve` anyway?

This is advisory, not blocking — the investor can override.

## Command Spec

### Frontmatter

```yaml
name: improve
description: One-shot improvements on a completed product — routes through business founder for context enrichment and browser QA. Usage: /improve [description of changes]
user_invocable: true
```

### Pre-Flight

1. Verify `.startup/` exists — if not: "Run `/startup` first to build the product."
2. Verify `docs/architecture/architecture.md` exists — tech founder needs stack/URL context.
3. Load orchestration skill: `Skill('saas-startup-team:startup-orchestration')`

Verify solution signoff exists (`.startup/go-live/solution-signoff.md`) — if not: "The build loop hasn't completed yet. Use `/startup` to resume or `/nudge` to redirect. `/improve` is for post-completion tweaks."

This keeps `/improve` scoped to its purpose and avoids Stop hook conflicts (the hook blocks exit at iteration 2+ without signoff).

### Capture Instructions

If arguments provided with the command, use them. Otherwise ask:

> What would you like improved? Describe the changes.

### Step 1: Dispatch Business Founder (Brief)

Kill stale agents, then spawn business founder via Task tool:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
>
> **Improvement task: Write a brief for the tech founder.**
>
> The investor wants these changes: [investor's instructions]
>
> Read `docs/architecture/architecture.md` for current stack and service URLs.
> Read `docs/business/brief.md` for product context.
> Read relevant `docs/research/` files if the improvement touches areas you researched.
>
> Write a brief to `.startup/improvements/001-brief.md` that includes:
> - What to change (specific, actionable)
> - Why (context the tech founder needs)
> - Acceptance criteria (what "done" looks like)
> - Any related concerns (responsive behavior, i18n, accessibility)
>
> Do NOT use the full handoff template — keep it concise. This is a targeted improvement, not a feature.
>
> After writing, message the team lead: "Improvement brief 001 ready for tech founder."

### Step 2: Dispatch Tech Founder (Implementation)

Kill stale agents, then spawn tech founder via Task tool:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/tech-founder.md` for your identity and tools.
>
> **Improvement task: Implement changes from brief.**
>
> Read `.startup/improvements/001-brief.md` for what to change.
> Read `docs/architecture/architecture.md` for stack and service URLs.
>
> Implement the changes. Write a summary of what you changed to `.startup/improvements/001-implementation.md`:
> - Files modified
> - What was changed and why
> - How to verify (localhost URL, specific page/action)
>
> Set 10s timeouts on all HTTP calls. Start/restart the dev server if needed.
>
> After completing, message the team lead: "Implementation 001 complete."

### Step 3: Dispatch Business Founder (QA)

Extract localhost URL from implementation summary, then spawn business founder:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
>
> **QA task: Verify improvement implementation.**
>
> Read `.startup/improvements/001-brief.md` for what was requested.
> Read `.startup/improvements/001-implementation.md` for what was changed.
>
> Open browser to `{localhost URL}` and verify:
> - Does the change meet the acceptance criteria from the brief?
> - Any visual regressions on the affected pages?
> - Does it work on mobile viewport (375px)?
>
> Write your QA result to `.startup/improvements/001-qa.md`:
> - PASS or FAIL
> - What you verified
> - Screenshots or observations
> - If FAIL: specific issues found
>
> After writing, message the team lead: "QA 001 complete."

### Step 4: Handle QA Result

**If PASS:** Report to investor, done. Free to exit.

**If FAIL (first attempt):** Dispatch tech founder with QA findings for a fix. Then re-QA. Increment file numbers (002-implementation.md, 002-qa.md).

**If FAIL (second attempt):** Report to investor with both QA results. Let them decide: try again, adjust instructions, or accept as-is.

### Communication

Same language rules as the build loop:
- Business founder speaks **Estonian** to investor
- Tech founder speaks **English** to investor
- Team lead speaks **English** for status

## What This Does NOT Do

- No iteration tracking or state.json changes
- No solution signoff ceremony
- No auto-learning hook integration (the auto-learn hook pattern-matches on handoff/review/signoff filenames in `.startup/` — improvement files use different names so they won't trigger, which is correct)
- No growth track interaction
- No human tasks generation

## Files to Create/Modify

| File | Action |
|------|--------|
| `commands/improve.md` | Create — the command definition |
| `templates/improvement-brief.md` | Create — lightweight brief template |
| `commands/bootstrap.md` | Modify — add `mkdir -p .startup/improvements` |
| `.claude-plugin/plugin.json` | Modify — bump version |
| `../../.claude-plugin/marketplace.json` | Modify — bump version, update description |
| `README.md` | Modify — add `/improve` to command list |
