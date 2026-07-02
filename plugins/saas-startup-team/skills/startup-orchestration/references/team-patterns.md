# Role Coordination Patterns

## Architecture

```
Human (Silent Investor)
  ↓ /startup command    ↓ /lawyer <topic>    ↓ /ux-test <url>
Team Lead (orchestrator session)
  ├── Business Founder (fresh role phase, blue)
  ├── Tech Founder (fresh role phase, green)
  ├── Lawyer (fresh role phase, magenta)
  ├── UX Tester (fresh role phase, cyan)
  └── File-based coordination via .startup/
```

**IMPORTANT: every relay runs a fresh role phase, never a persistent teammate.**
- **Claude Code:** dispatch one-shot Task/Agent workers; never use `TeamCreate` (persistent teammates cannot be dismissed).
- **Codex:** use the current session, Codex-supported multi-agent tooling, or `codex exec` when a separate worker is useful.

## Communication Channels

### Primary: File-Based Handoffs
- Structured, persistent, auditable
- Lives in `.startup/handoffs/`
- Carries full context between iterations
- Each founder gets fresh context — handoffs carry state, not LLM memory

### Secondary: Role Phase Results
- Each role phase reports its result to the team lead when done
- The team lead reads the result, then starts the next role phase
- No direct role-to-role communication - all coordination goes through the team lead and `.startup/` files

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

Each role phase starts from the relevant skill, `.startup/state.json`, and the named handoff files. Context does NOT accumulate across phases. All state lives in `.startup/` files.

Why this works:
- **File-based state**: All critical state lives in `.startup/` files, not LLM memory
- **Self-contained relay messages**: Team lead sends complete task descriptions with all file paths and instructions
- **Fresh context every time**: No degraded context and no accumulated confusion
- **2-feature handoff limit**: Keeps per-task token usage under ~50K, fitting comfortably in one context window
- **Handoff templates**: Structured format ensures nothing is lost between agent dispatches

## Quality Gates

| Gate | Purpose | Enforces |
|------|---------|----------|
| Handoff phase check | Founders must write handoffs | No phase ends without deliverable |
| Completion phase check | Features need full lifecycle | Implementation + signoff both required |
| Stop hook | Only business founder ends loop | Solution signoff must exist |

The active lifecycle hook keys are `PreToolUse`, `PostToolUse`, and `Stop`.
`TeammateIdle` and `TaskCompleted` are Claude-only lifecycle events; on Codex they
do not fire, so enforce those completeness checks as explicit workflow gates.

## Role Lifecycle Management

**Always start fresh role phases.** Every relay starts from the role skill and the
current files. Never depend on old role context. Since all state lives in `.startup/`
files, no information is lost.

**Right-size each dispatch.** Each agent should receive ONE cohesive task that
produces exactly ONE deliverable file (handoff, review, or signoff). Do NOT
micro-delegate — bundling 3-4 fixes from a review into a single agent dispatch
is correct; spawning 5 agents for 5 small fixes is wrong.

The lawyer and UX tester follow this same pattern - every `/lawyer` or
`/ux-test` invocation starts from a fresh role phase.

## UX Audit Handover Pattern

The UX Tester writes findings to `docs/ux/ux-*.md`. The team lead then:
1. Reads the findings and prioritizes by severity (Critical → Major → Minor)
2. Groups findings into max-2-feature handoff items for founders
3. Assigns code-fix findings (accessibility, responsive, states) to the tech founder
4. Assigns UX research follow-ups (user flows, competitive patterns) to the business founder
5. Tracks remediation through the normal handoff loop

**Hook compatibility**: PostToolUse hooks (auto-commit, auto-learn, enforce-tone)
fire on supported Codex file/tool events. Handoff and completion guarantees are
checked explicitly by the team lead before moving to the next role phase.

## Escalation Protocol

1. Founder sends message to team lead: "I need investor input on X"
2. Team lead reads the context and formulates the question
3. Team lead asks the investor (business founder translates to Estonian if needed)
4. Investor responds via `/nudge` or direct message
5. Team lead relays decision to the appropriate founder
