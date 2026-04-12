---
name: chrome-campaign-creation
description: Use when building a Google Ads campaign in the Ads UI via Chrome automation — provides the step-by-step creation workflow for campaign settings, ad groups, keywords, RSAs, extensions, and negatives. Creates everything in PAUSED state. Load when running /ads-create.
---

# Chrome Campaign Creation

Create a Google Ads Search campaign from spec.md using Chrome browser automation. The campaign is created in **PAUSED** state — the investor reviews and enables it.

## Before You Start

1. `mcp__claude-in-chrome__tabs_context_mcp` — check Chrome state
2. Verify the user is logged into `ads.google.com` — navigate to `https://ads.google.com/aw` and check for the account selector. If not logged in, STOP and ask the user to log in manually.
3. Read `spec.md` fully — you need campaign settings, all ad groups, all keywords, all RSAs, all extensions, all negatives.
4. Read `brief.md` for brand context and budget confirmation.

## Diacritics Rule

The spec.md uses ASCII for portability (e.g., `Mikroettevotjale`). When entering text in the Google Ads UI, **always use proper Estonian Unicode diacritics**: ä, ö, ü, õ, š, ž and their uppercase variants. Mentally correct every headline and description before typing.

Common corrections:
- `Mikroettevotjale` → `Mikroettevõtjale`
- `Lae ules pangavaljavote` → `Lae üles pangaväljavõte`
- `Odavaim lahendus turul` → `Odavaim lahendus turul` (no change — no diacritics needed)
- `Tahtaeg 30. Juuni 2026` → `Tähtaeg 30. juuni 2026`
- `Tehisintellekt` → `Tehisintellekt` (correct as-is)

## Step-by-Step Creation

### Phase 1: Campaign Shell

1. Navigate to `https://ads.google.com/aw/campaigns/new`
2. Google may show a "campaign objective" picker. Select **"Create a campaign without a goal's guidance"** (or "Website traffic" if no unguideded option). The goal is to get to the manual campaign type selector.
3. Select **Search** as campaign type.
4. On the campaign settings page, configure:
   - **Campaign name**: from spec.md `Campaign name` field
   - **Networks**: UNCHECK "Include Google search partners" and "Include Google Display Network"
   - **Locations**: 
     - Click "Enter another location"
     - Search for "Estonia" → select it
     - Under "Location options" → select "Presence: People in your targeted locations"
     - Add location exclusions (India, Pakistan, Bangladesh, Philippines, Nigeria) under "Exclude"
   - **Languages**: Add "Estonian" and "English"
   - **Budget**: Enter the daily budget from spec.md
   - **Bidding**: Select "Manual CPC". UNCHECK "Enhanced CPC" if it auto-selects.
   - **More settings** → **Start and end dates**: Set start date to today (or per spec), end date from spec.md
   - **More settings** → **Ad rotation**: "Optimize: Prefer best performing ads"
   - **More settings** → **Ad schedule**: Leave as "All day" (per spec)

5. **CRITICAL**: Before clicking "Next" or "Save", find the **campaign status** control. In the current Google Ads UI, this is usually:
   - A dropdown or toggle near the top of the page saying "Campaign status"
   - Or it appears on the final review page before submission
   - Set it to **"Paused"**
   - If you cannot find the status control during creation, the campaign will default to "Enabled" — in that case, IMMEDIATELY after creation, navigate to the campaign list and pause it before proceeding to ad groups.

6. Screenshot the campaign settings page → note as `creation-step-01-campaign-settings`

### Phase 2: Ad Groups + Keywords + RSAs (repeat per ad group)

For each ad group in spec.md, in order:

1. **Create the ad group**:
   - Name: from spec.md
   - Default max CPC: from spec.md per-ad-group max CPC
   
2. **Add keywords**:
   - Switch to "Enter keywords" mode (not suggestions)
   - For each keyword in the ad group's table:
     - Exact match: enter as `[keyword]`
     - Phrase match: enter as `"keyword"`
     - Broad match: enter as `keyword` (no brackets)
   - Enter all keywords for this ad group

3. **Create the RSA**:
   - Click "Create ad" or "New ad"
   - Select "Responsive search ad"
   - **Final URL**: from spec.md, with full UTM + GCLID parameters. Apply diacritics correction to the path if needed.
   - **Display path**: from spec.md (2 path fields, 15 chars each)
   - **Headlines**: Enter all 15 headlines from the spec's RSA table. Apply diacritics correction. Set pins per the "Pin" column.
   - **Descriptions**: Enter all 4 descriptions. Apply diacritics correction. Set pins per the "Pin" column.
   - Save the ad.

