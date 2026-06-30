---
name: ads-audit
description: Read-only audit for an existing Google Ads account or campaign before takeover, scaling, or iteration. Produces severity-rated findings with evidence and follow-up hypotheses.
user_invocable: true
allowed-tools: Task, Read, Write, Glob, Grep, Bash, WebFetch
argument-hint: "[account|campaign] [--tracking] [--search-terms] [--creative] [--budget]"
---

# /ads-audit - Existing Account Audit

Audit an existing Google Ads account or campaign. This command is read-only: do not create, edit, pause, enable, delete, or apply changes in Google Ads.

## Step 0: Load skills

```
Skill('google-ads-strategist:buyer-intent-targeting')
Skill('google-ads-strategist:browser-verification')
Skill('google-ads-strategist:iterative-optimization')
```

## Step 1: Determine scope

Parse arguments:

- `account` - account-level audit.
- `campaign` - campaign-level audit.
- `--tracking` - emphasize measurement readiness.
- `--search-terms` - emphasize query hygiene and negatives.
- `--creative` - emphasize RSA/assets/message match.
- `--budget` - emphasize budget, bidding, learning-period, and spend concentration.

If ambiguous, ask which account/campaign to audit and where current evidence lives.

## Step 2: Gather evidence

Use the `ads-strategist` agent via `Task` for Chrome/browser evidence collection. Pass the scope, requested audit flags, and the read-only boundary explicitly: the agent may inspect Google Ads, SERPs, landing pages, exports, and screenshots, but must not create, edit, pause, enable, delete, apply, or navigate billing.

Optional API/MCP data may be used only when already configured and read-only. If browser or account access is unavailable, record the access gap and do not rate high/critical findings from assumptions.

Collect evidence for:

### Tracking and measurement readiness
- Conversion actions exist and primary/secondary status is sane.
- GA4/GTM linkage is visible where inspectable.
- Final URLs have a UTM strategy.
- Landing pages are commercial, not informational.
- Conversion volume supports the selected bidding strategy.

### Account and campaign structure
- Branded and non-branded traffic are separated.
- Campaign/ad group names follow a usable taxonomy.
- Search network, search partners, display network, location, language, and device settings match the brief.

### Keyword and query hygiene
- Match-type mix is intentional.
- Negative keyword coverage blocks informational spend.
- Search-term waste candidates are identified when visible.

### Creative and assets
- RSA headline/description coverage is sufficient.
- Angles are not weak, duplicated, or mismatched to the landing page.
- Extensions/assets are present where useful.
- SERP/competitor observations reuse `/ads-spy` style evidence when relevant.

### Budget and bidding
- Budget-constrained campaigns are identified.
- Learning-period violations are called out.
- CPC/CPA sanity is compared to approved budget and target economics.
- Spend concentration risks are visible.

## Step 3: Write audit artifact

Write to one of:

```text
docs/ads/<campaign>/audit/YYYY-MM-DD.md
docs/ads/_account-audits/YYYY-MM-DD.md
```

Also create an `evidence/` subdirectory when screenshots or exports are captured.

Report format:

```markdown
# Google Ads Audit - <account-or-campaign>

**Scope:** account | campaign
**Mode:** read-only
**Date:** YYYY-MM-DD

## Executive Summary

## Severity-Rated Findings

### CRITICAL/HIGH/MEDIUM/LOW - <finding>
**Evidence:** <screenshot/export/path/browser observation>
**Impact:** <projected impact only where defensible>
**Fix:** <exact fix instructions>
**Follow-up hypothesis:** <single-variable test suitable for /ads-iterate>

## Measurement Readiness

## Query Hygiene

## Creative and Landing Page Match

## Budget and Bidding

## Next Actions
```

Every high/critical finding must include a concrete evidence source. If evidence is unavailable, downgrade the certainty and state what access is needed.

## Step 4: Feed the iteration loop

For each actionable finding, write a one-variable hypothesis that can feed `/ads-iterate`. Do not apply changes during the audit.

## Safety

- Never mutate the account.
- Never click enable/resume/status-change controls.
- Never navigate billing.
- Never fabricate metrics.
- Never mark a finding high/critical without evidence.
