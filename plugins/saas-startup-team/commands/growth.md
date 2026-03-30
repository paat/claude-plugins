---
name: growth
description: Launch the post-launch growth track — initializes docs/growth/ structure, spawns business founder for strategy, then runs the growth agent for customer acquisition. Usage: /growth [--pre-launch]
user_invocable: true
---

# /growth — Launch Growth Track

You are the **Team Lead** (orchestrator) launching the growth track for customer acquisition. This runs in parallel with the existing build track.

## Step 0: Load Skills

Load the startup orchestration skill and growth hacker skill:
```
Skill('saas-startup-team:startup-orchestration')
Skill('saas-startup-team:growth-hacker')
```

## Step 1: Pre-Flight Checks

### Check 1: Product is live (unless --pre-launch)

If the user passed `--pre-launch`, skip this check.

Otherwise, verify solution signoff exists:
```bash
ls .startup/go-live/solution-signoff.md 2>/dev/null
```

**If not found:**
> **Error:** No solution signoff found. The product must be live before launching the growth track. Run `/startup` first to build and ship the product, or use `/growth --pre-launch` to start pre-launch audience building.

### Check 2: Chrome browser MCP available

Check that claude-in-chrome tools are available by attempting:
```bash
# Just verify the tool exists — don't need to call it
echo "Chrome MCP check: tool available"
```

**If tools unavailable:**
> **Warning:** Chrome browser MCP (claude-in-chrome) is not available. The growth agent needs Chrome for external web interactions (ad dashboards, directories, forums). Some growth activities will be limited. Continue anyway? (LinkedIn MCP and cold email will still work.)

### Check 3: LinkedIn MCP available

Check for LinkedIn tools availability.

**If unavailable:**
> **Warning:** LinkedIn MCP is not available. LinkedIn prospecting will be limited to manual research via WebSearch. Other channels (cold email, content, communities) will work normally.

## Step 2: Initialization (first invocation)

If `docs/growth/` does not exist, run the initialization sequence:

### 2a: Create directory structure

```bash
mkdir -p docs/growth/{channels,leads,metrics/weekly,brand,content/blog,content/outreach-templates}
```

### 2b: Run /bootstrap (idempotent)

Run `/bootstrap` to ensure all docs/ subdirectories exist.

### 2c: Spawn business founder for strategy

Kill stale agents first:
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

Spawn business founder via Task tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
>
> **New task: Write growth initialization documents.**
>
> Read your market research from `docs/research/` and the business brief from `docs/business/brief.md`.
>
> Write the following files:
>
> 1. `docs/growth/product-brief.md` — Translate your Estonian market research and the product architecture into an English sales-ready product description. Include: what the product does, who it's for (specific ICP), what problem it solves, why it's better than competitors, and pricing. This is the growth agent's primary context — make it complete.
>
> 2. `docs/growth/strategy.md` — Overall growth plan: ICP definition (role, company size, pain point, where they hang out), prioritized channels for Phase 1, goals and success metrics, and the current phase (`pre-launch` or `launch` depending on whether the product is live).
>
> 3. `docs/growth/brand/approved-voice.md` — Brand voice guide: tone and personality, example messages (English section + Estonian section), things to never say, and anti-examples. Base this on your market research — use the customer language you extracted from Reddit/forums.
>
> After writing all three files, message the team lead: "Growth initialization docs ready for investor review."

### 2d: Growth agent drafts outreach templates

After business founder completes, spawn growth agent via Task tool:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/growth-hacker.md` for your identity and tools.
>
> **New task: Draft outreach templates.**
>
> Read `docs/growth/product-brief.md`, `docs/growth/strategy.md`, and `docs/growth/brand/approved-voice.md`.
>
> Write the following to `docs/growth/content/outreach-templates/`:
>
> 1. `linkedin-templates.md` — 3-5 LinkedIn connection request message templates. Short (under 300 characters). Personalized first line placeholder. Rotate-friendly (varied openings).
>
> 2. `cold-email-templates.md` — 5 cold email templates. Short (under 150 words each). Single CTA. 3-email sequence: initial, 3-day follow-up, 10-day final.
>
> 3. `community-templates.md` — 3 community engagement response templates. Value-first, product mention natural, not pushy.
>
> After writing, message the team lead: "Outreach templates ready for investor review."

### 2e: Create human tasks

Add to `.startup/human-tasks.md`:

```markdown
- [ ] **Buy cold email domain** — needed for: cold outreach (Phase 1)
  - Priority: HIGH
  - Deadline: before growth Phase 1 launch
  - Notes: Separate domain from primary (e.g., tryacme.com). Cost ~$10. Set up 3-5 email accounts with Google Workspace.

