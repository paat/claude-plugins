# Growth → Ads delegation design

**Date:** 2026-06-01
**Status:** Approved (design)
**Plugins touched:** `saas-startup-team`, `google-ads-strategist`

## Problem

`saas-startup-team`'s `growth-hacker` agent is a generalist post-launch executor. Among many channels it "manages Google Ads … via Chrome", but only as a thin "create a campaign, log it in `ads.md`" responsibility — no hypothesis discipline, no buyer-intent gate, no browser verification, no per-campaign learnings.

`google-ads-strategist`'s `ads-strategist` agent is a specialist designer that has exactly that discipline: single-variable hypotheses, buyer-intent + product-value gates, Ad-Preview/SERP/Transparency-Center verification, PAUSED-state creation, and accumulating `docs/ads/<campaign>/learnings.md`.

Today the two compose only **manually** (the ads README documents a hand-off: run `/ads-brief` … then hand the spec to growth-hacker). We want `growth-hacker` to **automatically** use the specialist instead of doing Google Ads itself.

## Decisions

These were settled during brainstorming:

1. **Auto-delegation, keep both plugins.** No merge. `growth-hacker` delegates Google Ads work to `ads-strategist`; both plugins stay independently installable.
2. **Hard dependency.** `saas-startup-team` requires `google-ads-strategist` for any Google Ads work. `growth-hacker`'s inline Google Ads handling is removed and replaced with mandatory delegation. Claude Code has no manifest-level dependency field, so "hard" means: documented requirement + the agent/command is instructed to delegate and **fail loudly** (with an install instruction) if the strategist is unavailable — never silently fall back to doing it inline.
3. **Records: index/pointer.** `docs/ads/<campaign>/` is the source of truth for Google Ads. `docs/growth/channels/ads.md` shrinks to a lightweight index (campaign slug, status, link to the `docs/ads/` folder). Non-Google channels (Meta/LinkedIn) are still logged inline in `ads.md`. No duplicated data.
4. **Hybrid architecture.** Two entry points, one engine:
   - `growth-hacker` auto-delegates via `Task(subagent_type: "ads-strategist")` for ad work that arises mid-execution.
   - A new `/saas-startup-team:ads` consultant command (mirroring `/lawyer`, `/ux-test`) lets the investor trigger campaign work directly.
   Both converge on the same `ads-strategist` agent and the same `docs/ads/<campaign>/` records.

## Architecture & data flow

```
                        ┌──────────────────────────────┐
  Investor ──/ads──────▶│  /saas-startup-team:ads       │  NEW consultant command
                        │  (team lead spawns strategist) │  (mirrors /lawyer, /ux-test)
                        └───────────────┬──────────────┘
                                        │ Task(subagent_type:"ads-strategist")
 growth-hacker ─(mid-execution)─────────┤
   hits Google Ads work, auto-delegates │
                                        ▼
                        ┌──────────────────────────────┐
                        │  ads-strategist (google-ads)   │  designs → verifies →
                        │  writes docs/ads/<campaign>/    │  creates PAUSED in Ads UI
                        └───────────────┬──────────────┘
                                        │ returns campaign folder + status
                                        ▼
   docs/ads/<campaign>/            = source of truth (brief, iterations, learnings)
   docs/growth/channels/ads.md     = lightweight index → links each docs/ads/ folder
```

**Boundary preserved end-to-end:** `ads-strategist` creates campaigns **PAUSED**; the investor enables them in the Ads UI after review. `growth-hacker` never launches anything — it triggers design/creation and reports. The existing human gate "first paid ad campaign launch (budget approval)" stays with growth-hacker/the investor.

**Scope:** delegation covers **Google Ads only** — `ads-strategist` is Google-Ads-specific. Meta/LinkedIn ads stay inline with `growth-hacker` (still budget-gated).

## Components

### saas-startup-team

#### `agents/growth-hacker.md` (edit)

- Rewrite "### 3. Ad Campaign Management" into two parts:
  - **Google Ads → delegate.** When Google Ads work arises, spawn `Task(subagent_type: "ads-strategist", …)`. Pass: product description, ICP, **approved budget cap**, brand name, and final-URL template — sourced from `docs/growth/product-brief.md`, `docs/growth/strategy.md`, and `docs/growth/brand/approved-voice.md`. Use a stable campaign slug (e.g. `<product>-<intent>-<market>`, like `aruannik-commercial-ee`).
  - **Meta/LinkedIn → inline.** Unchanged; still managed via Chrome, still budget-gated.
