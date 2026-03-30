# Post-Launch Growth System Design

**Date**: 2026-03-30
**Status**: Approved
**Scope**: Add a Growth Hacker agent and post-launch sales orchestration to the saas-startup-team plugin

---

## Problem

The saas-startup-team plugin builds SaaS products through a two-founder handoff loop. Once the business founder writes the solution signoff (go-live), there is no mechanism to acquire customers. The plugin needs a post-launch growth system that maximizes sales using Claude Code's browser automation, LinkedIn MCP, and human task delegation.

## Approach

**One new Growth Hacker agent** operating in a dual-track architecture alongside the existing build loop. The growth agent executes tactical sales/marketing activities; the business founder provides strategy via growth briefs; the investor handles identity-bound actions via human tasks.

This follows the proven hybrid AI+human model: AI handles research, content, and execution; humans handle strategy, relationships, and approvals.

---

## 1. Growth Hacker Agent

**Role**: Post-launch sales executor. Receives growth briefs from the business founder and executes tactical sales/marketing activities.

**Model**: Opus | **Color**: Yellow | **Language**: English (external content), Estonian (local market content)

### Tools

- **Chrome browser** (claude-in-chrome MCP): Navigate ad dashboards, publish content on platforms, submit to directories, manage analytics UIs, post on forums. Note: this is a real Chrome browser (headful), distinct from the Playwright MCP (headless) used by founders for localhost testing. External sites often block headless browsers, so the growth agent uses claude-in-chrome for all external web interactions.
- **LinkedIn MCP**: Search prospects, research companies, monitor competitor content, identify hiring signals. Subject to strict rate limits (see LinkedIn Safety section below).
- **WebSearch / WebFetch**: Keyword research, competitor monitoring, find communities where ICP lives
- **Read / Write / Edit / Glob / Grep**: Manage content files, read product docs for context, update growth metrics
- **Bash**: Run SEO tools, generate reports

### Boundaries

