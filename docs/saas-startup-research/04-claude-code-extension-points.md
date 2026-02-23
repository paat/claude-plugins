# Claude Code Extension Points

## Overview

Claude Code provides a comprehensive extension system through plugins, which bundle multiple extension points into distributable packages.

## Plugin Manifest (`.claude-plugin/plugin.json`)

Every plugin requires a manifest:
```json
{
  "name": "plugin-name",
  "version": "0.1.0",
  "description": "Human-readable description",
  "author": { "name": "Author Name" },
  "repository": "https://github.com/...",
  "license": "MIT",
  "keywords": ["generic", "project-agnostic", "terms"]
}
```

## Hook Events

Claude Code fires hooks at specific lifecycle points. Hooks can run shell commands or inject prompts.

### All 17 Hook Events

| Event | When It Fires | Can Block? |
|-------|---------------|------------|
| `SessionStart` | Session begins or resumes | No |
| `UserPromptSubmit` | User submits prompt, before processing | Yes |
| `PreToolUse` | Before tool call executes | Yes (allow/deny/ask) |
| `PermissionRequest` | When permission dialog appears | Yes |
| `PostToolUse` | After tool call succeeds | No (feedback only) |
| `PostToolUseFailure` | After tool call fails | No |
| `Notification` | When Claude sends notification | No |
| `SubagentStart` | When subagent spawned | No (context injection) |
| `SubagentStop` | When subagent finishes | Yes |
| `Stop` | When main agent finishes responding | Yes |
| `TeammateIdle` | When agent team teammate about to idle | Yes |
| `TaskCompleted` | When task marked completed | Yes |
| `ConfigChange` | When config file changes during session | Yes |
| `WorktreeCreate` | When worktree created | Yes |
| `WorktreeRemove` | When worktree removed | No |
| `PreCompact` | Before context compaction | No |
| `SessionEnd` | When session terminates | No |

### Hook Types

| Type | Description |
|------|-------------|
| `command` | Run a shell command. Exit 0 = pass, exit 2 = block with feedback. Receives JSON on stdin. |
| `prompt` | Single-turn LLM evaluation returning `{ok: true/false}`. Output becomes feedback. |
| `agent` | Spawns subagent with tool access (Read, Grep, Glob) for multi-turn verification. |

### Hook Configuration
```json
{
  "hooks": {
    "EventName": [
      {
        "matcher": "regex-for-tool-name",  // Optional, for tool-specific hooks
        "hooks": [
          {
            "type": "command",
            "command": "path/to/script.sh",
            "description": "Human-readable description"
          }
        ]
      }
    ]
  }
}
```

## Skills

Skills are markdown documents that provide domain knowledge and workflows. They activate based on description triggers.

### Skill Structure
```
skills/
└── skill-name/
    ├── SKILL.md           # Main skill document with frontmatter
    └── references/        # Supporting documentation
        └── *.md
```

### SKILL.md Format
```yaml
---
name: skill-name
description: When to use this skill (trigger phrases, contexts)
---

# Skill Title

[Comprehensive documentation of the workflow, patterns, and guidance]
```

Skills auto-activate when their description matches the current context. The description field is the primary trigger mechanism.

## Agents (Teammates)

Agent definitions describe specialized team members for Agent Teams.

### Agent Format
```yaml
---
name: agent-name
description: What this agent does and when to use it
model: opus | sonnet | haiku
color: blue | green | magenta | cyan | yellow | red
tools: Bash, Read, Write, Edit, Glob, Grep, ...
---

# Agent Name

[Agent capabilities, guidelines, ALWAYS/NEVER rules]
```

### Tool Access
Each agent can be given a specific subset of tools:
- Code tools: Bash, Read, Write, Edit, Glob, Grep
- Research tools: WebSearch, WebFetch, Task
- Browser tools: mcp__claude-in-chrome__* (all Chrome MCP tools)
- Coordination tools: TaskCreate, TaskUpdate, TaskList, TaskGet

## Commands (Slash Commands)

User-invocable commands that appear as `/plugin-name:command-name`.

### Command Format
```yaml
---
name: command-name
description: What the command does
user_invocable: true
---

# /command-name — Title

[Instructions for what Claude should do when this command is invoked]
```

Commands live in `commands/*.md` and are invoked via the Skill tool.

## MCP Servers

Plugins can declare MCP (Model Context Protocol) servers for external tool integration.

```json
{
  "mcpServers": {
    "server-name": {
      "type": "http",
      "url": "http://localhost:PORT"
    }
  }
}
```

MCP servers expose additional tools that agents can call, extending capabilities beyond built-in tools.

## Settings

Plugin-level settings including environment variables:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

## Scripts

Shell scripts in `scripts/` that hooks and commands can reference:
- Must be executable (`chmod +x`)
- Referenced via `${CLAUDE_PLUGIN_ROOT}/scripts/script.sh`
- Should handle stdin JSON for hook inputs
- Exit codes: 0 = success, 2 = block with feedback message

## Agent Teams (Experimental)

Enables multi-agent coordination with:
- Team lead (main session) + teammates (parallel sessions)
- Shared task list with dependency tracking
- Inter-agent mailbox messaging
- TeammateIdle and TaskCompleted hooks for quality gates
- Delegate mode (Shift+Tab) restricts lead to coordination only

Requires: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`

## Extension Point Combinations Used in Our Plugin

| Extension Point | Our Usage |
|-----------------|-----------|
| Plugin manifest | Metadata and distribution |
| Settings | Enable Agent Teams via env var |
| Agents | Business founder + tech founder definitions |
| Skills | 3 skill bundles (orchestration, business, tech) |
| Commands | /startup, /status, /nudge |
| Hooks | TeammateIdle, TaskCompleted, Stop |
| Scripts | check-idle.sh, check-task-complete.sh, status.sh |
| Templates | Handoff templates, signoff templates |
