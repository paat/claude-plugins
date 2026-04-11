---
name: ads-verify
description: Quick one-shot verification of a single keyword or the current iteration via the Anonymous Ad Preview Tool. Captures screenshot + structured result. Usage: /ads-verify [campaign] [keyword] [--location X] [--device mobile|desktop]
user_invocable: true
allowed-tools: Read, Write, Bash, Glob, mcp__claude-in-chrome__tabs_context_mcp, mcp__claude-in-chrome__tabs_create_mcp, mcp__claude-in-chrome__navigate, mcp__claude-in-chrome__read_page, mcp__claude-in-chrome__get_page_text, mcp__claude-in-chrome__form_input, mcp__claude-in-chrome__find, mcp__claude-in-chrome__javascript_tool, mcp__claude-in-chrome__computer
argument-hint: [campaign] [keyword] [--location X] [--device mobile|desktop]
---

# /ads-verify — Run Ad Preview Tool verification

You are running a one-shot verification against the Anonymous Ad Preview Tool. No ads.google.com login required. No impressions counted.

## Step 0: Load the skill

```
Skill('google-ads-strategist:browser-verification')
```

## Step 1: Parse arguments

- If `[keyword]` is provided, verify that single keyword
- If `[keyword]` is omitted but `[campaign]` is provided, verify every keyword in `docs/ads/<campaign>/current/spec.md`
- If both are omitted, ask the user which campaign

Parse `--location` (default: pull from brief.md), `--device` (default: both mobile and desktop).

## Step 2: Check Chrome state

```
mcp__claude-in-chrome__tabs_context_mcp
```

## Step 3: Run the verification loop

For each keyword:

1. Open new tab to `https://ads.google.com/anon/AdPreview`
2. Enter the keyword, set location, set language, set device
3. Click Preview
4. Wait for SERP to render
5. `get_page_text` → extract:
   - Is the target advertiser's ad visible?
   - Position in the ad stack
   - Headlines shown
   - Description shown
   - Extensions shown
   - Competing ads above the fold
6. Screenshot to `docs/ads/<campaign>/current/verification/preview-<keyword>-<location>-<device>.png`
7. Append a row to `verification/preview-log.md`

## Step 4: Cross-check with real SERP (incognito)

For each keyword also:

1. Open incognito tab
2. Navigate to `https://www.google.com/search?q=<keyword>&hl=<lang>&gl=<country>`
3. Screenshot SERP → `verification/serp-<keyword>.png`
4. Extract the commercial signals (paid ads count, shopping widgets, People Also Ask presence) to `verification/serp-<keyword>.md`

## Step 5: Report

```markdown
## Verification report — campaign <campaign>, keyword(s) [...]

| Keyword | Location | Device | Ad shows? | Position | Commercial SERP? |
|---------|----------|--------|-----------|----------|------------------|
| ... | ... | ... | YES | 2 | YES (3 paid ads) |
| ... | ... | ... | NO | — | YES (weak) |

Artifacts saved to docs/ads/<campaign>/current/verification/

**Issues found**:
- [keyword X] — ad not triggering → likely [diagnosis]
- [keyword Y] — position 6 → likely bid or QS
- [keyword Z] — SERP shows People Also Ask dominant → INFORMATIONAL intent, drop from campaign
```

## Step 6: Stop

Do NOT propose fixes in this command — this is a verification read only. To propose fixes, run `/ads-iterate`.
