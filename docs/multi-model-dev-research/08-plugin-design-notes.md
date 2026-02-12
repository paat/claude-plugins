# Plugin Design Notes

Synthesis of research findings into actionable design decisions.

## Problem Statement

Claude Max subscription token limits deplete too fast because:
1. Opus 4.6 is used for everything including trivial tasks
2. Subagents default to expensive models
3. Context windows fill with exploration data that cheap models could handle
4. No automatic model routing based on task complexity
5. Ralph loops and browser testing burn tokens without model optimization
6. Code review uses single model instead of cross-model diversity

## Design Principles (from oh-my-opencode)

### 1. Context-Light Architecture (Most Important)
Main agent (Opus) stays lean. Cheap agents do heavy lifting.
```
User -> Opus (analyze, plan, decide)
          |
          +-> Haiku (explore, read, grep)
          +-> Sonnet (implement, test)
          +-> Haiku (verify, report)
          |
       Opus (review, synthesize)
```

### 2. Right Model for Right Task
| Task | Model | Cost |
|------|-------|------|
| Strategy/Architecture | Opus | High |
| Implementation | Sonnet | Medium |
| Exploration/Discovery | Haiku | Low |
| Simple verification | Haiku | Low |
| Code review | Sonnet + Opus | Medium-High |

### 3. Magic Keywords (Zero Friction)
oh-my-opencode's "ultrawork" keyword triggers complex workflows.
Our plugin should have similar activation patterns.

### 4. Sensible Defaults
Should work well without configuration. Advanced users can tune.

## Proposed Execution Modes

Keep it to 4 modes (vs oh-my-claudecode's 7):

| Mode | Description | Model Mix |
|------|-------------|-----------|
| **Smart** (default) | Auto-routes by task complexity | Opus/Sonnet/Haiku |
| **Eco** | Maximum token savings | Sonnet/Haiku only |
| **Ralph** | Autonomous loop with model routing | Sonnet primary |
| **Review** | Cross-model code review | Opus + optional external |

## Key Workflows to Support

### 1. Discovery & Planning
- Haiku explores codebase (fast, cheap)
- Sonnet analyzes findings and creates plan
- Opus reviews plan for architectural decisions
- Token savings: ~70% vs all-Opus discovery

### 2. Implementation (Issue Loops)
- Opus breaks issue into subtasks
- Sonnet implements each subtask
- Haiku runs tests and collects results
- Sonnet fixes failures
- Opus reviews final implementation
- Token savings: ~50% vs all-Opus implementation

### 3. Browser Testing
- Sonnet generates Playwright tests
- Haiku runs tests via MCP, collects results
- Sonnet fixes failing tests (Ralph loop)
- Opus reviews test quality and coverage
- Token savings: ~60% vs all-Opus testing

### 4. Code Review
- Haiku collects diff and file context
- Sonnet does first-pass review
- Opus does architectural review
- Optional: External model (GPT via Codex CLI) for diversity
- Token savings: ~40% vs all-Opus review

### 5. Ralph Loops (Autonomous)
- Fresh Sonnet context per iteration
- Haiku for exploration within each iteration
- Opus only for stuck-detection and strategy changes
- Progress file eliminates re-exploration
- Token savings: ~60% vs all-Opus Ralph

## Implementation Strategy

### Plugin Components

1. **Model Router** (core)
   - Task classifier (rule-based + optional LLM fallback)
   - Environment variable management
   - Cost tracking

2. **Workflow Skills** (user-facing)
   - `/discover` - Model-routed codebase discovery
   - `/implement` - Issue implementation with model routing
   - `/review` - Multi-model code review
   - `/ralph` - Autonomous loop with model routing
   - `/test-fix` - Browser test fixing loop

3. **Hooks** (automatic)
   - PreToolUse: Route model based on tool type
   - PostToolUse: Track token usage
   - Stop: Review gate before session end
   - UserPromptSubmit: Classify complexity, suggest model

4. **Agents** (background workers)
   - Explorer (Haiku) - Codebase discovery
   - Implementer (Sonnet) - Code generation
   - Reviewer (Opus/Sonnet) - Code review
   - Tester (Haiku) - Test execution and result collection

## What Existing Plugins Don't Cover

Gap analysis from comparison matrix:

| Need | Covered By | Gap |
|------|------------|-----|
| Auto model routing | claude-router | No workflow integration |
| Multi-model review | Flow-Next | Requires external setup |
| Ralph loops | oh-my-claudecode | No model routing within loops |
| Browser testing | Playwright skill | No multi-model optimization |
| Token tracking | claude-hud, ccburn | Separate tools, no integration |
| Plan-first workflow | Flow-Next | Good, but no model routing |
| Combined solution | Nothing | **This is our opportunity** |

## Configuration Design

### Minimal Config (works out of box)
```yaml
# .claude/multi-model.local.md frontmatter
mode: smart     # smart | eco | review
```

### Advanced Config
```yaml
mode: smart
models:
  planning: opus
  implementation: sonnet
  exploration: haiku
  review: opus
ralph:
  max_iterations: 20
  model: sonnet
  exploration_model: haiku
review:
  external_enabled: false
  external_command: "codex review"
tracking:
  show_savings: true
  budget_warning_pct: 80
```

## Differentiation

Our plugin vs existing solutions:

1. **Unified**: One plugin for routing + workflows + review + ralph (vs installing 4 plugins)
2. **Native**: Built for Claude Code plugin system (vs external frameworks)
3. **Browser-aware**: First-class Playwright/testing workflow support
4. **Transparent**: Shows token savings in real-time
5. **Simple**: 4 modes vs 7, sensible defaults, zero required config
6. **Generic**: No hardcoded project names/paths per repo rules

## Open Questions

1. Should we build on top of Agent Teams (experimental) or use subagent Task tool?
2. How to handle model routing for subscription users (no direct API control)?
3. Should external model review (GPT) be a core feature or optional addon?
4. How much of Flow-Next's receipt-based gating should we adopt?
5. Should we integrate ccburn/claude-hud or build our own tracking?

## Sources

All sources documented in individual research files (01-07).
