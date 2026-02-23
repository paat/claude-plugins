# Claude Code Agent Teams Reference

## Overview

Agent Teams is an experimental Claude Code feature (February 2026) that enables a lead session to delegate work to multiple teammate sessions working in parallel, coordinating through shared task lists and mailbox messaging.

## Architecture

```
Team Lead (Main Claude Code Session)
  ├── Teammate A (parallel session, own context)
  ├── Teammate B (parallel session, own context)
  ├── Shared TaskList (dependency tracking)
  └── Mailbox System (~/.claude/teams/{name}/inboxes/)
```

### Four Components
1. **Team Lead**: Main session that analyzes tasks, creates team, spawns teammates
2. **Teammates**: Parallel sessions that self-claim available tasks and work autonomously
3. **Shared Task List**: Tasks with dependency tracking; blocking tasks auto-unblock downstream
4. **Mailbox System**: JSON files at `~/.claude/teams/{team-name}/inboxes/{name}.json`

## Configuration

### Enabling Agent Teams
```json
// settings.json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### Agent Definition (agents/*.md)
```yaml
---
name: teammate-name
description: What this teammate does
model: opus | sonnet | haiku
color: blue | green | magenta | cyan | yellow | red
tools: Bash, Read, Write, Edit, ...
---

# Teammate Name

[Capabilities, guidelines, constraints]
```

## Inter-Agent Messaging

The mailbox system is what makes Agent Teams fundamentally different from subagents:

| Scenario | Mechanism |
|----------|-----------|
| Lead → Teammate | Direct message via sendMessage |
| Teammate → Lead | Message to team lead |
| Teammate → Teammate | Direct inter-teammate messaging |
| Wake idle teammate | Message triggers wake-up and processing |

Messages are JSON objects with sender, content, and timestamp. Agents poll their inbox for new messages automatically.

## Key Hooks

### TeammateIdle
Fires when a teammate is about to go idle (no more work to do).

```json
{
  "hooks": {
    "TeammateIdle": [{
      "hooks": [{
        "type": "command",
        "command": "path/to/check-idle.sh",
        "description": "Validate teammate wrote a handoff before going idle"
      }]
    }]
  }
}
```

**Exit codes:**
- `0`: Allow idle (teammate can stop working)
- `2`: Block idle with feedback (keeps teammate working)

**Use cases:**
- Inject additional work into teammate
- Validate deliverables before allowing idle
- Redirect teammate to different task

### TaskCompleted
Fires when a task is being marked as complete.

```json
{
  "hooks": {
    "TaskCompleted": [{
      "hooks": [{
        "type": "command",
        "command": "path/to/check-task-complete.sh",
        "description": "Validate task has deliverables"
      }]
    }]
  }
}
```

**Exit codes:**
- `0`: Allow completion
- `2`: Block completion with feedback (task stays in progress)

**Use cases:**
- Run test suite — no task closes with broken tests
- Validate that implementation files exist
- Check that documentation was written

### Stop Hook (for loop control)
```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "test -f .startup/go-live/solution-signoff.md",
        "description": "Only allow stop when solution signoff exists"
      }]
    }]
  }
}
```

## Delegate Mode

Pressing **Shift+Tab** cycles into delegate mode:
- Restricts lead to coordination-only tools
- Prevents lead from competing with teammates for work
- Tools available: spawn teammates, messaging, task management
- Recommended when running 4+ teammate sessions

## Shared Task List

Tasks support dependency tracking:
```
Task 1: Set up database schema
Task 2: Implement API endpoints (blocked by Task 1)
Task 3: Build frontend components
Task 4: Integration testing (blocked by Task 2, Task 3)
```

When Task 1 completes, Task 2 automatically unblocks. Teammates self-claim next available unblocked task.

## Our Plugin's Usage

### Agent Team Structure
```
Team Lead (Orchestrator)
  ├── business-founder (blue, opus)
  │   Tools: Bash, Read, Write, Edit, Glob, Grep,
  │          WebSearch, WebFetch, Task, Chrome MCP
  │
  └── tech-founder (green, opus)
      Tools: Bash, Read, Write, Edit, Glob, Grep, Task
```

### Messaging Patterns
| Scenario | Channel |
|----------|---------|
| Requirements handoff | File: .startup/handoffs/NNN-business-to-tech.md |
| Implementation report | File: .startup/handoffs/NNN-tech-to-business.md |
| "Why" clarification | Agent Teams messaging (real-time) |
| Deadlock escalation | Agent Teams messaging → team lead → investor |
| Status notification | Agent Teams messaging ("handoff written, your turn") |

### Hook Usage
| Hook | Purpose |
|------|---------|
| TeammateIdle | Founder must write handoff before going idle |
| TaskCompleted | Roundtrip tasks need implementation + signoff |
| Stop | Only exits when solution signoff exists |

## Limitations

- Experimental feature, API may change
- Each teammate consumes separate token budget
- Context windows are independent (by design — prevents pollution)
- Mailbox polling has latency (not instant messaging)
- Team size recommended: 2-6 teammates (more creates coordination overhead)

## Sources

- [Claude Code Agent Teams docs](https://code.claude.com/docs/en/agent-teams)
- [Claude Code Agent Teams: Complete Guide 2026](https://claudefa.st/blog/guide/agents/agent-teams)
- [Addy Osmani: Claude Code Swarms](https://addyosmani.com/blog/claude-code-agent-teams/)
- [From Tasks to Swarms: Agent Teams in Claude Code](https://alexop.dev/posts/from-tasks-to-swarms-agent-teams-in-claude-code/)
