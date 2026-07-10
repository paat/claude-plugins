---
name: growth
description: Launch the lifecycle-aware growth track — initializes docs/growth/ structure, detects prelive/live/postlive/paused state, stages go-live readiness before outreach, and runs customer acquisition only when lifecycle gates allow it. Usage: /growth [--prelive|--pre-launch|--live|--postlive|--paused]
user_invocable: true
---

# /growth — Launch Growth Track

You are the **Team Lead** (orchestrator) launching the growth track. Growth is lifecycle-aware:
pre-live projects get go-live readiness and staged assets only; live-but-unvalidated projects
start with inbound/controlled validation; post-live projects execute acquisition channels.

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

### Check 1: Detect lifecycle state

Resolve one lifecycle value before creating tasks: `prelive`, `live`, `postlive`, or `paused`.
Explicit flags win (`--prelive`, legacy `--pre-launch`, `--live`, `--postlive`, `--paused`);
otherwise infer from state and launch evidence:

```bash
lifecycle=""
case " $* " in
  *" --prelive "*|*" --pre-launch "*) lifecycle="prelive" ;;
  *" --live "*) lifecycle="live" ;;
  *" --postlive "*) lifecycle="postlive" ;;
  *" --paused "*) lifecycle="paused" ;;
esac

if [ -z "$lifecycle" ] && [ -f .startup/state.json ] \
  && [ "$(jq -r '.status // empty' .startup/state.json)" = "paused" ]; then
  lifecycle="paused"
fi
if [ -z "$lifecycle" ] && [ ! -f .startup/go-live/solution-signoff.md ]; then
  lifecycle="prelive"
fi
if [ -z "$lifecycle" ]; then
  if [ -f docs/growth/metrics/summary.md ] \
    && grep -qiE 'paid conversion|customer acquisition cost|CAC|reply rate|scan conversion' docs/growth/metrics/summary.md; then
    lifecycle="postlive"
  else
    lifecycle="live"
  fi
fi
printf '%s\n' "$lifecycle" > .startup/growth-lifecycle
```

If lifecycle is `prelive`, do **not** execute outreach, prospect scans, paid ads, directory
submissions, or customer contact. Create/maintain launch-readiness and staged growth assets.
If lifecycle is `paused`, run diagnostics and blocker removal only.

### Check 2: Chrome browser MCP available

Attempt to call `mcp__claude-in-chrome__tabs_context_mcp` to verify Chrome is reachable. If the tool call fails or is unavailable:

> **Warning:** Chrome browser MCP (claude-in-chrome) is not available. External growth research and live channel work will be limited. Continue with local readiness/staging where possible.

### Check 3: LinkedIn MCP available

Check for LinkedIn tools availability.

**If unavailable:**
> **Warning:** LinkedIn MCP is not available. LinkedIn prospect research will be limited to public/browser research. Pre-live projects still stage assets only.

## Spend Envelope (owner pre-authorization)

The owner authorizes paid spend **once**, in `docs/growth/envelope.json`, instead of gating
every ad action. This is the *only* place the buyer-intent rule and the schema are stated —
do not restate them in other prompts.

```json
{
  "monthly_cap_eur": 200,
  "daily_cap_eur": 20,
  "locale": "et-EE",
  "channels": ["ads", "seo", "content"],
  "buyer_intent_only": true,
  "authorized_by": "owner name or handle",
  "authorized_at": "2026-07-09T00:00:00Z",
  "expires_at": "2026-12-31T23:59:59Z"
}
```

- **Fail closed.** No envelope, an expired `expires_at`, or malformed JSON ⇒ **today's
  behavior**: all paid spend and PAUSED→live is owner-gated. Never ship a default envelope
  and never invent caps — a missing file authorizes nothing.
- **Money stays a human carve-out** (`templates/merge-policy.md`). The envelope only
  pre-authorizes a *bounded* amount inside these caps; it does not remove the carve-out.
  Anything beyond the caps, or spend on a channel not listed, remains owner-gated.
- **Buyer-intent only** (standing rule): paid targeting must be commercial/transactional
  intent only; exclude informational queries. This is a non-negotiable envelope condition.
- **Within envelope** (present, unexpired, channel listed, projected spend within
  `daily_cap_eur`/`monthly_cap_eur`): ads may go PAUSED→live and SEO/content ship without a
  per-action owner gate. **Outside it**: PAUSED / owner-gated exactly as before.
- **Mechanical backstop.** `scripts/check-ad-budget.sh` reads `monthly_cap_eur` from the
  envelope (unexpired) as the hard stop; the `Approved budget:` line in `ads.md` is the
  fallback when no valid envelope exists. `daily_cap_eur` is a forecast constraint the
  ads-strategist checks, not a hook.
