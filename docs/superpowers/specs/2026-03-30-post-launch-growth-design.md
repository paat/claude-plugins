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

- **Chrome browser** (claude-in-chrome MCP): Navigate ad dashboards, publish content on platforms, submit to directories, manage analytics UIs, post on forums
- **LinkedIn MCP**: Search prospects, research companies, monitor competitor content, identify hiring signals
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

For any new channel (first LinkedIn post, first Reddit comment, first ad campaign), the growth agent writes a draft and requests human approval via human-tasks. After the investor approves the tone/approach for a channel, subsequent posts on that channel proceed autonomously.

### Context Source

The growth agent has no memory of the build phase. It reads:
- `docs/` (research, architecture, business brief) for product understanding
- `docs/growth/` for growth strategy, channel history, metrics, and approved brand voice

---

## 2. File-Based State

### Durable Growth Knowledge (git-tracked)

```
docs/growth/
├── strategy.md              ← Overall growth plan, ICP, channels, priorities
├── channels/
│   ├── content-marketing.md ← Published articles, keywords targeted, performance
│   ├── linkedin.md          ← Outreach history, connection stats, what messaging works
│   ├── directories.md       ← Where listed, submission dates, status
│   ├── ads.md               ← Campaigns, spend, ROAS, what's working
│   └── communities.md       ← Forums/Reddit, threads engaged, tone approved
├── leads/
│   └── pipeline.md          ← Prospects researched, status, next action
├── metrics/
│   └── weekly-report.md     ← KPIs tracked over time (MRR, signups, conversion)
└── brand/
    └── approved-voice.md    ← Investor-approved messaging, tone, examples
```

Each fresh agent spawn reads these files to know what's been done, what's working, and what to do next. Results and learnings accumulate here as durable, compounding knowledge.

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

**Pre-flight checks**:
- Solution signoff exists in `.startup/go-live/` (product is live)
- `docs/growth/strategy.md` exists (growth plan defined)
- Chrome browser MCP available

**Behavior**:
- Reads `docs/growth/strategy.md` for current phase and priorities
- Spawns business founder to write growth brief OR growth agent to execute
- Manages the growth loop alongside the build track
- Updates `.startup/state.json` with growth track state:
  - `growth_phase`: `"launch"` | `"outbound"` | `"optimize"`
  - `growth_status`: `"active"` | `"paused"`
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
