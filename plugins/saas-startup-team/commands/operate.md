---
name: operate
description: "Post-launch operations. Usage: /operate [status|monitor|investigate|replay|support]"
argument-hint: "[monitor|investigate|replay|support|status] [args]"
allowed-tools: Bash, Read, Write, Grep, Glob, Task
user_invocable: true
transitional: true
---

# /operate

Load `${CLAUDE_PLUGIN_ROOT}/skills/operate/SKILL.md` with `$ARGUMENTS`.
Config: `operate:` in `.claude/saas-startup-team.local.md` only. Do not create
`.startup/operate.yml`.

Modes: `status`, `monitor`, `investigate`, `replay`, `support`.
Support uses `subagent_type: "saas-startup-team:support-triage"`; the supervisor runs
issue filing when `--file-issues` is set.
