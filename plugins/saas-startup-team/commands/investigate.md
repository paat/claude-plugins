---
name: investigate
description: "Operate investigate mode. Usage: /investigate {CID|--recent N}"
argument-hint: "{CID | --recent N} [--dry-run] [--no-file-issues]"
allowed-tools: Bash, Read, Write, Grep, Glob, Task
user_invocable: true
transitional: true
---

# /investigate

Load `${CLAUDE_PLUGIN_ROOT}/skills/operate/SKILL.md` mode `investigate`.
Use `subagent_type: "saas-startup-team:incident-investigator"` when spawning.
Supervisor files a deduplicated GitHub issue only with explicit `--file-issues`.
