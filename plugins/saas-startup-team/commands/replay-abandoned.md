---
name: replay-abandoned
description: "Operate replay mode. Usage: /replay-abandoned [--dry-run]"
argument-hint: "[--band NAME] [--max N] [--dry-run] [--no-file-issues]"
allowed-tools: Bash, Read, Write, Grep, Glob, Task
user_invocable: true
transitional: true
---

# /replay-abandoned

Load `${CLAUDE_PLUGIN_ROOT}/skills/operate/SKILL.md` mode `replay`.
Use `subagent_type: "saas-startup-team:session-replay"` when spawning.
Emit structured `finding.json` for build-track follow-up.
