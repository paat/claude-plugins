# Browser Verification — Tool Navigation Sequences & Failure Recovery

Detailed Chrome MCP step sequences and failure recovery for the five tools in `browser-verification`.

## Tool 1: Anonymous Ad Preview Tool (`https://ads.google.com/anon/AdPreview`)

```
1. mcp__claude-in-chrome__tabs_create_mcp → new tab at https://ads.google.com/anon/AdPreview
2. mcp__claude-in-chrome__read_page → confirm the tool loaded
3. mcp__claude-in-chrome__form_input → enter keyword in search box
4. Adjust location targeting: click "Location" dropdown → type target city/country → select from autocomplete
5. Adjust language if multilingual; adjust device (desktop / mobile / tablet)
6. Click "Preview" button; wait for SERP preview to render (confirm via read_page)
7. mcp__claude-in-chrome__computer screenshot → save to iterations/vN/verification/preview-<keyword>-<location>-<device>.png
8. Extract via get_page_text: target ad visible (Yes/No), position (1, 2, 3...), headlines, description, extensions (sitelinks, callouts, price, structured snippets), and competing ads + order
```

### `verification/preview-log.md` Table Format

```markdown
| Keyword | Location | Device | Lang | Ad visible? | Position | Screenshot |
|---------|----------|--------|------|-------------|----------|------------|
| [keyword] | Tallinn | mobile | et | YES | 2 | preview-....png |
| [keyword] | Tallinn | desktop | et | NO | — | preview-....png |
```

## Tool 2: Authenticated Ad Preview & Diagnosis (`https://ads.google.com/aw/tools/adpreview`)

```
1. Navigate to https://ads.google.com/aw and read_page for the account switcher
2. If not logged in, DO NOT attempt auto-login — ask the user to log in manually
3. Pick the right account → Tools (wrench) → Troubleshooting → Ad Preview and Diagnosis (or direct URL)
4. Enter keyword, location, language, device
5. Capture screenshot + exact diagnosis string into iterations/vN/result.md
```

Common authenticated diagnoses:
- "Your keyword isn't eligible to show for this search" — match type issue
- "Your ad is limited by your daily budget" — budget exhausted
- "Your ad isn't showing for searches in this location" — targeting mismatch
- "Your ad Quality Score is too low" — copy / LP / relevance problem

## Tool 3: Real Google SERP Capture (`https://www.google.com/search?q=<keyword>&hl=<lang>&gl=<country>`)

```
1. Open an incognito tab via tabs_create_mcp (pass incognito: true if supported; else note personalization caveat)
2. Navigate to https://www.google.com/search?q=<keyword>&hl=<lang>&gl=<country> (set gl=ee, gl=us, etc.)
3. read_page → capture SERP structure; screenshot → iterations/vN/verification/serp-<keyword>.png
4. Extract: paid ads above fold (count + positions), paid ads at bottom, shopping carousel present?, People Also Ask box present + position, organic top 3 (commercial vs informational), local pack?
```

## Tool 4: Google Ads Transparency Center (`https://adstransparency.google.com/`)

```
1. Navigate to https://adstransparency.google.com/ and search by competitor name or domain
2. Filter by Country (target market), Ad format (Text), and recent Date range
3. Capture per ad: headline(s), description, display URL, format, date last seen
4. Screenshot + save structured data to iterations/vN/verification/transparency-<competitor>.md
```

Extract: competitor headline patterns, CTA verbs (buy/start/try/learn), differentiation claims (price/speed/quality/proof), and copy-variant frequency.

## Tool 5: Google Ads UI Metric Pulls (`https://ads.google.com/aw`, post-launch only)

```
1. Navigate to logged-in Ads account → Campaigns → [target campaign]
2. Set date range (last 7 days default for iteration checks)
3. Read: Impressions, Clicks, CTR, Avg CPC, Cost, Conversions, CPA, Conv Rate
4. Diagnostic drill-downs: Search Terms report (negative mining), Keywords tab → QS column, Auction Insights
5. Capture screenshots of every number reported — never retype from memory or earlier captures
```

## Common Failures

- **"read_page returns empty"**: page still loading — wait and retry once, then check `read_console_messages`.
- **"form_input not finding the field"**: use `find` with a more specific selector, or set value via `javascript_tool`.
- **"Google is showing a consent dialog"**: accept or dismiss via `javascript_tool`; never use Chrome modal dialogs.
- **"Ad Preview Tool is stuck loading"**: open a fresh incognito tab to clear session state.
- **"Results don't match what a human sees"**: check location + language + device settings, then verify with `/ads-serp` in incognito.

If the same Chrome operation fails 2–3 times in a row, stop and ask the user for guidance. Do not loop on broken browser state.
