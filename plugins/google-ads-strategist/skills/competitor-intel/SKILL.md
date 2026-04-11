---
name: competitor-intel
description: Use when researching what competitors are doing in Google Ads — guides the Google Ads Transparency Center workflow for pulling competitor ad copy, identifying differentiation gaps, and reading Auction Insights to diagnose competitive pressure. Load before /ads-spy, when rewriting ad copy under competitive pressure, or when a SERP capture shows undifferentiated copy.
---

# Competitor Intelligence

Google Ads is a competitive auction — the ad's performance depends as much on what competitors are showing as on absolute ad quality. Competitor intelligence is a first-class input to every copy and bidding hypothesis.

## The Three Sources

### 1. Google Ads Transparency Center — **primary source**
**URL**: `https://adstransparency.google.com/`

Google's official public archive of all running ads. Free, no API, no rate limits, no ToS violations. Use this first.

**What you can pull**:
- Every currently-running ad from a specific advertiser
- Ad copy (headlines, descriptions)
- Display URLs
- Date ranges (first seen, last seen)
- Countries where the ad is running
- Ad format (text, image, video)

**Workflow**:
1. Identify the competitor (domain or advertiser name)
2. Navigate to Transparency Center
3. Search → filter by country + date + format
4. For each ad, extract headlines + descriptions + date last seen
5. Save structured data to `iterations/vN/verification/transparency-<competitor>.md`

**What to look for**:
- **Headline patterns**: are competitors leading with price, speed, quality, proof, or outcome?
- **Repeated variants**: ads running for 60+ days are the ones working — ads churning every week are being tested
- **Unique angles**: what framing is NO competitor using? Differentiation opportunity.
- **Extensions used**: sitelinks, callouts, price extensions (visible via the preview in the Transparency Center)
- **Landing page paths**: the display URL tells you where they're sending traffic, which reveals their funnel entry

### 2. Real SERP capture — **for context**

Transparency Center shows what competitors *have*, but the real SERP shows what *actually appears together for a given keyword*. Use SERP capture to see the competitive layout in context.

**Workflow** (detailed in `browser-verification`):
1. `/ads-serp <keyword>` → incognito Google search
2. Screenshot + extract all paid ads above fold
3. For each competing ad, record: headline, description, display URL, extensions visible
4. Cross-reference with Transparency Center to see the competitor's fuller ad portfolio

**What to look for**:
- Who is winning position 1 for target keywords?
- Is position 1 stable across multiple captures (30 mins apart)? Stable = they're bidding well. Rotating = it's a bidding battleground.
- Copy-to-copy resemblance: if ≥ 3 ads on the SERP read identically, differentiation is a big lever
- "Sponsored" badge treatment and any shopping / service-listing widgets

### 3. Auction Insights (Google Ads UI) — **post-launch only**

**URL**: Inside the Google Ads UI, under Campaigns → [campaign] → Auction Insights tab

Shows the live auction data for your own campaign: which advertisers you share the auction with, their impression share, overlap rate, position above rate, top-of-page rate, and absolute top-of-page rate.

**Workflow** (post-launch):
1. Navigate to Auction Insights for the campaign
2. Capture screenshot
3. Extract the top 10 competing advertisers
4. Note their impression share change over time (if new competitors appeared, competitive pressure is rising)
5. Save to `iterations/vN/verification/auction-insights-YYYY-MM-DD.png`

**Interpretation**:
- **High overlap rate + rising competitor share**: you're losing auctions to a specific competitor — diagnose their copy and differentiate
- **High position above rate for a competitor**: they're outranking you — QS or bid gap
- **New advertiser appearing suddenly**: market entry or new campaign launch, re-examine auction dynamics
- **Your impression share dropping with no account change**: someone else is pushing harder, check their Transparency Center ads for recent churn

## The Differentiation Matrix

For every target keyword, build a matrix like this:

```markdown
## Competitor copy matrix — keyword: "annual report service estonia"

| Advertiser | Headline angle | Price shown? | Proof shown? | CTA | Extensions |
|------------|---------------|--------------|--------------|-----|------------|
| Competitor A | Speed ("In 15 min") | No | "Used by 500+" | Try Now | sitelinks, callouts |
| Competitor B | Compliance ("Fully legal") | No | "Since 2015" | Learn More | sitelinks |
| Competitor C | Price ("From €49") | Yes, €49 | No | Get Started | price, sitelinks |
| **Us (current)** | ??? | ??? | ??? | ??? | ??? |
| **Us (proposed)** | E-resident specific | Yes, €X | "500+ e-residents" | Start Now | price, callouts, structured snippets |
```

The matrix forces you to see the whitespace — angles no competitor is using. The hypothesis for the next iteration often comes straight from the matrix's empty cells.

## Brand Conquesting (don't)

Bidding on competitor brand names is technically allowed in most markets but carries risk:
- Triggers trademark complaints (Google adjudicates; you can lose the keyword)
- Burns goodwill with the competitor
- Usually unprofitable (brand-search CVR is much lower when the brand isn't yours)
- Legal exposure in jurisdictions with stricter IP law (e.g., Germany is notably strict)

**Default**: do not bid on competitor brand names unless the user explicitly requests it and confirms legal clearance.

**Exception**: defensive bidding on your OWN brand is mandatory — if you don't, competitors will snipe your branded traffic.

## Red Flags in Competitor Intel

Stop and flag if:

- A competitor has 10+ variants of the same ad running — they're churning hard, probably struggling
- A competitor suddenly stops running ads — either they paused due to budget/failure or they pivoted
- A new competitor appears with aggressive pricing — market dynamics changing
- Your exact copy is being mirrored by a competitor — escalate to the user (possible scraping)

## What NOT to do

- Do NOT click on competitor ads in the real SERP (wastes their budget, wastes yours, flags you)
- Do NOT scrape the real SERP at high velocity (Google will captcha you)
- Do NOT rely on third-party SERP APIs for claims you'll report to the user — use Google's first-party sources (Transparency Center, Auction Insights) so your claims are defensible
- Do NOT copy competitor ad copy verbatim — differentiation is the whole point; copy inspires, not imitates

## Related Skills

- `browser-verification` — the Chrome playbook for Transparency Center navigation
- `clickable-copy` — converts competitor analysis into differentiated copy hypotheses
- `buyer-intent-targeting` — SERP competitor density is a key intent signal
- `iterative-campaign-design` — the differentiation matrix feeds every copy hypothesis
