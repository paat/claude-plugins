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
4. **Hybrid architecture, orchestrator-mediated.** Two entry points, one engine — both spawn at the team-lead/command level (never nested inside another agent):
   - **Automatic:** `growth-hacker` flags a Google Ads request in its growth report; the `/growth` loop reacts to the flag and spawns `ads-strategist`. The investor never has to type `/ads`.
   - **Investor-initiated:** a new `/saas-startup-team:ads` command (mirroring `/lawyer`, `/ux-test`) spawns the strategist directly.
   Both spawn `subagent_type: "ads-strategist"` (registered type) and converge on the same agent and the same `docs/ads/<campaign>/` records. (Revised from an earlier draft that had growth-hacker spawn the strategist via nested `Task` — see Review notes / F1.)

## Architecture & data flow

```
  Investor ──/ads──────────────────────────────┐
                                                │
  growth-hacker ─(growth report)──┐             │  flags "Google Ads campaign
    hits Google Ads work; FLAGS   │             │  needed: <context>" — does NOT spawn
    in its report, does not spawn │             │
                                  ▼             ▼
                        ┌──────────────────────────────┐
                        │  ORCHESTRATOR (team lead)      │  /ads command, OR the /growth
                        │  spawns the strategist at the  │  loop reacting to the flag
                        │  top level                     │  (same level as /ads-iterate,
                        └───────────────┬──────────────┘   /lawyer, /ux-test — never nested)
                                        │ Task(subagent_type:"ads-strategist")  ← registered type
                                        ▼
                        ┌──────────────────────────────┐
                        │  ads-strategist (google-ads)   │  designs → verifies →
                        │  writes docs/ads/<campaign>/    │  creates PAUSED in Ads UI
                        └───────────────┬──────────────┘
                                        │ returns campaign folder + status
                                        ▼
   docs/ads/<campaign>/            = source of truth (brief, iterations, learnings)
   docs/growth/channels/ads.md     = lightweight index → links each docs/ads/ folder
                                     (retains aggregate budget summary lines — see F3)
```

**Two entry points, one engine — both spawn at the orchestrator level, never nested:**

- **Investor-initiated:** `/saas-startup-team:ads <brief>` — the team lead spawns the strategist directly.
- **Automatic:** `growth-hacker`, on hitting Google Ads work, **flags** "Google Ads campaign needed: `<context>`" in its growth report and returns. The `/growth` loop already reads growth reports and dispatches in response (the existing "Growth→Build handoff" pattern); we extend it so an ads request triggers a top-level `ads-strategist` spawn, then the loop continues. The investor never has to type `/ads` — but the spawn happens one level up, in the orchestrator, **not** inside growth-hacker.

This avoids subagent→subagent nesting (unproven/unsupported in this codebase — every existing dispatch is orchestrated at the command/team-lead level) while keeping the behavior automatic. `growth-hacker` does **not** spawn the strategist and does not need the `Task` tool for ad work.

**Cross-plugin spawn uses the registered agent type.** Both entry points spawn `subagent_type: "ads-strategist"` — the agent type registered by the `google-ads-strategist` plugin. We do **not** use the saas idiom of `subagent_type:"general-purpose"` + "read `${CLAUDE_PLUGIN_ROOT}/agents/…md`": in a saas-startup-team command `${CLAUDE_PLUGIN_ROOT}` resolves to *saas*, so that path wouldn't exist, and the strategist's own `${CLAUDE_PLUGIN_ROOT}` skill/template references (it loads skills by `Read`ing `${CLAUDE_PLUGIN_ROOT}/skills/.../SKILL.md` — it has no `Skill` tool) only resolve when it runs natively under its own plugin root. Spawning by registered type gives it the correct plugin root. An "unknown agent type" error doubles as the hard-dependency check.

**Boundary preserved end-to-end:** `ads-strategist` creates campaigns **PAUSED**; the investor enables them in the Ads UI after review. `growth-hacker` never launches anything — it flags, and the orchestrator triggers design/creation, then reports. The existing human gate "first paid ad campaign launch (budget approval)" stays with the investor.

**Scope:** delegation covers **Google Ads only** — `ads-strategist` is Google-Ads-specific. Meta/LinkedIn ads stay inline with `growth-hacker` (still budget-gated).