- **Spend reporting.** When a growth pass touches paid channels, record one
  `- Spend: EUR <amount> — <channel/campaign> (envelope <daily>/<monthly>)` line in the
  pass run artifact under `.startup/<loop>/runs/` (the daily digest, #194, scrapes
  `.startup/*/runs/*.md` into its Spend summary). Zero-spend passes report nothing.

Resolve the envelope once per pass:

```bash
env_file="docs/growth/envelope.json"
envelope_active=false
# Well-formed AND unexpired: a positive monthly cap, buyer-intent-only set, at least one
# channel, and a future expiry. Anything missing ⇒ inactive ⇒ owner-gated (fail closed).
if [ -f "$env_file" ] && jq -e '
  (.monthly_cap_eur // 0) > 0 and (.buyer_intent_only == true)
  and ((.channels // []) | length > 0) and (.expires_at != null)
' "$env_file" >/dev/null 2>&1; then
  exp=$(jq -r '.expires_at' "$env_file")
  [ "$(date +%s)" -le "$(date -d "$exp" +%s 2>/dev/null || echo 0)" ] && envelope_active=true
fi
```

## Step 2: Initialization (first invocation)

If `docs/growth/` does not exist, run the initialization sequence:

### 2a: Create directory structure

```bash
mkdir -p docs/growth/{channels,leads,metrics/weekly,brand,content/blog,content/outreach-templates,readiness}
```

### 2b: Run /bootstrap (idempotent)

Run `/bootstrap` to ensure all docs/ subdirectories exist.

### 2c: Spawn business founder for strategy

Before dispatching, claim the growth initialization lease:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --acquire "growth:init:${PWD}" --state-dir .startup/leases --owner "growth:init:$$" --ttl-seconds 1800
```

If no explicit channel or strategy direction was provided, run the market scout first. It
uses configured external market evidence when available and falls back to internal demand
discovery when browsing/source data is unavailable. Use the top candidate as one input into
`docs/growth/strategy.md`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/market-scout.sh"
```

Spawn business founder via Task tool with `subagent_type: "general-purpose"`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/business-founder.md` for your identity and tools.
>
> **New task: Write growth initialization documents.**
>
> Read your market research from `docs/research/` and the business brief from `docs/business/brief.md`.
> Read `.startup/growth-lifecycle` and any market-scout output under `.startup/demand/`.
>
> Write the following files:
>
> 1. `docs/growth/product-brief.md` — Translate your Estonian market research and the product architecture into an English sales-ready product description. Include: what the product does, who it's for (specific ICP), what problem it solves, why it's better than competitors, and pricing. This is the growth agent's primary context — make it complete.
>
> 2. `docs/growth/strategy.md` — Overall growth plan: ICP definition (role, company size, pain point, where they hang out), prioritized channels, goals and success metrics, and the current lifecycle (`prelive`, `live`, `postlive`, or `paused`).
>
> 3. `docs/growth/brand/approved-voice.md` — Brand voice guide: tone and personality, example messages (English section + Estonian section), things to never say, and anti-examples. Base this on your market research — use the customer language you extracted from Reddit/forums.
>
> 4. `docs/growth/autonomous-operations.md` — Autonomy-first operating policy. Include: autonomy principle; agent-owned work list; owner authorization gates for legal identity, domain/account ownership, public claim boundaries, paid spend caps, credential/recovery ownership, and pricing/offer envelope; automation targets to remove future gates; stop rules for legal, reputation, opt-out, platform, and spend risk. Do not create recurring manual review work.
>
> 5. `docs/growth/readiness/go-live-checklist.md` — For `prelive`, make this the primary artifact: public URL, production env, operator identity, legal wrapper, payment/report delivery, transactional email, retention/suppression, observability, smoke tests, and launch metrics. For other lifecycles, keep it as a short verification record.
>
> After writing the files, message the team lead: "Lifecycle-aware growth initialization docs ready."

### 2d: Growth agent drafts outreach templates

After business founder completes, spawn growth agent via Task tool:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/growth-hacker.md` for your identity and tools.
>
> **New task: Draft lifecycle-gated growth assets.**
>
> Read `docs/growth/product-brief.md`, `docs/growth/strategy.md`, and `docs/growth/brand/approved-voice.md`.
> Read `.startup/growth-lifecycle`.
>
> Write the following to `docs/growth/content/outreach-templates/`:
>
> 1. `linkedin-templates.md` — 3-5 LinkedIn connection request message templates. Short (under 300 characters). Personalized first line placeholder. Rotate-friendly (varied openings).
>
> 2. `cold-email-templates.md` — 5 cold email templates. Short (under 150 words each). Single CTA. 3-email sequence: initial, 3-day follow-up, 10-day final.
>
> 3. `community-templates.md` — 3 community engagement response templates. Value-first, product mention natural, not pushy.
>
> If lifecycle is `prelive`, prepend "STAGED - DO NOT CONTACT UNTIL GO-LIVE GATES PASS" to every outreach/template file and do not build/send lead batches. Lead-source research is allowed only as staged source notes in `docs/growth/leads/`.
>
> After writing, message the team lead: "Lifecycle-gated growth assets ready."

