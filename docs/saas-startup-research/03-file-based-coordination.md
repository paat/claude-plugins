# File-Based Coordination for AI Agents

## Why File-Based?

In multi-agent systems, coordination mechanisms fall into three categories:
1. **In-memory messaging** (AutoGen, CrewAI) — fast but ephemeral, lost on restart
2. **Database-backed** (traditional workflow engines) — durable but heavy infrastructure
3. **File-based** (our approach) — durable, human-readable, zero infrastructure, version-controlled

File-based coordination is ideal for AI coding agents because:
- Git provides free versioning and audit trail
- Files persist across context windows (critical for Ralph-style loops)
- Humans can read, edit, and inspect handoffs directly
- No additional infrastructure needed
- Each file is a discrete, manageable unit of state

## Maildir-Inspired Queue Pattern

The Maildir email format (qmail, 1995) provides a proven file-based queue:

```
maildir/
├── new/     # Unprocessed messages
├── cur/     # Messages being processed
└── tmp/     # Messages being written (atomic creation)
```

**Applied to agent handoffs:**
```
.startup/handoffs/
├── 001-business-to-tech.md    # Each file = one handoff
├── 002-tech-to-business.md    # Sequential numbering = ordering
└── ...                        # Files are immutable once written
```

The **Agent Message Queue (AMQ)** project ([GitHub](https://github.com/avivsinai/agent-message-queue)) implements this pattern for AI agents. The delivery sequence: write to `tmp/`, fsync to disk, atomic rename to `new/`, reader moves to `cur/` after consumption. Guarantees no corrupt or partial message ever appears, even on crash.

Key properties borrowed from Maildir:
- **One file per message**: No locking, no corruption
- **Sequential naming**: Provides natural ordering
- **Immutability**: Once written, a handoff is never modified (write new one instead)
- **Atomic creation**: Write to temp file, then rename (prevents partial reads)

## Task Directory Pattern

Used by snarktank/ralph and similar tools:

```
.project/
├── prd.json          # Task definitions with status
├── progress.txt      # Running log of completed work
└── AGENTS.md         # Accumulated learnings
```

Each iteration:
1. Agent reads `prd.json` → finds next incomplete task
2. Works on the task
3. Updates `progress.txt` with what happened
4. Updates `prd.json` with pass/fail status
5. Updates `AGENTS.md` with learnings for future iterations

## Agent Handoff Markers

Conventions for signaling state between agents:

| Marker | Meaning |
|--------|---------|
| File exists | Agent completed their work |
| File missing | Agent hasn't acted yet |
| Frontmatter `type: requirements` | Business → tech handoff |
| Frontmatter `type: implementation` | Tech → business handoff |
| `.startup/go-live/solution-signoff.md` exists | Loop should end |
| `EXIT_SIGNAL` file exists | Ralph loop can exit |

## AgentFS and Related Tools

### AgentFS
File system abstraction layer for AI agents:
- Provides virtual file system operations tailored for agent workflows
- Enables file-based communication without direct FS access
- Useful for sandboxed environments

### Claude Code Agent Teams Mailbox
Agent Teams uses file-based messaging at `~/.claude/teams/{team-name}/inboxes/{name}.json`:
- Each agent has an inbox file
- Messages are JSON objects with sender, content, timestamp
- Agents poll their inbox for new messages
- Complementary to structured handoff files (real-time vs. persistent)

## Best Practices

### DO
- Use structured frontmatter (YAML) for metadata
- Keep files small and focused (one handoff = one concern)
- Number files sequentially for ordering
- Make files immutable (create new, don't modify)
- Include a state file (state.json) for quick status checks
- Use git to track all changes

### DON'T
- Don't use file locking (agents can't coordinate on locks reliably)
- Don't put binary data in handoff files
- Don't rely on file timestamps for ordering (use sequential numbers)
- Don't write extremely long files (LLM context has limits)
- Don't use nested directory hierarchies deeper than 2 levels

### File Naming Convention
```
NNN-direction.md
  │    │
  │    └── business-to-tech | tech-to-business
  └── 001, 002, 003... (zero-padded, always incrementing)
```

## Our Implementation

```
.startup/
├── brief.md              # Input: the SaaS idea
├── state.json            # State: iteration, phase, active_role
├── human-tasks.md        # Side channel: non-blocking human tasks
├── handoffs/             # Primary: sequential handoff documents
│   ├── 001-business-to-tech.md
│   └── 002-tech-to-business.md
├── docs/                 # Working: research and architecture docs
├── signoffs/             # Validation: per-feature roundtrip signoffs
├── reviews/              # QA: browser verification notes
└── go-live/              # Terminal: solution signoff ends the loop
```

This combines:
- Maildir pattern (sequential, immutable handoffs)
- Task directory pattern (state.json tracks loop progress)
- Agent handoff markers (solution-signoff.md existence = loop end)
- Side channels (human-tasks.md for non-blocking human work)