The Growth Hacker does NOT:
- Change code (tech founder's domain)
- Make product strategy decisions (business founder's domain)
- Perform legal analysis (lawyer's domain)
- Create accounts, set up payments, approve ad budgets (human tasks)
- Post under the company name on a new channel without human approval (brand safety gate)

### Brand Safety Gate

The investor's time is the scarcest resource. Approve the playbook, not every play.

1. **Investor approves `docs/growth/brand/approved-voice.md` once** during `/growth` initialization — tone, personality, example messages, things to never say. This is the growth agent's operating manual.
2. **Growth agent operates autonomously** within those guidelines. All content logged to `docs/growth/channels/*.md` for audit — investor reads these when they want, no mandatory review cycle.
3. **Human approval required ONLY for**:
   - Pricing changes or discount offers (revenue impact)
   - Legal or compliance-adjacent statements (irreversible risk)
   - First paid ad campaign launch (money at stake)

No periodic review theater. The investor can spot-check anytime by reading the channel docs. The growth agent's job is to move fast, not wait for permission.

### LinkedIn Safety

Context: Apollo.io and Seamless.ai got banned for mass scraping — thousands of profiles per hour. That's not what we're doing. Real ban rate for moderate, human-like automation (40-60 requests/week) is 2-5%, and most "bans" are temporary 24-72 hour restrictions, not permanent.

Limits enforced by the growth agent:

- **Max 40 profile views per day** via LinkedIn MCP
- **Max 50 connection requests per week** (50% of LinkedIn's limit — aggressive but within safe zone)
- **Max 20 messages per day** to connections
- **Growth agent sends connection requests directly** using investor-approved message templates (investor approves 3-5 templates during init, not each individual send)
- **Rotate message templates** every 30-40 sends to avoid pattern detection
- **No bulk scraping** — research prospects individually, with natural timing gaps
- **Cool-down on restriction**: If LinkedIn restricts the account, pause for 72 hours, then resume at 50% volume for a week before returning to full volume
- **Business hours only**: LinkedIn activity between 8:00-18:00 local time, Monday-Friday

These limits are tracked in `docs/growth/channels/linkedin.md` with daily/weekly counters. The real risk of not doing LinkedIn outreach is far worse than a temporary restriction.

### Context Source

The growth agent has no memory of the build phase. It reads:
- `docs/growth/product-brief.md` for sales-ready product description (in English, written by business founder during `/growth` initialization — translates Estonian research into sales messaging)
- `docs/` (research, architecture, business brief) for deeper product context if needed
- `docs/growth/` for growth strategy, channel history, metrics, and approved brand voice

---

## 2. File-Based State

### Durable Growth Knowledge (git-tracked)

```
docs/growth/
├── product-brief.md         ← Sales-ready product description (English)
├── strategy.md              ← Overall growth plan, ICP, channels, priorities
├── channels/
│   ├── content-marketing.md ← Published articles, keywords targeted, performance
│   ├── linkedin.md          ← Outreach history, connection stats, daily/weekly counters
│   ├── directories.md       ← Where listed, submission dates, status
│   ├── ads.md               ← Campaigns, spend, ROAS, what's working
│   ├── cold-email.md        ← Domains, templates, deliverability, reply rates
│   ├── competitor-poaching.md ← Competitor complaints found, outreach sent, conversions
│   └── communities.md       ← Forums/Reddit/Slack, threads engaged, tone
├── leads/
│   ├── pipeline-research.md ← Prospects being researched
│   ├── pipeline-outreach.md ← Prospects in active outreach
│   └── pipeline-active.md   ← Prospects in trial/negotiation
├── metrics/
│   ├── summary.md           ← Current KPIs snapshot (overwritten each update)
│   └── weekly/
│       └── YYYY-WNN.md      ← Weekly report archive (one file per week)
├── brand/
│   └── approved-voice.md    ← Investor-approved messaging, tone, examples
└── content/
    ├── blog/                ← Draft and published blog posts
    └── outreach-templates/  ← Approved outreach message templates
```

Each fresh agent spawn reads these files to know what's been done, what's working, and what to do next. Results and learnings accumulate here as durable, compounding knowledge.

**Language rules for growth content:**
- `product-brief.md`, `strategy.md`, metrics, pipeline files: **English** (operational)
- Blog posts / SEO for international market: **English**
- Blog posts / community posts for Estonian market: **Estonian** (proper Unicode diacritics)
- `approved-voice.md`: **Both** — English section + Estonian section
- LinkedIn outreach: **Language of the prospect** (English default, Estonian for Estonian prospects)

### Ephemeral Growth Handoffs

Growth briefs and reports use the existing `.startup/handoffs/` numbering sequence.

---

## 3. Post-Launch Orchestration

After solution signoff, the orchestrator transitions to a dual-track loop:

### Build Track (existing)

Continues as-is. Triggered by customer feedback or growth agent findings. Business founder writes feature handoffs to tech founder. Stays idle when no build work is needed.

### Growth Track (new)

Business founder writes growth briefs. Growth agent executes and reports back. Follows the 90-day playbook phases.

### Cross-Track Interactions

| From | To | Trigger |
|------|----|---------|
| Growth → Build | Growth agent discovers "customers keep asking for X" or "conversion drops at step 3" → business founder writes feature handoff |
| Build → Growth | Tech founder ships new feature → business founder writes growth brief to promote it |
| Growth → Lawyer | Growth agent needs GDPR-compliant email collection or ad copy review → investor invokes `/lawyer` |
| Growth → UX Tester | Conversion is low on landing page → investor invokes `/ux-test` |

### Orchestrator Rules

- Growth track and build track run in parallel (separate agent spawns)
- Growth agent spawned fresh each time (same pattern as founders)
- Business founder is the bridge — the only role that writes to both tracks
- If no build work is needed, the build track stays idle
- **Urgent findings**: If the growth agent discovers something blocking sales (critical bug, broken signup, misleading content live), it writes an **urgent flag** in the growth report. The orchestrator bypasses normal sequencing and immediately dispatches business founder to triage, rather than waiting for the current build cycle to finish.

### Failure Modes & Recovery

| Failure | Recovery |
|---------|----------|
| Chrome session expired on external platform | Flag in human-tasks, switch to other channels — don't stop working |
| LinkedIn temporary restriction | 72-hour cool-down, then resume at 50% for a week. Meanwhile, shift effort to cold email and communities. A temporary restriction is a speed bump, not a crisis. |
| Zero conversions after 7 days | Don't pause — adjust. Growth agent analyzes: is it the messaging (low reply rate)? The ICP (low open rate)? The product (high trial drop-off)? Change the variable that's failing and keep going. Only escalate to investor if ALL channels at zero AND messaging has been iterated 3+ times. |
| Content tone miss | Fix the specific content, update `approved-voice.md` with the anti-example, keep going. Don't revert entire channel to human-approval. |
| Ad spend approaching limit | Flag in human-tasks when 80% of approved budget is spent. Hard stop at 100%. Request increase with ROAS data. |
| Cold email deliverability drops below 70% | Pause sending, check domain reputation, reduce volume to 20/day for a week, warm up again. |

---

## 4. Growth Brief Format

### Business Founder → Growth Hacker

Location: `.startup/handoffs/NNN-business-to-growth.md`

```markdown
---
from: business-founder
to: growth-hacker
iteration: N
date: YYYY-MM-DD
type: growth-brief | channel-launch | campaign-update
---

## Objective
[What we're trying to achieve]

## Target Customer
[ICP for this effort — role, company size, pain point]

## Channel & Tactic
[Which channel, what approach]

## Product Context
[Key features, differentiators, pricing]
[References to docs/research/* and docs/business/*]

## Brand Constraints
[Tone, language, claims we can/can't make]
[Reference docs/growth/brand/approved-voice.md]

## Success Metrics
[How we measure — signups, replies, clicks, conversions]

## Human Tasks (if any)
[What investor needs to do — approve copy, set up account, allocate budget]

## Budget (if applicable)
[Approved spend for this effort]
```

### Growth Hacker → Business Founder

Location: `.startup/handoffs/NNN-growth-to-business.md`

```markdown
---
from: growth-hacker
to: business-founder
iteration: N
date: YYYY-MM-DD
type: growth-report
---

## What Was Done
[Actions taken, content published, outreach sent]

## Results
[Metrics — signups, replies, impressions, conversion rates]

## What's Working / Not Working
[Data-driven observations]

## Recommendations
[Double down on X, stop Y, try Z next]

## Human Tasks Needed
[Any new investor actions required]
```

### Validation Rules (hook-enforced)

- Growth briefs MUST have Objective and Target Customer
- No hardcoded API keys or passwords
- Budget requires explicit investor approval via human tasks
- First use of any new channel requires brand safety approval

### Required Hooks (new additions to hooks.json)

| Hook Event | Script | Purpose |
|-----------|--------|---------|
| `PostToolUse` (Write) | `validate-growth-brief.sh` | Ensure growth briefs have Objective + Target Customer sections |
| `PostToolUse` (Write) | `check-linkedin-limits.sh` | Parse `docs/growth/channels/linkedin.md` counters; block if daily/weekly limits exceeded |
| `PostToolUse` (Write) | `check-ad-budget.sh` | Hard stop at 100% of approved budget |
| `PostToolUse` (Write) | `auto-commit-growth.sh` | Auto-commit growth content and metrics updates |

---

## 5. Sales Playbook

Metrics that matter: **paying customers and MRR**, not signups. Signups without conversion is vanity.

The growth agent follows a phased playbook. Phases overlap — don't wait for one to finish before starting the next. Business founder advances phases based on metrics.

### Phase 0: Pre-Launch (before go-live, optional but recommended)

Start building pipeline while the product is still being built. `/growth --pre-launch` skips the solution signoff check.

| Action | Executor |
|--------|----------|
| Build email waitlist landing page | Tech founder (via build track) |
| Research ICP, build prospect list of 200+ via LinkedIn MCP + WebSearch | Growth agent |
| Join and start contributing to communities where ICP hangs out (Reddit, Slack, forums) | Growth agent |
| Start "building in public" content on social channels | Growth agent |
| Set up a cold email domain (separate from primary) and start warming it | **Human task** (domain purchase + email account setup) |
| Create `docs/growth/strategy.md` and `docs/growth/product-brief.md` | Business founder |

The goal is to have a warm prospect list and community presence by launch day.

### Phase 1: Launch Blitz (Days 1-7)

**Goal**: First 5 paying customers within 7 days.

| Action | Executor |
|--------|----------|
| Submit to 10+ SaaS directories (Product Hunt, AlternativeTo, SaaSHub, etc.) via Chrome | Growth agent |
| Launch blog post + social media announcement | Growth agent |
| **Cold outreach blitz**: 30-50 LinkedIn messages/day + 50-100 cold emails/day to pre-built prospect list | Growth agent |
| Monitor competitor reviews (G2, Trustpilot, Reddit) — DM unhappy users of competitors: "saw your review, we built X to solve exactly that" | Growth agent |
| Post in communities where ICP lives (with genuine value, not pure pitch) | Growth agent |
| Offer "done for you" onboarding to first 10 customers — tech founder personally sets up their account | Tech founder (via build track) |
| Post on Product Hunt (needs founder identity) | **Human task** |
| Register accounts on platforms | **Human task** |

### Phase 2: Find What Works (Days 8-30)

**Goal**: 20 paying customers, identify which 1-2 channels have the best conversion rate.

| Action | Executor |
|--------|----------|
| Continue cold outreach — refine messaging based on Phase 1 reply/conversion data | Growth agent |
| Write 2-3 bottom-of-funnel SEO articles ("alternative to [competitor]", "[pain point] solution for [ICP]") | Growth agent |
| Set up competitor monitoring alerts — poach every publicly unhappy competitor customer | Growth agent |
| Start affiliate/referral outreach — find micro-influencers (1K-50K audience) in niche, offer 30-50% recurring commission | Growth agent |
| Track per-channel metrics: outreach → reply → trial → paid conversion rates | Growth agent |
| Build ICP-specific landing pages for top-performing channels | Tech founder (via build track) |
| Approve ad budget for first small experiment ($300-500) | **Human task** |

### Phase 3: Double Down (Days 31-60)

**Goal**: 50+ paying customers, $3K+ MRR, prove unit economics (LTV:CAC > 3:1).

| Action | Executor |
|--------|----------|
| Kill channels with no conversions. Double effort on the 1-2 channels that work. | Business founder decision, growth agent executes |
| Scale paid ads on winning channel via Chrome (Google Ads, Meta, LinkedIn Ads) | Growth agent |
| Write first customer case study | Growth agent (investor facilitates customer interview) |
| Set up referral/viral mechanics in product | Tech founder (via build track) |
| A/B test landing page copy and pricing | Growth agent + tech founder |
| Weekly metrics report to `docs/growth/metrics/weekly/` | Growth agent |
| Collect customer testimonials | **Human task** |

### Phase 4: Scale (Days 61-90+)

**Goal**: $10K+ MRR, repeatable acquisition engine.

| Action | Executor |
|--------|----------|
| Increase ad spend on proven channels | Business founder decision |
| Expand to adjacent ICP segments | Business founder strategy → growth agent executes |
| Content marketing at scale (4+ articles/week, SEO compounding) | Growth agent |
| Partnership and integration outreach | Growth agent drafts → investor closes |
| Document the sales playbook for eventual human hire | Growth agent |
| Negotiate partnership deals | **Human task** |

### Cold Email Setup (Critical Channel)

Cold email is the #1 channel cited by B2B SaaS founders for reaching $10K MRR. Setup:

1. **Human task**: Buy a separate domain for cold email (never use primary domain). Example: if product is `acme.com`, buy `tryacme.com` or `acme-app.com`. Cost: ~$10.
2. **Human task**: Set up 3-5 email accounts on the cold domain with a provider like Google Workspace.
3. **Growth agent**: Configure warm-up via a service (Instantly, Smartlead). 2-3 weeks warm-up before sending.
4. **Growth agent**: Write 5 personalized email templates (short, under 150 words, single CTA). Rotate every 30-40 sends.
5. **Growth agent**: Send 50-100 emails/day per domain. Track deliverability, reply rates, conversions in `docs/growth/channels/cold-email.md`.
6. **Target metrics**: 3-5% reply rate, 15-30% reply-to-meeting, first paying customer from cold email within 2-3 weeks.

### Competitor Customer Poaching (High-Conversion Tactic)

Research shows 10-20% conversion when reaching out to publicly unhappy competitor customers.

1. Growth agent monitors: G2 reviews (1-3 stars), Trustpilot complaints, Reddit threads, Twitter complaints about competitors via WebSearch
2. Growth agent drafts personalized outreach: "Saw your review of [competitor] mentioning [specific complaint]. We built [product] specifically to solve that. Want to try it?"
3. Sent via cold email or LinkedIn depending on where the review was posted
4. Tracked in `docs/growth/channels/competitor-poaching.md`

### Beyond 90 Days

Business founder reviews metrics and decides:
- **Continue scaling**: Growth agent continues, expand to new markets and segments
- **Hire human sales**: `docs/growth/` IS the onboarding manual. Growth agent shifts to supporting (research, content, analytics)
- **Pivot**: If no channel achieved LTV:CAC > 3:1 after honest effort, strategic review: change ICP, pricing, or product

### Token Cost Awareness

Browser-heavy work eats tokens. Be flexible:
- Content creation / outreach: ~30K tokens per spawn
- Chrome-heavy work (ad dashboards, analytics): ~50K tokens per spawn
- Research sprint: ~20K tokens per spawn
- Focus each spawn on one channel or one objective — don't try to do everything at once

---

## 6. Lawyer — Extended Scope

The lawyer remains a separate on-demand role (`/lawyer`). Post-launch, its scope extends to marketing compliance:

| Trigger | Analysis |
|---------|----------|
| Before first email campaign | GDPR consent requirements, opt-in mechanics, unsubscribe obligations |
| Before first ad campaign | Advertising claims compliance, Estonian Consumer Protection Act |
| Before collecting analytics data | Cookie consent (ePrivacy), data minimization, retention periods |
| Enterprise customer wants DPA | Data Processing Agreement template, sub-processor list, SCCs |
| ToS update needed | Updated terms reflecting new features, liability clauses |
| Competitor legal claim | IP analysis, response strategy |

The growth agent never does legal analysis — it flags the need via human tasks, and the investor invokes `/lawyer`.

---

## 7. New Command: `/growth`

Launches the growth track. Analogous to `/startup` for the build loop.

### Pre-flight Checks

- Solution signoff exists in `.startup/go-live/` (product is live) — unless `--pre-launch` flag is used
- Chrome browser MCP (claude-in-chrome) available
- LinkedIn MCP available (warning if not, not blocking)

### Initialization (first invocation)

If `docs/growth/` does not exist, `/growth` runs an initialization sequence:

1. Creates the full `docs/growth/` directory structure
2. Spawns business founder to write:
   - `docs/growth/product-brief.md` — translates Estonian research + architecture into English sales-ready product description (what it does, who it's for, why it's better, pricing)
   - `docs/growth/strategy.md` — overall growth plan: ICP definition, prioritized channels, phase 1 goals, success metrics
   - `docs/growth/brand/approved-voice.md` — brand voice guide with tone, personality, example messages, anti-examples. Business founder drafts based on market research; investor reviews once.
3. Growth agent drafts:
   - 3-5 LinkedIn connection request templates
   - 5 cold email templates (short, under 150 words each)
   - 3 community engagement response templates
   - Saved to `docs/growth/content/outreach-templates/`
4. Human tasks created:
   - Buy cold email domain (separate from primary)
   - Set up 3-5 email accounts on cold domain
   - Register accounts on target platforms (Product Hunt, directories, etc.)
5. Updates `.gitignore` if needed

Investor reviews product brief + strategy + templates. Growth loop starts as soon as investor approves — don't wait for cold email domain to be fully warmed up (that happens in parallel).

### Behavior (subsequent invocations)

- Reads `docs/growth/strategy.md` for current phase and priorities
- Spawns business founder to write growth brief OR growth agent to execute
- Manages the growth loop alongside the build track
- Updates `.startup/state.json` with growth track state:
  - `growth_phase`: `"pre-launch"` | `"launch"` | `"outbound"` | `"optimize"`
  - `growth_status`: `"active"` | `"paused"` | `"escalated"`
  - `growth_iteration`: counter for growth handoff cycles
  - `growth_started`: ISO timestamp of when `/growth` was first invoked

---

## 8. Role Summary (Post-Launch)

| Role | Domain | Invocation | Tools |
|------|--------|-----------|-------|
| Business Founder | Product strategy + growth strategy | Automatic (orchestrator) | Chrome, WebSearch, WebFetch, files |
| Tech Founder | Code + PLG features | Automatic (orchestrator) | Bash, files (no web) |
| Growth Hacker | Sales execution | Automatic (orchestrator) | Chrome, LinkedIn MCP, WebSearch, files |
| Lawyer | Legal compliance | On-demand (`/lawyer`) | Datalake API, WebSearch, files |
| UX Tester | Conversion optimization | On-demand (`/ux-test`) | Chrome, files |
| Investor (human) | Approvals, accounts, identity-bound actions | Human tasks | Real-world actions |