## Step 3: Update State

Update `.startup/state.json` — READ it first, then add growth fields AND overwrite `active_role`. Resetting `active_role` is mandatory: the `enforce-delegation` hook fires only when `active_role=="team-lead"`, and a stale value from a prior `/startup` session would block the growth-track subagents' writes.

```json
{
  "active_role": "business-founder",
  "growth_lifecycle": "prelive" or "live" or "postlive" or "paused",
  "growth_phase": "prelive" or "live" or "postlive" or "paused",
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
> Read `docs/growth/autonomous-operations.md` for owner authorization gates and stop rules.
> Read `.startup/growth-lifecycle`.
> Read the relevant channel doc in `docs/growth/channels/` for what's been done (if exists).
>
> **Lifecycle contract:**
> - `prelive`: do not contact prospects, send cold email, run paid ads, submit listings, perform prospect scans, or execute outreach. Stage assets only; maintain `docs/growth/readiness/go-live-checklist.md`; mark lead-source research and templates "STAGED - DO NOT CONTACT"; route app/code launch blockers through the startup-team build track; report launch metrics (gates verified, smoke tests passed, staged leads, launch content drafted).
> - `live`: launch inbound first (free scan, checklist/content page, passive demand capture). Run warm intros or very low-volume controlled validation only when sender identity, legal claim, opt-out, and suppression gates are clear. Keep paid ads research-only until conversion tracking and offer proof exist.
> - `postlive`: execute approved acquisition channels within policy and budget caps: outbound, communities, agency partners, SEO/content, paid ads. Track reply, scan, paid conversion, CAC, and stop-loss rules.
> - `paused`: run diagnostics and blocker removal; do not start acquisition.
>
> **Paid spend** is governed by `docs/growth/envelope.json` (see Spend Envelope): within an active envelope's caps and listed channels, paid activation is pre-authorized and needs no per-action owner gate; outside it, spend stays owner-gated. Record the `- Spend:` line in the pass run artifact whenever a pass touches paid channels (see Spend Envelope).
>
> **Your goal is to EXECUTE only where the lifecycle contract and spend envelope permit execution.** For blocked authority boundaries (domain ownership, legal identity, credentials, spend beyond the envelope, pricing), update `docs/growth/autonomous-operations.md` as an owner authorization gate and continue with agent-owned work.
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
3. Spawn the strategist with the `Task` tool using `subagent_type: "ads-strategist"` (the registered type from `google-ads-strategist` — NOT `general-purpose`+read-md, which would resolve `${CLAUDE_PLUGIN_ROOT}` to the saas plugin). Pass the request block plus `docs/business/brief.md`, `docs/growth/product-brief.md`, `docs/growth/strategy.md`, `docs/growth/brand/approved-voice.md`, and `docs/growth/channels/ads.md`, with the instruction: create `docs/ads/<slug>/brief.md` from this context if absent, run the pre-launch loop, verify in the browser, and create the campaign **PAUSED**. Enablement is gated by the envelope (see Spend Envelope): pass `enable_authorized: true` only when `envelope_active` is true, `ads` is in `channels`, and the campaign forecast is within `daily_cap_eur`/`monthly_cap_eur` — then the strategist may take the campaign PAUSED→live. Otherwise it stays PAUSED for the owner to enable.
4. **If the `ads-strategist` agent type is unknown**, the `google-ads-strategist` plugin is not installed. Stop and tell the investor to install it (`/plugin install google-ads-strategist`); do NOT fall back to building the campaign inline.
5. After the strategist returns, update the `docs/growth/channels/ads.md` index entry for the slug (status: created-paused), then continue the growth loop.

**Pre-live caveat:** if lifecycle is `prelive` (no commercial landing page / `final_url` or launch gates incomplete), defer ads execution. The strategist may draft/research campaign assets in PAUSED/planning form only; record the blocker as an owner authorization gate or go-live checklist item, not as recurring manual review work.

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
