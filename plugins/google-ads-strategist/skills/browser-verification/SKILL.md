---
name: browser-verification
description: Use when verifying a Google Ads iteration in Chrome — provides the exact navigation sequences, selectors, and screenshot-capture playbook for the Anonymous Ad Preview Tool, the authenticated Ad Preview & Diagnosis Tool, real Google SERP capture in incognito, and metric pulls from the Google Ads UI. Load before running /ads-verify, /ads-serp, or /ads-metrics.
---

# Browser Verification Playbook

All verification happens in the real browser. Never fabricate results. Every claim must be backed by an artifact in `iterations/vN/verification/`.

## Before Every Session

Always start by checking Chrome tab state:

```
mcp__claude-in-chrome__tabs_context_mcp
```

This returns the current tab set. If the user has an existing Google Ads tab open, note it but prefer opening new tabs with `tabs_create_mcp` unless the user explicitly asks to reuse.

Never trigger browser modal dialogs (alert, confirm, prompt) — they block all subsequent events. If a page prompts unexpectedly, dismiss via `javascript_tool` before proceeding.

## Tool 1: Anonymous Ad Preview Tool (SECONDARY — see warning below)

**URL**: `https://ads.google.com/anon/AdPreview`

Public, no login required, no impressions counted, no account needed. Works for any keyword, any location, any device.

### KNOWN ISSUE: Unreliable for small markets (e.g., Estonia)

During real-world testing on Estonian commercial keywords, the Anonymous Ad Preview Tool **consistently showed 0 paid ads** on every query tested (all devices, all locations), while authenticated google.com SERPs showed 3-4 paid ads on the same queries. The anonymous tool produces a "thin auction" view without personalization or advertiser context.

**For small markets**: use **authenticated Google Search** (Tool 3 below) as the PRIMARY competitive baseline. Use this anonymous tool only as a floor/best-case reference, or to verify your OWN ad triggers post-launch (where it removes personalization bias).

### Navigation sequence

```
1. mcp__claude-in-chrome__tabs_create_mcp → new tab at https://ads.google.com/anon/AdPreview
2. mcp__claude-in-chrome__read_page → confirm the tool loaded
3. mcp__claude-in-chrome__form_input → enter keyword in search box
4. Adjust location targeting:
   - Click "Location" dropdown
   - Type target city/country
   - Select from autocomplete
5. Adjust language if multilingual
6. Adjust device (desktop / mobile / tablet)
7. Click "Preview" button
8. Wait for SERP preview to render (check via read_page for result markers)
9. mcp__claude-in-chrome__computer screenshot → save to iterations/vN/verification/preview-<keyword>-<location>-<device>.png
10. Extract structured data from the preview via get_page_text:
    - Is the target site's ad visible? Yes/No
    - Position in the ad block (1, 2, 3, ...)
    - Headlines shown
    - Description shown
    - Extensions shown (sitelinks, callouts, price, structured snippets)
    - Competing ads visible and their order
```

### Record every run in `verification/preview-log.md`

```markdown
| Keyword | Location | Device | Lang | Ad visible? | Position | Screenshot |
|---------|----------|--------|------|-------------|----------|------------|
| [keyword] | Tallinn | mobile | et | YES | 2 | preview-....png |
| [keyword] | Tallinn | desktop | et | NO | — | preview-....png |
```

### What to look for

- **Ad does not appear**: log NO, note position "—", record the keyword in the diagnosis. Candidate causes: match type too narrow, bid too low, quality signal too low, keyword excluded from plan. The diagnosis path depends on other signals.
- **Ad appears at position 4+**: note the position. Candidate causes: bid too low, ad rank dragged down by quality, competitive pressure.
- **Ad appears but copy looks weak vs competitors**: the preview shows competing ads — compare side by side. This feeds the `clickable-copy` diagnosis.

## Tool 2: Authenticated Ad Preview & Diagnosis Tool

**URL**: `https://ads.google.com/aw/tools/adpreview` (requires login to a Google Ads account)

Use when the advertiser has an active or draft campaign in their account and wants to test against it specifically (not just "what would Google show anyone"). Also does not count impressions.

### Navigation sequence

```
1. Check if already logged in: navigate to https://ads.google.com/aw and read_page for the account switcher
2. If not logged in, DO NOT attempt auto-login — ask the user to log in manually
3. Once logged in:
   - Click account selector → pick the right account
   - Navigate to Tools (wrench icon) → Troubleshooting → Ad Preview and Diagnosis
   - Or direct URL: https://ads.google.com/aw/tools/adpreview
4. Enter keyword, location, language, device (same as anonymous tool)
5. The result shows the advertiser's specific ads AND an explanation of why they did/didn't appear
6. Capture screenshot + extract the diagnosis text
```

### What's different from the anonymous tool

The authenticated tool explains **why** an ad didn't appear. Common diagnoses:
- "Your keyword isn't eligible to show for this search" — match type issue
- "Your ad is limited by your daily budget" — budget exhausted
- "Your ad isn't showing for searches in this location" — targeting mismatch
- "Your ad Quality Score is too low" — copy / LP / relevance problem

