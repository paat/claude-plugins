# Agent Teams Coordination Patterns

## Architecture

```
Human (Silent Investor)
  ↓ /startup command         ↓ /lawyer <topic>
Team Lead (Main Session)
  ├── Business Founder (teammate, blue)
  ├── Tech Founder (teammate, green)
  ├── Lawyer (on-demand consultant, magenta)
  ├── Shared TaskList
  └── Inter-agent messaging
```

## Communication Channels

### Primary: File-Based Handoffs
- Structured, persistent, auditable
- Lives in `.startup/handoffs/`
- Carries full context between iterations
- Each founder gets fresh context — handoffs carry state, not LLM memory

### Secondary: Agent Team Messaging
- Real-time clarifications between founders
- Notifications ("I've written my handoff, your turn")
- Escalation to team lead ("I'm stuck, need investor input")

### Tertiary: Shared TaskList
- Track features as tasks with dependencies
- Business founder creates tasks → tech founder implements
- TaskCompleted hook validates deliverables

## Information Flow Rules

```
Web/Reddit/Browser → Business Founder (ONLY)
                         ↓ handoff docs
                     Tech Founder
                         ↓ handoff docs
                     Business Founder (browser verification)
```

The tech founder has NO access to:
- WebSearch / WebFetch
- Browser MCP tools
- Reddit or any external data source

This is intentional — it forces the business founder to be thorough in research and handoff quality.

## Fresh Context Pattern

Each teammate gets their own context window (Agent Teams native behavior):
- Business founder's context: research tools + handoff history
- Tech founder's context: code tools + handoff history
- State carries forward via files, not LLM memory

This mirrors the "Ralph Loop" insight: fresh context per iteration prevents context pollution and cognitive overload.

## Quality Gate Hooks

| Hook | Purpose | Enforces |
|------|---------|----------|
| TeammateIdle | Founders must write handoffs | No idle without deliverable |
| TaskCompleted | Features need full lifecycle | Implementation + signoff both required |
| Stop | Only business founder ends loop | Solution signoff must exist |

## Escalation Protocol

1. Founder sends message to team lead: "I need investor input on X"
2. Team lead reads the context and formulates the question
3. Team lead asks the investor (business founder translates to Estonian if needed)
4. Investor responds via `/nudge` or direct message
5. Team lead relays decision to the appropriate founder
