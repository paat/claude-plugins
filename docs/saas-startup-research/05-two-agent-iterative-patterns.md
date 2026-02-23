# Two-Agent Iterative Patterns

## Why Two Agents?

Multi-agent systems face quadratic communication overhead: N agents require N*(N-1)/2 communication channels. Two agents is the minimum for productive iteration while being the simplest to coordinate:

| Agent Count | Channels | Complexity |
|-------------|----------|------------|
| 2 | 1 | Simple ping-pong |
| 3 | 3 | Triangle coordination |
| 5 | 10 | Star or mesh topology needed |
| 7 | 21 | Requires hierarchy |

Two agents with clear roles (one generates, one evaluates) is the most efficient pattern for iterative development.

## Pattern 1: Worker-Critic Loop

The most common two-agent pattern. One agent produces work, the other evaluates it.

```
Worker Agent → output → Critic Agent → feedback → Worker Agent
                                          ↓
                                     APPROVED → done
```

**Used by**: Google ADK LoopAgent, code review bots, academic paper review agents

**Our variant**: Tech founder (worker) produces implementation; business founder (critic) evaluates via browser. The key difference: our critic also does research and writes requirements, making the loop bidirectional rather than one-directional.

## Pattern 2: Pair Programming Agents

Two agents alternate between "driver" (writing code) and "navigator" (reviewing direction).

```
Agent A (driver) → writes code → Agent B (navigator) → reviews direction
         ↕                                    ↕
Agent A (navigator) ← reviews direction ← Agent B (driver)
```

**Key insight**: The agents swap roles. Each has domain expertise that complements the other.

**Our variant**: Roles are fixed (not swapping) because the domains are fundamentally different — business knowledge vs. technical knowledge. But the iterative back-and-forth is the same.

## Pattern 3: Spec-Execute-Verify

One agent writes specifications, another executes them, the first verifies results.

```
Spec Agent → specification → Execute Agent → implementation → Spec Agent (verify)
                                                                    ↓
                                                              PASS → next spec
                                                              FAIL → feedback → Execute Agent
```

**Used by**: snarktank/ralph (PRD → implementation → validation), MetaGPT (PM → Engineer → QA)

**Our implementation**: Business founder writes specification (handoff), tech founder implements, business founder verifies via browser. This is exactly the spec-execute-verify pattern.

## Pattern 4: Research-Build

One agent researches and gathers information, another builds based on findings.

```
Research Agent → findings document → Build Agent → implementation
       ↑                                                  ↓
       └────────── validation results ←──────────────────┘
```

**Our variant**: Business founder does ALL real-world research (web, Reddit, browser), tech founder has NO web access. This creates intentional information asymmetry that forces thorough research.

## Handoff Best Practices

### Structured Over Free-Form
Use templates with required sections. Free-form handoffs lead to:
- Missing context ("why" not explained)
- Ambiguous requirements (no acceptance criteria)
- Incomplete reports (no testing instructions)

### Required Sections for Every Handoff
1. **Summary**: One paragraph overview
2. **Why**: Business justification (for requirement handoffs)
3. **What**: Specific items with acceptance criteria
4. **Blockers**: Items needing resolution
5. **Next Action**: What the receiving agent should do

### Frontmatter for Metadata
```yaml
---
from: agent-name
to: agent-name
iteration: N
date: YYYY-MM-DD
type: requirements | implementation | review | feedback
---
```

### File Naming
```
NNN-direction.md
001-business-to-tech.md → 002-tech-to-business.md → 003-business-to-tech.md
```

## Orchestration Patterns

### Ping-Pong (Our Pattern)
```
A → B → A → B → A → B → ... → DONE
```
Simple, predictable, easy to track. Each agent takes turns. State file tracks whose turn it is.

### Round-Robin
```
A → B → C → A → B → C → ... → DONE
```
Used with 3+ agents. More complex coordination needed.

### Hub-and-Spoke
```
    B
    ↑
A ← Hub → C
    ↓
    D
```
Central coordinator routes messages. Used by CrewAI hierarchical mode and Agent Teams team lead.

### Our Hybrid
```
Team Lead (Hub)
  ├── Business Founder ←→ Tech Founder (Ping-Pong via files)
  └── Escalation to Human (Hub-and-Spoke)
```

## Anti-Patterns

### 1. Infinite Feedback Loop
**Symptom**: Same feature rejected 3+ times
**Cause**: Vague acceptance criteria, subjective quality bar
**Fix**: Explicit acceptance criteria in handoffs. Escalate after 3 round-trips.

### 2. Context Amnesia
**Symptom**: Agent repeats work or contradicts previous decisions
**Cause**: Fresh context window loses institutional knowledge
**Fix**: Write learnings to AGENTS.md / architecture.md. Reference previous handoffs.

### 3. Scope Creep During Review
**Symptom**: Reviewer adds new requirements during validation phase
**Cause**: No separation between "review current feature" and "plan next feature"
**Fix**: Roundtrip signoff only validates current feature. New requirements go in next handoff.

### 4. Missing "Why"
**Symptom**: Implementer builds the wrong thing or over-engineers
**Cause**: Handoff only says "what" not "why"
**Fix**: Required "Why" section in every requirement handoff. Implementer STOPS if missing.

### 5. Premature Signoff
**Symptom**: Feature signed off without proper testing
**Cause**: Reviewer skips browser verification
**Fix**: Require browser review notes before roundtrip signoff. TaskCompleted hook validates.

### 6. Both Agents Idle
**Symptom**: Neither agent is working, loop is stalled
**Cause**: State tracking out of sync, unclear whose turn it is
**Fix**: state.json tracks active_role explicitly. TeammateIdle hook forces handoff before idle.

### 7. "Bag of Agents" Error Amplification
**Source**: Towards Data Science, "17x Error Trap"
**Symptom**: Uncoordinated agents amplify errors ~17x vs. structured alternatives
**Cause**: Adding agents without structured topology; accuracy saturates past 4-agent threshold
**Fix**: Organize agents into functional planes with closed-loop feedback. Two well-coordinated agents beat five uncoordinated ones.

## Microsoft's Five Canonical Orchestration Patterns

From the Azure Architecture Center (Feb 2026):

| Pattern | Description | Best For |
|---------|-------------|----------|
| Sequential | Linear chain, each agent processes previous output | Step-by-step refinement |
| Concurrent | Multiple agents process same input simultaneously | Independent analysis |
| Group Chat | Shared conversation thread with flow manager | Collaborative reasoning |
| Handoff | Dynamic delegation, full control transfer | Routing/triage/dispatch |
| Magentic | Manager builds/refines task ledger dynamically | Open-ended problems |

Our plugin uses **Handoff** (business↔tech file-based handoffs) orchestrated by a **Sequential** loop (research → requirements → implementation → review → signoff).

## Sources

- [Microsoft Azure Architecture Center: AI Agent Design Patterns](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/ai-agent-design-patterns)
- [Towards Data Science: 17x Error Trap](https://towardsdatascience.com/why-your-multi-agent-system-is-failing-escaping-the-17x-error-trap-of-the-bag-of-agents/)
- [MAST Failure Taxonomy (UC Berkeley/Stanford)](https://arxiv.org/pdf/2503.13657)
- [Tacnode: 8 Coordination Patterns](https://tacnode.io/post/ai-agent-coordination)
- [OpenAI Agents SDK: Multi-agent](https://openai.github.io/openai-agents-python/multi_agent/)
