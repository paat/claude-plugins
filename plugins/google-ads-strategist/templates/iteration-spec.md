# Iteration v<N> spec — <campaign>

**Date**: YYYY-MM-DD
**Hypothesis**: see hypothesis.md in this folder
**Status**: <draft | verified | ready-to-launch | applied>

## Campaign settings

- **Campaign type**: Search
- **Networks**: Google Search (no search partners unless justified)
- **Languages**: <list>
- **Locations**: <list with radius if relevant>
- **Daily budget**: <€X>
- **Bidding strategy**: <max clicks | tCPA | tROAS | manual CPC>
- **Device bid adjustments**: mobile <x%>, tablet <x%>, desktop <x%>

## Ad groups

### AG_branded_defensive — intent: navigational — language: <all>

**REQUIRED** if the advertiser has a brand name in brief.md. Captures own-brand searches at low cost to prevent competitor conquesting.

**Final URL**: `<official_site>?utm_source=google&utm_medium=cpc&utm_campaign=<campaign_slug>&utm_content=<iteration>&utm_term={keyword}&utm_adgroup=branded_defensive`

**Bidding**: manual CPC, max bid from `brand_defensive_bid_cap` in brief.md (typical €0.10–€0.50)

**Keywords**:

| Keyword | Match type | Intent | Notes |
|---------|------------|--------|-------|
| <brand name> | [exact] | navigational | primary brand |
| <brand variant 1> | [exact] | navigational | misspelling |
| <brand + "service"> | "phrase" | navigational | brand + category |
| <brand + "pricing"> | "phrase" | navigational | commercial combo |

**RSA — headlines** (3 pinned + 2 free):
1. `<Brand> — Official Site` (pin pos 1)
2. `<Product category>` (pin pos 2)
3. `<Primary CTA + value>` (pin pos 3)
4. `<Proof point>`
5. `<Extension line>`

**RSA — descriptions**:
1. `Official <Brand> site. <Primary value>. Start now from <price>.`
2. `<Category> service by <Brand>. <Proof>. No risk.`

### AG1: <name> — intent: <commercial | transactional> — language: <lang>

**Final URL**: `<LP>?utm_source=google&utm_medium=cpc&utm_campaign=<campaign_slug>&utm_content=<iteration>&utm_term={keyword}&utm_adgroup=<slug>`  (commercial page only — NOT a blog/guide)

**Keywords**:

| Keyword | Match type | Intent | Final URL | Monthly vol (est) | Competition |
|---------|------------|--------|-----------|-------------------|-------------|
| <kw 1> | [exact] | transactional | ...utm... | — | — |
| <kw 2> | "phrase" | commercial | ...utm... | — | — |

**Negative keywords** (on top of the default informational negatives list):

- <negative 1>
- <negative 2>

**RSA — headlines** (15 max, 30 chars each):

| # | Headline | Pin | Intent formula |
|---|----------|-----|-----|
| 1 | | pos 1 | |
| 2 | | | |
| ... | | | |

**RSA — descriptions** (4 max, 90 chars each):

| # | Description | Pin |
|---|-------------|-----|
| 1 | | pos 1 |
| 2 | | |
| 3 | | |
| 4 | | |

**Paths** (2 max, 15 chars each):
- /<path1>
- /<path2>

**Extensions**:
- Sitelinks: <list>
- Callouts: <list>
- Structured snippets: <list>
- Price: <if applicable>
- Promotion: <if applicable>

### AG2: <name> — ...

(repeat per ad group)

## Default negative keywords (informational filter)

```
how to
what is
guide
tutorial
free
template
example
explained
definition
meaning
DIY
...
```

(plus language-specific variants — see `buyer-intent-targeting` skill)

## Verification targets

After this spec is written, `/ads-verify` must confirm:

- [ ] Every keyword triggers the ad in Ad Preview Tool
- [ ] Average position ≤ 3
- [ ] SERP captures confirm commercial intent for every target keyword
- [ ] Copy differentiation visible against competitor matrix

## Notes

(anything reviewer should know)
