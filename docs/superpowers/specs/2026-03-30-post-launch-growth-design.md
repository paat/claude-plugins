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

Three tiers of content review:

1. **First use of a new channel**: Growth agent writes a draft and requests human approval via human-tasks. Investor approves tone, messaging, and approach. Approved examples saved to `docs/growth/brand/approved-voice.md`.
2. **Routine content on approved channels**: Growth agent proceeds autonomously but logs all published content to the relevant `docs/growth/channels/*.md` file for audit.
3. **Sensitive content — always requires human approval**:
   - Responding to negative comments or complaints
   - Content touching controversial topics
   - Any claims about competitors
   - Pricing or discount offers
   - Legal or compliance-adjacent statements

**Periodic review**: Every 2 weeks (or every 10 published pieces, whichever comes first), the growth agent flags a sample of recent content in human-tasks for investor spot-check. This prevents tone drift.

### LinkedIn Safety

LinkedIn bans are a real and escalating risk (Apollo.io and Seamless.ai banned March 2025, 23% ban risk for automated accounts). Hard limits enforced by the growth agent:

- **Max 15 profile views per day** via LinkedIn MCP
- **Max 10 connection requests per week** (well under LinkedIn's 100/week limit — conservative to avoid detection)
- **Max 5 messages per day** to non-connections
- **All connection requests go through human-tasks** — the investor sends them from their own account
- **No scraping or bulk data extraction** — research individual prospects, don't build databases
- **Cool-down**: If any LinkedIn action returns an error or warning, pause all LinkedIn activity for 48 hours and flag in human-tasks
- LinkedIn MCP is for **research and intelligence**, not for automated outreach at scale

These limits are tracked in `docs/growth/channels/linkedin.md` with daily/weekly counters.

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
│   └── communities.md       ← Forums/Reddit, threads engaged, tone approved
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

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Chrome can't log into external platform (session expired, CAPTCHA, 2FA) | Tool returns error or page shows login screen | Flag in human-tasks: "investor must re-authenticate session for [platform]". Pause that channel, continue others. |
| LinkedIn MCP rate limited or returns errors | Any LinkedIn tool error or warning response | 48-hour cool-down on all LinkedIn activity. Log in `docs/growth/channels/linkedin.md`. |
| All Phase 1 channels produce zero signups after 14 days | Growth report shows 0 conversions across all channels | Escalate to investor: "Phase 1 produced no results. Possible causes: wrong ICP, wrong channels, product-market fit issue. Recommend investor review before continuing." Pause growth track. |
| Growth agent publishes inappropriate content | Periodic review catches it, or investor notices | Immediately pause autonomous posting on that channel. Revert to human-approval-required. Update `approved-voice.md` with anti-examples. |
| Ad spend exceeds approved budget | Growth agent checks budget in growth brief before any ad action | Hard stop: never exceed approved budget. Flag in human-tasks if more budget needed. |
| Growth agent context overload (too many channels active) | Growth report quality degrades, actions become unfocused | Orchestrator limits active channels to max 3 per growth cycle. Business founder prioritizes in growth brief. |

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
| `PostToolUse` (Write) | `check-brand-safety.sh` | Block writes to external-facing content files unless channel is in approved list in `approved-voice.md`, or content is flagged for human review |
| `PostToolUse` (Write) | `check-linkedin-limits.sh` | Parse `docs/growth/channels/linkedin.md` counters; block LinkedIn MCP calls if daily/weekly limits exceeded |
| `PostToolUse` (Write) | `check-ad-budget.sh` | Verify ad actions don't exceed approved budget from growth brief |
| `PostToolUse` (Write) | `auto-commit-growth.sh` | Auto-commit growth content and metrics updates (same pattern as existing `auto-commit.sh`) |

---

## 5. 90-Day Sales Playbook

The growth agent follows a phased playbook. Business founder sets the phase based on metrics in `docs/growth/metrics/`.

### Phase 1: Launch (Days 1-14)

**Goal**: First 10-20 signups through visibility burst

| Action | Executor |
|--------|----------|
| Submit to SaaS directories (Product Hunt, AlternativeTo, etc.) | Growth agent via Chrome |
| Write and publish launch blog post | Growth agent → investor approves |
| Post in relevant Estonian communities/forums | Growth agent → investor approves first post |
| Research and list 50 high-fit prospects via LinkedIn MCP | Growth agent |
| Set up basic analytics tracking via Chrome | Growth agent |
| Register accounts on platforms | **Human task** |
| Post on Product Hunt (needs founder identity) | **Human task** |

### Phase 2: Outbound + Content Engine (Days 15-45)

**Goal**: 50 signups, establish repeatable acquisition

| Action | Executor |
|--------|----------|
| Draft personalized outreach messages for top prospects | Growth agent → investor reviews first batch |
| Write 2 SEO articles per week (bottom-of-funnel) | Growth agent |
| Monitor competitor content via LinkedIn MCP + WebSearch | Growth agent |
| Engage in community threads where ICP asks relevant questions | Growth agent (approved tone) |
| Track conversions, update docs/growth/metrics/ | Growth agent |
| Build ICP-specific landing pages | Tech founder (via build track) |
| Send LinkedIn connection requests from investor's account | **Human task** |
| Approve ad budget | **Human task** |

### Phase 3: Optimize + Scale (Days 46-90)

**Goal**: 100+ signups, identify primary growth channel, prove unit economics

| Action | Executor |
|--------|----------|
| Manage ad campaigns via Chrome (Google Ads, Meta) | Growth agent |
| A/B test landing page copy | Growth agent + tech founder |
| Write first customer case study | Growth agent (interviews via human) |
| Set up referral mechanics | Tech founder (via build track) |
| Weekly metrics report | Growth agent |
| Kill channels with no traction after 45 days | Business founder decision |
| Double budget on proven channels | Business founder decision |
| Collect customer testimonials | **Human task** |
| Negotiate partnership deals | **Human task** |

Phase transitions are driven by metrics, not calendar. If Phase 1 exceeds targets, advance early.

### Phase 0: Pre-Launch (Optional, before go-live)

If the investor wants to build audience before the product is live, `/growth` can be invoked with the `--pre-launch` flag, which skips the solution signoff check. Limited to:

| Action | Executor |
|--------|----------|
| Build email waitlist landing page | Tech founder (via build track) |
| Write "building in public" content | Growth agent → investor approves |
| Research and join relevant communities | Growth agent |
| Create `docs/growth/strategy.md` and `docs/growth/product-brief.md` | Business founder |

No outreach, no ads, no directory submissions in pre-launch — just audience building and preparation.

### Beyond 90 Days

After Phase 3, the business founder reviews growth metrics and decides:

- **Continue scaling**: Add budget to winning channels, expand to new markets. Growth agent continues with Phase 3 tactics on a rolling basis.
- **Hire human sales**: Growth agent's documented playbook (`docs/growth/`) serves as the onboarding manual. Growth agent shifts to supporting the human (research, content drafting, analytics) rather than executing directly.
- **Pivot**: If no channel achieved sustainable unit economics (LTV:CAC > 3:1), escalate to investor for strategic review. Possible outcomes: change ICP, change pricing, change product, or pause growth.

### Token Cost Awareness

Each growth agent spawn should complete its task within ~30K tokens of agent context. Guidelines:
- One channel focus per spawn (don't try to execute across all channels in one dispatch)
- Content creation: 1-2 articles or 5-10 outreach drafts per spawn
- Research: max 20 prospect profiles per spawn
- Analytics: read dashboards and write one metrics update per spawn

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
3. Creates empty `docs/growth/brand/approved-voice.md` with a human-task requesting investor to provide brand guidelines (tone, personality, things to avoid)
4. Updates `.gitignore` if needed

The growth loop does not start until initialization is complete and investor has approved the product brief and strategy.

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
