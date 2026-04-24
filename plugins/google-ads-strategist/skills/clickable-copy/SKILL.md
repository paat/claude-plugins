---
name: clickable-copy
description: Use when writing or rewriting Google Ads headlines, descriptions, extensions, or landing-page-match copy — provides intent-class-specific copy formulas, Quality Score alignment rules, differentiation frameworks against the competitor matrix, and character-count discipline for Responsive Search Ads. Load when the iteration hypothesis touches the copy variable class or when competitor analysis reveals undifferentiated copy.
---

# Clickable Copy for Google Ads

Copy that gets clicked follows intent. Copy that converts follows message match. Copy that wins the auction follows Quality Score. This skill handles all three, with explicit formulas.

## The Three Jobs of Ad Copy

1. **Earn the click** — headlines + descriptions that stand out against competitors on the same SERP
2. **Qualify the click** — self-select the right buyer so you don't pay for tire-kickers
3. **Match the landing page** — message continuity so Quality Score and CVR both hold up

A copy change that improves (1) but breaks (2) or (3) is a loss. Always optimize for the weakest of the three.

## Responsive Search Ads (RSA) Anatomy

Google's current ad format for search campaigns:

- **15 headlines** (30 chars each)
- **4 descriptions** (90 chars each)
- **2 paths** (15 chars each, appended to display URL)
- **Extensions**: sitelinks, callouts, structured snippets, price, promotion, location, call, lead form

Google rotates the assets to find the best combinations. **You cannot control the specific combination shown** — the only levers are which headlines can appear, and which are **pinned** to a position.

### Pinning Strategy

Pinning removes an asset from the rotation and forces it to a specific position. Use pinning to:
- Protect brand integrity (pin "Aruannik — AI Annual Reports" to position 1)
- Guarantee a legal disclosure shows (pin a compliance headline)
- Force a specific value prop to position 1

**But**: heavy pinning kills Google's machine-learning optimization. The rule: pin at most 2 headlines and 1 description per ad. Everything else should compete freely in rotation.

## Intent-Class Copy Formulas

### Commercial Investigation Formulas

The searcher is comparing options. Your job: stand out + be the obvious rational choice.

**Formula 1: Differentiation lead**
```
H1: [Category] for [Specific Audience]
H2: [Unique Differentiator vs competitors]
H3: [Proof point]
D1: [Expanded differentiator] + [benefit to audience]
```

Example (Aruannik):
- H1: "Annual Report for E-Residents"
- H2: "Built for e-residents, not accountants"
- H3: "Used by 500+ e-resident OÜs"
- D1: "Purpose-built for e-resident micro-OÜs — XBRL-compliant, guided wizard, no accounting background needed."

**Formula 2: Price-anchor**
```
H1: [Category] from €[Low Price]
H2: [Category descriptor]
H3: [Why the price is this low]
D1: [Price breakdown] + [value justification]
```

Use when your price is a genuine advantage. Never hide the price.

**Formula 3: Comparison lead** (do NOT name the competitor — use generic framing)
```
H1: [Category] Without [Competitor Pain Point]
H2: [Your advantage]
H3: [Audience]
```

Example: "Annual Report Without the Accountant" (implies competitors = accountants, positions as DIY-friendly).

### Transactional Formulas

The searcher has decided to buy. Your job: reduce friction, make the action obvious.

**Formula 1: Action verb + speed**
```
H1: [Action] [Category] in [Time]
H2: [Removing friction]
H3: [Price or starter offer]
D1: [Step count] + [outcome on completion]
CTA in every extension: Start Now / Order Now / Book Now
```

Example:
- H1: "File Annual Report in 15 Min"
- H2: "No Accountant Needed"
- H3: "From €49"
- D1: "Six guided steps from bank CSV to legally-compliant XBRL. Ready for Business Register upload."

**Formula 2: Deadline urgency** (only if honest)
```
H1: [Category] — Deadline [Date]
H2: [Action verb] before penalty
H3: [Your speed vs deadline]
```

Never fabricate urgency. If the real deadline is six months away, don't claim "today only".

**Formula 3: Risk reversal**
```
H1: [Action] [Category] — [Guarantee]
H2: [Value prop]
H3: [Social proof]
```

Example: "File Annual Report — Money-Back if Rejected"

### Branded (defensive) formulas

For your own brand name:
```
H1: [Brand] — Official Site
H2: [Primary category]
H3: [Clear CTA]
```

Goal: simple, unambiguous, reclaim traffic. Do not get cute on branded ads.

## Quality Score Alignment

Google's Quality Score is a 1-10 score per keyword based on three components:

