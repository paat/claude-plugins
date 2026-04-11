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

Detect active campaign (or ask if ambiguous). Verify it's in pre-launch mode (no `launched_at` in brief.md). If already launched, use `/ads-metrics` instead.

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
- [ ] A SERP capture exists in `verification/serp-*.png` for every target keyword
- [ ] A competitor copy matrix exists in `verification/transparency-*.md` for each listed competitor
- [ ] The RSA assets occupy whitespace identified in the matrix (at least 2 headlines are differentiated)

### 5. Landing page alignment
- [ ] LP URL is a commercial page (pricing, signup, checkout) — NOT a blog post or guide
- [ ] LP H1 repeats primary ad headline's value prop
- [ ] LP CTA verb matches ad CTA verb
- [ ] PageSpeed Insights mobile score ≥ threshold (run via WebFetch if not checked yet)

### 6. Message match
- [ ] Ad copy promise matches LP first impression
- [ ] Price in ad (if shown) matches price on LP
- [ ] Audience framing in ad matches audience framing on LP

### 7. Tracking + budget
- [ ] `conversion_tracking_configured: true` in brief.md
- [ ] `approved_budget: <value>` in brief.md
- [ ] `target_cpa` or `target_roas` in brief.md

### 8. Hypothesis closed
- [ ] `current/result.md` exists
- [ ] `result.md` states hypothesis held or documents why it was superseded
- [ ] `hypothesis-log.md` has an entry for every iteration

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
- READY WITH CAVEATS is allowed only if failures are all in category 7 (tracking/budget) — those are human prerequisites, not ad design issues
- If multiple conditions fail, pick the MOST critical one and show it prominently in the recommendation
