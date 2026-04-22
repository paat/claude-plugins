---
name: buyer-intent-targeting
description: Use whenever classifying keywords, selecting seed terms, building negative keyword lists, choosing landing pages, or writing ad copy — enforces the rule that Google Ads spend only follows commercial and transactional buyer intent, never informational intent, even when the site has high-quality content matching informational queries. Load FIRST in any pre-launch iteration, before iterative-campaign-design.
---

# Buyer-Intent Targeting

## The Core Rule

**Google Ads spend must follow buyer intent, not content relevance.**

A site can have brilliant informational pages that rank for "how to file an annual report in Estonia" — but the people searching that query are looking for *free help*, not a *paid service*. Spending ad budget to send them to a commercial page wastes money. Spending ad budget to send them to the informational page wastes money even faster, because informational-intent traffic has near-zero conversion to paid.

**Content relevance and buyer intent are two orthogonal axes.** SEO can and should claim the content-relevance axis for free traffic on all four intent classes. Paid search must stay on the commercial + transactional half of the intent axis. Mixing them is the most expensive mistake in PPC.

This skill is the **first filter** in campaign design. Every keyword must pass intent classification before it is allowed into an iteration spec. Every landing page choice, every ad copy decision, and every negative-keyword list derives from this classification.

## The Four Intent Classes

### 1. Informational — **NEVER bid**
The searcher wants to learn, not buy. High volume, low conversion, expensive lessons.

**Signals in the query**:
- "how to", "how do I", "what is", "why does", "when should"
- "guide", "tutorial", "explained", "meaning", "definition"
- "free", "template", "example", "sample"
- "DIY", "manual", "step by step"
- Long-tail question forms ("can I file my own annual report")

**Signals in the SERP**:
- "People Also Ask" box dominates top fold
- Organic results are listicles, blog posts, Wikipedia
- Few or no shopping/ad results above the fold
- Featured snippets showing long-form text

**Exception**: None for paid search. Let SEO have these.

### 2. Navigational — **Bid only on your own brand, defensively**
The searcher wants a specific destination. They already know who they want.

**Signals in the query**:
- A specific brand name ("aruannik")
- Brand + generic modifier ("aruannik login", "aruannik price")
- A specific product name + company

**Action**:
- Bid on your own brand as a defensive moat (prevents competitors from stealing your branded traffic)
- DO NOT bid on competitors' brand names unless you have an explicit brand-conquesting strategy and legal clearance — it burns goodwill and often triggers trademark complaints
- Navigational traffic on your own brand has the highest CVR of any intent class — always include a branded campaign

### 3. Commercial Investigation — **PRIORITY target**
The searcher is comparing options and will likely buy soon. High value, manageable volume.

**Signals in the query**:
- "best [category]" ("best annual report service Estonia")
- "[category] for [audience]" ("annual report for e-residents")
- "[brand A] vs [brand B]"
- "[brand] review", "[brand] alternative", "[brand] pricing"
- "cheap [category]", "affordable [category]", "[category] cost"
- "top [category]"

**Signals in the SERP**:
- Multiple paid ads above the fold
- Comparison articles and listicles mixed with commercial results
- Shopping / service-listing results
- "People Also Ask" present but not dominant

**Ad copy framing**:
- Lead with differentiation: "Unlike X, we Y"
- Show price or price-range in the ad if it's a positive differentiator
- Include sitelinks to pricing and comparison pages
- Emphasize proof (reviews, customer count, certifications)

### 4. Transactional — **HIGHEST priority target**
The searcher has decided to buy and is looking to execute. Low volume, highest CVR, expensive clicks.

**Signals in the query**:
- "buy", "order", "hire", "book", "get", "purchase"
- "[service] near me", "[service] in [city]"
- "[category] price", "[category] cost" (note: overlaps with commercial investigation)
- "[category] online"
- "[service] today"
- "sign up for [category]", "register [category]"

**Signals in the SERP**:
- Paid ads at top AND bottom
- Shopping carousel or service-listing results
- Local pack (for local services)
- Very few informational results above the fold

**Ad copy framing**:
- Lead with the action: "Start Now", "Order in 5 Minutes", "Book a Slot Today"
- Urgency / scarcity if honest ("Deadline April 30")
- Price up front if competitive
- CTA button-mimicking phrasing ("Get Started — €X")
- Include all relevant extensions: sitelinks, callouts, price, promotion, structured snippets