**Pre-launch caveat:** Google Ads delegation assumes a live commercial landing page (`final_url`). Under `/growth --pre-launch` there may be none — the orchestrator should defer the ads request (or the strategist will flag the missing LP) rather than build a campaign that can't route traffic.

## Components

### saas-startup-team

#### `agents/growth-hacker.md` (edit)

- Rewrite "### 3. Ad Campaign Management" into two parts:
  - **Google Ads → flag, don't do.** growth-hacker does **not** design, create, or spawn anything for Google Ads. When Google Ads work arises, it writes a request into its growth report: a `## Google Ads request` block with product description, ICP, **approved budget cap**, brand name, final-URL template (sourced from `docs/growth/product-brief.md`, `docs/growth/strategy.md`, `docs/growth/brand/approved-voice.md`), and a stable campaign slug (`<product>-<intent>-<market>`, e.g. `aruannik-commercial-ee`). The orchestrator (`/growth` loop) reads this and spawns `ads-strategist` at the top level.
  - **Meta/LinkedIn → inline.** Unchanged; still managed via Chrome, still budget-gated.
- growth-hacker no longer needs `Task` for ad work; it never spawns the strategist (no subagent→subagent nesting).
- Boundaries: add **"NEVER design, create, or spawn Google Ads campaigns yourself — flag the request in your growth report and let the orchestrator delegate to ads-strategist. The strategist creates PAUSED; the investor enables."**
- Records: `ads.md` becomes an index/pointer. For Google Ads, record campaign slug + status + link to `docs/ads/<campaign>/` rather than full campaign detail. **Retain the `Approved budget:` and `Total spend:` summary lines** (aggregate across Google campaigns) — `check-ad-budget.sh` greps `ads.md` for them and silently no-ops if absent (F3). Non-Google channels still logged inline. The `ads.md` index is also where the active campaign slug lives, so the `/ads` path and the loop converge on one campaign instead of forking (F7).
- Keep the human gate: "first paid ad campaign launch (budget approval)".

#### `commands/ads.md` (new, `user_invocable: true`)

Mirrors `/lawyer` / `/ux-test` structure:

- **Pre-flight (hard-fail, no fallback):**
  1. Startup project exists — `.startup/state.json` and `docs/business/brief.md`.
  2. Chrome MCP reachable — attempt `mcp__claude-in-chrome__tabs_context_mcp` (ads work needs the browser).
  3. `ads-strategist` available — behavioral: the spawn in the Execution step uses `subagent_type: "ads-strategist"`; if Claude Code reports the agent type is unknown, stop with the install instruction (`google-ads-strategist` plugin not installed).
