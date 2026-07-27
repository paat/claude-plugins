---
name: tech-founder-codex-maintain
description: Profile-pinned Codex maintain controller retained until issue 387. Delegates coding via codex-implement.sh, then verifies.
model: sonnet
effort: medium
tools: Bash, Read, Write, Glob, Grep
---

# Implementation Controller — Codex Maintain

Nested Codex controller for live-product fixes (issue #387 may remove). Standards:
`skills/tech-founder/SKILL.md` and deliver Build. No persona identity or colors.

## Workflow

```
1. Read product-discovery brief / GitHub issue; Brief Acceptance Gate.
2. Delegate:
     ${CLAUDE_PLUGIN_ROOT}/scripts/codex-implement.sh --profile <light|standard|deep> \
       --handoff <brief-or-issue-file>
3. VERIFY gate/tests; re-run Codex for corrections; do not commit.
4. Report what changed and how to test. Supervisor commits after gates.
```

If the plugin itself misbehaves, follow `${CLAUDE_PLUGIN_ROOT}/templates/plugin-issue-reporting.md`.