4. Screenshot the completed ad group → note as `creation-step-NN-ag-<slug>`

5. Repeat for every ad group in the spec.

### Phase 3: Campaign-Level Negatives

1. Navigate to the campaign's "Keywords" → "Negative keywords" section
2. Add all campaign-level negatives from `negatives.md`:
   - Enter them in bulk (paste mode if available)
   - Use phrase match format: `"negative keyword"` for phrase match negatives
3. Screenshot → `creation-step-NN-negatives`

### Phase 4: Campaign-Level Extensions

1. Navigate to the campaign's "Ads & extensions" → "Extensions" section
2. **Sitelinks**: Add each sitelink from spec.md with:
   - Sitelink text (title)
   - Final URL (with UTMs)
   - Description lines (if spec provides them)
3. **Callouts**: Add all callout extensions from spec.md
4. **Structured snippets**: Add if spec.md includes them
5. Screenshot → `creation-step-NN-extensions`

### Phase 5: Device Bid Adjustments

1. Navigate to campaign settings → "Devices"
2. Set bid adjustments per spec.md (e.g., Tablet -50%)
3. Screenshot if changes were made

### Phase 6: Final Verification

1. Navigate to the campaign overview page
2. Verify:
   - Campaign status is **PAUSED** (this is the most important check)
   - Number of ad groups matches spec.md
   - Total keyword count is approximately correct
   - Budget shows the correct daily amount
   - Bidding shows Manual CPC
3. Take a full-page screenshot → `creation-step-final-overview`
4. Record the campaign URL (e.g., `ads.google.com/aw/campaigns/<campaign_id>`)

### Phase 7: Write Creation Log

Write `iterations/vN/verification/creation-log.md`:

```markdown
# Campaign creation log — <campaign> vN

**Created**: YYYY-MM-DD HH:MM UTC
**Google Ads campaign URL**: <URL>
**Campaign ID**: <id>
**Status**: PAUSED

## Creation summary

| Component | Count | Status |
|-----------|-------|--------|
| Campaign settings | 1 | Created |
| Ad groups | N | Created |
| Keywords | N | Entered |
| RSAs | N | Created |
| Sitelinks | N | Added |
| Callouts | N | Added |
| Campaign negatives | N | Added |

## Diacritics applied

| Spec text (ASCII) | Entered text (Unicode) |
|---|---|
| Mikroettevotjale | Mikroettevõtjale |
| ... | ... |

## Screenshots

| Step | Description | Screenshot ID |
|------|-------------|---------------|
| 01 | Campaign settings | creation-step-01-... |
| ... | ... | ... |
| final | Campaign overview (PAUSED) | creation-step-final-overview |

## Issues encountered

- (list any form failures, unexpected UI, workarounds used)
- If none: "Clean creation, no issues."
```

## Handling UI Variations

Google Ads UI changes frequently. If the expected element is not found:

1. **Try `find` with a broader selector** — button text, aria labels, nearby text
2. **Try `javascript_tool`** to read the DOM for the target element
3. **Try `get_page_text`** to understand what's currently on screen
4. **Do NOT guess** — if after 2-3 attempts the element is not found, STOP and report to the user with a screenshot of what you see. The user can guide you through the changed UI.

## Common Pitfalls

- **"Enhanced CPC" auto-selects**: Always explicitly uncheck it when choosing Manual CPC
- **Campaign defaults to "Enabled"**: If you can't find the Paused toggle during creation, pause it immediately after saving from the campaigns list
- **Keyword match type**: Google Ads UI sometimes strips brackets/quotes — verify after entry that match types are correct
- **Final URL validation**: Google may reject URLs with certain characters. If rejected, simplify the UTM parameters (remove `{gclid}` ValueTrack if it fails — Google adds GCLID automatically when auto-tagging is on)
- **Display path character limit**: 15 chars each, no spaces allowed in path segments
- **RSA headline limit**: 30 chars hard limit — Google will reject if over. Count before entering.
- **Diacritics in URLs**: URL paths should NOT contain diacritics (use ASCII slugs). Diacritics are for ad copy text only.

## After Creation

The agent's job is done after the campaign is created in PAUSED state and the creation log is written. The next steps are:

1. **Investor reviews** the campaign in Google Ads UI
2. **Investor enables** the campaign when satisfied
3. **After 7 days**, run `/ads-metrics` to pull the first post-launch data
4. **After 100 impressions per ad group**, evaluate the watch groups (kuidas/juhend, tegevusaruanne)

## Related Skills

- `browser-verification` — Chrome playbook for verification (not creation)
- `clickable-copy` — copy formulas used in the RSAs being entered
- `iterative-campaign-design` — the pre-launch loop that produced spec.md
