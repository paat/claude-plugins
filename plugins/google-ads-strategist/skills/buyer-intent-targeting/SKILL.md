---
name: buyer-intent-targeting
description: "Use for commercial-intent keyword selection, negatives, landing pages, and ad copy before Google Ads spend."
---

# Buyer-Intent Targeting

## The Core Rule

**Google Ads spend must follow buyer intent, not content relevance.** Content relevance and buyer intent are orthogonal axes: let SEO capture free informational traffic, and keep paid search strictly on the commercial + transactional half (plus defensive own-brand navigational). Every keyword must pass intent classification before entering an iteration spec; landing page choice, ad copy, and negatives all derive from it.

Be token-frugal: load `references/intent-signals-and-negatives.md` when you need the full query-signal word lists or the EN/ET/RU Day-1 negative keyword lists.

## The Four Intent Classes

| Class | Paid Search Action | Core Signal | Ad Copy / LP Framing |
|---|---|---|---|
| **1. Informational** | **NEVER bid** (move to negatives; let SEO own) | Learn/DIY ("how to", "guide", "free", "template"); PAA + blogs dominate SERP | None — never bid |
| **2. Navigational** | **Own brand only, defensively** (highest CVR; no competitor brands without explicit strategy + legal clearance) | Specific brand name or brand + modifier (`login`, `price`) | Official-site branded ad → homepage or named product page |
| **3. Commercial Investigation** | **PRIORITY target** | Comparing options ("best", "vs", "review", "alternative", "for [audience]", "cost"); multiple paid ads above fold | Differentiation, proof, competitive price → comparison/pricing/feature page with CTA |
| **4. Transactional** | **HIGHEST priority target** | Ready to act ("buy", "order", "hire", "book", "online", "near me"); paid ads top + bottom, shopping/local pack | Direct action, honest urgency, price + full extensions → direct signup/checkout/pricing LP |

Detailed signal word lists and copy framing rules: `references/intent-signals-and-negatives.md`.

## The Classification Workflow

For every candidate keyword:
1. Parse the query for signal words (`references/intent-signals-and-negatives.md`).
2. Check the live SERP via Chrome (`/ads-serp <keyword>`) — SERP layout overrides query wording.
3. Assign one of `{informational, navigational, commercial, transactional}`.
4. Record the classification in the keyword table in `iterations/vN/spec.md`.
5. Drop informational keywords and move their root terms to the negative keyword list.
6. Route own-brand navigational keywords to the defensive branded ad group only.
7. Separate commercial investigation and transactional keywords into distinct ad groups — **never mix intents in one ad group** because copy framing must differ.

## Default Negative Keywords (Day 1)

Load the full English, Estonian, and Russian phrase-match negative lists from `references/intent-signals-and-negatives.md` into every new campaign on Day 1. Check project memory for override rules first — project memory overrides take precedence over defaults. Refresh negatives from the real Search Terms report after the first 1,000 impressions.

## Landing Page Routing

| Intent | Landing page |
|---|---|
| Informational | **Do not bid** (never send paid traffic to blogs/guides) |
| Navigational (own brand) | Homepage or the specific product page matching the query |
| Commercial investigation | Comparison, pricing, "why us", or feature page with a clear CTA |
| Transactional | Direct signup / checkout / pricing-with-button page — NEVER a blog post |

**The CTA test**: a valid commercial LP has a prominent CTA button above the fold initiating the paid transaction. Scroll-to-read body text with no above-the-fold CTA is informational — reject it for PPC.

## Verification in the SERP

Run `/ads-serp <keyword>` on every target keyword before inclusion (evidence in `iterations/vN/verification/serp-<keyword>.png` or `.md`):

- **≥ 3 paid ads + shopping results**: strong commercial/transactional signal — proceed.
- **"People Also Ask" + listicles + zero paid ads**: informational — drop the keyword.
- **Only your own brand in top results**: navigational to your brand — branded campaign only.
- **Competitor ads present with weak organic ads**: commercial investigation — high priority.

## Product-Value Gate (drop even if intent is commercial)

Run AFTER intent classification and BEFORE a keyword enters `spec.md`. Even with clear commercial intent and zero competition, **drop the keyword if the product cannot deliver paid-worthy value** (e.g., the searcher can complete the exact task for free on an official portal and the product does not meaningfully outperform it). Ask: *"If this person lands on our commercial page, will they pay rather than use the free path?"* If not, drop it and let SEO own it.

## Red Flags (refuse and ask the user before adding)

- High-volume generic category terms without a buyer modifier ("annual report", "accounting software")
- Question-form DIY queries ("can I file my own annual report?")
- `"free"` + category
- Competitor brand names (legal + ethical risk)
- Broad terms without location or buyer modifier

## Related Skills

- `iterative-campaign-design` — runs this first for v1 keyword selection
- `iterative-optimization` — Search Terms report negative mining
- `competitor-intel` — commercial-intent whitespace discovery
- `clickable-copy` — intent-specific RSA formulas
- `browser-verification` — Chrome playbook for SERP capture