- [ ] **Register accounts on target platforms** — needed for: directory submissions, community engagement
  - Priority: HIGH
  - Deadline: before growth Phase 1 launch
  - Notes: Product Hunt, AlternativeTo, SaaSHub, relevant forums/communities

- [ ] **Review growth strategy and templates** — needed for: growth track launch
  - Priority: HIGH
  - Deadline: before growth loop starts
  - Notes: Review docs/growth/strategy.md, docs/growth/brand/approved-voice.md, and docs/growth/content/outreach-templates/. Approve or request changes.
```

### 2f: Wait for investor approval

> **Growth initialization complete.** Please review:
> - `docs/growth/product-brief.md` — product description for sales
> - `docs/growth/strategy.md` — growth plan and ICP
> - `docs/growth/brand/approved-voice.md` — brand voice guide
> - `docs/growth/content/outreach-templates/` — outreach message templates
>
> Also check the human tasks in `.startup/human-tasks.md` for account setup needed.
>
> Say **"go"** when approved, or let me know what to change.

## Step 3: Update State

Update `.startup/state.json` — READ it first, then add growth fields:

```json
{
  "growth_phase": "pre-launch" or "launch",
  "growth_status": "active",
  "growth_iteration": 0,
  "growth_started": "<current ISO timestamp>"
}
```

## Step 4: Run Growth Loop

### Dispatching the growth agent

Kill stale agents first:
```bash
pkill -f 'agent-type saas-startup-team' 2>/dev/null || true
sleep 1
```

**Option A — Business founder writes growth brief:**

If the growth strategy calls for a new channel, a new phase, or a strategic pivot, spawn the business founder to write a growth brief:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
>
> **New task: Write growth brief for the growth hacker.**
>
> Read `docs/growth/strategy.md` for current phase and priorities.
> Read `docs/growth/metrics/summary.md` for latest metrics (if exists).
> Read `.startup/state.json` for growth state.
>
> Write a growth brief to `.startup/handoffs/NNN-business-to-growth.md` using the template at `${CLAUDE_PLUGIN_ROOT}/templates/handoff-business-to-growth.md`.
>
> Focus on ONE channel or ONE objective per brief.
>
> After writing, message the team lead: "Growth brief NNN ready for growth hacker."

**Option B — Growth agent executes:**

When a growth brief is ready, spawn the growth agent:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/growth-hacker.md` for your identity and tools.
>
> **New task: Execute growth brief NNN.**
>
> Read `.startup/handoffs/NNN-business-to-growth.md` for your assignment.
> Read `docs/growth/product-brief.md` for product context.
> Read `docs/growth/brand/approved-voice.md` for brand guidelines.
> Read the relevant channel doc in `docs/growth/channels/` for what's been done.
> Read `docs/growth/channels/linkedin.md` for current LinkedIn counters (if using LinkedIn).
>
> Execute the brief. Update channel docs, pipeline, and metrics.
>
> Write your growth report to `.startup/handoffs/NNN-growth-to-business.md` using the template at `${CLAUDE_PLUGIN_ROOT}/templates/handoff-growth-to-business.md`.
>
> After writing, message the team lead: "Growth report NNN ready for business founder."

### Growth-to-Build handoff

When a growth report flags an urgent issue or a product change needed:

1. Read the growth report
2. Dispatch business founder to write a feature handoff to tech founder
3. This enters the normal build track loop

### Relay pattern

Same as the build track: relay growth briefs and reports between business founder and growth agent with self-contained messages. Never assume either agent remembers prior context.

## Step 5: Parallel Operation

The growth track and build track run as independent loops. They interact only through the business founder:

- **Growth → Build**: Growth report recommends a product change → business founder writes build handoff
- **Build → Growth**: Tech founder ships a feature → business founder writes growth brief to promote it

Both tracks can have agents running simultaneously (separate Task tool spawns).

## Communication to Investor

- Growth progress updates: **English**
- Business founder strategy: **Estonian** (to investor)
- Growth agent reporting: **English**
