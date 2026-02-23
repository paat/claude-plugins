# Multi-Agent Loops: Ralph Wiggum and Beyond

## The Ralph Wiggum Loop

### Origin
Created by Geoffrey Huntley in late 2025, the Ralph Wiggum loop is an autonomous iteration technique for Claude Code. Named after The Simpsons character (embodying persistent iteration despite setbacks) and 1980s slang for vomiting (feeding output back in). Went viral in December 2025 and was formalized as an official Claude Code plugin by Boris Cherny (Anthropic's Head of Claude Code).

### Core Mechanism
At its heart, Ralph is a `while true` bash loop:

1. Spawns a Claude Code session with a prompt file
2. Claude works on the task, modifying files and making git commits
3. When Claude tries to exit, a **Stop hook** intercepts (exit code 2)
4. The hook re-injects the original prompt
5. Claude sees its previous changes via git history and continues
6. Each iteration gets a fresh context window but persistent file state

### Stopping Conditions

| Mechanism | Description |
|-----------|-------------|
| Completion promise | Claude outputs a signal word ("COMPLETE") when done |
| Dual-condition gate | Requires BOTH output indicators AND an EXIT_SIGNAL file |
| Max iterations | Hard cap (e.g., `--max-iterations 20`) |
| Rate limiting | API call management to prevent cost overruns |
| Circuit breaker | Detects stuck failure patterns |

### Key Insight
Fresh context per iteration prevents drift. Git serves as memory — file changes and commit history persist across iterations even though context windows are fresh.

## Ralph Variants

### snarktank/ralph
PRD-driven variant using `prd.json` to define user stories with pass/fail status. Key features:
- `progress.txt` for cross-iteration memory
- `AGENTS.md` for accumulated learnings (institutional knowledge)
- Exits when all user stories have `passes: true`
- Supports both Amp CLI and Claude Code

### frankbria/ralph-claude-code
Focused on intelligent exit detection with a dual-condition gate:
- `.ralph/` folder structure: `PROMPT.md`, `fix_plan.md`, `AGENT.md`, specs, logs
- Exit requires BOTH completion indicators in output AND `EXIT_SIGNAL` file
- Includes rate limiting, 5-hour API limit handling, circuit breaker
- At v0.11.5 with 566 tests at 100% pass rate

### Anthropic Official Plugin
Canonical implementation in `claude-code/plugins/ralph-wiggum`:
- Uses Stop hooks with exit code 2
- Simple, clean implementation following Anthropic's plugin patterns

## Flow-Next

Zero-dependency Claude Code plugin combining structured workflow enforcement with Ralph-style looping:
- **Re-anchoring**: Before every task, re-reads epic spec, task spec, and git state — prevents hallucinated scope creep
- **Receipt-based gating**: Reviews must produce a receipt JSON file proving they ran
- **Multi-model review gates**: A second model (via Codex) must return "SHIP" before task completion
- **Guard hooks**: Deterministic enforcement blocking forbidden flags

Key command: `/flow-next:prime` assesses codebase for agent-readiness across 8 pillars with 48 criteria.

## Google ADK LoopAgent

Deterministic workflow agent in Google's Agent Development Kit:
- Not LLM-powered — the LoopAgent itself is deterministic
- Executes sub_agents sequentially in each iteration
- Typical pattern: worker agent + critic agent wrapped in LoopAgent
- Termination: `max_iterations` or agent escalation (`tool_context.actions.escalate = True`)
- State persists across iterations via shared `InvocationContext`

Key pattern: Separation of concerns — worker generates, critic evaluates, LoopAgent orchestrates without LLM overhead.

## Lessons Learned Across All Implementations

1. **Fresh context per iteration prevents drift** — accumulated hallucinations compound
2. **Git as memory** — file state persists; LLM memory doesn't need to
3. **Institutional knowledge files** (AGENTS.md) — write learnings for future iterations
4. **Always set max iterations** — without hard caps, loops run indefinitely
5. **Best for mechanical tasks** — refactors, batch operations, test coverage, greenfield builds
6. **Economics matter** — one engineer reportedly did a $50K contract for $297 in API costs

## Sources

- [Ralph Wiggum - Awesome Claude](https://awesomeclaude.ai/ralph-wiggum)
- [The Register: Ralph Wiggum loop](https://www.theregister.com/2026/01/27/ralph_wiggum_claude_loops/)
- [Geoffrey Huntley's Ralph page](https://ghuntley.com/ralph/)
- [Inventing the Ralph Wiggum Loop — Dev Interrupted](https://devinterrupted.substack.com/p/inventing-the-ralph-wiggum-loop-creator)
- [A Brief History of Ralph — HumanLayer](https://www.humanlayer.dev/blog/brief-history-of-ralph)
- [snarktank/ralph GitHub](https://github.com/snarktank/ralph)
- [frankbria/ralph-claude-code GitHub](https://github.com/frankbria/ralph-claude-code)
- [Flow-Next](https://mickel.tech/apps/flow-next)
- [Google ADK Loop Agents](https://google.github.io/adk-docs/agents/workflow-agents/loop-agents/)
