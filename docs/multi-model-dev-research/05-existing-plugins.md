# Existing Multi-Model Plugins & Frameworks

## Claude Code Plugins

### claude-router (0xrdan)
**GitHub**: [0xrdan/claude-router](https://github.com/0xrdan/claude-router)

Automatic complexity-based routing to optimal Claude model.

**Routing Logic**: Two-tier system:
1. Rule-based classification (~0ms latency, zero cost) for obvious patterns
2. LLM fallback (~100ms, ~$0.001 via Haiku) for ambiguous queries
3. Multi-turn context awareness detects follow-ups

**Model Assignment**:
- Haiku: Simple queries (~$0.01)
- Sonnet: Standard coding (~$0.03)
- Opus: Complex analysis (~$0.06)

**Commands**:
- `/route <model>` - Manual override
- `/router-stats` - Usage statistics
- `/learn` - Extract conversation insights
- `/orchestrate` - Complex task execution with forking
- `/router-analytics` - HTML dashboard

**Cost Savings**: ~80% on simple queries, 50-70% mixed workloads

**Install**:
```bash
/plugin marketplace add 0xrdan/claude-plugins
/plugin install claude-router
```

---

### Flow-Next (gmickel)
**GitHub**: [gmickel/gmickel-claude-marketplace](https://github.com/gmickel/gmickel-claude-marketplace)

Plan-first orchestration with multi-model review gates.

**Commands**:
| Command | Purpose |
|---------|---------|
| `/flow-next:plan` | Codebase research, epic/task creation |
| `/flow-next:work` | Task execution with context re-anchoring |
| `/flow-next:interview` | Specification refinement (40+ questions) |
| `/flow-next:plan-review` | Cross-model plan validation |
| `/flow-next:impl-review` | Cross-model code review |
| `/flow-next:prime` | Codebase readiness assessment |
| `/flow-next:ralph-init` | Autonomous loop scaffolding |
| `/flow-next:epic-review` | Epic-completion verification gate |

**Key Innovations**:
- **Re-anchoring**: Re-reads specs from `.flow/` before every task
- **Receipt-based gating**: Requires documented proof (commits, test output, PRs)
- **Cross-model reviews**: Uses RepoPrompt (macOS) or Codex CLI (any OS) with GPT 5.2
- **Auto-block**: Fails stuck tasks after N attempts
- **Ralph integration**: Overnight autonomous mode with validation layers

**Install**:
```bash
/plugin marketplace add https://github.com/gmickel/gmickel-claude-marketplace
/plugin install flow-next
/flow-next:setup
```

---

### claude-code-router (musistudio)
**GitHub**: [musistudio/claude-code-router](https://github.com/musistudio/claude-code-router)

Proxy tool enabling Claude Code with alternative AI providers.

Supports: OpenRouter, DeepSeek, Ollama, Gemini, Volcengine, SiliconFlow.
Routes through configurable transformers. Dynamic model switching via `/model`.
GitHub Actions integration.

---

### wshobson/agents
**GitHub**: [wshobson/agents](https://github.com/wshobson/agents)

99 specialized agents, 15 orchestrators, 107 skills, 71 tools across 67 plugins.

**Preset Teams**: review, debug, feature, fullstack, research, security, migration.
Spawns pre-configured teams using Agent Teams experimental feature.

**Install**: `/plugin marketplace add wshobson/agents`

---

### Anthropic Official: code-review Plugin
**GitHub**: [anthropics/claude-code/plugins/code-review](https://github.com/anthropics/claude-code/blob/main/plugins/code-review/README.md)

Launches 4 parallel review agents scoring each issue for confidence.
Outputs issues with at least 80 confidence score.

---

### Anthropic Official: ralph-wiggum Plugin
**GitHub**: [anthropics/claude-code/plugins/ralph-wiggum](https://github.com/anthropics/claude-code/blob/main/plugins/ralph-wiggum/README.md)

Official Ralph loop implementation using Stop hook mechanism.

---

## External Frameworks

### claude-flow (12.9k stars)
**GitHub**: [ruvnet/claude-flow](https://github.com/ruvnet/claude-flow)

Enterprise-grade orchestration:
- 60+ agents
- SONA self-learning system
- 170+ MCP tools
- Supports using Claude Code with open models

### Claude Squad (5.8k stars)
Terminal interface managing multiple coding tools with Git worktree isolation.
Each agent works in its own worktree, preventing file conflicts.

### ccswarm
Rust-native multi-agent orchestration:
- Zero-cost abstractions
- Channel-based communication
- Minimal orchestration overhead

### codemoot
**GitHub**: [katarmal-ram/codemoot](https://github.com/katarmal-ram/codemoot)

Multi-model collaborative development: Claude + GPT debate, review,
and build together. Focuses on cross-model code review and architectural decisions.

---

## Monitoring & Analytics Tools

| Tool | Purpose |
|------|---------|
| ccburn | Visual burn-rate charts, depletion prediction |
| claude-hud | In-terminal context monitoring |
| `/usage` | Built-in session/weekly totals |
| `/context` | Current context window usage |

## Comparison Matrix

| Feature | claude-router | Flow-Next | oh-my-claudecode | wshobson/agents |
|---------|--------------|-----------|------------------|-----------------|
| Auto model routing | Yes | No (manual) | Yes | No |
| Multi-model review | No | Yes (GPT 5.2) | Yes (optional) | No |
| Ralph loop | No | Yes | Yes | No |
| Agent Teams | No | No | Yes | Yes |
| Token tracking | Yes (analytics) | No | Yes | No |
| Plan-first workflow | No | Yes | Yes | No |
| Browser testing | No | No | No | No |
| Ecomode | No | No | Yes | No |
| Zero config | Yes | Needs setup | Needs setup | Yes |

**Gap**: No existing plugin combines automatic model routing with browser testing
workflows, Ralph loops, AND multi-model code review in a single package.

## Sources

- [claude-router | GitHub](https://github.com/0xrdan/claude-router)
- [claude-code-router | GitHub](https://github.com/musistudio/claude-code-router)
- [gmickel-claude-marketplace | GitHub](https://github.com/gmickel/gmickel-claude-marketplace)
- [wshobson/agents | GitHub](https://github.com/wshobson/agents)
- [claude-flow | GitHub](https://github.com/ruvnet/claude-flow)
- [Top 10 Claude Code Plugins | Firecrawl](https://www.firecrawl.dev/blog/best-claude-code-plugins)
- [awesome-claude-plugins | GitHub](https://github.com/Chat2AnyLLM/awesome-claude-plugins)