Record the exact diagnosis string in the iteration's `result.md`.

## Tool 3: Real Google SERP capture (for competitive analysis)

**URL**: `https://www.google.com/search?q=<keyword>&hl=<lang>&gl=<country>`

Use for: competitor ad copy analysis, SERP layout intent classification, "is this keyword actually commercial" verification.

### Navigation sequence (use incognito to avoid personalization)

```
1. Open an incognito tab via tabs_create_mcp (pass incognito: true in context if supported)
2. If incognito is not supported, note that personalization may affect results
3. Navigate to https://www.google.com/search?q=<keyword>&hl=<lang>&gl=<country>
4. Set the country code explicitly (gl=ee for Estonia, gl=us for US, etc.) to force the right SERP
5. read_page → capture the full SERP structure
6. Screenshot → save to iterations/vN/verification/serp-<keyword>.png
7. Extract:
   - Paid ads above fold (count + positions)
   - Paid ads at bottom of page
   - Shopping carousel present? (strong commercial signal)
   - "People Also Ask" box present and where? (informational signal if at top)
   - Organic top 3: commercial (pricing, signup, product) vs informational (blog, guide, wikipedia)
   - Local pack? (local-intent signal)
```

### SERP intent classification cheat sheet

- **≥ 3 paid ads + shopping carousel + commercial organic**: strong commercial/transactional — proceed
- **1-2 paid ads + mixed organic**: commercial investigation — proceed with emphasis on differentiation
- **0 paid ads + "People Also Ask" at top + listicles**: informational — DROP THE KEYWORD
- **Only brand result + knowledge panel**: navigational — branded campaign only

**NEVER** click on competitor ads in the real SERP — that costs them money, wastes your own visit budget (Google flags repeated clicks from the same IP as suspicious), and is unethical. Read-only inspection via `get_page_text`.

## Tool 4: Google Ads Transparency Center

**URL**: `https://adstransparency.google.com/`

Public archive of all currently-running Google ads. Use for competitor ad copy research without touching the real SERP.

### Navigation sequence

```
1. Navigate to https://adstransparency.google.com/
2. Search by competitor advertiser name or domain
3. Filter by:
   - Country (match your target market)
   - Ad format (Text for search ads)
   - Date range (recent is most relevant)
4. For each ad, capture:
   - Headline(s)
   - Description
   - Display URL
   - Format
   - Date last seen
5. Screenshot + save structured data to iterations/vN/verification/transparency-<competitor>.md
```

### What to extract

- Competitor headline patterns (what angles are they using?)
- Competitor CTA verbs (buy / start / try / learn / etc.)
- Competitor differentiation claims (price, speed, quality, proof)
- Frequency: which copy variants are they running most? (proxy for what's working for them)

## Tool 5: Google Ads UI for metric pulls (post-launch only)

**URL**: `https://ads.google.com/aw` → campaign view

Use when no API access and real metrics need to come from the UI.

### Navigation sequence

```
1. Navigate to the logged-in Ads account
2. Go to Campaigns → [target campaign]
3. Adjust date range (last 7 days default for iteration checks)
4. Read the columns: Impressions, Clicks, CTR, Avg CPC, Cost, Conversions, CPA, Conv Rate
5. For diagnostic drill-down:
   - Search Terms report (for negative keyword mining)
   - Keywords tab → QS column (Quality Score per keyword)
   - Auction Insights (competitive pressure)
6. Capture screenshots of every number you report — never retype numbers from memory or from earlier captures
```

## Artifact Discipline

Every Chrome session produces artifacts. The artifacts are the evidence. No artifact = no claim.

```
iterations/v{N}/verification/
├── preview-<keyword>-<location>-<device>.png
├── preview-log.md
├── serp-<keyword>.png
├── serp-<keyword>.md         # structured extraction
├── transparency-<competitor>.md
├── metrics-YYYY-MM-DD.png    # post-launch only
└── metrics-YYYY-MM-DD.md     # structured numbers
```

File names must encode the relevant variables (keyword, location, device) so future iterations can diff against them.

## Common Failures

- **"read_page returns empty"**: the page is still loading — wait and retry once, then check via `read_console_messages` for errors
- **"form_input not finding the field"**: use `find` with a more specific selector, or use `javascript_tool` to set the value directly
- **"Google is showing a consent dialog"**: accept or dismiss via `javascript_tool`, DO NOT use Chrome modal dialogs
- **"Ad Preview Tool is stuck loading"**: try opening in a fresh incognito tab — sometimes Google's session state interferes
- **"Results don't match what a human sees"**: check location + language + device settings, then verify with `/ads-serp` in incognito

If the same Chrome operation fails 2-3 times in a row, stop and ask the user for guidance. Do not loop on broken browser state.

## Related Skills

- `buyer-intent-targeting` — uses SERP capture to classify intent
- `competitor-intel` — deeper workflow for Transparency Center
- `iterative-campaign-design` — calls this skill for every pre-launch iteration
- `iterative-optimization` — calls this skill for metric pulls and search-term mining
