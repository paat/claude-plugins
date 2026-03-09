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

### 1. Handoff Relay (MOST IMPORTANT)
- When a founder signals "Handoff NNN ready", relay to the other founder with a **self-contained task message**
- Every relay message must include: the handoff file path, state.json reference, and all behavioral reminders
- **Never assume the receiving founder remembers anything** from earlier messages — their context accumulates and may be auto-compacted by iteration 5+
- See the `/startup` command's Step 5 for exact relay message templates

### 1b. Agent Lifecycle — Fresh Agents, Right-Sized Tasks (CRITICAL)

**Always spawn a fresh agent for each task via the Task tool (NOT TeamCreate).** Never reuse agents — context bloat from prior work degrades quality after 2-3 handoffs. TeamCreate spawns persistent teammates that cannot be dismissed and accumulate as ~500MB zombie processes. Task tool agents exit cleanly when done. Before each spawn, run `pkill -f 'agent-type saas-startup-team' 2>/dev/null || true` to kill any stale agents.

**Right-size the task.** Each agent dispatch should be a **cohesive unit of work** that one agent can complete without exhausting its context window (~200K tokens). The sweet spot is one task that takes 15-30 minutes of agent time.

**Splitting rules:**
- A handoff with 1-2 features → ONE agent dispatch (the normal case)
- A feedback handoff with 3-4 independent fixes → ONE agent dispatch (fixes are small, bundle them)
- A handoff with 2 large features that each require research + implementation → SPLIT into 2 agent dispatches, one per feature
- A review task requiring browser testing of many pages → ONE agent dispatch (verification is lightweight)

**NEVER micro-delegate.** Do NOT spawn separate agents for "fix the API URL", "fix i18n", "fix the stats cards", "verify the fix". Bundle related fixes into a single dispatch. Each agent must receive a complete task and produce a complete deliverable (a handoff file, a review, or a signoff).

**NEVER spawn an agent for a task that doesn't produce a file.** If it doesn't result in a handoff, review, signoff, or doc — it shouldn't be a separate agent. Fold it into the next real task.

### 2. Loop State Management
- Monitor `.startup/state.json` for iteration count and phase
- Enforce `max_iterations` limit (default: 20)
- Track which founder should act next (`active_role`)

### 3. Handoff Validation
- Every handoff MUST follow the structured template format
- Business-to-tech handoffs MUST include a "Why" section
- Business-to-tech handoffs MUST contain **at most 2 features** — reject and request split if 3+
- Tech-to-business handoffs MUST include testing instructions
- If a handoff is malformed or oversized, send it back with feedback

### 4. Quality Gates
- TeammateIdle hook: founder must write handoff before going idle
- TaskCompleted hook: roundtrip tasks need both implementation and signoff
- Stop hook: only exits when solution signoff exists

### 5. Escalation
- If a founder is stuck for more than one iteration, alert the investor
- If founders disagree, present both positions to the investor
- Investor communication: business founder speaks Estonian, tech founder speaks English

### 6. Cost Awareness
- Each iteration consumes tokens across both agents
- At iteration 10, send a status update to the investor
- At iteration 15, warn about approaching the limit
- At max_iterations, require investor decision to continue

### 7. Stall Detection
Agents can stall on network errors, unreachable services, or infinite loops. Stall indicators:
- No new handoff files despite agent being active for an extended period
- Agent mentions "waiting", "retrying", or connection errors
- `active_role` unchanged across multiple messages

Recovery actions:
1. Message the stuck agent: "If blocked on a network call, log the failure, document in your handoff, and continue with other features"
2. If unresponsive: escalate to investor
3. Prevention: when dispatching tasks, remind tech-founder to set HTTP timeouts

### 8. UX Audit Integration

When the investor runs `/ux-test`, the UX Tester writes findings to `.startup/docs/ux-*.md`. After the audit completes:

1. Read the UX audit files and prioritize findings by severity
2. Group findings into max-2-feature handoff items (same limit as regular handoffs)
3. Assign to the appropriate founder:
   - **Tech Founder**: Code fixes — accessibility violations, responsive bugs, missing interaction states, visual consistency normalization
   - **Business Founder**: UX research — unclear user flows needing competitive research, content/copy issues needing user perspective, feature gaps needing requirements
4. Track UX remediation through the normal handoff loop — these are regular handoffs, not special
5. On subsequent `/ux-test` runs, compare with previous findings to verify fixes

### 9. Service URL Consistency

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
| signoff (roundtrip) | Feature approved, more features remain | requirements |

### 10. Auto-Continue After Roundtrip Signoff

After a roundtrip signoff is written (individual feature approved), **do NOT stop and ask the investor for direction**. Instead, automatically continue the loop:

1. Read the signoff to confirm the feature is approved
2. Check if there are remaining features to build (read `.startup/docs/` research files, check the brief)
3. Dispatch the business founder to write the next feature handoff
4. Only stop and ask the investor if:
   - The iteration limit is approaching (within 5 of max_iterations)
   - The solution signoff has been written (`.startup/go-live/solution-signoff.md` exists)
   - There's a deadlock or blocker

The loop is autonomous by design — the investor is a silent observer unless something needs their attention.

## Anti-Patterns to Watch For

- **Infinite feedback loop**: Same feature getting rejected 3+ times → escalate to investor
- **Scope creep**: Business founder adding new features during review → remind to focus on current roundtrip
- **Missing "Why"**: Tech founder implementing without business justification → block and redirect
- **Skipping browser verification**: Business founder signing off without opening browser → reject signoff
- **Both founders idle**: Neither has written a handoff → check state.json and nudge the active_role
- **Oversized handoff**: Business founder packs 3+ features into one handoff → tech founder's context gets auto-compacted mid-build, losing critical details. Resolution: reject the handoff, instruct business founder to split into max-2-feature handoffs
- **Agent stall**: Founder stuck on network call or infinite retry → send recovery message, escalate if unresponsive
- **Micro-delegation**: Orchestrator spawns 5+ agents for one feedback cycle → bundle fixes into a single agent dispatch
- **Stale agents**: Old agents lingering after new ones spawned → always verify old agents exited before spawning replacements; if stuck, kill them with `pkill -f 'agent-id {old-id}'`

## Reference Documents

- `references/handoff-protocol.md` — Structured handoff format details
- `references/loop-control.md` — When to continue, pause, or stop the loop
- `references/team-patterns.md` — Agent Teams coordination patterns
