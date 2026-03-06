# Agent Teams Coordination Patterns

## Architecture

```
Human (Silent Investor)
  ↓ /startup command    ↓ /lawyer <topic>    ↓ /ux-test <url>
Team Lead (Main Session)
  ├── Business Founder (one-shot Task agent, blue)
  ├── Tech Founder (one-shot Task agent, green)
  ├── Lawyer (one-shot Task agent, magenta)
  ├── UX Tester (one-shot Task agent, cyan)
  └── File-based coordination via .startup/
```

**IMPORTANT: All agents are one-shot Task tool agents, NOT persistent teammates.**
TeamCreate spawns persistent processes that cannot be dismissed — they accumulate as
~500MB zombie processes. The Task tool spawns agents that exit cleanly when done.

## Communication Channels

### Primary: File-Based Handoffs
- Structured, persistent, auditable
- Lives in `.startup/handoffs/`
- Carries full context between iterations
- Each founder gets fresh context — handoffs carry state, not LLM memory

### Secondary: Task Agent Results
- Each one-shot agent returns its result to the team lead when done
- The team lead reads the result, then dispatches the next agent
- No direct agent-to-agent communication — all coordination goes through the team lead and `.startup/` files

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

Each agent is a fresh one-shot Task agent with a clean context window. Context does NOT accumulate — every dispatch starts from zero. All state lives in `.startup/` files.

Why this works:
- **File-based state**: All critical state lives in `.startup/` files, not LLM memory
- **Self-contained relay messages**: Team lead sends complete task descriptions with all file paths and instructions
- **Fresh context every time**: No auto-compaction, no degraded context, no accumulated confusion
- **2-feature handoff limit**: Keeps per-task token usage under ~50K, fitting comfortably in one context window
- **Handoff templates**: Structured format ensures nothing is lost between agent dispatches

## Quality Gate Hooks

| Hook | Purpose | Enforces |
|------|---------|----------|
| TeammateIdle | Founders must write handoffs | No idle without deliverable |
| TaskCompleted | Features need full lifecycle | Implementation + signoff both required |
| Stop | Only business founder ends loop | Solution signoff must exist |

## Agent Lifecycle Management

**Always spawn fresh agents.** Every relay dispatches a new agent via the Task
tool. Never reuse agents — context bloat from prior work degrades quality even
after just 2-3 handoffs.

Before spawning a new agent, kill stale agents from the same role:
```bash
pkill -f 'agent-type saas-startup-team:{role}' 2>/dev/null || true
sleep 1
```

Fresh agents use the same agent definition (tools, model, system prompt) but
start with zero conversation history. Since all state lives in `.startup/`
files, no information is lost.

**Right-size each dispatch.** Each agent should receive ONE cohesive task that
produces exactly ONE deliverable file (handoff, review, or signoff). Do NOT
micro-delegate — bundling 3-4 fixes from a review into a single agent dispatch
is correct; spawning 5 agents for 5 small fixes is wrong.

The lawyer and UX tester follow this same pattern — every `/lawyer` or
`/ux-test` invocation spawns a fresh one-shot agent.

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
