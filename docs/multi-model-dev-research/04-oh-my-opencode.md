# oh-my-opencode & oh-my-claudecode Analysis

Two related projects by the same team. oh-my-opencode targets OpenCode (multi-provider),
oh-my-claudecode targets Claude Code specifically. Both share architectural DNA.

## oh-my-opencode (30.8k stars)

GitHub: [code-yeongyu/oh-my-opencode](https://github.com/code-yeongyu/oh-my-opencode)

### Architecture: Named Agent Team

**Main Orchestrator: Sisyphus** (Opus 4.5 High)
- Primary coordinator
- Philosophy: agents as "dev team leads" with human oversight

**Specialized Agents:**

| Agent | Model | Role |
|-------|-------|------|
| Sisyphus | Opus 4.5 High | Orchestration, strategic decisions |
| Hephaestus | GPT 5.2 Codex Medium | Autonomous deep worker, goal-oriented execution |
| Oracle | GPT 5.2 Medium | Architecture review and debugging |
| Frontend Engineer | Gemini 3 Pro | Visual and interface development |
| Librarian | Claude Sonnet 4.5 | Documentation, open-source exploration |
| Explore | Claude Haiku 4.5 | Fast contextual grep, codebase mapping |

### Key Design Patterns

#### Context-Light Architecture
- Dispatches heavy exploration to cheaper models
- Preserves main agent (Opus) context for decisions
- This is the core token-saving mechanism

#### Task-Based Model Routing

| Task Type | Primary Model | Rationale |
|-----------|---------------|-----------|
| Strategic Logic | GPT 5.2 Medium | High-level reasoning |
| Autonomous Work | GPT 5.2 Codex Medium | Deep independent execution |
| Frontend | Gemini 3 Pro | Visual expertise |
| Documentation | Claude Sonnet 4.5 | Comprehensive analysis |
| Fast Exploration | Claude Haiku 4.5 | Best cost-performance |

#### "Ultrawork" Magic Keyword
Including "ultrawork" (or "ulw") in prompts triggers:
- Parallel agent exploration
- Deep codebase analysis
- Multi-model coordination
- Relentless execution until completion

### Quality Enforcement

- **Todo Continuation Enforcer**: Forces agents to complete tasks, no stopping midway
- **Comment Checker**: Prevents excessive AI-generated comments
- **LSP/AST Integration**: Surgical refactoring via Language Server Protocol

### Configuration

Locations: `.opencode/oh-my-opencode.json` or `~/.config/opencode/oh-my-opencode.json`

Capabilities:
- JSONC syntax with comments
- Per-agent model, temperature, and prompt overrides
- Concurrency limits by provider/model
- Category-based task delegation (visual, business-logic, custom)
- Disabled hooks configuration
- MCP customization

### Token Investment
Author reports ~$24,000 in token experimentation condensed into the framework.

---

## oh-my-claudecode (Claude Code Plugin)

GitHub: [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode)

### Installation
```bash
/plugin marketplace add https://github.com/Yeachan-Heo/oh-my-claudecode
/plugin install oh-my-claudecode
/oh-my-claudecode:omc-setup
```

npm package: `oh-my-claude-sisyphus`

### Execution Modes

| Mode | Purpose | Best For |
|------|---------|----------|
| **Team** (canonical) | Staged pipeline: plan -> PRD -> execute -> verify -> fix | Coordinated multi-agent work |
| **Autopilot** | Autonomous single lead agent | End-to-end features, minimal oversight |
| **Ultrawork** | Maximum parallel execution | Burst fixes/refactors |
| **Ralph** | Persistent verify/fix loops | Full completion guarantees |
| **Ecomode** | Token-efficient routing | Budget-conscious iteration |
| **Pipeline** | Sequential stage processing | Multi-step transformations |
| **Swarm/Ultrapilot** | Legacy facades routing to Team | Backward compatibility |

### Magic Keywords

```
team N:role "task"    # Team orchestration with N agents
autopilot:            # Full autonomous execution
ralph:                # Persistence mode
ulw                   # Ultrawork (parallel)
eco:                  # Ecomode (token-efficient)
plan                  # Planning interview
ralplan               # Iterative consensus planning
```

### Smart Model Routing
- Claude Haiku for simple tasks (cost-efficient)
- Claude Opus for complex reasoning (high-capability)
- Automatic delegation to appropriate agent
- **30-50% token savings** reported

### 32 Specialized Agents
Across domains:
- Architecture & design
- Research & analysis
- Testing & QA
- Data science
- Code review & optimization

### Multi-AI Integration (Optional)

| Provider | Install | Enables |
|----------|---------|---------|
| Gemini CLI | `npm i -g @google/gemini-cli` | Design review, UI consistency |
| Codex CLI | `npm i -g @openai/codex` | Architecture validation |

Works fully standalone - external providers are optional enhancement.

### Rate Limit Management
```bash
omc wait          # Check status
omc wait --start  # Enable auto-resume daemon (requires tmux)
omc wait --stop   # Disable daemon
```

### Notification Integration
Telegram and Discord callbacks for session summaries.

### Requirements
- Claude Code CLI
- Claude Max/Pro subscription OR Anthropic API key
- Optional: Gemini CLI, Codex CLI, tmux

---

## Design Lessons for Our Plugin

### What oh-my-opencode Gets Right
1. **Named agent roles** - Clear responsibility boundaries
2. **Context-light architecture** - Cheap models handle exploration, expensive models decide
3. **Magic keywords** - Zero-friction activation of complex workflows
4. **Per-agent model config** - Right model for the right task
5. **Quality enforcement hooks** - Prevent common AI failure modes

### What We Can Improve On
1. **Simpler execution** - oh-my-opencode requires OpenCode; we target Claude Code natively
2. **Fewer modes** - 7 modes is confusing; focus on the 3-4 that matter most
3. **Better defaults** - Should work well without configuration
4. **Transparent cost tracking** - Show token savings in real-time
5. **Browser testing integration** - oh-my-opencode lacks Playwright-specific workflows

### Critical Insight: Context-Light Architecture
The most impactful pattern: **main agent stays lean, cheap agents do heavy lifting**.

```
User Request -> Opus (analyze, plan, decide)
                  |
                  +-> Haiku (explore codebase, read files, grep)
                  +-> Sonnet (implement code, run tests)
                  +-> Haiku (verify results, report back)
                  |
               Opus (review, synthesize, respond)
```

This is the architecture our plugin should replicate.

## Sources

- [oh-my-opencode | GitHub](https://github.com/code-yeongyu/oh-my-opencode)
- [oh-my-claudecode | GitHub](https://github.com/Yeachan-Heo/oh-my-claudecode)
- [oh-my-opencode-slim | GitHub](https://github.com/alvinunreal/oh-my-opencode-slim)
- [ohmyopencode.com](https://ohmyopencode.com/) (note: unauthorized third-party site)
