---
name: monitor
description: "Operate monitor mode. Usage: /monitor [section] [--dry-run]"
argument-hint: "[sessions|payments|health|costs|traffic|funnel|support|all] [--dry-run]"
allowed-tools: Bash, Read, Write, Grep, Glob
user_invocable: true
transitional: true
---

# /monitor

Load `${CLAUDE_PLUGIN_ROOT}/skills/operate/SKILL.md` mode `monitor` with `$ARGUMENTS`.
Engine: `scripts/monitor-dedup.sh`. Config from `monitor:` / `operate:` blocks.
