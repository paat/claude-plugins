---
name: ads-distill
description: Roll the hypothesis log into the learnings file — distill patterns that hold across ≥ 3 iterations into principles, and propose graduation candidates for project-level auto-memory. Usage: /ads-distill [campaign]
user_invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: [campaign]
---

# /ads-distill — Distill hypothesis log into learnings

Take the append-only `hypothesis-log.md`, find patterns that hold across ≥ 3 iterations (or ≥ 2 campaigns), and write them as principles into `learnings.md`. Propose graduation candidates for project-level auto-memory.

## Step 0: Load skill

```
Skill('google-ads-strategist:hypothesis-journaling')
```

## Step 1: Determine campaign

Detect active or ask which campaign. Must have ≥ 3 iterations with result.md to distill meaningfully — otherwise report "Not enough data yet (need ≥ 3 completed iterations)".

## Step 2: Read inputs

- `docs/ads/<campaign>/hypothesis-log.md`
- Every `iterations/vN/result.md`
- Current `learnings.md`
- `docs/ads/*/learnings.md` across OTHER campaigns (for cross-campaign patterns)
- Project memory at `/config/.claude/projects/*/memory/MEMORY.md` — check what's already graduated

## Step 3: Find patterns

### Intra-campaign patterns (within this campaign)

For each variable class, look for:
- **Consistent wins**: 3+ iterations in the same variable class all HELD — that's a principle
- **Consistent fails**: 3+ iterations in the same class all NO — that's an anti-principle ("X doesn't work here")
- **Scope constraints**: if wins only held for a specific audience/language/device, tag the scope

### Cross-campaign patterns (across ≥ 2 campaigns)

- A principle that held in campaign A AND in campaign B for the same advertiser is a graduation candidate
- A principle that only held in one campaign stays campaign-local

## Step 4: Write/update learnings.md

Update the existing file (don't overwrite — learnings accumulate):

```markdown
# Learnings — <campaign>

Last distilled: YYYY-MM-DD from vN

## What works
- [principle] — scope: [context] — evidence: [v# references]

## What does not work
- [principle] — scope: [context] — evidence: [v# references]

## Open questions
- [untested]

## Promoted to project memory
- [graduated entries]
```

## Step 5: Propose graduation candidates

If cross-campaign patterns exist, show them to the user:

```markdown
## Graduation candidates (require user approval)

These patterns held across multiple campaigns and are candidates for promotion to project auto-memory:

1. **[Principle]**
   - Evidence: [campaign A v3, v5; campaign B v2, v4]
   - Proposed memory file: `ads_<slug>.md`
   - Type: project

2. ...

Approve any (e.g., "yes 1 2") and I'll write them to `/config/.claude/projects/<project>/memory/` and update MEMORY.md.
```

DO NOT auto-write project memory — user must confirm, because project memory survives across sessions and subtly shapes future decisions.

## Step 6: On approval

For each approved candidate:

1. Write `/config/.claude/projects/<project>/memory/ads_<slug>.md`:

```markdown
---
name: <Principle name>
description: <one-line for index>
type: project
---

<principle statement>

**Why:** [evidence — cite campaign references]

**How to apply:** [when/where this kicks in for future PPC work]
```

2. Append to `/config/.claude/projects/<project>/memory/MEMORY.md`:

```markdown
- [<Principle name>](ads_<slug>.md) — <one-line hook>
```

3. Add a line to `learnings.md` under "Promoted to project memory" section with the memory filename and date.

## Notes

- Never graduate from a single-campaign observation — requires cross-campaign evidence
- Never graduate "campaign X CPA improved after Y" — those are diffs, not principles. Principles are stated as rules about HOW things work for this advertiser.
- Keep learnings.md append-only in structure — don't rewrite past entries, add new ones on top
