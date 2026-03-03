# Agent Teams Coordination Patterns

## Architecture

```
Human (Silent Investor)
  ↓ /startup command    ↓ /lawyer <topic>    ↓ /ux-test <url>
Team Lead (Main Session)
  ├── Business Founder (teammate, blue)
  ├── Tech Founder (teammate, green)
  ├── Lawyer (on-demand consultant, magenta)
  ├── UX Tester (on-demand consultant, cyan)
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

## Context Management Pattern

Each teammate gets their own context window (Agent Teams native behavior), but context **accumulates** across iterations — it is NOT reset per task. By iteration 5+, auto-compaction may remove earlier conversation details.

Mitigations:
- **File-based state**: All critical state lives in `.startup/` files, not LLM memory
- **Self-contained relay messages**: Team lead sends complete task descriptions with all file paths and instructions — never assumes the founder "remembers" earlier messages
- **2-feature handoff limit**: Keeps per-iteration token usage under ~50K, slowing accumulation
- **Handoff templates**: Structured format ensures nothing is lost even if conversation history is compacted

Key rule: treat every relay message as if the receiving founder has never seen any previous messages. Point to files, not conversation history.

## Quality Gate Hooks

| Hook | Purpose | Enforces |
|------|---------|----------|
| TeammateIdle | Founders must write handoffs | No idle without deliverable |
| TaskCompleted | Features need full lifecycle | Implementation + signoff both required |
| Stop | Only business founder ends loop | Solution signoff must exist |

## Agent Lifecycle Management

Persistent teammates accumulate context across iterations. By handoff 4+,
auto-compaction degrades context quality unpredictably. The team lead manages
agent freshness:

- **Handoffs 1-3**: Message persistent teammate (benefits from continuity)
- **Handoffs 4+**: Spawn fresh via Task tool (clean context, same file-based state)
- **Counter resets** on each fresh spawn

Fresh-spawn agents use the same agent definition (tools, model, system prompt)
but start with zero conversation history. Since all state lives in `.startup/`
files, no information is lost.

The lawyer and UX tester both use this one-shot pattern — every `/lawyer` or
`/ux-test` invocation spawns a fresh Task agent. Founders adopt the same pattern
once their context is stale.

## UX Audit Handover Pattern

The UX Tester writes findings to `.startup/docs/ux-*.md`. The team lead then:
1. Reads the findings and prioritizes by severity (Critical → Major → Minor)
2. Groups findings into max-2-feature handoff items for founders
3. Assigns code-fix findings (accessibility, responsive, states) to the tech founder
4. Assigns UX research follow-ups (user flows, competitive patterns) to the business founder
5. Tracks remediation through the normal handoff loop

**Hook compatibility**: PostToolUse hooks (auto-commit, auto-learn, enforce-tone)
fire on any agent's tool use — Task agents included. TeammateIdle won't fire for
Task agents, but that's fine — Task agents complete and return, they don't go idle.

## Escalation Protocol

1. Founder sends message to team lead: "I need investor input on X"
2. Team lead reads the context and formulates the question
3. Team lead asks the investor (business founder translates to Estonian if needed)
4. Investor responds via `/nudge` or direct message
5. Team lead relays decision to the appropriate founder
