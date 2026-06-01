---
name: ads
description: On-demand Google Ads campaign design — spawns the google-ads-strategist's ads-strategist agent to design, browser-verify, and create a campaign in PAUSED state for investor review. Usage: /ads <campaign brief or objective>
user_invocable: true
argument-hint: <campaign brief or objective>
---

# /ads — On-Demand Google Ads Campaign

The investor requests a Google Ads campaign. You (the Team Lead) spawn the **ads-strategist** agent from the `google-ads-strategist` plugin to design it through the iterative loop, verify it in the browser, and create it in **PAUSED** state. The investor reviews in the Ads UI and enables it.

**ads-strategist is a one-shot specialist, NOT a loop participant.** It spawns, designs/verifies/creates the campaign in `docs/ads/<campaign>/`, and exits. This command is the investor-initiated twin of the automatic Growth→Ads delegation in `/growth`.

## Pre-Flight Checks (HARD FAIL — No Fallbacks)

All of the following must pass. If any fails, stop with the error and do NOT proceed. There is no inline fallback — Google Ads work requires the `google-ads-strategist` plugin (hard dependency).

### Check 1: Startup project exists

Verify these files exist:
- `.startup/state.json`
- `docs/business/brief.md`

**If missing:**
> **Error:** No startup project found. Run `/startup` first to initialize the project before running `/ads`.

### Check 2: Chrome MCP is reachable

Attempt to call `mcp__claude-in-chrome__tabs_context_mcp`. The strategist verifies every keyword in the real browser (Ad Preview Tool, SERP, Transparency Center) and creates the campaign via Chrome.

**If unavailable:**
> **Error:** Chrome browser MCP (claude-in-chrome) is not available. ads-strategist needs Chrome for Ad Preview verification and campaign creation. Connect Chrome and retry.

## Step 0: Reset active_role

Overwrite `active_role` in `.startup/state.json` before spawning. The `enforce-delegation` and `check-stop` hooks bypass for Task-spawned agents via the `--agent-id` process-tree check, but resetting clears any stale `"team-lead"` value that could block an edge-case Edit. Same pattern as `/lawyer` Step 0.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "ads-strategist"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

## Step 1: Determine the campaign slug

If `docs/growth/channels/ads.md` exists and names an active campaign slug, reuse it (so this command and the `/growth` loop converge on one campaign, not two). Otherwise derive a stable slug `<product>-<intent>-<market>` (e.g. `aruannik-commercial-ee`) from the brief.

```bash
mkdir -p docs/ads
```

## Step 2: Gather context for the strategist

Read whichever of these exist, to pass as context:
- `docs/business/brief.md` — what the product is
- `docs/growth/product-brief.md` — sales-ready product description, ICP, pricing
- `docs/growth/strategy.md` — ICP, channels, goals
- `docs/growth/brand/approved-voice.md` — tone, approved messaging
- `docs/growth/channels/ads.md` — existing campaign index + approved budget

## Step 3: Spawn the ads-strategist

Use the `Task` tool with `subagent_type: "ads-strategist"` — the registered agent type provided by the `google-ads-strategist` plugin. Do **NOT** spawn `general-purpose` and have it read the strategist's agent-definition markdown by `${CLAUDE_PLUGIN_ROOT}` path: in this command `${CLAUDE_PLUGIN_ROOT}` is the saas plugin, so that path does not exist, and the strategist's own `${CLAUDE_PLUGIN_ROOT}` skill/template references only resolve when it runs natively under its own plugin.

**If Claude Code reports the `ads-strategist` agent type is unknown**, the `google-ads-strategist` plugin is not installed. Stop with:
> **Error:** The `ads-strategist` agent is not available. `/ads` requires the **google-ads-strategist** plugin. Install it from the marketplace (`/plugin marketplace … && /plugin install google-ads-strategist`), then retry.

Pass the strategist this brief:

> **Campaign:** `<slug>`
>
> **Objective (from the investor):** `$ARGUMENTS`
>
> **Context (read these for product, audience, budget, brand, final-URL):**
> - `docs/business/brief.md`
> - `docs/growth/product-brief.md`
> - `docs/growth/strategy.md`
> - `docs/growth/brand/approved-voice.md`
> - `docs/growth/channels/ads.md` (existing campaigns + approved budget cap — do NOT exceed it in forecasts)
>
> If `docs/ads/<campaign>/brief.md` does not exist, create it from the context above (product, audience, budget, goals, brand, final-URL template), then run your pre-launch iteration loop, verify in the browser, and create the campaign in **PAUSED** state. Do NOT enable it — the investor enables after review.

## Step 4: Report to the investor (English)

After the strategist completes, summarize:
- Campaign folder written: `docs/ads/<slug>/`
- Iteration / verification status (which keywords trigger the ad, position, competitor differentiation)
- Whether the campaign was created PAUSED in the Ads UI
- **Next action for the investor:** review the campaign in Google Ads and enable it when satisfied — the plugin never enables.
- Update `docs/growth/channels/ads.md` index entry for `<slug>` (status: designed/created-paused) if it changed.
