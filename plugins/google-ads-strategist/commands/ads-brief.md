---
name: ads-brief
description: Start a new Google Ads campaign by creating the brief.md + folder structure. Interactive intake that captures product, audience, commercial pages, budget, goals, and buyer-intent context. Usage: /ads-brief [campaign-name]
user_invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, WebFetch
argument-hint: [campaign-name]
---

# /ads-brief — Create a Google Ads campaign brief

You are setting up a new Google Ads campaign. The output of this command is a `docs/ads/<campaign>/brief.md` file and the full iteration folder skeleton, ready for `/ads-iterate` to take over.

## Step 0: Load the critical skills

```
Skill('google-ads-strategist:buyer-intent-targeting')
Skill('google-ads-strategist:iterative-campaign-design')
```

## Step 1: Determine the campaign name

If the user passed an argument, use it (kebab-case). If not, ask:

> What should we call this campaign? Short kebab-case slug, e.g., `aruannik-commercial-ee` or `acme-signup-us`.

## Step 2: Check for existing brief

```bash
ls docs/ads/<campaign>/brief.md 2>/dev/null
```

If it exists, STOP and ask:

> A brief for `<campaign>` already exists. Run `/ads-iterate` to continue the existing campaign, or choose a different campaign name.

## Step 3: Scrape the product context (if a URL is available)

Ask the user:

> What is the URL of the product / landing page we're promoting?

Then use `WebFetch` to pull the page and extract:
- Product category
- Primary value proposition (from the H1 or hero)
- Stated price (if any)
- Target audience (from copy tone + any "for X" mentions)
- Available landing pages (pricing, signup, features, blog, guides)

Also read (if they exist):
- `docs/business/brief.md`
- `docs/growth/product-brief.md`
- `docs/growth/brand/approved-voice.md`
- `docs/growth/strategy.md`
- `docs/seo/` — SEO research may already have keyword lists and intent classifications

Do NOT assume the project's existing SEO keywords are the right PPC keywords — SEO often targets informational queries. The strategist must reclassify every keyword by buyer intent before using it.

## Step 4: Interactive intake — single batched message

Present all 15 questions in ONE numbered message so the user can answer in a single block. This is faster than sequential interrogation and the answers don't depend on each other.

> Before I can write the brief for `<campaign>`, I need answers to 15 questions. Answer as a numbered list — skip any you want me to estimate from the product context I already scraped.
>
> 1. **Goal**: new signups / trial starts / direct purchases / qualified leads?
> 2. **Audience**: who are we targeting? Role + country + language + stage/size.
> 3. **Markets**: which countries and languages? (list all)
> 4. **Budget**: daily budget, and monthly hard cap?
> 5. **Target CPA or ROAS**: what's the efficiency goal?
> 6. **Commercial landing pages**: list the URLs where a visitor can actually pay or sign up. Do NOT include blogs or guides — those are never valid PPC destinations.
> 7. **Brand name + variants**: exact brand name, plus misspellings / alternate forms / brand+category combos (for the defensive branded ad group).
> 8. **Brand defensive bid cap**: max CPC for branded keywords (typically €0.10-€0.50 — own traffic should be cheap to recapture).
> 9. **Buyer-modifier words**: what words do paying customers use when searching? (e.g., "service", "hire", "pricing", "buy", "book", "near me")
> 10. **Competitors**: 3-5 direct competitors (domain or brand) — I'll pull their currently-running ads from the Transparency Center for the differentiation matrix.
> 11. **Forecast baseline (optional)**: known CTR%, CVR%, avg CPC? Leave blank and I'll estimate from the competitor SERP.
> 12. **Exclusions**: any audiences, query patterns, or geographies to exclude?
> 13. **Conversion tracking + launcher**: is Google Ads conversion tracking configured (yes/no), and who will take the finished spec and launch it in the Ads UI? (design-only — human or growth-hacker launches.)
> 14. **Existing campaigns**: are there any campaigns already running in this Google Ads account? If yes, list them (name + status + daily budget). We need to know to avoid keyword cannibalization and to decide whether to replace, evolve, or run in parallel.
> 15. **Language scope**: how many languages should this campaign cover from day 1? (e.g., "ET only", "ET + EN", "ET + EN + RU"). Each language gets its own ad groups, copy, and verification loop. More languages = more iteration cycles before launch-ready.

Wait for the user's numbered block, then derive missing fields from the scraped product context.

## Step 4b: Validate existing campaigns (if declared)

If the user reported existing campaigns (Q14), write a prominent section in the brief:

```markdown
## Existing Campaigns in Account

| Campaign | Status | Daily Budget | Overlap Risk |
|----------|--------|-------------|--------------|
| [name] | [status] | [budget] | [HIGH/MEDIUM/LOW — based on keyword overlap with this campaign's targets] |

**Decision required before launch**: Replace / Evolve / Run in parallel?
- Replace: pause the old campaign, launch this one
- Evolve: incorporate old campaign learnings into v1, then pause old
- Parallel: run both (risk: keyword cannibalization, budget split)
```

If the user said "no existing campaigns" but `brief.md` claims "account not yet created," trust the user's answer but flag the discrepancy — the strategist should verify in Chrome on first `/ads-iterate` run.

## Step 4c: Scaffold multilingual structure (if multi-language)

If the user specified multiple languages (Q15), note this in the brief and create per-language iteration subfolders in v1:

```bash
for lang in et en ru; do
  mkdir -p docs/ads/<campaign>/iterations/v1/$lang
done
```

Each language gets independent keyword lists, copy, and verification. The hypothesis-log.md tracks language as a column. If the user chose single-language, skip this — flat iteration structure is fine.

## Step 5: Write the brief

Create the folder structure:

```bash
mkdir -p docs/ads/<campaign>/iterations
```

Write `docs/ads/<campaign>/brief.md` using the template at `${CLAUDE_PLUGIN_ROOT}/templates/campaign-brief.md`. Fill in every section from the user's answers + scraped product context. Do NOT embed launched/applied state in the brief — those live in separate marker files (see template comment).

Write an empty `docs/ads/<campaign>/hypothesis-log.md` with just the header row.

Write a stub `docs/ads/<campaign>/learnings.md` with the "Last distilled: never" header.

## Step 6: Flag tracking setup as a human task (if not configured)

If the user said conversion tracking is not set up, write a prominent warning to the brief under "Blockers":

```markdown
## Blockers (must resolve before launch)

- [ ] **Google Ads conversion tracking not configured** — any post-launch optimization will be blind. Set up via Google Ads UI → Tools → Conversions. Track: signup, trial start, paid conversion. Add the gtag to the site.
```

## Step 7: Report back

Show the user:

> Brief for **<campaign>** ready at `docs/ads/<campaign>/brief.md`.
>
> Quick summary:
> - **Goal**: [goal]
> - **Audience**: [audience]
> - **Markets**: [languages and countries]
> - **Budget**: [daily] daily / [cap] monthly cap
> - **Target CPA**: [cpa]
> - **Commercial LPs identified**: [count] pages
> - **Competitors to research**: [list]
> - **Blockers**: [count] (see brief.md)
>
> **Next step**: run `/ads-iterate` to generate v1 of the campaign — the strategist will classify candidate keywords by buyer intent, pull competitor ads from the Transparency Center, write a hypothesis, and produce the first verification-ready spec.
