---
name: clickable-copy
description: "Use for Google Ads headlines, descriptions, extensions, landing-page-match copy, competitor differentiation, and RSA character limits."
---

# Clickable Copy for Google Ads

Copy that gets clicked follows intent; copy that converts follows message match; copy that wins the auction follows Quality Score. Load `references/copy-formulas-and-locales.md` when drafting headlines/descriptions by intent class or writing Estonian/Russian copy.

## The Three Jobs of Ad Copy

1. **Earn the click** — stand out against competitors on the same SERP.
2. **Qualify the click** — self-select real buyers so budget isn't spent on tire-kickers.
3. **Match the landing page** — preserve message continuity for Quality Score and CVR.

A change that helps (1) while breaking (2) or (3) is a net loss. Always optimize the weakest of the three.

## Responsive Search Ads (RSA) Anatomy & Pinning

- **15 headlines** (≤ 30 chars each), **4 descriptions** (≤ 90 chars each), **2 display paths** (≤ 15 chars each), plus **extensions** (sitelinks, callouts, structured snippets, price, promotion, location, call, lead form).
- Google rotates combinations dynamically. Use **pinning** sparingly — to protect brand integrity (`[Brand] — [Tagline]` at Pos 1), guarantee a legal disclosure, or lock a core value prop.
- **Pinning cap**: pin **at most 2 headlines and 1 description** per ad so Google's rotation can still optimize.

## Intent-Class Copy Formulas

Apply the formula matching the ad group's intent class from `buyer-intent-targeting` (full templates and examples in `references/copy-formulas-and-locales.md`):

- **Commercial investigation**: Differentiation lead, Price-anchor (if genuinely cheaper), or generic Comparison lead (never name competitors).
- **Transactional**: Action verb + speed, honest Deadline urgency (never fabricate), or Risk reversal + action CTAs in extensions.
- **Branded (defensive)**: `[Brand] — Official Site` + primary category + clear CTA. Keep simple and unambiguous.

## Quality Score Alignment

Quality Score (1–10 per keyword) tracks **Expected CTR**, **Ad relevance**, and **Landing page experience**:
- **Fastest lift**: include the target keyword verbatim in at least one headline per ad (specific beats generic).
- **Second fastest lift**: repeat the primary ad headline's value prop in the landing page H1.

## Character-Count Discipline

Google truncates over-length assets silently. Count budgets **before** writing (angle → budget → draft):
- Headlines: **30 chars** (spaces included) | Descriptions: **90 chars** | Paths: **15 chars**
- Sitelink title: **25 chars** | Sitelink descriptions: **35 chars** each

## Differentiation Test

For every headline, verify against the `competitor-intel` copy matrix so each headline occupies real whitespace:
1. Could a competitor run this exact headline? If yes, rewrite.
2. Does it name a specific audience, price, speed, or proof? If no, it's generic.
3. Does a searcher know what happens after clicking? If no, CVR will drop.

## Landing Page Message Match

- Primary ad headline appears (verbatim or nearly) in LP H1/hero; LP CTA matches ad CTA verb.
- LP hero visual reinforces the ad promise (e.g., speed/proof), and any stated price matches the LP exactly.
- If the LP cannot be edited, constrain ad copy to what the LP actually delivers.

## Multilingual Copy Discipline

Write each language **native-first** in its own RSA (never machine-translate): Estonian uses full Unicode diacritics (`ä, ö, ü, õ, š, ž`); Russian uses Cyrillic with verified numeral case agreement, 2–3 char shorter mobile headlines, matching `"Вы"/"вы"` register, and `"€N"` pricing; English for non-native markets avoids idioms (`references/copy-formulas-and-locales.md`).

## RSA Writing Checklist

Before adding an RSA to `spec.md`:
- [ ] 15 headlines (≤ 30 chars) & 4 descriptions (≤ 90 chars), counts confirmed
- [ ] Primary keyword verbatim in ≥ 3 headlines; differentiation angle from matrix in ≥ 2 headlines
- [ ] Intent-class formula applied; CTA in ≥ 2 headlines and ≥ 1 description
- [ ] No duplicate/near-duplicate headlines; branded variant + proof point (≥ 1 asset) included
- [ ] LP message match verified (H1 + CTA + hero + price); language-native, not translated

## Related Skills

- `buyer-intent-targeting` | `competitor-intel` | `iterative-campaign-design` | `browser-verification`
