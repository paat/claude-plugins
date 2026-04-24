---
name: ads-serp
description: Capture a real Google SERP (in incognito) for a keyword to classify its buyer intent and see competing ads. Writes screenshot + structured intent analysis. Usage: /ads-serp <keyword> [--country X] [--lang Y]
user_invocable: true
allowed-tools: Read, Write, Bash, mcp__claude-in-chrome__tabs_context_mcp, mcp__claude-in-chrome__tabs_create_mcp, mcp__claude-in-chrome__navigate, mcp__claude-in-chrome__read_page, mcp__claude-in-chrome__get_page_text, mcp__claude-in-chrome__computer, mcp__claude-in-chrome__javascript_tool
argument-hint: <keyword> [--country X] [--lang Y]
---

# /ads-serp — Capture and classify a Google SERP

Quick intent-classification of a single keyword via real SERP capture.

## Step 0: Load the skills

```
Skill('google-ads-strategist:buyer-intent-targeting')
Skill('google-ads-strategist:browser-verification')
```

## Step 1: Parse arguments

- `<keyword>` is required
- `--country` defaults to `ee` if not specified
- `--lang` defaults to `et` if not specified
- If a campaign context is active (docs/ads/* exists), default country+lang to the first entry in brief.md

## Step 2: Capture the SERP

1. `mcp__claude-in-chrome__tabs_context_mcp` → check state
2. Open incognito tab (or note that personalization may affect results if incognito is unavailable)
3. Navigate to `https://www.google.com/search?q=<URL-encoded keyword>&hl=<lang>&gl=<country>`
4. If a consent dialog appears, dismiss it via `javascript_tool`
5. `read_page` to confirm load
6. Screenshot full page → save to `docs/ads/_scratch/serp-<keyword>-<country>-<YYYY-MM-DD>.png` (or to campaign verification folder if a campaign is active)
7. `get_page_text` → extract:
   - Paid ad slots above the fold (count + advertiser names + headlines)
   - Paid ad slots below organic results
   - Shopping carousel present?
   - "People Also Ask" box present and where?
   - Organic top 3 (domain + title + is-it-commercial?)
   - Local pack present?
   - Knowledge panel present?

## Step 3: Classify the intent

Apply the `buyer-intent-targeting` cheat sheet:

- **≥ 3 paid ads + shopping carousel + commercial organic** → TRANSACTIONAL
- **1-2 paid ads + mixed organic** → COMMERCIAL INVESTIGATION
- **0 paid ads + People Also Ask at top + listicles dominant** → INFORMATIONAL — do not target
- **Brand-only results + knowledge panel** → NAVIGATIONAL (to that brand)

## Step 4: Write the analysis

Write a markdown file next to the screenshot:

```markdown
# SERP analysis — "<keyword>"

**Date**: YYYY-MM-DD
**Country**: <country>
**Language**: <lang>
**Intent class**: [INFORMATIONAL | NAVIGATIONAL | COMMERCIAL | TRANSACTIONAL]
**Should we bid?**: [YES | NO | BRANDED-ONLY]

## Paid ads above fold
1. [advertiser] — "[headline]" — [display URL]
2. ...

## Commercial signals
- [x] paid ads above fold: N
- [x] shopping carousel: yes/no
- [x] local pack: yes/no
- [x] People Also Ask dominant: yes/no

## Organic top 3
1. [domain] — "[title]" — [commercial | informational]
2. ...

## Verdict
[Sentence explaining why this keyword does or does not belong in a PPC campaign]

## Competitor copy matrix (if commercial)
| Advertiser | Headline angle | Price? | Proof? | CTA | Extensions |
|---|---|---|---|---|---|
| ... | ... | ... | ... | ... | ... |
```

## Step 5: Report to user

```markdown
**SERP analysis: "<keyword>"**

- Intent: [class]
- Bid?: [YES / NO / BRANDED-ONLY]
- [One-sentence rationale]

Screenshot: [path]
Analysis: [path]
```

If the verdict is INFORMATIONAL, explicitly recommend adding the query modifier(s) to the negative keyword list.
