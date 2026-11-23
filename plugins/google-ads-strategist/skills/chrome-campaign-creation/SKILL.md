---
name: chrome-campaign-creation
description: "Use to create paused Google Ads campaigns in Chrome: settings, ad groups, keywords, RSAs, extensions, and negatives."
---

# Chrome Campaign Creation

Create a Google Ads Search campaign from `spec.md` via Chrome automation in **PAUSED** state so the investor can review and enable it. Load `references/creation-log-and-pitfalls.md` when writing `creation-log.md` or troubleshooting form pitfalls.

## Before You Start

1. Check Chrome state with `mcp__claude-in-chrome__tabs_context_mcp`.
2. Navigate to `https://ads.google.com/aw` and verify the account selector. If not logged in, **STOP** and ask the user to log in manually.
3. Read `spec.md` (campaign settings, ad groups, keywords, RSAs, extensions, negatives) and `brief.md` (brand context, budget confirmation) once; do not re-read unchanged sections.

## Diacritics Rule

If `spec.md` uses ASCII for portability, **always enter proper Estonian Unicode diacritics** (`ä, ö, ü, õ, š, ž` and uppercase) for all ad copy headlines/descriptions — never in URL path slugs (`references/creation-log-and-pitfalls.md`).

## Step-by-Step Creation

### Phase 1: Campaign Shell

1. Open `https://ads.google.com/aw/campaigns/new` → pick **"Create a campaign without a goal's guidance"** (or "Website traffic" if unavailable) → select **Search**.
2. Configure per `spec.md`:
   - **Campaign name**: from `spec.md`
   - **Networks**: UNCHECK Search partners and Display Network
   - **Locations**: add each target location; under Location options choose **"Presence: People in your targeted locations"**; add all location exclusions
   - **Languages**: add all target languages
   - **Budget & Bidding**: daily budget from `spec.md`; **Manual CPC** with **Enhanced CPC UNCHECKED**
   - **More settings**: start/end dates per spec; ad rotation **"Optimize: Prefer best performing ads"**; ad schedule **"All day"**
3. **CRITICAL — Set Status to PAUSED**: Before saving, set campaign status to **"Paused"**. If no status control is shown during creation, **IMMEDIATELY** pause the campaign from the campaigns list after saving before adding ad groups.
4. Screenshot → `creation-step-01-campaign-settings`.

### Phase 2: Ad Groups + Keywords + RSAs (repeat per ad group)

For each ad group in `spec.md`:
1. Create ad group with exact name and per-ad-group default max CPC.
2. **Keywords** (use "Enter keywords", not suggestions): `[exact]`, `"phrase"`, or `broad` per table; verify match types were not stripped after entry.
3. **RSA**:
   - **Final URL**: from `spec.md` with full UTM parameters (ASCII slugs; drop `{gclid}` only if Google rejects it).
   - **Display path**: 2 segments, max 15 chars each, no spaces.
   - **Headlines / Descriptions**: enter all 15 headlines (≤ 30 chars) and 4 descriptions (≤ 90 chars) with proper diacritics and pins per the Pin column; save.
4. Screenshot → `creation-step-NN-ag-<slug>`.

### Phase 3: Campaign-Level Negatives

1. Open Keywords → Negative keywords; bulk-paste all campaign negatives from `negatives.md` in `"phrase"` match format.
2. Screenshot → `creation-step-NN-negatives`.

### Phase 4: Campaign-Level Extensions

1. Open Ads & extensions → Extensions.
2. Add all **Sitelinks** (title, UTM Final URL, optional description lines), **Callouts**, and **Structured snippets** from `spec.md`.
3. Screenshot → `creation-step-NN-extensions`.

### Phase 5: Device Bid Adjustments

1. Open Campaign settings → Devices; apply adjustments from `spec.md` (e.g., Tablet -50%) and screenshot if changed.

### Phase 6: Final Verification

1. Open campaign overview and confirm: **status is PAUSED** (most important), ad group count matches `spec.md`, keyword count is right, daily budget matches, bidding is Manual CPC.
2. Full-page screenshot → `creation-step-final-overview`; record the campaign URL (`ads.google.com/aw/campaigns/<campaign_id>`).

### Phase 7: Write Creation Log

Write `iterations/vN/verification/creation-log.md` using the template in `references/creation-log-and-pitfalls.md` (timestamp, URL, campaign ID, PAUSED status, component counts, diacritics table, screenshots, issues).

## Handling UI Variations

When an expected control is missing: (1) try `find` with broader text/aria labels, (2) inspect DOM with `javascript_tool`, (3) read screen with `get_page_text`. **Never guess** — after 2–3 failed attempts, STOP and report to the user with a screenshot. See `references/creation-log-and-pitfalls.md` for common form quirks.

## After Creation

Stop once the campaign is PAUSED and `creation-log.md` is written. Next steps belong to the investor: review and enable in Google Ads UI → run `/ads-metrics` after 7 days → evaluate watch groups after 100 impressions/ad group.

## Related Skills

- `browser-verification` — Chrome verification playbook
- `clickable-copy` — RSA copy formulas
- `iterative-campaign-design` — pre-launch loop producing `spec.md`
