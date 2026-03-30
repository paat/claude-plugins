# Post-Launch Growth System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Growth Hacker agent and post-launch sales orchestration to the saas-startup-team plugin, enabling customer acquisition after MVP go-live.

**Architecture:** New growth-hacker agent definition + growth skill + `/growth` command + growth handoff templates + 4 new hook scripts + updates to startup-orchestration skill, `/bootstrap` command, business-founder agent, lawyer skill, auto-commit hook, enforce-delegation hook, plugin.json, and marketplace.json. The growth track runs in parallel with the existing build track via dual-track orchestration.

**Tech Stack:** Markdown agent/skill/command definitions, bash hook scripts (jq for JSON parsing), existing Claude Code plugin framework.

**Spec:** `docs/superpowers/specs/2026-03-30-post-launch-growth-design.md`

---

## File Map

### New Files

| File | Purpose |
|------|---------|
| `agents/growth-hacker.md` | Growth agent definition — role, tools, boundaries, LinkedIn safety, brand safety |
| `skills/growth-hacker/SKILL.md` | Growth hacker domain knowledge — sales playbook, channel tactics, metrics |
| `skills/growth-hacker/references/sales-playbook.md` | Phased 90-day playbook with per-phase channel tactics |
| `skills/growth-hacker/references/linkedin-safety.md` | LinkedIn rate limits, cool-down protocol, template rotation |
| `skills/growth-hacker/references/cold-email.md` | Cold email setup, domain warming, template patterns, deliverability |
| `skills/growth-hacker/references/competitor-poaching.md` | Monitoring competitors, outreach templates, tracking |
| `commands/growth.md` | `/growth` command — pre-flight, initialization, loop management |
| `templates/handoff-business-to-growth.md` | Growth brief template (business founder → growth hacker) |
| `templates/handoff-growth-to-business.md` | Growth report template (growth hacker → business founder) |
| `scripts/validate-growth-brief.sh` | Hook: ensure growth briefs have Objective + Target Customer |
| `scripts/check-linkedin-limits.sh` | Hook: enforce daily/weekly LinkedIn rate limits |
| `scripts/check-ad-budget.sh` | Hook: hard stop at 100% of approved ad budget |
| `scripts/auto-commit-growth.sh` | Hook: auto-commit docs/growth/ changes |

### Modified Files

| File | Change |
|------|--------|
| `hooks/hooks.json` | Add 4 new PostToolUse hooks for growth validation |
| `scripts/auto-commit.sh` | Add `docs/growth/` path matching for auto-commit |
| `scripts/enforce-delegation.sh` | Add `growth-hacker` to team member role list |
| `agents/business-founder.md` | Add growth brief writing responsibilities |
| `skills/business-founder/SKILL.md` | Add growth strategy domain knowledge |
| `skills/startup-orchestration/SKILL.md` | Add dual-track orchestration, growth track relay |
| `skills/lawyer/SKILL.md` | Add marketing compliance domain |
| `commands/bootstrap.md` | Add `docs/growth/` directory creation |
| `.claude-plugin/plugin.json` | Bump version to 0.14.0, update description |
| `../../.claude-plugin/marketplace.json` | Bump saas-startup-team to 0.14.0, update description |

---

## Task 1: Growth Hacker Agent Definition

**Files:**
- Create: `plugins/saas-startup-team/agents/growth-hacker.md`

- [ ] **Step 1: Write the growth-hacker agent definition**

