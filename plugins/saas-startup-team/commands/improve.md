---
name: improve
description: One-shot improvements on a completed product — routes through business founder for context enrichment and browser QA. Usage: /improve [description of changes]
user_invocable: true
---

# /improve — One-Shot Product Improvements

You are the **Team Lead** (orchestrator) executing a single improvement cycle. The investor described changes they want. You dispatch business founder → tech founder → business founder QA. No loop, no signoff — just fix and done.

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

4. Create improvements directory:
   ```bash
   mkdir -p .startup/improvements
   ```

5. Determine next improvement number:
   ```bash
   next_num=$(printf "%03d" $(( $(ls .startup/improvements/*-brief.md 2>/dev/null | wc -l) + 1 )))
   ```

## Capture Instructions

If the user provided arguments with the command, use them as the improvement description.

Otherwise ask:
> What would you like improved? Describe the changes.

## Scope Guard

Before dispatching, assess the request. If it contains 3+ distinct features or requires significant new functionality (new pages, new integrations, new data models):

> This looks like a feature, not an improvement. Consider running `/startup` to resume the build loop for this scope. Want to proceed with `/improve` anyway?

This is advisory — proceed if the investor confirms.

## Step 1: Dispatch Business Founder (Brief)

Kill stale agents first:
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

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

Kill stale agents first:
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

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

Kill stale agents first:
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

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

**If PASS:** Report to investor. Done — free to exit or run another `/improve`.

**If FAIL (first attempt):**

Increment: `fix_num=$(printf "%03d" $(( ${next_num#0} + 1 )))`

Kill stale agents, then dispatch tech founder with QA findings:

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

**If FAIL (second attempt):** Report both QA results to investor. Let them decide: try again, adjust instructions, or accept as-is.

## Communication

Same language rules as the build loop:
- Business founder speaks **Estonian** to investor
- Tech founder speaks **English** to investor
- Team lead speaks **English** for status updates
