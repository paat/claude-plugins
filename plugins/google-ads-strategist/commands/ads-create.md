---
name: ads-create
description: Create the v1 campaign in Google Ads via Chrome automation. Reads spec.md, builds the campaign in the Ads UI step by step, and saves it in PAUSED state for investor review. The investor enables the campaign after reviewing it in the Ads UI. Usage: /ads-create [campaign]
user_invocable: true
allowed-tools: Task, Read, Write, Bash, Glob
argument-hint: [campaign]
---

# /ads-create — Build campaign in Google Ads via Chrome

Delegates to the ads-strategist to create the campaign in the Google Ads UI using Chrome automation. The campaign is created in **PAUSED state** — the investor reviews it in the Ads UI and clicks Enable when satisfied.

## Step 0: Pre-flight

If no campaign argument, detect from `docs/ads/*/brief.md`. If multiple, ask.

Verify:
1. `iterations/v1/spec.md` exists — if not, run `/ads-iterate` first
2. `iterations/v1/result.md` exists and says "READY TO LAUNCH" — if not, run `/ads-ready`
3. Chrome MCP is available: `mcp__claude-in-chrome__tabs_context_mcp`

If any fail, STOP and direct the user.

## Step 1: Confirm with user

> **About to create campaign `<campaign>` in Google Ads via Chrome.**
>
> - Source: `docs/ads/<campaign>/iterations/v1/spec.md`
> - Campaign will be created in **PAUSED state** — it will NOT start serving ads
> - You will review it in the Google Ads UI and enable it when ready
> - Estimated time: 5-15 minutes of Chrome automation
>
> **Prerequisites**:
> - You must be logged into Google Ads at `ads.google.com` in Chrome
> - The existing FY2025 campaign should be paused first (if applicable)
>
> Proceed?

Wait for user confirmation.

## Step 2: Dispatch the ads-strategist

Spawn the ads-strategist via Task tool:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md` for your identity.
>
> **Task: Create campaign `<campaign>` in Google Ads UI via Chrome.**
>
> Load skills:
> 1. `google-ads-strategist:chrome-campaign-creation`
> 2. `google-ads-strategist:browser-verification`
>
> Read:
> - `docs/ads/<campaign>/iterations/v1/spec.md` — the full campaign spec to build
> - `docs/ads/<campaign>/brief.md` — for context (brand name, budget, etc.)
>
> Follow the `chrome-campaign-creation` skill step by step. Key rules:
>
> 1. **Create the campaign in PAUSED state** — set status to Paused in the campaign creation wizard BEFORE saving. NEVER enable.
> 2. **Use proper Estonian diacritics** in all ad copy (ä, ö, ü, õ, š, ž) — the spec.md uses ASCII for portability, but the Ads UI must have proper Unicode.
> 3. **Screenshot every major step** into `iterations/v1/verification/creation-step-NN.png` (or note screenshot IDs if inline).
> 4. **Build in this order**: campaign settings → ad groups (one at a time: keywords + RSA + extensions) → campaign-level negatives → campaign-level extensions (sitelinks, callouts) → verify PAUSED status
> 5. If any step fails (form not loading, selector not found, unexpected UI), STOP and report — do not guess or retry blindly.
> 6. After all ad groups are created, take a final screenshot of the campaign overview showing PAUSED status.
>
> Report back:
> - Campaign URL in Google Ads (e.g., `ads.google.com/aw/campaigns/<id>`)
> - Number of ad groups created
> - Number of keywords entered
> - Number of RSAs created
> - Confirmation that status is PAUSED
> - Any warnings or issues encountered
> - List of screenshots taken

## Step 3: Report to user

> **Campaign `<campaign>` created in Google Ads — PAUSED.**
>
> [summary from agent]
>
> **Your next steps:**
> 1. Open Google Ads → Campaigns → `<campaign-name>` (link: ...)
> 2. Review: ad copy, keywords, extensions, budget, targeting
> 3. Fix any issues you spot (the agent may have minor formatting differences from spec)
> 4. When satisfied, change campaign status from Paused → Enabled
> 5. After enabling, run `/ads-metrics` in 7 days to pull the first post-launch data

## Notes

- The campaign is ALWAYS created as PAUSED — the agent never enables it
- If the Google Ads UI has changed since the skill was written, the agent may need to adapt selectors — it will report if it gets stuck
- Screenshots are saved inline in the conversation (referenced by screenshot IDs) since Chrome MCP doesn't write to disk directly — the agent notes the IDs in verification/
- If there's an existing campaign that needs pausing first, the agent will check but NOT pause it — the investor does that manually before running /ads-create