1. **Expected CTR**: will users click this ad given the keyword? Driven by historical CTR + keyword-headline match.
2. **Ad relevance**: how well does the ad copy match the keyword? Driven by keyword presence in headlines.
3. **Landing page experience**: does the LP deliver on the ad promise? Driven by page content, speed, mobile-friendliness.

**The fastest Quality Score lift**: include the target keyword verbatim in at least one headline per ad. Generic copy ("the best service") hurts relevance scoring; specific copy ("annual report service estonia") helps.

**The second fastest lift**: landing page H1 repeats the primary ad headline's value prop. Message match is scored.

## Character-Count Discipline

Google cuts off over-length assets without warning. Hard rules:

- Headlines: max 30 characters, count spaces
- Descriptions: max 90 characters
- Paths: max 15 characters
- Sitelink title: 25 characters
- Sitelink description lines: 35 characters each

Do character counts BEFORE writing, not after. The cadence is: decide the angle → count the character budget → write within the budget. Rewriting to fit is painful and usually produces awkward copy.

## Differentiation Test

For every headline you write, ask:
1. Could a competitor run this exact headline? If yes, it's not differentiated.
2. Does it mention a specific audience, price, speed, or proof? If no, it's generic.
3. Would someone see this and know what to expect on click? If no, it will tank CVR.

Run the competitor copy matrix from `competitor-intel`. Every new headline must occupy whitespace the matrix reveals.

## Landing Page Message Match

For each keyword:
- The primary headline in the ad should appear (verbatim or nearly) in the LP H1 or hero
- The CTA button text on the LP should match the CTA verb in the ad
- The visual hero on the LP should reinforce the ad's value prop (e.g., if the ad says "in 15 minutes", the LP should show a time-emphasizing graphic or testimonial)
- The price shown in the ad (if any) must match the price shown on the LP — discrepancies tank trust

If the LP is a commercial page that can't be modified, that constrains the ad copy — don't promise what the LP doesn't deliver.

## Multilingual Copy Discipline

For Estonian: all copy uses proper diacritics (ä, ö, ü, õ, š, ž). Never ASCII-ified. "Aastaaruanne e-residendile" not "Aastaaruanne e-residendile" with wrong chars.

For Russian: Cyrillic throughout, never transliterated. Additional RU-specific rules:

- **Numeral grammar**: Russian numerals govern noun case. This matters in headlines with numbers (prices, time, counts):
  - 1: nominative singular ("1 год", "1 минута", "1 отчёт")
  - 2-4: genitive singular ("2 года", "3 минуты", "4 отчёта")
  - 5-20: genitive plural ("5 лет", "10 минут", "15 отчётов")
  - 21: back to nominative singular ("21 год"), 22-24 genitive singular, etc.
  - **Ad copy with wrong numeral agreement looks illiterate** — always verify after writing
- **Character budget**: Cyrillic characters are wider than Latin in most fonts. A 30-char headline in Russian will visually appear longer than 30 chars of English. Write RU headlines 2-3 chars shorter than the limit to avoid visual cramping on mobile.
- **Formal "вы"**: B2B and financial services use formal "Вы" (capitalized). Consumer products use lowercase "вы". Match the product's register.
- **Price format**: Use the target market's convention. For Estonia/EU: "€29" (symbol before number). Never "29 евро" in a headline — wastes 4 chars.

For English: when targeting non-native-English markets (e.g., Estonian e-residents), avoid idioms and colloquialisms that won't translate — "crush it" is a no, "save time" is yes.

Each language gets its own RSA, its own headlines, its own formulas. Do NOT machine-translate the English ads into Estonian and Russian — write them native-first.

## RSA Writing Checklist

Before adding an RSA to an iteration spec:

- [ ] 15 headlines, each ≤ 30 characters
- [ ] 4 descriptions, each ≤ 90 characters
- [ ] Primary keyword verbatim in at least 3 headlines
- [ ] Differentiation angle from competitor matrix reflected in ≥ 2 headlines
- [ ] Intent-class formula applied (commercial or transactional)
- [ ] CTA in at least 2 headlines and 1 description
- [ ] No duplicate or near-duplicate headlines (Google rejects)
- [ ] Branded variant headline (for relevance + branded queries)
- [ ] Proof point (social, certification, customer count) in ≥ 1 asset
- [ ] LP message match verified (H1 + CTA + hero visual)
- [ ] Character counts confirmed
- [ ] Language-native, not translated

## Related Skills

- `buyer-intent-targeting` — determines which formula applies per keyword
- `competitor-intel` — provides the differentiation matrix
- `iterative-campaign-design` — calls this skill for copy-variable hypotheses
- `browser-verification` — Ad Preview Tool is where you confirm the copy actually shows and reads well
