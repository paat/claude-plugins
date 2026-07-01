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

Run the reusable health preflight first:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --check-sync
```

In Codex, include `--require-codex`; missing Codex CLI/auth is an environment blocker
when a separate Codex worker or GitHub mutation is required.

### Check 1: Product is live (unless --pre-launch)

If the user passed `--pre-launch`, skip this check.

Otherwise, verify solution signoff exists:
```bash
ls .startup/go-live/solution-signoff.md 2>/dev/null
```

**If not found:**
> **Error:** No solution signoff found. The product must be live before launching the growth track. Run `/startup` first to build and ship the product, or use `/growth --pre-launch` to start pre-launch audience building.

### Check 2: Chrome browser MCP available

Attempt to call `mcp__claude-in-chrome__tabs_context_mcp` to verify Chrome is reachable. If the tool call fails or is unavailable:

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

Before dispatching, claim the growth initialization lease:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --acquire "growth:init:${PWD}" --state-dir .startup/leases --owner "growth:init:$$" --ttl-seconds 1800
```

If no explicit channel or strategy direction was provided, run internal demand discovery
and use the top candidate as one input into `docs/growth/strategy.md`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/demand-discovery.sh"
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

Add to `docs/human-tasks.md`:

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
> Also check the human tasks in `docs/human-tasks.md` for account setup needed.
>
> Say **"go"** when approved, or let me know what to change.

## Step 3: Update State

Update `.startup/state.json` — READ it first, then add growth fields AND overwrite `active_role`. Resetting `active_role` is mandatory: the `enforce-delegation` hook fires only when `active_role=="team-lead"`, and a stale value from a prior `/startup` session would block the growth-track subagents' writes.

```json
{
  "active_role": "business-founder",
  "growth_phase": "pre-launch" or "launch",
  "growth_status": "active",
  "growth_iteration": 0,
  "growth_started": "<current ISO timestamp>"
}
```

## Step 4: Run Growth Loop

### Dispatching the growth agent

Claim a lease for the channel/objective before dispatching:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --acquire "growth:${channel_or_objective}" --state-dir .startup/leases --owner "growth:$$" --ttl-seconds 1800
```

If a live owner exists, read its heartbeat/logs and continue from existing artifacts
instead of starting over.

**Choose the lightest workflow that fits:**

**Option A — Direct execution (default for known channels):**

When the investor gives a clear directive ("do Reddit marketing", "set up Google Ads"), skip the brief pipeline and dispatch the growth agent directly with inline context:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/growth-hacker.md` for your identity and tools.
>
> **New task: [what the investor asked for]**
>
> Read `docs/growth/product-brief.md` for product context.
> Read `docs/growth/brand/approved-voice.md` for brand guidelines.
> Read `docs/growth/strategy.md` for ICP and channel priorities.
> Read the relevant channel doc in `docs/growth/channels/` for what's been done (if exists).
>
> **Your goal is to EXECUTE, not plan.** Post responses, create campaigns, send messages, submit listings — use Chrome browser for all external actions. If you can't act (no account, no access), flag it as a human task and move to the next actionable item.
>
> After executing, update the relevant `docs/growth/channels/*.md` with what you actually did (URLs, timestamps, metrics).
> Write a short growth report to `.startup/handoffs/NNN-growth-to-business.md` summarizing actions taken and results.

**Option B — Business founder writes growth brief first:**

Use this ONLY when strategy input is genuinely needed — entering a new phase, pivoting channels based on metrics, or the investor asks for a strategic assessment before execution:

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

Then dispatch the growth agent per Option A, referencing the brief as additional context.

### Growth-to-Build handoff

When a growth report flags an urgent issue or a product change needed:

1. Read the growth report
2. Dispatch business founder to write a feature handoff to tech founder
3. This enters the normal build track loop

### Growth-to-Ads delegation (automatic)

When a growth report contains a `## Google Ads request` block, the growth hacker has flagged Google Ads work it must NOT do itself (the `google-ads-strategist` plugin is a hard dependency for Google Ads). Delegate it at the team-lead level — do not have the growth hacker spawn anything (no nested subagents).

1. Read the `## Google Ads request` block (it carries product, ICP, goals (target CPA/ROAS, primary conversion), approved budget cap, brand, final-URL template, and a campaign slug).
2. Reset `active_role` (defensive, matches `/lawyer`):
   ```bash
   if [ -f .startup/state.json ]; then
     jq '.active_role = "ads-strategist"' .startup/state.json \
       > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
   fi
   ```
3. Spawn the strategist with the `Task` tool using `subagent_type: "ads-strategist"` (the registered type from `google-ads-strategist` — NOT `general-purpose`+read-md, which would resolve `${CLAUDE_PLUGIN_ROOT}` to the saas plugin). Pass the request block plus `docs/business/brief.md`, `docs/growth/product-brief.md`, `docs/growth/strategy.md`, `docs/growth/brand/approved-voice.md`, and `docs/growth/channels/ads.md`, with the instruction: create `docs/ads/<slug>/brief.md` from this context if absent, run the pre-launch loop, verify in the browser, and create the campaign **PAUSED**.
4. **If the `ads-strategist` agent type is unknown**, the `google-ads-strategist` plugin is not installed. Stop and tell the investor to install it (`/plugin install google-ads-strategist`); do NOT fall back to building the campaign inline.
5. After the strategist returns, update the `docs/growth/channels/ads.md` index entry for the slug (status: created-paused), then continue the growth loop.

**Pre-launch caveat:** if the product is not yet live (`/growth --pre-launch`, no commercial landing page / `final_url`), defer the ads request — note it as a human task and continue — rather than building a campaign that cannot route traffic.

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
