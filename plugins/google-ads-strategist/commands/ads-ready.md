---
name: ads-ready
description: Audit the current iteration against the launch-readiness checklist. Does NOT launch — only reports pass/fail per condition, with evidence links. Usage: /ads-ready [campaign]
user_invocable: true
allowed-tools: Read, Glob, Grep, Bash
argument-hint: [campaign]
---

# /ads-ready — Launch-readiness audit

Run the pre-launch stop-condition checklist from `iterative-campaign-design` against the current iteration. Report pass/fail for each condition with evidence.

## Step 0: Load skills

```
Skill('google-ads-strategist:iterative-campaign-design')
Skill('google-ads-strategist:buyer-intent-targeting')
```

## Step 1: Determine campaign

Detect active campaign (or ask if ambiguous). Verify it's in pre-launch mode (no `launched_at` marker file in the campaign directory). If already launched, use `/ads-metrics` instead.

## Step 2: Read the current iteration

- `current/spec.md`
- `current/hypothesis.md`
- `current/result.md` (if exists)
- `current/verification/*`

## Step 3: Run the checklist

For each condition, check and report:

### 0. Revenue rails (non-negotiable)
- [ ] Every final URL in spec.md contains `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, and `utm_term` (at least). Grep proves it: `grep -c 'utm_source=google' spec.md` should equal keyword count.
- [ ] If `brand_name` is set in brief.md, an ad group named `AG_branded_defensive` exists in spec.md with at least the exact-match brand keyword and an "Official Site" RSA.
- [ ] `iterations/<current>/forecast.md` exists and states daily_clicks ≥ 10 (or explicit acknowledgement of slow-learning mode).
- [ ] `iterations/<current>/negatives.md` exists with ≥ 20 preloaded informational negatives per language.

### 1. Buyer-intent classification (prerequisite)
- [ ] Every keyword in spec.md is tagged with an intent class
- [ ] Zero keywords are classified informational
- [ ] Commercial-investigation and transactional keywords are in separate ad groups
- [ ] Default informational negatives are present in the negative list
- [ ] Language-specific negatives added for every target language

### 2. Trigger coverage
- [ ] Every target keyword has a preview screenshot in `verification/preview-*.png`
- [ ] Every screenshot shows the ad visible (position ≤ N)
- [ ] Coverage includes all target locations × devices combinations

### 3. Position
- [ ] Average ad position across target keywords ≤ 3 in the preview
- [ ] No target keyword shows position > 4

### 4. Copy differentiation
- [ ] A SERP capture exists in `verification/serp-*` (.png screenshot or .md structured extraction) for every target keyword
- [ ] A competitor copy matrix exists in `verification/transparency-*.md` for each listed competitor
- [ ] The RSA assets occupy whitespace identified in the matrix (at least 2 headlines are differentiated)

### 4b. Ad extensions
- [ ] Each ad group has at least 4 sitelinks if competitor SERP captures show sitelinks
- [ ] At least 4 callout extensions per ad group
- [ ] At least 1 structured snippet per ad group
- [ ] If price is a differentiator (from competitor matrix), price extensions are present

### 5. Landing page alignment
- [ ] LP URL is a commercial page (pricing, signup, checkout) — NOT a blog post or guide
- [ ] LP H1 repeats primary ad headline's value prop
- [ ] LP CTA verb matches ad CTA verb
- [ ] PageSpeed Insights mobile score ≥ threshold (run via WebFetch if not checked yet)

### 5b. Landing page voice compliance
For each unique LP URL in spec.md, fetch the page content and check:
- [ ] No fear-selling language (fines, penalties, legal threats used to pressure purchase)
- [ ] Price shown on LP matches price in ad copy (no bait-and-switch)
- [ ] No claims that contradict ad copy (ad says "15 min", LP says "1 hour")
- [ ] If the project defines a brand voice document or memory rule about voice/tone, cross-reference and enforce its rules

Flag violations as **HIGH BLOCKER** — fear-selling or voice violations must be fixed before launch, not noted as caveats.

### 6. Message match
- [ ] Ad copy promise matches LP first impression
- [ ] Price in ad (if shown) matches price on LP
- [ ] Audience framing in ad matches audience framing on LP

### 7. Tracking + budget
- [ ] `conversion_tracking_configured: true` in brief.md
- [ ] `approved_budget: <value>` in brief.md
- [ ] `target_cpa` or `target_roas` in brief.md

### 7b. Conversion infrastructure readiness (if tracking uses offline conversions)
If the campaign relies on offline conversion upload (GCLID → API), check:
- [ ] GCLID capture code is deployed to production (not just merged — verify the LP actually stores gclid from URL params)
- [ ] Google Ads developer token is active (not "pending" or "test")
- [ ] Conversion action exists in Google Ads account (name matches what backend expects)
- [ ] Required environment variables are set on production (not just in .env.example)
- [ ] End-to-end test: fake conversion uploaded and visible in Google Ads within 24h

If any of these fail, flag as **MEDIUM BLOCKER** — the campaign can launch with Manual CPC but post-launch optimization will be blind without conversion data. Note in the report that the post-launch loop cannot begin until tracking is verified.

### 8. Hypothesis closed
- [ ] `current/result.md` exists
- [ ] `result.md` states hypothesis held or documents why it was superseded
- [ ] `hypothesis-log.md` has an entry for every iteration (the `check-hypothesis-log.sh` hook enforces this on write, but verify here in case of manual edits)

### 9. Existing campaign conflict check
If brief.md lists existing campaigns in the account (from Q14 of `/ads-brief`):
- [ ] Decision recorded: Replace / Evolve / Parallel
- [ ] If Replace: existing campaign will be paused before this one enables
- [ ] If Parallel: no keyword overlap between campaigns (grep both specs for shared exact-match keywords)
- [ ] If Evolve: learnings from old campaign incorporated into hypothesis-log.md

## Step 4: Produce the report

```markdown
# Launch-readiness audit — <campaign> <current-version>

**Status**: [READY | NOT READY | READY WITH CAVEATS]

## Checklist
| # | Condition | Pass | Evidence |
|---|-----------|------|----------|
| 1.1 | Buyer-intent classified | ✅ | spec.md intent column |
| 1.2 | Zero informational | ✅ | — |
| 2.1 | Trigger coverage | ❌ | 3/10 keywords missing preview |
| ... | ... | ... | ... |

## Failures
- [condition] — [what's missing] — [how to fix]

## Recommendation
- [READY → hand off to human/launcher] OR
- [NOT READY → run /ads-iterate to address failures]

## If READY, next step
- Campaign spec is at: `docs/ads/<campaign>/current/spec.md`
- Hand off to growth-hacker or human launcher for manual campaign creation in Google Ads UI
- The ads-strategist will not launch autonomously
```

## Notes

- NEVER mark READY if any Pass column is ❌
- READY WITH CAVEATS is allowed only if failures are all in categories 4b/7/7b/9 (extensions/tracking/budget/existing campaign) — those are human prerequisites or incremental improvements, not core ad design issues
- Section 5b (LP voice compliance) failures are HIGH BLOCKERs — NEVER mark READY WITH CAVEATS for voice violations
- If multiple conditions fail, pick the MOST critical one and show it prominently in the recommendation
