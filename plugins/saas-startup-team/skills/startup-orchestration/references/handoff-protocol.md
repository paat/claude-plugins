# Handoff Protocol Reference

## Structured Handoff Format

Every handoff between founders MUST follow this structure. Free-form handoffs are rejected.

### Required Sections

```markdown
---
from: business-founder | tech-founder
to: tech-founder | business-founder
iteration: N
date: YYYY-MM-DD
type: requirements | implementation | review | feedback
---

## Summary
## Why (Business Justification)    ← REQUIRED for business-to-tech
## What Changed / What's Needed
## Blockers / Questions
## Human Tasks (if any)
## Next Expected Action
```

### Business-to-Tech Requirements

The "Why" section must include at least ONE of:
- Customer pain point (from research)
- Competition analysis finding
- Market research insight
- Revenue/business model justification

If the "Why" section is empty or vague ("because it's needed"), the tech founder should reject the handoff and ask for clarification.

### Scope Limits

Each business-to-tech handoff MUST contain **at most 2 features**. A "feature" is any distinct:
- User-facing capability (e.g., "add CSV import")
- New UI section or page (e.g., "new Step 3 wizard")
- New integration (e.g., "OCR for invoices")
- New data flow (e.g., "AI categorization pipeline")

If a handoff exceeds 2 features:
- The tech founder MUST reject it and request splitting
- The business founder splits into sequential handoffs (e.g., handoff 009 = features A+B, handoff 010 = features C+D)
- Multiple handoffs can belong to the same iteration

Why: A 3+ feature handoff requires 100K+ tokens to implement, triggering context auto-compaction that loses critical details mid-build. Smaller handoffs produce higher-quality implementations.

### Tech-to-Business Implementation Reports

Must include:
- What was built (files changed, architecture decisions)
- How to test (localhost URL, steps to reproduce)
- What the customer will experience (non-technical description)
- Known limitations

### File Naming Convention

```
.startup/handoffs/
├── 001-business-to-tech.md    ← First handoff (initial requirements)
├── 002-tech-to-business.md    ← First implementation report
├── 003-business-to-tech.md    ← Review feedback or next feature
├── 004-tech-to-business.md    ← Second implementation
└── ...
```

Numbers are zero-padded to 3 digits. Always increment by 1. Handoff numbers are independent of iteration numbers — multiple handoffs can belong to the same iteration (e.g., handoffs 009, 010, 011 may all be part of iteration 5).

### Handoff Index (INDEX.md)

When any handoff is written, a PostToolUse hook (`index-handoff.sh`) appends/upserts an entry into `.startup/handoffs/INDEX.md`. Agents and humans should read `INDEX.md` instead of listing the directory — it stays discoverable as handoff count grows past the hundreds.

Format (pipe-separated, one per line):
```
NNN | direction | date | filename | summary
```

Example lookups:
- "Which handoff introduced feature X?" → `grep -i "feature X" .startup/handoffs/INDEX.md`
- "What was the last business-to-tech handoff?" → `grep '| business-to-tech |' .startup/handoffs/INDEX.md | tail -1`

For legacy projects that predate the hook, rebuild the index once with `bash $CLAUDE_PLUGIN_ROOT/scripts/backfill-handoff-index.sh`.

### Enforcement

The canonical format is enforced by a PreToolUse hook (`enforce-handoff-naming.sh`). Writes to `.startup/handoffs/` that don't match `NNN-<direction>.md` with one of the four canonical directions are blocked with an error message that names the next available NNN.

Misrouted content has dedicated homes:
- Signoffs → `.startup/signoffs/`
- Review artifacts (QA, lawyer, UX audit, tribunal, regression) → `.startup/reviews/`
- Binaries and directories → `.startup/attachments/`

For legacy projects with pre-existing non-conforming files, run the one-time migration script:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/migrate-handoff-names.sh          # dry-run, review the plan
bash $CLAUDE_PLUGIN_ROOT/scripts/migrate-handoff-names.sh --apply  # execute
```

The migration moves misrouted content to the right subdirectory and renames residual topic-slug handoffs to `NNN-<direction>.md` with next-available numbers. Sort is by mtime so chronology is preserved.

## Handoff Validation Checklist

### For Business-to-Tech:
- [ ] Frontmatter is complete (from, to, iteration, date, type)
- [ ] Summary is one paragraph (not empty)
- [ ] "Why" section has concrete business justification
- [ ] Requirements have acceptance criteria
- [ ] Maximum 2 features per handoff (reject and request split if 3+)
- [ ] Scope is implementable in one focused session (~50K tokens)
- [ ] Research references point to existing docs in `docs/`

### For Tech-to-Business:
- [ ] Frontmatter is complete
- [ ] Summary is one paragraph
- [ ] Files changed are listed
- [ ] Testing instructions include localhost URL
- [ ] Customer experience is described in non-technical terms
- [ ] No hardcoded secrets — curl examples use `$VAR_NAME`, not literal key values

### For ALL Handoffs:
- [ ] No hardcoded API keys, passwords, tokens, or secrets anywhere in the document
- [ ] Credentials referenced by env var name only (`$OPENROUTER_API_KEY`, `$ADMIN_API_KEY`), never by value
- [ ] Curl/test examples use `$VARIABLE_NAME` in headers, not literal strings
