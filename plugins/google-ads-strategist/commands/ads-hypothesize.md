---
name: ads-hypothesize
description: Given the current state of a campaign (pre-launch or post-launch), propose a ranked list of candidate hypotheses for the next iteration — expected impact × confidence. Does NOT write the hypothesis, only suggests. Usage: /ads-hypothesize [campaign]
user_invocable: true
allowed-tools: Read, Glob, Grep, Bash
argument-hint: [campaign]
---

# /ads-hypothesize — Propose candidate next hypotheses

Read the current campaign state and propose 3-5 ranked candidate hypotheses for the next iteration. This is a reasoning command — it does not write to disk.

## Step 0: Load skills

```
Skill('google-ads-strategist:iterative-campaign-design')  # if pre-launch
Skill('google-ads-strategist:iterative-optimization')      # if post-launch
Skill('google-ads-strategist:hypothesis-journaling')
Skill('google-ads-strategist:buyer-intent-targeting')
```

## Step 1: Determine campaign and loop

Detect active campaign. Check for `launched_at` in brief.md to classify as pre-launch or post-launch.

## Step 2: Read prior state

- `brief.md` — goals, budget, constraints
- `learnings.md` — what the advertiser has already learned (high-confidence priors)
- `hypothesis-log.md` — past iterations and outcomes
- `current/spec.md` — the active iteration
- `current/result.md` — the latest verification or metrics
- `current/verification/*` — evidence from last verification

## Step 3: Identify the dominant symptom or gap

**For pre-launch**: run the stop-condition checklist from `iterative-campaign-design`. Which condition(s) failed? Which is the highest-impact to address?

**For post-launch**: run the decision tree from `iterative-optimization`. What is the dominant symptom (high-imp/low-CTR, high-CTR/low-CVR, low-imp-share, high-CPA-specific-keywords, declining-performance)?

## Step 4: Generate 3-5 candidate hypotheses

For each candidate:

```markdown
### Candidate N: [short title]

- **Variable class**: [class]
- **Change**: [exact diff from current]
- **Prediction**: [falsifiable observable]
- **Reasoning**: [why]
- **Expected impact**: [Low | Medium | High]
- **Confidence**: [Low | Medium | High]
- **Blast radius**: [Low | Medium | High]
- **Requires**: [any prerequisites — e.g., "tracking must be configured", "LP variant must exist"]
```

Rank by: **Expected impact × Confidence ÷ Blast radius**. Put the highest-ranked first.

## Step 5: Present the list and ask

```markdown
## Proposed next hypotheses for <campaign> v_{n+1}

Current state: [brief summary]
Dominant symptom: [one-line]

1. [highest-ranked candidate]
2. ...
3. ...

**Recommendation**: candidate 1 — [one-line rationale]

Reply with the candidate number to commit, or ask me to refine. To write the hypothesis.md file, run `/ads-iterate` after choosing.
```

## Notes

- **Never** pick a candidate that would change > 1 variable class (unless you explicitly flag it as multivariate and justify)
- **Never** pick a copy hypothesis if the dominant symptom is CVR (low CVR → LP problem, not copy)
- **Never** pick a bid hypothesis if QS is "Below average" — fix QS first, bids second
- If learnings.md says a specific class of change has failed ≥ 2 times in prior campaigns, exclude that class from the candidate list or flag it as "historically unsuccessful for this advertiser"