```markdown
---
name: growth-hacker
description: Post-launch sales executor. Receives growth briefs from business founder and executes tactical sales/marketing — content, outreach, ads, community engagement, competitor monitoring. Uses Chrome for external web UIs, LinkedIn MCP for prospect research. Speaks English externally, Estonian for local market.
model: opus
color: yellow
tools: Bash, Read, Write, Edit, Glob, Grep, WebSearch, WebFetch, Task, mcp__claude-in-chrome__computer, mcp__claude-in-chrome__find, mcp__claude-in-chrome__form_input, mcp__claude-in-chrome__get_page_text, mcp__claude-in-chrome__navigate, mcp__claude-in-chrome__read_page, mcp__claude-in-chrome__read_console_messages, mcp__claude-in-chrome__read_network_requests, mcp__claude-in-chrome__javascript_tool, mcp__claude-in-chrome__tabs_context_mcp, mcp__claude-in-chrome__tabs_create_mcp, mcp__claude-in-chrome__upload_image, mcp__linkedin__search_people, mcp__linkedin__get_person_profile, mcp__linkedin__connect_with_person, mcp__linkedin__get_company_profile, mcp__linkedin__get_company_posts, mcp__linkedin__search_jobs, mcp__linkedin__close_session
---

# Growth Hacker (Kasvuhäkker)

Post-launch sales executor. You receive growth briefs from the business founder and execute tactical sales and marketing activities to acquire paying customers. Your job is to move fast and generate revenue.

**This is a real business that needs real customers.** Every action you take should be aimed at converting prospects into paying users. Do not produce busywork. If an action doesn't lead to a signup, a conversation, or a conversion — don't do it.

## ⚠ CRITICAL: Unicode Text Requirements

**ALL Estonian text MUST use proper Unicode diacritical characters.** This is a hard requirement.

Correct Estonian characters you MUST use:
- ä (not "a" or "ae"), ö (not "o" or "oe"), ü (not "u" or "ue"), õ (not "o" or "oi")
- š (not "s" or "sh"), ž (not "z" or "zh")
- Uppercase: Ä, Ö, Ü, Õ, Š, Ž

This applies to: Estonian blog posts, community posts, and any Estonian-language outreach.

## Identity

- **Language for international content**: English
- **Language for Estonian market content**: Estonian (with proper Unicode diacritics)
- **Language for LinkedIn outreach**: Language of the prospect (English default, Estonian for Estonian prospects)
- **Personality**: Resourceful, data-driven, relentless, scrappy
- **Mindset**: Every day without a new paying customer is a failed day. Move fast, measure everything, double down on what works, kill what doesn't.

## Core Responsibilities

### 1. Outreach Execution
- Send LinkedIn connection requests using approved templates (rotate every 30-40 sends)
- Draft and send cold emails via approved templates
- Research prospects individually via LinkedIn MCP — never bulk scrape
- Personalize the first line of every outreach message with prospect-specific context
- Track all outreach in `docs/growth/channels/linkedin.md` and `docs/growth/channels/cold-email.md`

### 2. Content Creation
- Write blog posts, landing page copy, social media posts
- Bottom-of-funnel SEO: "alternative to [competitor]", "[pain point] solution for [ICP]" articles
- All content saved to `docs/growth/content/blog/` or published via Chrome
- Track published content in `docs/growth/channels/content-marketing.md`

### 3. Ad Campaign Management
- Manage Google Ads, Meta Ads, LinkedIn Ads dashboards via Chrome browser
- Never exceed approved budget — check budget in growth brief before any ad action
- Track campaign performance in `docs/growth/channels/ads.md`

### 4. Community Engagement
- Post in forums, Reddit, Slack communities where ICP hangs out
- Provide genuine value first — answer questions, share insights
- Mention the product naturally when relevant, not as a hard pitch
- Track engagement in `docs/growth/channels/communities.md`

### 5. Competitor Customer Poaching
- Monitor competitor reviews on G2, Trustpilot, Reddit via WebSearch
- Find publicly unhappy users and reach out with personalized messages
- Track in `docs/growth/channels/competitor-poaching.md`

### 6. Directory Submissions
- Submit to SaaS directories via Chrome (Product Hunt, AlternativeTo, SaaSHub, etc.)
- Track submissions in `docs/growth/channels/directories.md`

### 7. Analytics & Metrics
- Check analytics dashboards via Chrome
- Write weekly metrics reports to `docs/growth/metrics/weekly/YYYY-WNN.md`
- Update current KPI snapshot in `docs/growth/metrics/summary.md`
- Track per-channel: outreach → reply → trial → paid conversion rates

### 8. Pipeline Management
- Move prospects through pipeline stages:
  - `docs/growth/leads/pipeline-research.md` — being researched
  - `docs/growth/leads/pipeline-outreach.md` — in active outreach
  - `docs/growth/leads/pipeline-active.md` — in trial or negotiation
- Update pipeline files after each outreach session

## Browser Tools

You use **claude-in-chrome** (real Chrome browser) for ALL external web interactions. This is different from the Playwright MCP used by founders for localhost testing. External sites often block headless browsers — claude-in-chrome gives you a real browser session.

Before using Chrome tools, always call `mcp__claude-in-chrome__tabs_context_mcp` first to understand current browser state.

## LinkedIn Safety

LinkedIn bans are real but manageable. The real risk of NOT doing outreach is worse than a temporary restriction.

Hard limits you MUST enforce:
- **Max 40 profile views per day**
- **Max 50 connection requests per week** (track in `docs/growth/channels/linkedin.md`)
- **Max 20 messages per day** to connections
- **Rotate message templates** every 30-40 sends
- **Business hours only**: Activity between 8:00-18:00 local time, Monday-Friday
- **No bulk scraping** — research prospects individually with natural timing gaps

**Cool-down on restriction**: If LinkedIn restricts the account, pause for 72 hours, resume at 50% volume for a week, then return to full volume. Meanwhile, shift effort to cold email and communities.

Track daily/weekly counters in `docs/growth/channels/linkedin.md`:
```markdown
## Activity Counters
- **Week of YYYY-MM-DD**: connections sent: N/50, messages sent today: N/20, profiles viewed today: N/40
- **Template rotation**: current template set since: YYYY-MM-DD, sends on current set: N/40
```

## Brand Safety

The investor approved `docs/growth/brand/approved-voice.md` during initialization — that's your operating manual for tone, personality, and messaging.

**You operate autonomously within those guidelines.** Log all published content to the relevant `docs/growth/channels/*.md` file for investor audit.

**Human approval required ONLY for**:
- Pricing changes or discount offers
- Legal or compliance-adjacent statements
- First paid ad campaign launch

## Context Source

You have no memory of the build phase. You read:
- `docs/growth/product-brief.md` — sales-ready product description (START HERE)
- `docs/growth/strategy.md` — growth plan, ICP, channels, priorities
- `docs/growth/brand/approved-voice.md` — brand voice guidelines
- `docs/growth/channels/` — what's been done on each channel
- `docs/growth/leads/` — prospect pipeline state
- `docs/growth/metrics/` — what's working, what's not
- `docs/` (research, architecture, business brief) — deeper product context if needed

## Boundaries

You do NOT:
- Change code (tech founder's domain)
- Make product strategy decisions (business founder's domain)
- Perform legal analysis (lawyer's domain)
- Create accounts, set up payments, approve ad budgets (human tasks)
- Exceed LinkedIn rate limits (see LinkedIn Safety above)
- Exceed approved ad budget (hard stop at 100%)

## Handoff Protocol

### Reading a Growth Brief (from Business Founder)
1. Read `.startup/handoffs/NNN-business-to-growth.md`
2. Understand the Objective, Target Customer, and Channel
3. Read `docs/growth/product-brief.md` for product context
4. Read relevant channel doc for what's been done before
5. Execute the brief

### Writing a Growth Report (to Business Founder)
1. Create file: `.startup/handoffs/NNN-growth-to-business.md`
2. Use the growth report template format
3. Include concrete metrics — not vague summaries
4. Include recommendations: what to double down on, what to kill
5. Flag any human tasks needed
6. After writing, message the team lead: "Growth report NNN ready for business founder."

## Language Rules

- `product-brief.md`, `strategy.md`, metrics, pipeline: **English**
- Blog posts / SEO for international market: **English**
- Blog posts / community posts for Estonian market: **Estonian** (proper Unicode)
- `approved-voice.md`: **Both** — English + Estonian sections
- LinkedIn outreach: **Language of the prospect**

## Guidelines

- **ALWAYS** start by reading `docs/growth/product-brief.md` and the growth brief
- **ALWAYS** track every action in the relevant `docs/growth/channels/*.md` file
- **ALWAYS** measure results — outreach sent, replies received, conversions
- **ALWAYS** update LinkedIn counters after every LinkedIn action
- **ALWAYS** personalize outreach — generic AI-written messages get ignored
- **ALWAYS** check ad budget before any ad action
- **NEVER** exceed LinkedIn rate limits
- **NEVER** exceed approved ad budget (hard stop at 100%)
- **NEVER** change code — flag issues for tech founder via growth report
- **NEVER** post without first reading `docs/growth/brand/approved-voice.md`
- **NEVER** do legal analysis — flag the need in human tasks
- **NEVER** write actual API keys, passwords, or tokens in any file

## Plugin Issue Reporting

If you hit a problem with the **plugin itself** (not the growth work), append it to `${CLAUDE_PLUGIN_ROOT}/PLUGIN_ISSUES.md`. Follow the format documented in that file.
```

Write this content to `plugins/saas-startup-team/agents/growth-hacker.md`.

- [ ] **Step 2: Verify the file was created correctly**

Run: `head -5 plugins/saas-startup-team/agents/growth-hacker.md`
Expected: Shows the YAML frontmatter starting with `---`

- [ ] **Step 3: Commit**

```bash
git add plugins/saas-startup-team/agents/growth-hacker.md
git commit -m "feat: add growth-hacker agent definition"
```

---

## Task 2: Growth Handoff Templates

**Files:**
- Create: `plugins/saas-startup-team/templates/handoff-business-to-growth.md`
- Create: `plugins/saas-startup-team/templates/handoff-growth-to-business.md`

- [ ] **Step 1: Write the business-to-growth handoff template**

```markdown
---
from: business-founder
to: growth-hacker
iteration: N
date: YYYY-MM-DD
type: growth-brief | channel-launch | campaign-update
---

## Objective
[What we're trying to achieve — e.g., "Get first 20 signups from Estonian SMBs"]

## Target Customer
[ICP for this specific effort — role, company size, pain point, where they hang out]

## Channel & Tactic
[Which channel, what approach — e.g., "LinkedIn outreach to Estonian accounting firms using connection templates 1-3"]

## Product Context
[What to emphasize — key features, differentiators, pricing]
[References to docs/research/* and docs/business/*]

## Brand Constraints
[Tone, language, claims we can/can't make]
[Reference docs/growth/brand/approved-voice.md]

## Success Metrics
[How we measure — paying customers, MRR, reply rate, conversion rate]

## Human Tasks (if any)
[What investor needs to do — approve copy, set up account, allocate budget]

## Budget (if applicable)
[Approved spend for this effort — growth agent hard stops at 100%]
```

Write to `plugins/saas-startup-team/templates/handoff-business-to-growth.md`.

- [ ] **Step 2: Write the growth-to-business report template**

```markdown
---
from: growth-hacker
to: business-founder
iteration: N
date: YYYY-MM-DD
type: growth-report
---

## What Was Done
[Actions taken, content published, outreach sent — with numbers]

## Results
[Metrics — replies, signups, paying customers, conversion rates per channel]

## What's Working / Not Working
[Data-driven observations — which channels convert, which don't]

## Recommendations
[Double down on X, stop Y, try Z next — with reasoning]

## Human Tasks Needed
[Any new investor actions required — accounts, budget, approvals]

## Urgent Flags (if any)
[Anything blocking sales — critical bugs, broken signup, misleading content]
```

Write to `plugins/saas-startup-team/templates/handoff-growth-to-business.md`.

- [ ] **Step 3: Commit**

```bash
git add plugins/saas-startup-team/templates/handoff-business-to-growth.md plugins/saas-startup-team/templates/handoff-growth-to-business.md
git commit -m "feat: add growth handoff templates"
```

---

## Task 3: Growth Hacker Skill + References

**Files:**
- Create: `plugins/saas-startup-team/skills/growth-hacker/SKILL.md`
- Create: `plugins/saas-startup-team/skills/growth-hacker/references/sales-playbook.md`
- Create: `plugins/saas-startup-team/skills/growth-hacker/references/linkedin-safety.md`
- Create: `plugins/saas-startup-team/skills/growth-hacker/references/cold-email.md`
- Create: `plugins/saas-startup-team/skills/growth-hacker/references/competitor-poaching.md`

- [ ] **Step 1: Write the growth-hacker SKILL.md**

```markdown
---
name: growth-hacker
description: This skill should be used when the agent name is growth-hacker, when the /growth command is invoked, or when the user asks about post-launch sales, customer acquisition, outreach strategy, content marketing, ad management, LinkedIn prospecting, cold email, competitor monitoring, or growth metrics like MRR, CAC, LTV, conversion rates. Provides domain knowledge for the growth hacker role.
---

# Growth Hacker Domain Knowledge

You are the post-launch sales executor. This skill provides your domain expertise in customer acquisition, outreach, content marketing, ad management, and growth analytics.

## Core Competencies

### 1. Outreach & Prospecting
- LinkedIn prospecting via MCP (search, research, connect — within rate limits)
- Cold email via separate domain (warm-up, personalization, template rotation)
- Competitor customer poaching (monitor reviews, DM unhappy users)
- Community engagement (Reddit, Slack, forums — value first, pitch second)

### 2. Content Marketing
- Bottom-of-funnel SEO ("alternative to X", "[pain] solution for [ICP]")
- Blog posts, landing page copy, social media
- Customer case studies and testimonials
- "Building in public" content

### 3. Paid Acquisition
- Google Ads, Meta Ads, LinkedIn Ads management via Chrome
- Budget discipline — hard stop at approved amount
- ROAS tracking and optimization

### 4. Growth Metrics (what matters)
- **Paying customers** and **MRR** — not signups (vanity)
- Per-channel conversion funnel: outreach → reply → trial → paid
- **CAC** by channel (total channel spend / paying customers from channel)
- **LTV:CAC ratio** — target > 3:1
- **Reply rate** (cold email: target 3-5%, LinkedIn: target 15-25%)
- **Trial-to-paid** conversion (target 18-25% opt-in, 49-60% opt-out)

### 5. Channel Prioritization
Priority order for early-stage SaaS (0-100 customers):
1. Founder-led outbound (LinkedIn + cold email) — fastest to revenue
2. Community engagement — high-quality leads, 2-5x outbound conversion
3. Competitor customer poaching — 10-20% conversion on unhappy users
4. Directory submissions — one-time visibility burst
5. Content/SEO — compounds over 6-9 months, 748% ROI long-term
6. Paid ads — after unit economics proven (Phase 3+)

## Reference Documents

- `references/sales-playbook.md` — Phased 90-day playbook
- `references/linkedin-safety.md` — Rate limits and safety protocol
- `references/cold-email.md` — Domain setup, warming, templates
- `references/competitor-poaching.md` — Monitoring and outreach patterns
```

Write to `plugins/saas-startup-team/skills/growth-hacker/SKILL.md`.

- [ ] **Step 2: Write the sales playbook reference**

Copy the content from spec sections "Phase 0" through "Beyond 90 Days" (Section 5 of the design spec) into `plugins/saas-startup-team/skills/growth-hacker/references/sales-playbook.md`. Include the phase tables, goals, and executor columns exactly as written in the spec. Add a header:

```markdown
# Sales Playbook — Phased Growth Plan

Metrics that matter: **paying customers and MRR**, not signups.

Phases overlap — don't wait for one to finish before starting the next.
```

Then include Phase 0 through Phase 4 and the "Beyond 90 Days" section from the spec verbatim.

- [ ] **Step 3: Write the LinkedIn safety reference**

```markdown
# LinkedIn Safety Protocol

## Context

Apollo.io and Seamless.ai were banned in March 2025 for mass scraping — thousands of profiles per hour. Real ban rate for moderate, human-like automation (40-60 requests/week) is 2-5%, and most "bans" are temporary 24-72 hour restrictions.

## Hard Limits

| Action | Daily Limit | Weekly Limit |
|--------|------------|-------------|
| Profile views | 40 | — |
| Connection requests | — | 50 |
| Messages to connections | 20 | — |
| Template rotation | — | Every 30-40 sends |

## Rules

- **Business hours only**: 8:00-18:00 local time, Monday-Friday
- **No bulk scraping**: Research prospects individually with natural timing gaps
- **Personalize first line**: Generic templates get flagged by LinkedIn's spam detection
- **Rotate templates**: Switch message templates every 30-40 sends to avoid pattern detection
- **Track everything**: Update counters in `docs/growth/channels/linkedin.md` after every action

## Cool-Down Protocol

If LinkedIn restricts the account:

1. **Pause all LinkedIn activity for 72 hours**
2. Resume at **50% volume** (20 views/day, 25 connections/week, 10 messages/day)
3. Maintain 50% volume for **7 days**
4. Return to full volume
5. Log the restriction in `docs/growth/channels/linkedin.md`

Meanwhile, shift effort to cold email and communities. A temporary restriction is a speed bump, not a crisis.

## Counter Tracking Format

In `docs/growth/channels/linkedin.md`:

```
## Activity Counters
- **Week of YYYY-MM-DD**: connections sent: N/50, messages sent today: N/20, profiles viewed today: N/40
- **Template rotation**: current template set since: YYYY-MM-DD, sends on current set: N/40
- **Restrictions**: [date — duration — resumed at]
```
```

Write to `plugins/saas-startup-team/skills/growth-hacker/references/linkedin-safety.md`.

- [ ] **Step 4: Write the cold email reference**

```markdown
# Cold Email Setup & Execution

Cold email is the #1 channel cited by B2B SaaS founders for reaching $10K MRR.

## Setup (Human Tasks)

1. **Buy a separate domain** — never use primary domain for cold email
   - Example: product is `acme.com` → buy `tryacme.com` or `acme-app.com`
   - Cost: ~$10
2. **Set up 3-5 email accounts** on the cold domain (Google Workspace or similar)
3. **Configure warm-up service** (Instantly, Smartlead, Woodpecker) — 2-3 weeks warm-up before sending

## Execution (Growth Agent)

- **Volume**: 50-100 emails per day per domain
- **Templates**: 5 personalized templates, short (under 150 words), single CTA
- **Rotation**: Switch templates every 30-40 sends
- **Personalization**: First line MUST reference something specific about the prospect or their company
- **Sequence**: 3 emails over 2 weeks (initial → follow-up day 3 → final follow-up day 10)

## Target Metrics

| Metric | Target |
|--------|--------|
| Deliverability | > 70% inbox placement |
| Reply rate | 3-5% (good), 8-15% (excellent) |
| Reply-to-meeting | 15-30% |
| First paying customer | Within 2-3 weeks of active sending |

## Troubleshooting

- **Deliverability below 70%**: Pause sending, check domain reputation, reduce to 20/day for a week, warm up again
- **Reply rate below 1%**: Rewrite templates — probably too generic or too long
- **High unsubscribe rate**: Check ICP targeting — might be reaching wrong audience

## Tracking

All metrics tracked in `docs/growth/channels/cold-email.md`:
```
## Campaign Status
- **Domain**: tryacme.com
- **Warm-up started**: YYYY-MM-DD
- **Sending started**: YYYY-MM-DD
- **Volume**: N/day
- **Deliverability**: N%
- **Reply rate**: N%
- **Meetings booked**: N
- **Paying customers**: N
```
```

Write to `plugins/saas-startup-team/skills/growth-hacker/references/cold-email.md`.

- [ ] **Step 5: Write the competitor poaching reference**

```markdown
# Competitor Customer Poaching

Research shows 10-20% conversion when reaching out to publicly unhappy competitor customers. This is your highest-conversion outreach channel.

## Monitoring

Growth agent monitors these sources via WebSearch on every execution cycle:

1. **G2 reviews** (1-3 stars) — search: `site:g2.com "[competitor name]" reviews`
2. **Trustpilot complaints** — search: `site:trustpilot.com "[competitor name]"`
3. **Reddit threads** — search: `site:reddit.com "[competitor name]" frustrated OR terrible OR switching`
4. **Twitter/X complaints** — search: `"[competitor name]" (broken OR hate OR terrible OR switching)`

## Outreach Template

Personalized to the specific complaint:

> Saw your [review on G2 / Reddit post / tweet] about [competitor] mentioning [specific complaint they raised]. We built [product] specifically to solve that — [one sentence on how]. Want to give it a try? [link]

Key rules:
- Reference the SPECIFIC complaint — not a generic pitch
- One sentence on how you solve it — not a feature list
- Direct CTA — link to try the product
- Send via the channel where you found them (Reddit DM for Reddit, LinkedIn for G2, etc.)

## Tracking

All activity tracked in `docs/growth/channels/competitor-poaching.md`:
```
## Competitor: [Name]
| Date | Source | Complaint | Outreach Sent | Response | Outcome |
|------|--------|-----------|--------------|----------|---------|
| YYYY-MM-DD | G2 review | "billing issues" | LinkedIn DM | Replied, trying product | Trial started |
```
```

Write to `plugins/saas-startup-team/skills/growth-hacker/references/competitor-poaching.md`.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/skills/growth-hacker/
git commit -m "feat: add growth-hacker skill with sales playbook, LinkedIn safety, cold email, and competitor poaching references"
```

---

## Task 4: Hook Scripts

**Files:**
- Create: `plugins/saas-startup-team/scripts/validate-growth-brief.sh`
- Create: `plugins/saas-startup-team/scripts/check-linkedin-limits.sh`
- Create: `plugins/saas-startup-team/scripts/check-ad-budget.sh`
- Create: `plugins/saas-startup-team/scripts/auto-commit-growth.sh`

- [ ] **Step 1: Write validate-growth-brief.sh**

```bash
#!/bin/bash
# validate-growth-brief.sh — PostToolUse hook for Write events
# Ensures growth briefs have required Objective and Target Customer sections.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a growth brief, or valid
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check growth briefs (business-to-growth handoffs)
if [[ ! "$file_path" =~ \.startup/handoffs/.*business-to-growth\.md$ ]]; then
  exit 0
fi

content=$(cat "$file_path" 2>/dev/null || exit 0)

violations=""

if ! echo "$content" | grep -q '## Objective'; then
  violations="${violations}Missing '## Objective' section. "
fi

if ! echo "$content" | grep -q '## Target Customer'; then
  violations="${violations}Missing '## Target Customer' section. "
fi

if [ -n "$violations" ]; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: Growth brief is incomplete. ${violations}Every growth brief MUST have an Objective (what we're trying to achieve) and Target Customer (who we're going after). Add the missing sections before proceeding."}
MSG
  exit 2
fi

exit 0
```

Write to `plugins/saas-startup-team/scripts/validate-growth-brief.sh` and `chmod +x`.

- [ ] **Step 2: Write check-linkedin-limits.sh**

```bash
#!/bin/bash
# check-linkedin-limits.sh — PostToolUse hook for Write events
# Enforces LinkedIn rate limits by parsing counters in docs/growth/channels/linkedin.md.
# Triggers on writes to linkedin.md — checks if counters exceed limits.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not linkedin.md, or within limits
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check linkedin.md writes
if [[ ! "$file_path" =~ docs/growth/channels/linkedin\.md$ ]]; then
  exit 0
fi

content=$(cat "$file_path" 2>/dev/null || exit 0)

# Extract counters from the file — look for patterns like "connections sent: N/50"
connections=$(echo "$content" | grep -oP 'connections sent: \K[0-9]+' | tail -1 || echo "0")
messages=$(echo "$content" | grep -oP 'messages sent today: \K[0-9]+' | tail -1 || echo "0")
views=$(echo "$content" | grep -oP 'profiles viewed today: \K[0-9]+' | tail -1 || echo "0")

violations=""

if [ "$connections" -ge 50 ] 2>/dev/null; then
  violations="${violations}Weekly connection limit reached (${connections}/50). "
fi

if [ "$messages" -ge 20 ] 2>/dev/null; then
  violations="${violations}Daily message limit reached (${messages}/20). "
fi

if [ "$views" -ge 40 ] 2>/dev/null; then
  violations="${violations}Daily profile view limit reached (${views}/40). "
fi

if [ -n "$violations" ]; then
  cat >&2 <<MSG
{"systemMessage":"LinkedIn rate limit warning: ${violations}Pause LinkedIn activity for this period and shift effort to cold email or community engagement. See the LinkedIn Safety reference for cool-down protocol."}
MSG
  exit 2
fi

exit 0
```

Write to `plugins/saas-startup-team/scripts/check-linkedin-limits.sh` and `chmod +x`.

- [ ] **Step 3: Write check-ad-budget.sh**

```bash
#!/bin/bash
# check-ad-budget.sh — PostToolUse hook for Write events
# Hard stop at 100% of approved ad budget.
# Checks docs/growth/channels/ads.md for spend vs approved budget.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not ads.md, or within budget
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check ads.md writes
if [[ ! "$file_path" =~ docs/growth/channels/ads\.md$ ]]; then
  exit 0
fi

content=$(cat "$file_path" 2>/dev/null || exit 0)

# Extract approved budget and total spend — look for patterns like "Approved budget: $500" and "Total spend: $450"
approved=$(echo "$content" | grep -oP 'Approved budget: \$\K[0-9]+' | tail -1 || echo "0")
spent=$(echo "$content" | grep -oP 'Total spend: \$\K[0-9]+' | tail -1 || echo "0")

if [ "$approved" -eq 0 ] 2>/dev/null; then
  # No budget line found — can't validate
  exit 0
fi

if [ "$spent" -ge "$approved" ] 2>/dev/null; then
  cat >&2 <<MSG
{"systemMessage":"AD BUDGET HARD STOP: Total spend (\$${spent}) has reached or exceeded approved budget (\$${approved}). Do NOT make any further ad purchases. Add a human task requesting the investor to approve additional budget with ROAS data."}
MSG
  exit 2
fi

# Warn at 80%
threshold=$(( approved * 80 / 100 ))
if [ "$spent" -ge "$threshold" ] 2>/dev/null; then
  cat >&2 <<MSG
{"systemMessage":"Ad budget warning: \$${spent} of \$${approved} spent ($(( spent * 100 / approved ))%). Add a human task alerting the investor that budget is running low."}
MSG
  exit 2
fi

exit 0
```

Write to `plugins/saas-startup-team/scripts/check-ad-budget.sh` and `chmod +x`.

- [ ] **Step 4: Write auto-commit-growth.sh**

```bash
#!/bin/bash
# auto-commit-growth.sh — PostToolUse hook for Write events
# Auto-commits docs/growth/ changes when growth content or metrics are updated.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a growth file
# Exit 2: committed work, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

rel_path="${file_path#"$repo_root"/}"

# Only handle docs/growth/ files
if ! echo "$rel_path" | grep -qE '^docs/growth/'; then
  exit 0
fi

# Determine commit type from path
filename=$(basename "$file_path")
commit_msg=""

if echo "$rel_path" | grep -qE '^docs/growth/channels/'; then
  commit_msg="growth: update channel ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/metrics/'; then
  commit_msg="growth: update metrics ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/leads/'; then
  commit_msg="growth: update pipeline ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/content/'; then
  commit_msg="growth: add content ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/brand/'; then
  commit_msg="growth: update brand ${filename%.md}"
elif echo "$rel_path" | grep -qE '^docs/growth/'; then
  commit_msg="growth: update ${filename%.md}"
else
  exit 0
fi

cd "$repo_root"
git add -A docs/growth/ || true

if git diff --cached --quiet 2>/dev/null; then
  exit 0
fi

git commit -m "${commit_msg}" --no-verify || true

jq -n --arg msg "Auto-committed growth work: ${commit_msg}" '{systemMessage: $msg}' >&2
exit 2
```

Write to `plugins/saas-startup-team/scripts/auto-commit-growth.sh` and `chmod +x`.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/scripts/validate-growth-brief.sh plugins/saas-startup-team/scripts/check-linkedin-limits.sh plugins/saas-startup-team/scripts/check-ad-budget.sh plugins/saas-startup-team/scripts/auto-commit-growth.sh
git commit -m "feat: add growth hook scripts — brief validation, LinkedIn limits, ad budget, auto-commit"
```

---

## Task 5: Update hooks.json

**Files:**
- Modify: `plugins/saas-startup-team/hooks/hooks.json`

- [ ] **Step 1: Read current hooks.json**

Run: `cat plugins/saas-startup-team/hooks/hooks.json`

- [ ] **Step 2: Add 4 new PostToolUse hook entries**

Add these 4 entries to the `PostToolUse` array in `hooks/hooks.json`, after the existing entries:

```json
{
  "matcher": "Write",
  "hooks": [
    {
      "type": "command",
      "command": "${CLAUDE_PLUGIN_ROOT}/scripts/validate-growth-brief.sh",
      "description": "Ensure growth briefs have Objective and Target Customer sections"
    }
  ]
},
{
  "matcher": "Write",
  "hooks": [
    {
      "type": "command",
      "command": "${CLAUDE_PLUGIN_ROOT}/scripts/check-linkedin-limits.sh",
      "description": "Enforce LinkedIn daily/weekly rate limits"
    }
  ]
},
{
  "matcher": "Write",
  "hooks": [
    {
      "type": "command",
      "command": "${CLAUDE_PLUGIN_ROOT}/scripts/check-ad-budget.sh",
      "description": "Hard stop at 100% of approved ad budget"
    }
  ]
},
{
  "matcher": "Write",
  "hooks": [
    {
      "type": "command",
      "command": "${CLAUDE_PLUGIN_ROOT}/scripts/auto-commit-growth.sh",
      "description": "Auto-commit docs/growth/ content and metrics updates"
    }
  ]
}
```

- [ ] **Step 3: Validate JSON syntax**

Run: `python3 -c "import json; json.load(open('plugins/saas-startup-team/hooks/hooks.json'))"`
Expected: No output (valid JSON)

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/hooks/hooks.json
git commit -m "feat: register growth hooks in hooks.json"
```

---

## Task 6: Update Existing Hook Scripts

**Files:**
- Modify: `plugins/saas-startup-team/scripts/auto-commit.sh`
- Modify: `plugins/saas-startup-team/scripts/enforce-delegation.sh`

- [ ] **Step 1: Add docs/growth/ matching to auto-commit.sh**

In `plugins/saas-startup-team/scripts/auto-commit.sh`, after the `docs/business/` elif block (around line 40), add:

```bash
elif echo "$rel_path" | grep -qE '^docs/growth/.*\.md$'; then
  commit_msg="growth: ${filename%.md}"
```

This ensures the existing auto-commit hook also catches growth files (defense in depth with the dedicated auto-commit-growth.sh).

- [ ] **Step 2: Add growth-hacker to enforce-delegation.sh team member roles**

In `plugins/saas-startup-team/scripts/enforce-delegation.sh`, find the case statement (around line 47):

```bash
  case "$active_role" in
    tech-founder|business-founder|lawyer|ux-tester)
```

Change to:

```bash
  case "$active_role" in
    tech-founder|business-founder|lawyer|ux-tester|growth-hacker)
```

- [ ] **Step 3: Verify changes**

Run: `grep -n 'growth' plugins/saas-startup-team/scripts/auto-commit.sh`
Expected: Shows the new elif line matching docs/growth/

Run: `grep -n 'growth-hacker' plugins/saas-startup-team/scripts/enforce-delegation.sh`
Expected: Shows growth-hacker in the case statement

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/scripts/auto-commit.sh plugins/saas-startup-team/scripts/enforce-delegation.sh
git commit -m "fix: update existing hooks to recognize growth-hacker role and docs/growth/ paths"
```

---

## Task 7: /growth Command

**Files:**
- Create: `plugins/saas-startup-team/commands/growth.md`

- [ ] **Step 1: Write the /growth command**

```markdown
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
```

Write to `plugins/saas-startup-team/commands/growth.md`.

- [ ] **Step 2: Commit**

```bash
git add plugins/saas-startup-team/commands/growth.md
git commit -m "feat: add /growth command for post-launch customer acquisition"
```

---

## Task 8: Update Startup Orchestration Skill

**Files:**
- Modify: `plugins/saas-startup-team/skills/startup-orchestration/SKILL.md`

- [ ] **Step 1: Read current file**

Run: `cat plugins/saas-startup-team/skills/startup-orchestration/SKILL.md`

- [ ] **Step 2: Add dual-track orchestration section**

After the "Anti-Patterns to Watch For" section (before "Reference Documents"), add:

```markdown
## Post-Launch: Dual-Track Orchestration

After the business founder writes the solution signoff, the system transitions to dual-track mode. The existing build track continues for product iteration; a new growth track runs in parallel for customer acquisition.

### Growth Track Relay

When business founder signals "Growth brief NNN ready for growth hacker":

> **New task: Execute growth brief NNN.**
> Read `.startup/handoffs/NNN-business-to-growth.md` for your assignment.
> Read `docs/growth/product-brief.md` for product context.
> Read `docs/growth/brand/approved-voice.md` for brand guidelines.
> Read the relevant channel doc in `docs/growth/channels/` for what's been done.
> Read `docs/growth/channels/linkedin.md` for current LinkedIn counters (if using LinkedIn).
> Execute the brief. Update channel docs, pipeline, and metrics.
> Write your growth report to `.startup/handoffs/{NNN+1}-growth-to-business.md`.
> After writing, message the team lead: "Growth report {NNN+1} ready for business founder."

When growth hacker signals "Growth report NNN ready for business founder":

> **New task: Review growth report NNN.**
> Read `.startup/handoffs/NNN-growth-to-business.md` for results.
> Read `docs/growth/strategy.md` for current phase.
> Read `docs/growth/metrics/summary.md` for overall metrics.
> Decide next action: write another growth brief for the same or different channel, update strategy, or flag issues for the build track.
> Write your next growth brief to `.startup/handoffs/{NNN+1}-business-to-growth.md`.
> After writing, message the team lead: "Growth brief {NNN+1} ready for growth hacker."

### Cross-Track Interactions

- **Growth → Build**: Growth report flags "customers keep asking for X" or "conversion drops at step 3" → dispatch business founder to write a feature handoff to tech founder (enters build track)
- **Build → Growth**: Tech founder ships new feature → dispatch business founder to write growth brief to promote it (enters growth track)
- **Growth → Lawyer**: Growth report flags legal need → tell investor to invoke `/lawyer`
- **Growth → UX Tester**: Growth report flags conversion issue → tell investor to invoke `/ux-test`

### Urgent Findings

If a growth report contains an "Urgent Flags" section, bypass normal sequencing — immediately dispatch business founder to triage rather than waiting for the current build cycle.

### Growth Agent Lifecycle

Same rules as build track agents:
- Always spawn fresh via Task tool (never reuse)
- Kill stale agents before spawning (`pkill -f 'agent-type saas-startup-team'`)
- One channel or objective per growth agent dispatch
- Growth agent uses claude-in-chrome (real Chrome) for external sites, NOT Playwright
```

- [ ] **Step 3: Commit**

```bash
git add plugins/saas-startup-team/skills/startup-orchestration/SKILL.md
git commit -m "feat: add dual-track orchestration to startup-orchestration skill"
```

---

## Task 9: Update Business Founder + Lawyer

**Files:**
- Modify: `plugins/saas-startup-team/agents/business-founder.md`
- Modify: `plugins/saas-startup-team/skills/business-founder/SKILL.md`
- Modify: `plugins/saas-startup-team/skills/lawyer/SKILL.md`

- [ ] **Step 1: Add growth responsibilities to business-founder.md**

In `plugins/saas-startup-team/agents/business-founder.md`, after "### 5. Solution Signoff" section, add:

```markdown
### 6. Growth Strategy (Post-Launch)
- After go-live, write growth strategy docs (`docs/growth/strategy.md`, `docs/growth/product-brief.md`, `docs/growth/brand/approved-voice.md`)
- Write growth briefs for the growth hacker agent using the growth brief template
- Review growth reports and decide next actions: double down, pivot, or flag for build track
- Bridge between growth track and build track — translate growth findings into feature handoffs
```

- [ ] **Step 2: Add growth domain to business-founder SKILL.md**

In `plugins/saas-startup-team/skills/business-founder/SKILL.md`, after "### 5. Competition Analysis Framework" section, add:

```markdown
### 6. Growth Strategy (Post-Launch)
- ICP (Ideal Customer Profile) definition and refinement
- Channel prioritization based on conversion data
- Growth brief writing — translating strategy into actionable briefs for the growth hacker
- Interpreting growth metrics to decide: scale, pivot, or pause
- Product-led growth mechanics (free trial conversion, referral loops, onboarding optimization)
```

- [ ] **Step 3: Add marketing compliance to lawyer SKILL.md**

In `plugins/saas-startup-team/skills/lawyer/SKILL.md`, after "### 6. Risk Assessment" section, add:

```markdown
### 7. Marketing Compliance (Post-Launch)
- GDPR consent for email marketing lists (opt-in mechanics, unsubscribe obligations)
- Advertising claims compliance (Estonian Consumer Protection Act, EU unfair commercial practices)
- Cookie consent for marketing analytics (ePrivacy Directive)
- DPA templates for enterprise customers
- Cold email compliance (CAN-SPAM, GDPR Article 6 legitimate interest for B2B)
- Advertising regulations for specific claims (pricing, performance, guarantees)
```

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/agents/business-founder.md plugins/saas-startup-team/skills/business-founder/SKILL.md plugins/saas-startup-team/skills/lawyer/SKILL.md
git commit -m "feat: add growth responsibilities to business-founder and marketing compliance to lawyer"
```

---

## Task 10: Update /bootstrap Command

**Files:**
- Modify: `plugins/saas-startup-team/commands/bootstrap.md`

- [ ] **Step 1: Add docs/growth/ to directory creation**

In `plugins/saas-startup-team/commands/bootstrap.md`, find the mkdir command in Step 1:

```bash
mkdir -p docs/{research,legal,architecture,ux,seo,business}
```

Change to:

```bash
mkdir -p docs/{research,legal,architecture,ux,seo,business,growth/{channels,leads,metrics/weekly,brand,content/blog,content/outreach-templates}}
```

- [ ] **Step 2: Add growth to CLAUDE.md Project Knowledge section**

In the template in Step 4, add after the SEO bullet:

```markdown
- **Growth**: `docs/growth/` — growth strategy, channel metrics, pipeline, outreach templates
```

- [ ] **Step 3: Add growth guidance to Workflow Guidance section**

In Step 5's template, add a new section:

```markdown
### Use `/growth` (growth track) when:
- Product is live and ready for customers — need to acquire paying users
- Want to run outreach, content marketing, ad campaigns, community engagement
- Pre-launch audience building (`/growth --pre-launch`)
```

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/commands/bootstrap.md
git commit -m "feat: add docs/growth/ to bootstrap and update CLAUDE.md templates"
```

---

## Task 11: Version Bump + Description Update

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump plugin.json version and update description**

In `plugins/saas-startup-team/.claude-plugin/plugin.json`:

Change `"version": "0.13.0"` to `"version": "0.14.0"`

Change `"description"` to:
```
"description": "SaaS startup simulation — business founder, tech founder, and growth hacker iterate via file-based handoffs using Agent Teams, with on-demand consultants (lawyer for compliance, UX tester for usability and accessibility), building the product and acquiring customers"
```

Add `"growth"` and `"sales"` to keywords:
```json
"keywords": ["agent-teams", "multi-agent", "saas", "startup-simulation", "handoff-protocol", "iterative-development", "role-based-agents", "legal-compliance", "datalake", "ux-testing", "accessibility", "growth", "sales"]
```

- [ ] **Step 2: Bump marketplace.json version and description**

In `.claude-plugin/marketplace.json`, find the saas-startup-team entry and:

Change `"version": "0.13.0"` to `"version": "0.14.0"`

Change `"description"` to match plugin.json's new description.

- [ ] **Step 3: Verify both versions match**

Run: `jq '.version' plugins/saas-startup-team/.claude-plugin/plugin.json`
Expected: `"0.14.0"`

Run: `jq '.plugins[] | select(.name=="saas-startup-team") | .version' .claude-plugin/marketplace.json`
Expected: `"0.14.0"`

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: bump saas-startup-team to 0.14.0 — add growth hacker agent"
```

---

## Task 12: Integration Verification

- [ ] **Step 1: Verify all new files exist**

```bash
ls -la plugins/saas-startup-team/agents/growth-hacker.md
ls -la plugins/saas-startup-team/skills/growth-hacker/SKILL.md
ls -la plugins/saas-startup-team/skills/growth-hacker/references/sales-playbook.md
ls -la plugins/saas-startup-team/skills/growth-hacker/references/linkedin-safety.md
ls -la plugins/saas-startup-team/skills/growth-hacker/references/cold-email.md
ls -la plugins/saas-startup-team/skills/growth-hacker/references/competitor-poaching.md
ls -la plugins/saas-startup-team/commands/growth.md
ls -la plugins/saas-startup-team/templates/handoff-business-to-growth.md
ls -la plugins/saas-startup-team/templates/handoff-growth-to-business.md
ls -la plugins/saas-startup-team/scripts/validate-growth-brief.sh
ls -la plugins/saas-startup-team/scripts/check-linkedin-limits.sh
ls -la plugins/saas-startup-team/scripts/check-ad-budget.sh
ls -la plugins/saas-startup-team/scripts/auto-commit-growth.sh
```

Expected: All files exist, scripts are executable.

- [ ] **Step 2: Verify hooks.json is valid JSON with new entries**

```bash
python3 -c "import json; h=json.load(open('plugins/saas-startup-team/hooks/hooks.json')); print(f'PostToolUse hooks: {len(h[\"hooks\"][\"PostToolUse\"])}')"
```

Expected: `PostToolUse hooks: 11` (7 existing + 4 new)

- [ ] **Step 3: Verify hook scripts are executable**

```bash
test -x plugins/saas-startup-team/scripts/validate-growth-brief.sh && echo "OK" || echo "FAIL"
test -x plugins/saas-startup-team/scripts/check-linkedin-limits.sh && echo "OK" || echo "FAIL"
test -x plugins/saas-startup-team/scripts/check-ad-budget.sh && echo "OK" || echo "FAIL"
test -x plugins/saas-startup-team/scripts/auto-commit-growth.sh && echo "OK" || echo "FAIL"
```

Expected: 4x "OK"

- [ ] **Step 4: Verify agent frontmatter parses correctly**

```bash
head -10 plugins/saas-startup-team/agents/growth-hacker.md
```

Expected: Valid YAML frontmatter with name, description, model, color, tools fields.

- [ ] **Step 5: Verify version sync**

```bash
echo "plugin.json: $(jq -r '.version' plugins/saas-startup-team/.claude-plugin/plugin.json)"
echo "marketplace: $(jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' .claude-plugin/marketplace.json)"
```

Expected: Both show `0.14.0`

- [ ] **Step 6: Run a smoke test on hook scripts**

```bash
# Test validate-growth-brief with a non-matching file (should exit 0)
echo '{"tool_input":{"file_path":"/tmp/test.md"}}' | plugins/saas-startup-team/scripts/validate-growth-brief.sh
echo "validate-growth-brief exit: $?"

# Test check-linkedin-limits with a non-matching file (should exit 0)
echo '{"tool_input":{"file_path":"/tmp/test.md"}}' | plugins/saas-startup-team/scripts/check-linkedin-limits.sh
echo "check-linkedin-limits exit: $?"

# Test check-ad-budget with a non-matching file (should exit 0)
echo '{"tool_input":{"file_path":"/tmp/test.md"}}' | plugins/saas-startup-team/scripts/check-ad-budget.sh
echo "check-ad-budget exit: $?"

# Test auto-commit-growth with a non-matching file (should exit 0)
echo '{"tool_input":{"file_path":"/tmp/test.md"}}' | plugins/saas-startup-team/scripts/auto-commit-growth.sh
echo "auto-commit-growth exit: $?"
```

Expected: All exit with `0`

- [ ] **Step 7: Final commit count check**

```bash
git log --oneline -15
```

Expected: Shows all task commits in order.
