# Token Optimization Strategies

## The Problem

Claude Max subscription has two-layer token economy:
- **5-hour rolling windows** - resets 5 hours after first message
- **Weekly limits** - caps total usage across all sessions
- Separate buckets per model tier

Opus burns allocation ~5x faster than Sonnet. A single complex prompt to Opus
costs what 5 equivalent Sonnet prompts would.

## Model Routing Strategy

### Tier Assignment

| Task Type | Recommended Model | Rationale |
|-----------|-------------------|-----------|
| Architecture decisions | Opus | Superior reasoning needed |
| Multi-file refactoring | Opus | Complex coordination |
| Code generation | Sonnet | Good enough, 5x cheaper |
| File exploration | Haiku | Fast, 15x cheaper |
| Simple edits | Haiku | Minimal reasoning needed |
| Test generation | Sonnet | Moderate complexity |
| Code review | Sonnet + external | Cross-model diversity |
| Documentation | Haiku/Sonnet | Straightforward |

### Distribution Target
- 10-20% Opus (planning, architecture, complex debugging)
- 50-60% Sonnet (implementation, moderate reasoning)
- 20-30% Haiku (exploration, simple tasks, subagents)

## Context Management Techniques

### 1. Proactive Compaction
- Execute `/compact` at 70% context usage
- ~50% context reduction while preserving critical decisions
- Commit pending changes before compacting (restore point)

### 2. Query Specificity (WHAT/WHERE/HOW/VERIFY)
- 70-95% token savings on file reads
- Instead of "Check auth.ts for issues" -> "Check `login()` in auth.ts:45-60"
- Always specify line numbers, function names, file paths

### 3. Session Hygiene
- `/clear` between unrelated task categories
- One chat window per task
- Keep AGENTS.md under 60 lines to reduce context loading

### 4. MCP Tool Search
- Enable `ENABLE_TOOL_SEARCH` for lazy loading
- 85% reduction in context overhead
- Without: 5 servers x 2,000 tokens = 10,000 tokens
- With: ~1,500 tokens total overhead

### 5. .claudeignore
Exclude from scanning:
```
node_modules/
build/
dist/
*.log
.git/
coverage/
```

### 6. Headless Mode
- `claude --print "run tests"` for CI/CD
- Significantly reduces tokens in non-interactive scenarios

### 7. Batch Operations
- ~40% reduction vs sequential operations
- Combine multiple file reads into single requests
- Combine multiple edits into single operations

## Session Timing Strategy

- Start sessions 2-3 hours before peak work time
- Position the 5-hour window reset during focus time
- Effectively doubles available tokens per work day
- Use ccburn tool for visual token tracking and depletion prediction

## Advanced Techniques

### RTK (Rust Token Killer) Output Filtering
- 70-90% token reduction on command output
- git log: 2,500 -> 685 tokens (72.6% reduction)
- git status: 1,200 -> 340 tokens (71.7% reduction)
- Works as bash wrapper or hook

### Local Execution Bridge
- Generate execution plan in Claude -> Pass to local script -> Return summary
- 91.7% reduction on multi-operation tasks
- Best for batch file operations, large-scale refactoring

### Progress File Pattern
- Maintain `progress.txt` committed after each iteration
- Eliminates costly context resets in loops
- Agent reads progress, understands state immediately

## Cost Monitoring Tools

| Tool | Purpose |
|------|---------|
| `/usage` | Quick session and weekly totals |
| `/context` | Current context window usage |
| ccburn | Visual burn-rate charts with depletion prediction |
| claude-hud | In-terminal context monitoring plugin |
| Usage dashboard | claude.ai/settings/usage |

## Target Savings

With full optimization stack:
- 60-80% token reduction vs unoptimized sessions
- Simple queries: ~80% savings via Haiku routing
- Mixed workloads: 50-70% savings via model routing
- Context management: additional 40-60% via compaction and specificity

## Sources

- [JuanjoFuchs: Maximizing Claude Code Pro/Max Plan](https://juanjofuchs.github.io/ai-development/2026/01/20/maximizing-claude-code-subscription.html)
- [12 Proven Token Techniques | Aslam Doctor](https://aslamdoctor.com/12-proven-techniques-to-save-tokens-in-claude-code/)
- [Token Optimization | DeepWiki](https://deepwiki.com/FlorianBruniaux/claude-code-ultimate-guide/10.4-token-optimization-techniques)
- [Claude Code Token Limits | Faros AI](https://www.faros.ai/blog/claude-code-token-limits)
- [Manage costs - Claude Code Docs](https://code.claude.com/docs/en/costs)
- [95% Token Savings | Medium](https://medium.com/@simonsruggi/youre-using-claude-code-wrong-here-s-how-to-save-95-of-tokens-db6114c1f4d6)
