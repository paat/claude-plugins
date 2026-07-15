---
name: ux-test
description: "On-demand UX audit — evaluates usability, accessibility (WCAG 2.2 AA), visual consistency, and responsive design via Playwright browser testing. Usage: /ux-test <url>"
user_invocable: true
---

# /ux-test — On-Demand UX Audit

The human investor requests a UX audit of the product. You spawn the UX Tester agent to evaluate usability, accessibility, visual consistency, and responsive design.

**The UX Tester is a one-shot consultant, NOT a loop participant.** It spawns, does its audit, writes to `docs/ux/ux-*.md`, and exits.

## Pre-Flight Checks

Before spawning the UX Tester agent, all checks must pass. Diagnose and repair an
in-scope failed check before stopping.

### Check 1: Dev server is reachable

The URL comes from command arguments. If no URL provided, try to find it from `docs/architecture/architecture.md` or `CLAUDE.md`.

```bash
curl --max-time 10 -s -o /dev/null -w "%{http_code}" <URL>
```

**Must return:** `200` (or `301`/`302` redirect) from the requested target or the
local replacement below.

**If unreachable:**

1. Diagnose the failed service or route. Repair it when the repository or dev
   container owns the cause.
2. If the remote URL represents code in this repository, use only its documented setup
   and start/restart commands for one repair attempt, then inspect bounded startup logs
   and audit localhost. Use the fetched default-branch SHA for a baseline audit and
   candidate HEAD after a fix. Do not invent commands or stop after the first `curl`.
3. Local evidence is valid for an audit and pre-merge QA. It does not prove deployed
   or live behavior; run that verification against the public URL after deployment.

Stop only when neither target can be made reachable without external authority, and
report the concrete dependency that must change.

### Check 2: Startup project exists

Verify that these files exist:
- `.startup/state.json`
- `docs/business/brief.md`

**If missing:**
> **Error:** No startup project found. Run /startup first to initialize the project before running /ux-test.

### Check 3: Playwright MCP is available

Test that browser tools are accessible by checking for the `mcp__plugin_saas-startup-team_playwright__browser_navigate` tool.

**If not available:**
> **Error:** Playwright MCP tools are not available. Ensure the Playwright MCP server is configured in `.mcp.json` and running.

## Execution

### Step 0: Reset active_role

Overwrite `active_role` in `.startup/state.json` before spawning the UX Tester. The `enforce-delegation` hook fires only when `active_role=="team-lead"`; a stale value from a prior `/startup` session would otherwise block the UX Tester's writes. `/ux-test` is never a team-lead context.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "ux-tester"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

### Step 1: Load UX Tester Skill

```
Skill('saas-startup-team:ux-tester')
```

### Step 2: Gather Project Context

Read the following files to build context for the UX Tester:
1. `docs/business/brief.md` — what SaaS is being built, target users
2. `.startup/state.json` — current project phase and iteration
3. `docs/architecture/architecture.md` — tech stack, service URLs
4. Latest handoff in `.startup/handoffs/` — current state of implementation
5. Any affected `.startup/workflows/WORKFLOW-*.md` specs — QA cases and expected state transitions

### Step 3: Spawn UX Tester Agent

Use `Task` with `subagent_type: "saas-startup-team:ux-tester"` to spawn the UX Tester as a one-shot agent:

Pass the following to the UX Tester agent:
- The target URL to audit (from command arguments or architecture.md)
- Project context summary (from Step 2)
- Tech stack information (from architecture.md)
- Reminder: write findings to `docs/ux/ux-*.md` in English
- Reminder: test at minimum 2 breakpoints (375px, 1280px)
- Reminder: always include evidence and severity ratings
- Reminder: check accessibility — it is not optional
- Reminder: derive QA cases from `.startup/workflows/` when specs exist and report missing workflow coverage in the audit; do not edit the registry
- Reminder: apply triggered SaaS gates when relevant: async paid-flow states, checkout CTA proximity, customer copy/value units, structured-result raw-value scan, LLM quality evidence, and compliance/risk claim taxonomy

### Step 4: Report to Investor

After the UX Tester completes, summarize the findings for the investor:

1. **Severity overview** — how many Critical, Major, Minor, Enhancement findings
2. **Top issues** — list the Critical and Major findings with one-line descriptions
3. **Where to find the full audit** — file paths for `docs/ux/ux-*.md`

### Step 5: Create Actionable Items for Founders

As team lead, translate UX findings into work items for the founders. Group findings into max-2-feature handoff items:

**For Tech Founder (code fixes):**
- Accessibility violations (missing ARIA, contrast fixes, keyboard navigation)
- Responsive design bugs (overflow, layout breaks, touch targets)
- Missing interaction states (loading, error, empty, hover, focus)
- Visual consistency fixes (normalize colors, typography, spacing)

**For Business Founder (UX research follow-ups):**
- Unclear user flows that need competitive research
- Content and copy issues that need user perspective
- Feature gaps identified during the audit that need requirements definition

Write these as structured messages ready to relay to founders via the normal handoff protocol. Do NOT create handoff files directly — the team lead creates handoffs, not the command.
