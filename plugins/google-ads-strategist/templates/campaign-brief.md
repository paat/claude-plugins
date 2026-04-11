# Campaign brief — <CAMPAIGN_NAME>

**Created**: YYYY-MM-DD

<!--
State tracking: this plugin uses plain marker files in the campaign directory,
NOT fields in this brief. Do not embed launched/applied state in markdown.

  docs/ads/<campaign>/launched_at             — touch to mark campaign launched (contents: ISO timestamp)
  docs/ads/<campaign>/iterations/vN/applied_at — touch to mark iteration applied (contents: ISO timestamp)
  docs/ads/<campaign>/wait_days                — optional, override default 7-day wait gate

/ads-metrics writes these automatically on first successful post-launch metric read.
-->


## Product

- **What**: <one-line description of what we are selling>
- **URL**: <primary product URL>
- **Primary value prop**: <the one-line reason someone would pay>
- **Price**: <price or price range>
- **Pricing page**: <URL>

## Brand (for defensive branded campaign — mandatory)

- **Brand name**: <exact brand name>
- **Brand variants**: <misspellings, alternate forms, brand + category combos> (e.g., "Acme Corp", "acmecorp", "acme reports", "Acme OÜ")
- **Official site URL**: <URL — usually homepage or main commercial page>
- **Brand defensive bid cap**: <max CPC for branded keywords, typically €0.10-€0.50 — branded traffic should be cheap>

## Final URL template (mandatory — attribution is non-negotiable)

Every final URL in every spec is derived from this template. Must include UTMs.

```
<landing_page>?utm_source=google&utm_medium=cpc&utm_campaign={campaign_slug}&utm_content={iteration}&utm_term={keyword}&utm_adgroup={adgroup}
```

Replacements at spec-write time:
- `{campaign_slug}` — the campaign name from this brief
- `{iteration}` — e.g., `v3`
- `{adgroup}` — the ad group slug
- `{keyword}` — Google's ValueTrack parameter, substituted at click time

**Landing pages used (must all be commercial — no blogs/guides):**
- <LP 1 URL> — <purpose>
- <LP 2 URL>

## Forecast baseline (for budget sanity check before v1)

Rough expectations that anchor the v1 cost forecast. Fill in what you know, leave the rest for the strategist to estimate from competitor SERP pressure.

- **Expected avg CPC (€)**: <X — or "estimate from SERP">
- **Expected CTR (%)**: <X — or "estimate">
- **Expected CVR (%)**: <X from current site data, or "unknown">
- **Daily impression target**: <count — to size the keyword list correctly>
- **Sanity check**: daily_budget / avg_CPC ≈ expected daily clicks. If that number is < 10, the campaign will produce zero learnable data per day — expand the keyword list or raise budget.

## Commercial landing pages (paid-traffic destinations only)

These are the ONLY pages paid traffic may be sent to. Blog posts, guides, and informational content are NOT valid destinations even if content-matched.

- <URL 1> — <purpose> — intent class: <commercial | transactional>
- <URL 2> — <purpose> — intent class: <commercial | transactional>

## Target audience

- **Who**: <specific role / type of buyer>
- **Where**: <countries>
- **Languages**: <languages>
- **Business stage / size / context**: <specific constraints>

## Goals

- **Primary goal**: <signup | trial | purchase | qualified lead>
- **Target CPA**: <€X>
- **Target ROAS**: <X>
- **Success metric for this campaign**: <observable>

## Budget

- **Daily budget**: <€X>
- **Monthly hard cap**: <€X>
- **Approved by**: <who>
- **Approved on**: YYYY-MM-DD

## Tracking

- **Conversion tracking configured**: <true | false>
- **Tracked conversions**: <list>
- **Attribution model**: <last click | data driven | ...>

## Competitors

(for `/ads-spy` + differentiation matrix)

- <competitor 1> — <domain> — <one-line note>
- <competitor 2>
- <competitor 3>

## Buyer-modifier keywords (what paying customers say)

- <word 1>
- <word 2>
- ...

## Exclusions

- **Audiences to exclude**: <list>
- **Query patterns to exclude**: <list>
- **Geographies to exclude**: <list>

## Blockers (must resolve before launch)

- [ ] <blocker 1>
- [ ] <blocker 2>

## Constraints and notes

(anything the strategist needs to know that doesn't fit above)
