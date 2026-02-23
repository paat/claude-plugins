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

Numbers are zero-padded to 3 digits. Always increment by 1.

## Handoff Validation Checklist

### For Business-to-Tech:
- [ ] Frontmatter is complete (from, to, iteration, date, type)
- [ ] Summary is one paragraph (not empty)
- [ ] "Why" section has concrete business justification
- [ ] Requirements have acceptance criteria
- [ ] Research references point to existing docs in `.startup/docs/`

### For Tech-to-Business:
- [ ] Frontmatter is complete
- [ ] Summary is one paragraph
- [ ] Files changed are listed
- [ ] Testing instructions include localhost URL
- [ ] Customer experience is described in non-technical terms
