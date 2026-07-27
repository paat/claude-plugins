---
name: ux-test
description: "On-demand UX audit — evaluates usability, accessibility (WCAG 2.2 AA), visual consistency, and responsive design via Playwright browser testing. Usage: /ux-test <url>"
user_invocable: true
transitional: true
---

# /ux-test — On-Demand UX Audit

The investor requests a UX audit. Load the **ux-review** capability and run it as an independent worker (not the implementer).

**ux-review is a one-shot capability, not a loop participant.** It audits, writes `docs/ux/ux-*.md`, and exits.

## Pre-Flight Checks

Before spawning the ux-review agent, all checks must pass. Diagnose and repair an
in-scope failed check before stopping.

### Check 1: Dev server is reachable

The URL comes from command arguments. If no URL provided, try to find it from `docs/architecture/architecture.md` or `CLAUDE.md`.

```bash
curl --max-time 10 -s -o /dev/null -w "%{http_code}" <URL>
```

**Must return:** `200` (or `301`/`302` redirect) from the requested target or the
local replacement below.

**If unreachable:**

1. Diagnose the failed service or route.
2. If the repository or dev container owns the cause, attempt only reversible runtime
   recovery that does not modify tracked product source: use its documented setup and
   start/restart commands once, then inspect bounded startup logs and retry.
3. Follow `skills/ux-review/references/design-review-leg.md` §Pre-merge design-review
   leg for exact-checkout baseline/candidate localhost serving and cleanup.
4. If reaching the route requires a tracked-source change, record it as an audit finding.
   Only a parent delivery workflow may route that fix through implementation, regression
   tests, review, and delivery gates. Do not invent repair commands.
5. For live evidence, follow the same reference's §Post-deploy visual smoke; local
   audit evidence never substitutes for it.

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

Overwrite `active_role` in `.startup/state.json` before spawning the ux-review. The `enforce-delegation` hook fires only when `active_role=="team-lead"`; a stale value from a prior `/startup` session would otherwise block the ux-review's writes. `/ux-test` is never a team-lead context.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "ux-tester"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

### Step 1: Load ux-review Skill

```
Skill('saas-startup-team:ux-review')
```

### Step 2: Gather Project Context

Read the following files to build context for the ux-review:
1. `docs/business/brief.md` — what SaaS is being built, target users
2. `.startup/state.json` — current project phase and iteration
3. `docs/architecture/architecture.md` — tech stack, service URLs
4. Latest handoff in `.startup/handoffs/` — current state of implementation
5. Any affected `.startup/workflows/WORKFLOW-*.md` specs — QA cases and expected state transitions

### Step 3: Run Independent UX Review

Claude: generic Task/Agent with `skills/ux-review` loaded. Codex: Skill in session.
Never the same worker that implemented the code under test.

Pass:
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

After the ux-review completes, summarize the findings for the investor:

1. **Severity overview** — how many Critical, Major, Minor, Enhancement findings
2. **Top issues** — list the Critical and Major findings with one-line descriptions
3. **Where to find the full audit** — file paths for `docs/ux/ux-*.md`

### Step 5: Route Findings

Map Critical/Major findings to deliver units (code/a11y/responsive) or product-discovery
briefs (flows/copy/feature gaps). Do not invent handoffs from this command alone.
