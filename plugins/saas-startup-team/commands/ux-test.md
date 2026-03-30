---
name: ux-test
description: On-demand UX audit — evaluates usability, accessibility (WCAG 2.2 AA), visual consistency, and responsive design via Playwright browser testing. Usage: /ux-test <url>
user_invocable: true
---

# /ux-test — On-Demand UX Audit

The human investor requests a UX audit of the product. You spawn the UX Tester agent to evaluate usability, accessibility, visual consistency, and responsive design.

**The UX Tester is a one-shot consultant, NOT a loop participant.** It spawns, does its audit, writes to `.startup/docs/ux-*.md`, and exits.

## Pre-Flight Checks (HARD FAIL — No Fallbacks)

Before spawning the UX Tester agent, ALL of the following must pass. If any check fails, stop with an error message and do NOT proceed.

### Check 1: Dev server is reachable

The URL comes from command arguments. If no URL provided, try to find it from `.startup/docs/architecture.md` or `CLAUDE.md`.

```bash
curl --max-time 10 -s -o /dev/null -w "%{http_code}" <URL>
```

**Must return:** `200` (or `301`/`302` redirect)

**If unreachable:**
> **Error:** Dev server is not reachable at `<URL>`. Start the dev server before running /ux-test. If the URL is wrong, pass the correct one: `/ux-test http://localhost:PORT`

### Check 2: Startup project exists

Verify that these files exist:
- `.startup/state.json`
- `.startup/brief.md`

**If missing:**
> **Error:** No startup project found. Run /startup first to initialize the project before running /ux-test.

### Check 3: Playwright MCP is available

Test that browser tools are accessible by checking for the `mcp__plugin_saas-startup-team_playwright__browser_navigate` tool.

**If not available:**
> **Error:** Playwright MCP tools are not available. Ensure the Playwright MCP server is configured in `.mcp.json` and running.

## Execution

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

### Step 3: Spawn UX Tester Agent

Use `Task` tool to spawn the UX Tester as a one-shot agent:

Pass the following to the UX Tester agent:
- The target URL to audit (from command arguments or architecture.md)
- Project context summary (from Step 2)
- Tech stack information (from architecture.md)
- Reminder: write findings to `.startup/docs/ux-*.md` in English
- Reminder: test at minimum 2 breakpoints (375px, 1280px)
- Reminder: always include evidence and severity ratings
- Reminder: check accessibility — it is not optional

### Step 4: Report to Investor

After the UX Tester completes, summarize the findings for the investor:

1. **Severity overview** — how many Critical, Major, Minor, Enhancement findings
2. **Top issues** — list the Critical and Major findings with one-line descriptions
3. **Where to find the full audit** — file paths for `.startup/docs/ux-*.md`

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
