# Ralph Wiggum Loops

## Core Concept

An iterative AI development pattern named after The Simpsons character.
The canonical form: `while :; do cat PROMPT.md | claude-code ; done`

**Key insight**: Progress persists in files/git history, not in LLM context.
Each iteration gets fresh context by reading current project state from disk.

## Four Elements

1. **Perception**: Task spec + workspace state
2. **Action**: File edits + commands
3. **Feedback**: Test failures, errors, logs
4. **Iterative Conditioning**: Context accumulates consequences of prior attempts

## Exit Detection

- Functional correctness (passing tests)
- Maximum iteration thresholds
- Timeout limits
- Stagnation detection (repeated identical errors)
- Dual conditions: heuristic indicators AND explicit model confirmation

## Execution Modes

### HITL (Human-in-the-Loop)
- Run single iterations while monitoring
- Perfect for learning and refining prompts
- Interactive pair programming

### AFK (Away From Keyboard)
- Run in loops with capped iterations (5-50)
- For bulk work when prompt is proven reliable
- Use Docker sandboxes for safety

### Progression
Learning phase -> Prompt refinement -> Hands-off execution

## Essential Files

```
PROMPT_build.md / PROMPT_plan.md    # Task specification
AGENTS.md                           # Operational guide
IMPLEMENTATION_PLAN.md              # Detailed plan
progress.txt                        # State tracking between iterations
specs/                              # Requirements by JTBD
```

## 11 Tips for Ralph Wiggum (AI Hero)

1. **Ralph is a Loop** - Agent chooses the task, not you
2. **Start HITL, Then Go AFK** - Refine prompts before autonomous execution
3. **Define the Scope** - Explicit "done" criteria (markdown, issues, JSON)
4. **Track Progress** - `progress.txt` file committed each iteration
5. **Use Feedback Loops** - TypeScript, unit tests, ESLint, pre-commit hooks
6. **Take Small Steps** - Smaller PRD items = more frequent feedback
7. **Prioritize Risky Tasks** - Architecture first, polish last
8. **Define Software Quality** - Explicit quality standards in AGENTS.md
9. **Use Docker Sandboxes** - Essential for overnight AFK loops
10. **Pay to Play** - API costs required, local models insufficient (for now)
11. **Make It Your Own** - Customize task sources, outputs, loop types

## Key Implementations

### Official Plugin (anthropics/claude-code)
- `claude-code/plugins/ralph-wiggum/`
- Uses Stop hook to prevent exit
- Works inside current session without external bash loops

### frankbria/ralph-claude-code
- Requires TWO conditions to stop: heuristic indicators AND model confirmation
- Rate limiting: max iterations, time limits, cost thresholds
- Context preservation across iterations

### Flow-Next Ralph Mode (gmickel)
- Fresh context per iteration (not accumulated)
- Multi-model review gates
- Auto-blocks stuck tasks after N failures
- Multi-source validation (tests + receipts + reviews)
- Launch: `scripts/ralph/ralph.sh` after `/flow-next:ralph-init`

### snartank/ralph
- PRD-driven task management with flowcharts
- GitHub: github.com/snarktank/ralph

### Multi-Agent Ralph (alfredolopez80)
- Multiple AI backends (GLM-4.7, Claude, Codex, Gemini)
- Quality gates, memory system, 67 hooks
- GitHub: github.com/alfredolopez80/multi-agent-ralph-loop

## Common Failure Modes

- **Infinite loops** - Always set max iterations
- **Oscillation** - Fix A breaks B, fix B breaks A
- **Context overload** - Fresh context per iteration is the solution
- **Hallucination entrenchment** - Bad assumptions compound
- **Metric gaming** - Agent deletes failing tests instead of fixing code

## Multi-Model Ralph Strategy

For token optimization in Ralph loops:
1. Use **Haiku** for exploration and file reading phases
2. Use **Sonnet** for code generation and implementation
3. Use **Opus** only for architectural decisions and complex debugging
4. Fresh context per iteration naturally limits per-iteration token usage
5. Progress file eliminates re-exploration costs

## Ralph Loop Customizations

| Loop Type | Purpose |
|-----------|---------|
| Test coverage | Iteratively increase coverage percentage |
| Duplication detection | Refactor cloned code |
| Linting | Fix violations systematically |
| Entropy | Eliminate dead code and code smells |
| Migration | Jest to Vitest, React class to hooks, etc. |
| Browser testing | Fix failing Playwright tests iteratively |

## Success Stories

- YC hackathon team: 6+ repos overnight, ~$297 API costs
- $50K contract delivered for $297 in API costs (MVP tested + reviewed)
- Jest-to-Vitest migration: completion verified through tests + build criteria

## Sources

- [Ralph Wiggum Loop | beuke.org](https://beuke.org/ralph-wiggum-loop/)
- [awesome-ralph | GitHub](https://github.com/snwfdhmp/awesome-ralph)
- [11 Tips | AI Hero](https://www.aihero.dev/tips-for-ai-coding-with-ralph-wiggum)
- [frankbria/ralph-claude-code | GitHub](https://github.com/frankbria/ralph-claude-code)
- [Ralph Wiggum | Awesome Claude](https://awesomeclaude.ai/ralph-wiggum)
- [A Brief History of Ralph | HumanLayer](https://www.humanlayer.dev/blog/brief-history-of-ralph)
- [Ship Code While You Sleep | Webcoda](https://ai-checker.webcoda.com.au/articles/ralph-wiggum-technique-claude-code-autonomous-loops-2026)
- [Ralph Wiggum Technique | atcyrus.com](https://www.atcyrus.com/stories/ralph-wiggum-technique-claude-code-autonomous-loops)
- [Autonomous Loops | paddo.dev](https://paddo.dev/blog/ralph-wiggum-autonomous-loops/)