- Hard-dependency behavior: if the spawn fails because the `ads-strategist` agent type is unknown, **stop** and emit the install message — do **not** fall back to doing Google Ads inline.
- Boundaries: add **"NEVER design or create Google Ads campaigns directly — always delegate to ads-strategist. The strategist creates PAUSED; the investor enables."**
- Records: `ads.md` becomes an index/pointer. For Google Ads, record campaign slug + status + link to `docs/ads/<campaign>/` rather than full campaign detail. Non-Google channels still logged inline.
- Keep the human gate: "first paid ad campaign launch (budget approval)".

#### `commands/ads.md` (new, `user_invocable: true`)

Mirrors `/lawyer` / `/ux-test` structure:

- **Pre-flight (hard-fail, no fallback):**
  1. Startup project exists — `.startup/state.json` and `docs/business/brief.md`.
  2. Chrome MCP reachable — attempt `mcp__claude-in-chrome__tabs_context_mcp` (ads work needs the browser).
  3. `ads-strategist` available — behavioral: the spawn in the Execution step uses `subagent_type: "ads-strategist"`; if Claude Code reports the agent type is unknown, stop with the install instruction (`google-ads-strategist` plugin not installed).
- **Reset `active_role`** in `state.json` → `"ads-strategist"` before spawning, so the `enforce-delegation` hook (fires only when `active_role=="team-lead"`) doesn't block the strategist's writes. Same pattern as `/lawyer` Step 0.
- **Spawn** `ads-strategist` via `Task`, passing the investor's free-form brief (`$ARGUMENTS`) plus project context: `docs/business/brief.md`, `docs/growth/product-brief.md`, `docs/growth/strategy.md`, `docs/growth/brand/approved-voice.md` (whichever exist). Instruct it to create `docs/ads/<campaign>/brief.md` from this context if absent, then run its iteration loop and create PAUSED.
- **Report to investor (English):** which campaign folder was written, iteration/verification status, and what to review in the Ads UI before enabling. Note: the strategist creates PAUSED — the investor enables.

#### `README.md` (edit)

- Add `/saas-startup-team:ads` to the commands table.
- Prerequisites: add `google-ads-strategist` as **required** for any Google Ads work, noting the dependency is behavioral (no manifest field).
- Mention the `docs/ads/` ↔ `docs/growth/channels/ads.md` index relationship.

### google-ads-strategist

#### `agents/ads-strategist.md` (edit — programmatic invocation)

- Current behavior: "If `brief.md` does not exist, stop and instruct the user to run `/ads-brief` first."
- New behavior: **if invoked programmatically with brief fields supplied in the spawn prompt** (product, audience, budget, goals, brand, final-URL template), create `docs/ads/<campaign>/brief.md` from that context and proceed. The interactive `/ads-brief` path is unchanged; only the "refuse when missing" rule is relaxed for the programmatic case.

#### `README.md` (edit — "Relationship to other plugins")

- Update from "compose manually / growth-hacker handles the manual launch" to **auto-delegation**: `growth-hacker` auto-delegates and `/saas-startup-team:ads` exists; `ads-strategist` creates PAUSED and the investor enables; `growth-hacker` tracks campaigns via the `docs/growth/channels/ads.md` index.

## Versioning

Per repo rule, bump in **both** `.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json`:

- `saas-startup-team`: 0.37.0 → **0.38.0** (new `/ads` command + growth-hacker delegation behavior).
- `google-ads-strategist`: 0.4.1 → **0.5.0** (programmatic-invocation behavior change to `ads-strategist`).

## Testing

Add light, self-contained smoke checks to `plugins/saas-startup-team/tests/run-tests.sh`:

- `commands/ads.md` exists and declares `user_invocable: true`.
- `commands/ads.md` references `ads-strategist` and resets `active_role`.
- `agents/growth-hacker.md` contains the delegation rule and the "NEVER design or create Google Ads campaigns directly" boundary.
- `agents/growth-hacker.md` no longer instructs inline Google Ads campaign creation (negative assertion on the old "Create the Google Ads campaign in the dashboard" inline directive — scoped so the Meta/LinkedIn inline text doesn't false-positive).

No runtime/integration test of the live cross-plugin spawn (requires Agent Teams + Chrome + Google account); covered by manual verification.

## Out of scope

- Merging the two plugins (explicitly rejected — auto-delegation only).
- Meta/LinkedIn ad specialization (stays inline with growth-hacker).
- A manifest-level plugin dependency mechanism (Claude Code has none; enforced behaviorally).
- Auto-enabling campaigns (the PAUSED → investor-enables boundary is non-negotiable).
