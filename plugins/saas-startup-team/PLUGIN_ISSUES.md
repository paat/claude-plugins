# Plugin Issues

Issues with the **saas-startup-team plugin itself** — NOT product bugs.

Agents: when you encounter a problem with the plugin (hooks, templates, commands, agent instructions), append it here following the format below.

## What Goes Here

- Hook failures (script errors, wrong exit codes, false positives/negatives)
- Template problems (missing placeholders, wrong frontmatter, bad formatting)
- Agent instruction gaps (unclear rules, missing guidance, contradictory directives)
- MCP integration issues (Playwright connection failures, tool name mismatches)
- state.json schema problems (missing fields, wrong types, race conditions)
- Command issues (/startup flow bugs, missing steps, wrong sequencing)

## What Does NOT Go Here

- SaaS product bugs (broken UI, server errors, wrong business logic)
- UX feedback on the product being built
- Feature requests for the product
- Human tasks (company registration, domain setup, payments)

## Format

```markdown
### [CATEGORY] Title

- **Found by**: business-founder | tech-founder
- **When**: During iteration N, phase X
- **Expected**: What should have happened
- **Actual**: What actually happened
- **Severity**: blocker | major | minor
```

Categories: `HOOK`, `TEMPLATE`, `AGENT`, `MCP`, `STATE`, `COMMAND`

## Issues

<!-- Agents: append new issues below this line -->
