---
name: browser-verification
description: "Use for Google Ads browser verification, Ad Preview tools, incognito SERP captures, screenshots, and UI metric pulls."
---

# Browser Verification Playbook

All verification happens in the real browser. Never fabricate results. Every claim must be backed by an artifact in `iterations/vN/verification/`. Be token-frugal: run only the tools required by the current step, and load `references/tool-sequences.md` when you need step-by-step Chrome MCP navigation or error recovery.

## Before Every Session

1. Check tab state with `mcp__claude-in-chrome__tabs_context_mcp`. Note any existing Google Ads tab, but prefer opening new tabs with `tabs_create_mcp` unless the user asks to reuse one.
2. Never trigger browser modal dialogs (`alert`, `confirm`, `prompt`) — they block subsequent events. Dismiss unexpected prompts via `javascript_tool`.
3. If the same Chrome operation fails 2–3 times in a row, stop and ask the user; do not loop on broken browser state (`references/tool-sequences.md`).

## Tool 1: Anonymous Ad Preview Tool (SECONDARY — see warning)

- **URL**: `https://ads.google.com/anon/AdPreview` (public, no login, no impressions counted).
- **KNOWN ISSUE — Unreliable for small markets (e.g., Estonia)**: On Estonian commercial keywords, the anonymous tool consistently showed 0 paid ads while authenticated google.com SERPs showed 3–4 paid ads ("thin auction" view without context). For small markets, use **Tool 3** as the PRIMARY competitive baseline; use Tool 1 only as a floor/best-case reference or post-launch own-ad trigger check.
- Save screenshots to `iterations/vN/verification/preview-<keyword>-<location>-<device>.png` and log every run in `verification/preview-log.md` (`references/tool-sequences.md`).
- **Diagnosis cues**: Ad absent → match type, bid, quality signal, or excluded keyword. Position 4+ → low bid, low ad rank, or competition. Weak copy vs competitors → feed `clickable-copy`.

## Tool 2: Authenticated Ad Preview & Diagnosis Tool

- **URL**: `https://ads.google.com/aw/tools/adpreview` (requires Google Ads login; no impressions counted).
- If not logged in, **DO NOT attempt auto-login** — ask the user to log in manually.
- Use when testing an active/draft campaign in-account: explains **why** an ad didn't appear (match type, daily budget, location targeting, Quality Score). Record the exact diagnosis string in `result.md`.

## Tool 3: Real Google SERP Capture (Competitive & Intent Baseline)

- **URL**: `https://www.google.com/search?q=<keyword>&hl=<lang>&gl=<country>` (prefer incognito via `tabs_create_mcp`; always pass `gl=<country>`).
- Capture to `iterations/vN/verification/serp-<keyword>.png` (or structured `.md`) with paid ads above/below fold, shopping carousel, People Also Ask, organic top 3, and local pack.
- Classify intent with `buyer-intent-targeting` ("Verification in the SERP") — single source for thresholds.
- **NEVER click on competitor ads** in a real SERP — read-only inspection via `get_page_text` only.

## Tool 4: Google Ads Transparency Center

- **URL**: `https://adstransparency.google.com/` (public archive of running Google ads; filter by target country, Text format, recent dates).
- Save screenshot + structured headlines, descriptions, display URL, format, last-seen date, CTA verbs, and differentiation angles to `iterations/vN/verification/transparency-<competitor>.md`.

## Tool 5: Google Ads UI Metric Pulls (Post-Launch Only)

- **URL**: `https://ads.google.com/aw` → Campaigns → `[target campaign]` (last 7 days default).
- Read Impressions, Clicks, CTR, Avg CPC, Cost, Conversions, CPA, Conv Rate; drill into Search Terms, Keywords (QS), and Auction Insights.
- Capture screenshots of every reported number — never retype numbers from memory or earlier captures.

## Artifact Discipline

No artifact = no claim. File names must encode keyword, location, and device so later iterations can diff:

```
iterations/v{N}/verification/
├── preview-<keyword>-<location>-<device>.png
├── preview-log.md
├── serp-<keyword>.png | serp-<keyword>.md
├── transparency-<competitor>.md
└── metrics-YYYY-MM-DD.png | metrics-YYYY-MM-DD.md   # post-launch only
```

**SERP evidence formats**: Both `.png` screenshots and `.md` structured extractions are valid SERP evidence. A structured `.md` extraction must include paid ad count, organic top 3, People Also Ask presence, shopping carousel presence, and intent classification conclusion. Use `.md` as standard fallback when screenshots fail — never skip SERP verification.

## Related Skills

- `buyer-intent-targeting` — SERP intent classification thresholds
- `competitor-intel` — Transparency Center differentiation workflow
- `iterative-campaign-design` / `iterative-optimization` — pre-launch and post-launch callers
