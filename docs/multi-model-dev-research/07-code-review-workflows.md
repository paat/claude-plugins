# Multi-Model Code Review Workflows

## Core Pattern: Cross-Model Review

Use Claude to draft code, then use a different model as reviewer.
Different models catch different blind spots, similar to human peer review.

### Why Multi-Model Review Works
- Each model has different training biases and strengths
- Author model has "tunnel vision" from its own generation process
- External model provides genuinely independent perspective
- Catches edge cases, inconsistencies, and forgotten details

## Implementations

### Anthropic Official: code-review Plugin
- Launches 4 parallel review agents
- Each scores issues for confidence
- Outputs issues with confidence >= 80
- All agents use Claude (same model family)

### Flow-Next: Cross-Model Review
- `/flow-next:impl-review` sends code to external model
- Uses RepoPrompt (macOS) or Codex CLI (any OS) with GPT 5.2 High
- Independent model provides perspective author model misses
- Receipt-based gating: review must pass before task completion

### codemoot: Claude + GPT Debate
- Multiple models debate architectural decisions
- Claude and GPT review each other's suggestions
- Produces consensus through structured disagreement

### oh-my-opencode: Oracle Agent
- Dedicated "Oracle" agent (GPT 5.2 Medium) for architecture review
- Separate from implementation agents
- Reviews after implementation, before merge

## Boris Cherny's Workflow (Claude Code Creator)

From InfoQ interview:
- Runs 10-15 simultaneous Claude Code sessions
- 5 local terminal + 5-10 on Anthropic website
- Uses Plan mode iteratively until satisfied
- PostToolUse hooks auto-format code
- Each team maintains CLAUDE.md documenting mistakes and best practices

## Agent Teams for Parallel Review

Using Claude Code experimental Agent Teams:
- Spawn 3 reviewers with different lenses:
  1. Security reviewer
  2. Performance reviewer
  3. Test coverage reviewer
- Team lead synthesizes findings
- Each reviewer can use different model (Sonnet for cost efficiency)

## Multi-Model Review Strategy for Our Plugin

### Tier 1: Self-Review (Free)
- Same Claude model reviews its own output
- Basic but catches obvious issues
- Use Haiku for cost efficiency

### Tier 2: Cross-Model Review (Claude Family)
- Implementation in Sonnet, review in Opus
- Different reasoning depths catch different issues
- Stays within Claude ecosystem (no external API needed)

### Tier 3: External Review (Optional)
- Send to GPT via Codex CLI or OpenRouter
- Maximum diversity of perspectives
- Requires external API setup

### Review Workflow
```
1. Sonnet implements feature
2. Haiku runs tests, verifies compilation
3. Opus reviews code quality, architecture
4. (Optional) External model provides independent review
5. Issues filed, Sonnet fixes, cycle repeats
```

## Review Focus Areas by Model

| Concern | Best Reviewer | Why |
|---------|---------------|-----|
| Logic errors | Opus | Deep reasoning |
| Security vulnerabilities | Opus + External | Different perspectives |
| Performance | Sonnet | Good enough, cheaper |
| Code style | Haiku | Pattern matching |
| Test coverage gaps | Sonnet | Moderate reasoning |
| Architecture | Opus | Complex tradeoffs |
| Documentation | Haiku | Straightforward |

## Automation Hooks

### PreToolUse Hook for Auto-Review
```json
{
  "event": "PostToolUse",
  "hooks": [{
    "type": "command",
    "command": "review-check.sh",
    "matcher": "Write|Edit"
  }]
}
```

Trigger lightweight review after every file write/edit.

### Stop Hook for Final Review
Before session ends, force a comprehensive review pass.

## Sources

- [Auto-Reviewing Claude's Code | O'Reilly](https://www.oreilly.com/radar/auto-reviewing-claudes-code/)
- [Claude Code Creator Workflow | InfoQ](https://www.infoq.com/news/2026/01/claude-code-creator-workflow/)
- [code-review plugin | anthropics/claude-code](https://github.com/anthropics/claude-code/blob/main/plugins/code-review/README.md)
- [Best AI Models for Coding 2026 | Faros AI](https://www.faros.ai/blog/best-ai-model-for-coding-2026)
- [codemoot | GitHub](https://github.com/katarmal-ram/codemoot)
- [Multiple Agent Systems Guide | eesel.ai](https://www.eesel.ai/blog/claude-code-multiple-agent-systems-complete-2026-guide)