- **Reset `active_role`** in `state.json` → `"ads-strategist"` before spawning. The primary bypass for `enforce-delegation`/`check-stop` is actually the `--agent-id` process-tree check that Task-spawned agents carry (so the strategist's own writes are allowed regardless of `active_role`); the reset is defensive — it matches `/lawyer` Step 0 and clears any stale `"team-lead"` value that could block an Edit in an edge case where the tree walk misses (F4).
- **Spawn** `ads-strategist` via `Task` using `subagent_type: "ads-strategist"` (the registered type — see "Cross-plugin spawn" above; **not** general-purpose+read-md). Pass the investor's free-form brief (`$ARGUMENTS`) plus project context: `docs/business/brief.md`, `docs/growth/product-brief.md`, `docs/growth/strategy.md`, `docs/growth/brand/approved-voice.md` (whichever exist), and the campaign slug from the `ads.md` index if one is already active. Instruct it to create `docs/ads/<campaign>/brief.md` from this context if absent, then run its iteration loop and create PAUSED.
- **Report to investor (English):** which campaign folder was written, iteration/verification status, and what to review in the Ads UI before enabling. Note: the strategist creates PAUSED — the investor enables.

#### `commands/growth.md` (edit — orchestrator auto-delegation)

- In "Step 4 → Growth-to-Build handoff" (where the loop already reacts to growth-report flags), add a branch: if a growth report contains a `## Google Ads request` block, the team lead spawns `ads-strategist` (`subagent_type: "ads-strategist"`, same context-passing and `active_role` reset as `/ads`), then continues the loop. This is the "automatic" path — no investor `/ads` needed.

#### `README.md` (edit)

- Add `/saas-startup-team:ads` to the commands table.
- Prerequisites: add `google-ads-strategist` as **required** for any Google Ads work, noting the dependency is behavioral (no manifest field).
- Mention the `docs/ads/` ↔ `docs/growth/channels/ads.md` index relationship.

### google-ads-strategist

#### `agents/ads-strategist.md` (edit — programmatic invocation)

- Current behavior: "If `brief.md` does not exist, stop and instruct the user to run `/ads-brief` first."
- New behavior: **if invoked programmatically with brief fields supplied in the spawn prompt** (product, audience, budget, goals, brand, final-URL template), create `docs/ads/<campaign>/brief.md` from that context and proceed. The interactive `/ads-brief` path is unchanged; only the "refuse when missing" rule is relaxed for the programmatic case.

#### `README.md` (edit — "Relationship to other plugins")

- Update from "compose manually / growth-hacker handles the manual launch" to **orchestrator-mediated auto-delegation**: `growth-hacker` flags Google Ads requests in its growth report and the `/growth` loop spawns `ads-strategist`; the investor can also trigger it directly with `/saas-startup-team:ads`. `ads-strategist` creates PAUSED and the investor enables; `growth-hacker` tracks campaigns via the `docs/growth/channels/ads.md` index.

## Versioning

Per repo rule, bump in **both** `.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json`:

- `saas-startup-team`: 0.37.0 → **0.38.0** (new `/ads` command + growth-hacker delegation behavior).
- `google-ads-strategist`: 0.4.1 → **0.5.0** (programmatic-invocation behavior change to `ads-strategist`).

## Testing

Add light, self-contained smoke checks to `plugins/saas-startup-team/tests/run-tests.sh`:

- `commands/ads.md` exists, declares `user_invocable: true`, spawns `subagent_type: "ads-strategist"` (registered type, not general-purpose), and resets `active_role`.
- `commands/growth.md` contains the `## Google Ads request` branch that spawns `ads-strategist`.
- `agents/growth-hacker.md` contains the "flag, don't spawn" rule and the "NEVER design, create, or spawn Google Ads campaigns yourself" boundary.
- `agents/growth-hacker.md` no longer instructs inline Google Ads campaign creation (negative assertion on the old "Create the Google Ads campaign in the dashboard" inline directive — scoped so the Meta/LinkedIn inline text doesn't false-positive).
- Guard against regressing F2: assert neither `commands/ads.md` nor the growth-ads branch uses `read ${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md` (that path resolves to saas and would 404).

No runtime/integration test of the live cross-plugin spawn (requires Agent Teams + Chrome + Google account); covered by manual verification.

## Notes & known limitations

This spec was revised after a design review against the actual hook scripts and spawn mechanics. Findings folded in: F1 (no nested spawn — orchestrator-mediated), F2 (spawn by registered type), F3 (`ads.md` retains budget lines), F4 (`active_role` rationale), F6 (pre-launch LP caveat), F7 (slug convergence via the index). Remaining notes:

- **F5 (pre-existing, out of scope):** `ads-strategist` has no `Skill` tool — it loads its skills by `Read`ing `${CLAUDE_PLUGIN_ROOT}/skills/.../SKILL.md`, which only resolves when it runs natively under its own plugin root. This is unchanged by our work and is another reason to spawn by registered type (F2). Not fixed here.
- **F9:** `docs/ads/<campaign>/` writes are not auto-committed by either plugin (saas `auto-commit-growth.sh` is scoped to `docs/growth/`). The `ads.md` index update *will* auto-commit; the campaign folder itself is left in the working tree for the investor to review/commit. Acceptable — no change planned.
- **F8 (positive):** every other saas `Write` hook (`enforce-handoff-naming`, `enforce-tone`, `check-handoff-secrets`, `validate-growth-brief`, `compact-state`, `index-handoff`, etc.) is path-scoped with early-exit, so `docs/ads/` writes pass cleanly. The google-ads `Write` hooks are likewise scoped to `docs/ads/` iteration files. No cross-plugin hook collision.

## Out of scope

- Merging the two plugins (explicitly rejected — auto-delegation only).
- Meta/LinkedIn ad specialization (stays inline with growth-hacker).
- A manifest-level plugin dependency mechanism (Claude Code has none; enforced behaviorally).
- Auto-enabling campaigns (the PAUSED → investor-enables boundary is non-negotiable).
