---
name: ads-diff
description: Show what changed between two iterations of a campaign — the diff across keywords, copy, targeting, bids, and landing pages — plus the hypothesis that drove the change. Usage: /ads-diff [campaign] <v_a> <v_b>
user_invocable: true
allowed-tools: Read, Bash, Glob, Grep
argument-hint: [campaign] <v_a> <v_b>
---

# /ads-diff — Compare two iterations

Show the clean diff between two iterations, with the hypothesis that motivated the change and the result.

## Step 1: Parse arguments

If only two arguments are passed (e.g., `v2 v3`), detect the campaign from `docs/ads/*/brief.md`. If multiple campaigns exist, ask which one.

## Step 2: Read the iterations

```bash
docs/ads/<campaign>/iterations/<v_a>/spec.md
docs/ads/<campaign>/iterations/<v_b>/spec.md
docs/ads/<campaign>/iterations/<v_b>/hypothesis.md
docs/ads/<campaign>/iterations/<v_b>/result.md   # if exists
```

If either iteration is missing, STOP and tell the user which ones exist.

## Step 3: Produce the diff

Parse each spec.md and extract the structured data:
- Ad groups and their keywords (with match types)
- RSAs (headlines, descriptions, pinning)
- Targeting (location, language, device)
- Bidding strategy + budget
- Landing page per ad group
- Extensions

Compare the two and categorize each change by variable class:

```markdown
## Diff: <v_a> → <v_b>

**Variable class changed**: [keywords | copy | targeting | landing-page | bidding | extensions | MULTIVARIATE]

### Keywords
- Added: [list]
- Removed: [list]
- Match type changed: [list]

### Copy (RSAs)
- Headlines added: [list]
- Headlines removed: [list]
- Descriptions changed: [list]
- Pinning changes: [list]

### Targeting
- [any changes]

### Landing pages
- [any changes]

### Bidding
- [any changes]

### Extensions
- [any changes]
```

## Step 4: Show the hypothesis

Read `iterations/<v_b>/hypothesis.md` and display:

```markdown
## Hypothesis for <v_b>

**Variable class**: [class]
**Change from <v_a>**: [diff description]
**Prediction**: [what was expected]
**Reasoning**: [why]
**Evidence needed**: [what would confirm]
```

## Step 5: Show the result (if exists)

Read `iterations/<v_b>/result.md` and display:

```markdown
## Result for <v_b>

**Verified**: [date]
**Hypothesis held**: [YES | NO | PARTIAL]
**What actually happened**: [summary]
**Learning candidate**: [if any]
```

If `result.md` doesn't exist yet, note: "v_b is still pending verification — run `/ads-verify` or `/ads-iterate` to produce the result."

## Step 6: Check the single-variable rule

If the diff shows changes across more than one variable class, flag it:

```markdown
⚠ **MULTIVARIATE change detected** — this iteration modified more than one variable class.
Confounded attribution — cannot cleanly ascribe the result to either change.
Check iterations/<v_b>/hypothesis.md for a --multivariate marker + justification.
```

## Notes

- This is a read-only command — it never writes to disk
- If the comparison is between v1 and a much later iteration (e.g., v1 vs v7), the diff will be large — in that case also show a note: "Large diff — this compares non-adjacent iterations. For iteration-by-iteration history, run /ads-distill or read the hypothesis-log."
