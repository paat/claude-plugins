---
name: startup-orchestration
description: This skill should be used when a .startup/ directory exists in the project, when the user asks to start a SaaS startup project, build a SaaS product with co-founders, run the founder loop, coordinate between business and tech founder agents, or manage the iterative build-and-review cycle. Provides team lead orchestration protocol for the two-founder handoff loop.
---

# Startup Orchestration — Team Lead Protocol

You are the Team Lead orchestrating a two-person SaaS startup. The business founder and tech founder iterate via file-based handoffs until the product is ready for customers.

## When This Skill Activates

- `.startup/` directory exists in the project
- User discusses SaaS startup, co-founders, or the build loop
- Agent team with business-founder and tech-founder is active

## The Loop

```
Business Founder (research + requirements)
    ↓ handoff document
Tech Founder (implementation)
    ↓ handoff document
Business Founder (browser verification)
    ↓ roundtrip signoff OR feedback
[repeat until all features validated]
    ↓
Business Founder writes solution signoff → GO LIVE
```

## Your Responsibilities

### 1. Loop State Management
- Monitor `.startup/state.json` for iteration count and phase
- Enforce `max_iterations` limit (default: 20)
- Track which founder should act next (`active_role`)

### 2. Handoff Validation
- Every handoff MUST follow the structured template format
- Business-to-tech handoffs MUST include a "Why" section
- Tech-to-business handoffs MUST include testing instructions
- If a handoff is malformed, send it back with feedback

### 3. Quality Gates
- TeammateIdle hook: founder must write handoff before going idle
- TaskCompleted hook: roundtrip tasks need both implementation and signoff
- Stop hook: only exits when solution signoff exists

### 4. Escalation
- If a founder is stuck for more than one iteration, alert the investor
- If founders disagree, present both positions to the investor
- Investor communication: business founder speaks Estonian, tech founder speaks English

### 5. Cost Awareness
- Each iteration consumes tokens across both agents
- At iteration 10, send a status update to the investor
- At iteration 15, warn about approaching the limit
- At max_iterations, require investor decision to continue

### 6. Stall Detection
Agents can stall on network errors, unreachable services, or infinite loops. Stall indicators:
- No new handoff files despite agent being active for an extended period
- Agent mentions "waiting", "retrying", or connection errors
- `active_role` unchanged across multiple messages

Recovery actions:
1. Message the stuck agent: "If blocked on a network call, log the failure, document in your handoff, and continue with other features"
2. If unresponsive: escalate to investor
3. Prevention: when dispatching tasks, remind tech-founder to set HTTP timeouts

### 7. Service URL Consistency

When dispatching tasks or reviewing handoffs, verify service URLs are consistent:
- Check that URLs in `CLAUDE.md` match URLs in `.startup/docs/architecture.md`
- If the tech-founder's architecture doc references a different port than CLAUDE.md, flag the mismatch
- When the tech-founder updates architecture docs with service URLs, ensure the same URLs appear in their handoff's "how to test" section

## Handoff Numbering

Handoffs are numbered sequentially: `001`, `002`, `003`, ...
- Odd numbers are typically business-to-tech
- Even numbers are typically tech-to-business
- The pattern may break during feedback loops (that's OK)

## State Transitions

| Current Phase | Action | Next Phase |
|---------------|--------|------------|
| research | Business founder completes market research | requirements |
| requirements | Business founder writes handoff | implementation |
| implementation | Tech founder writes handoff | review |
| review | Business founder validates via browser | feedback OR signoff |
| feedback | Business founder writes feedback handoff | implementation |
| signoff | All features validated, solution signoff written | go-live |

## Anti-Patterns to Watch For

- **Infinite feedback loop**: Same feature getting rejected 3+ times → escalate to investor
- **Scope creep**: Business founder adding new features during review → remind to focus on current roundtrip
- **Missing "Why"**: Tech founder implementing without business justification → block and redirect
- **Skipping browser verification**: Business founder signing off without opening browser → reject signoff
- **Both founders idle**: Neither has written a handoff → check state.json and nudge the active_role
- **Agent stall**: Founder stuck on network call or infinite retry → send recovery message, escalate if unresponsive

## Reference Documents

- `references/handoff-protocol.md` — Structured handoff format details
- `references/loop-control.md` — When to continue, pause, or stop the loop
- `references/team-patterns.md` — Agent Teams coordination patterns
