# Claude Code Native Multi-Model Capabilities

## Model Aliases

| Alias | Behavior |
|-------|----------|
| `default` | Opus 4.6 for Max/Teams/Pro users |
| `sonnet` | Latest Sonnet (currently 4.5) for daily coding |
| `opus` | Latest Opus (currently 4.6) for complex reasoning |
| `haiku` | Fast and efficient for simple tasks |
| `sonnet[1m]` | Sonnet with 1M token context window |
| `opusplan` | Opus for plan mode, auto-switches to Sonnet for execution |

Switch models mid-session with `/model <alias>`.

## Environment Variables

| Variable | Controls |
|----------|----------|
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | Which model the `opus` alias maps to |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Which model `sonnet` and opusplan execution maps to |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Which model `haiku` and background functionality maps to |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Which model subagents use |
| `CLAUDE_CODE_EFFORT_LEVEL` | `low|medium|high` - controls Opus 4.6 reasoning depth |

## OpusPlan Mode

The key built-in multi-model strategy:
- **Plan mode**: Uses Opus for complex reasoning and architecture decisions
- **Execution mode**: Automatically switches to Sonnet for code generation
- Achieves roughly 10-20% Opus / 80-90% Sonnet distribution
- 30-50% cost savings vs all-Opus approaches

## Agent Teams (Experimental)

Released February 6, 2026. Enable via settings:
```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

### Architecture
- **Team Lead**: Main session that spawns teammates and coordinates
- **Teammates**: Separate Claude Code instances, each in own context window
- **Task List**: Shared work items with dependency tracking and auto-unblocking
- **Mailbox**: Direct messaging between agents (not just to lead)

### Key Differences from Subagents
- Teammates message each other directly and self-coordinate
- Subagents only report back to parent
- Can specify models per teammate: "Use Sonnet for each teammate"

### Best Practices
- 5-6 tasks per teammate
- Break work so each teammate owns different files
- Start with research/review before parallel implementation

### Limitations
- No session resumption for in-process teammates
- One team per session, no nested teams
- Task status can lag
- Split panes require tmux or iTerm2

## Subagent Model Selection

The Task tool accepts a `model` parameter:
```
model: "sonnet" | "opus" | "haiku"
```

This allows per-subagent model selection. Prefer haiku for quick, straightforward
tasks to minimize cost and latency.

## Pricing Context (Feb 2026)

| Model | Input (per 1M) | Output (per 1M) | Relative Cost |
|-------|----------------|------------------|---------------|
| Opus 4.6 | $5 | $25 | 1x |
| Sonnet 4.5 | ~$1 | ~$5 | ~5x cheaper |
| Haiku 4.5 | ~$0.33 | ~$1.67 | ~15x cheaper |

## Token Economy for Max Subscription

- **5-hour rolling windows** and **weekly limits**
- Separate buckets for different models
- Opus burns allocation ~5x faster than Sonnet
- Haiku is ~1/3 of Sonnet's cost

## Sources

- [Model configuration - Claude Code Docs](https://code.claude.com/docs/en/model-config)
- [Claude Code model configuration | Help Center](https://support.claude.com/en/articles/11940350-claude-code-model-configuration)
- [Agent Teams - Claude Code Docs](https://code.claude.com/docs/en/agent-teams)
- [Addy Osmani - Claude Code Agent Teams](https://addyosmani.com/blog/claude-code-agent-teams/)
- [Hidden Multi-Agent System | paddo.dev](https://paddo.dev/blog/claude-code-hidden-swarm/)
