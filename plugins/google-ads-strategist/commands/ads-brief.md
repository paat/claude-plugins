---
name: ads-brief
description: "Start a new Google Ads campaign by creating the brief.md + folder structure. Interactive intake that captures product, audience, commercial pages, budget, goals, and buyer-intent context. Usage: /ads-brief [campaign-name]"
user_invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, WebFetch
argument-hint: [campaign-name]
---

# /ads-brief — Create a Google Ads campaign brief

Set up a new Google Ads campaign: create `docs/ads/<campaign>/brief.md` and the iteration folder skeleton ready for `/ads-iterate`. Be token-frugal: read only existing brief/growth files once and stop early if a brief already exists.

## Step 0: Load the critical skills

```
Skill('google-ads-strategist:buyer-intent-targeting')
Skill('google-ads-strategist:iterative-campaign-design')
```

## Step 1: Determine the campaign name & check for existing brief

Use the passed kebab-case slug argument, or ask: *"What should we call this campaign? Short kebab-case slug, e.g., `<product>-commercial-ee` or `<brand>-signup-us`."*

Check `ls docs/ads/<campaign>/brief.md 2>/dev/null`. If it exists, **STOP** and ask the user to run `/ads-iterate` or choose another campaign name.

## Step 2: Scrape product context

Ask for the product/landing-page URL, then use `WebFetch` to extract: product category, primary value prop (H1/hero), stated price, target audience, and available landing pages (pricing, signup, features, blog, guides).

Also read if present: `docs/business/brief.md`, `docs/growth/product-brief.md`, `docs/growth/brand/approved-voice.md`, `docs/growth/strategy.md`, and `docs/seo/`. Do **not** carry SEO keywords into the brief unfiltered — every keyword must pass intent classification in `buyer-intent-targeting`.

## Step 3: Interactive intake — single batched message

Present all 15 questions in ONE numbered message so the user answers in a single block (skip any they want estimated from scraped context):

> Before I can write the brief for `<campaign>`, I need answers to 15 questions. Answer as a numbered list — skip any you want me to estimate from the product context I already scraped.
>
> 1. **Goal**: new signups / trial starts / direct purchases / qualified leads?
> 2. **Audience**: who are we targeting? Role + country + language + stage/size.
> 3. **Markets**: which countries and languages? (list all)
> 4. **Budget**: daily budget, and monthly hard cap?
> 5. **Target CPA or ROAS**: what's the efficiency goal?
> 6. **Commercial landing pages**: URLs where a visitor can actually pay or sign up (NO blogs/guides).
> 7. **Brand name + variants**: exact brand name, misspellings, alternate forms, brand+category combos (for defensive branded ad group).
> 8. **Brand defensive bid cap**: max CPC for branded keywords (typically €0.10–€0.50).
> 9. **Buyer-modifier words**: words paying customers search (e.g., "service", "hire", "pricing", "buy", "book", "near me").
> 10. **Competitors**: 3–5 direct competitors (domain or brand) for Transparency Center differentiation.
> 11. **Forecast baseline (optional)**: known CTR%, CVR%, avg CPC? Leave blank to estimate from SERP.
> 12. **Exclusions**: audiences, query patterns, or geographies to exclude?
> 13. **Conversion tracking + launcher**: is Google Ads conversion tracking configured (yes/no), and who will launch the finished spec in the Ads UI? (design-only — human or growth-hacker launches.)
> 14. **Existing campaigns**: any campaigns already running in this account? List name + status + daily budget (needed to avoid keyword cannibalization and decide Replace / Evolve / Parallel).
> 15. **Language scope**: how many languages from day 1 (e.g., "ET only", "ET + EN", "ET + EN + RU")? Each language gets independent ad groups, copy, and verification.

Wait for the user's block, then derive any skipped fields from scraped context.

## Step 4: Existing campaigns & multilingual scaffold

- **Existing campaigns (Q14)**: if declared, add an `## Existing Campaigns in Account` section in `brief.md` with a `| Campaign | Status | Daily Budget | Overlap Risk |` table (`HIGH/MEDIUM/LOW`) plus the required pre-launch decision: **Replace** (pause old, launch new) / **Evolve** (fold learnings into v1, pause old) / **Parallel** (run both; cannibalization + budget split risk). If the user said "no existing campaigns" while context says otherwise, trust the user but flag for Chrome verification on first `/ads-iterate`.
- **Multi-language (Q15)**: if multiple languages were specified, note them in `brief.md` and scaffold per-language subfolders (`mkdir -p docs/ads/<campaign>/iterations/v1/<lang>` for each language; track language as a column in `hypothesis-log.md`). Single-language campaigns use a flat iteration folder.

## Step 5: Write the brief & tracking blocker

1. `mkdir -p docs/ads/<campaign>/iterations`
2. Write `docs/ads/<campaign>/brief.md` from `${CLAUDE_PLUGIN_ROOT}/templates/campaign-brief.md` using user answers + scraped context. Do **not** embed launched/applied state in `brief.md` (those live in marker files).
3. Write an empty `docs/ads/<campaign>/hypothesis-log.md` (header row only) and stub `docs/ads/<campaign>/learnings.md` (`Last distilled: never`).
4. If conversion tracking is NOT configured (Q13), add under `## Blockers (must resolve before launch)`:
   `- [ ] **Google Ads conversion tracking not configured** — post-launch optimization will be blind. Set up via Google Ads UI → Tools → Conversions (signup, trial start, paid conversion) and install gtag.`

## Step 6: Report back

Report the created path (`docs/ads/<campaign>/brief.md`) with a concise summary: **Goal**, **Audience**, **Markets**, **Budget** (daily / monthly cap), **Target CPA**, **Commercial LPs identified** (count), **Competitors to research**, and **Blockers** count. Next step: run `/ads-iterate` to generate v1 (intent classification, Transparency Center pull, hypothesis, and first verification-ready spec).