## The Classification Workflow

For every candidate keyword:

1. **Parse the query for signal words** (the bullet lists above)
2. **Check the SERP via Chrome** (`/ads-serp <keyword>`) — intent signals in the results layout often override query-word signals
3. **Assign one of {informational, navigational, commercial, transactional}**
4. **Record the classification in the keyword table** in `iterations/vN/spec.md`
5. **Drop informational** — move to the negative keyword list instead
6. **Route navigational** to the branded campaign only
7. **Group commercial and transactional** into their own ad groups — NEVER mix intents in one ad group because the ad copy needs to differ

## Default Negative Keywords (add to every campaign)

These go into every new campaign as phrase-match negatives on Day 1:

```
how to
how do
what is
what are
why does
guide
tutorial
free
template
example
sample
explained
meaning
definition
DIY
manual
step by step
course
lesson
learn
wikipedia
youtube
reddit
```

Add language-specific variants. For Estonian campaigns, also include:

> **Important**: Before applying these defaults, check project memory for override rules. Some projects explicitly reclassify certain words (e.g., a word that is informational in general but a buyer modifier in a specific product niche). Project memory overrides take precedence over these defaults.

```
kuidas
mis on
miks
juhend
näidis
õpetus
tasuta
mall
```

For Russian campaigns:
```
как
что такое
почему
руководство
пример
бесплатно
шаблон
```

Regenerate this list from the project's actual Search Terms report after the first 1,000 impressions — real user queries will surface negatives you didn't anticipate.

## Landing Page Routing

Intent class dictates landing page:

| Intent | Landing page |
|---|---|
| Informational | **Do not bid** — if you accidentally bid, send to blog/guide page (but you should not be bidding) |
| Navigational (own brand) | Homepage or the specific product page matching the query |
| Commercial investigation | Comparison page, pricing page, "why us" page, or feature-highlight page with a clear CTA |
| Transactional | Direct signup / checkout / pricing-with-button page. NEVER a blog post. |

**The test**: if the landing page has a prominent CTA button above the fold that initiates the paid transaction, it is a commercial LP. If it has a scroll-to-read body text and no button above the fold, it is an informational LP — do not send paid traffic there.

## Verification in the SERP

Always run `/ads-serp <keyword>` on every target keyword before including it. The SERP tells you the ground truth:

- **If you see ≥ 3 paid ads + shopping results**: strong commercial/transactional signal — proceed
- **If you see "People Also Ask" + listicles + zero paid ads**: informational — drop the keyword
- **If you see only your own brand in the top results**: navigational to your brand — branded campaign only
- **If you see competitors' ads but weak organic ads**: commercial investigation — high priority

Take a screenshot of every SERP into `iterations/vN/verification/serp-<keyword>.png`. The screenshot is evidence, not decoration.

## Product-Value Gate (drop even if intent is commercial)

Even when a keyword has clear commercial intent and zero competition, **drop it if the product cannot deliver meaningful value to that searcher**. Paying for clicks that can't convert is waste regardless of intent class.

Example: a nullaruanne (zero-activity annual report) keyword may have perfect commercial signals, but if the product only provides instructions for a free DIY portal and cannot meaningfully outperform the free option, the click produces no conversion. Drop the keyword — let SEO handle it for free.

This gate runs AFTER intent classification and BEFORE the keyword enters the spec. Ask: "If this person clicks and lands on our commercial page, can we charge them for something they'd pay for?" If the answer is "they'd just use the free alternative", the keyword fails the product-value gate.

## Red Flags (refuse to add these keywords)

Stop and ask the user if they insist on any of these:

- High-volume generic category terms with no buyer modifier ("annual report", "accounting software") — these are usually informational traffic at huge volume, will burn budget fast
- Question-form queries even if the product technically answers them ("can I file my own annual report?" — they want to DIY, not hire)
- "Free" + [your category] — explicitly not looking to pay
- Competitor brand names — legal risk + ethical risk
- Exact-match on very broad terms without location or modifier

## Related Skills

- `iterative-campaign-design` — calls this skill FIRST when selecting v1 keywords
- `iterative-optimization` — uses intent classification when mining Search Terms reports for new negatives
- `competitor-intel` — uses SERP intent signals to find commercial-intent gaps where competitors under-serve
- `clickable-copy` — copy formulas are intent-class specific (commercial vs transactional framing differ)
- `browser-verification` — provides the Chrome playbook for the SERP classification step
