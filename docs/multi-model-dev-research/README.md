# Multi-Model Development Research

Research compiled February 2026 for designing a Claude Code plugin that optimizes
token usage through intelligent multi-model orchestration.

## Problem Statement

Claude Max subscription token limits deplete too fast when using Opus 4.6 for all
tasks. Need intelligent routing: Opus as orchestrator, cheap models (Haiku/Sonnet)
for subagent work including discovery, coding, test fixing, browser testing, code
review, and planning.

## Research Documents

| Document | Contents |
|----------|----------|
| [01-native-capabilities.md](01-native-capabilities.md) | Claude Code's built-in multi-model support |
| [02-token-optimization.md](02-token-optimization.md) | Token saving techniques and cost strategies |
| [03-ralph-wiggum-loops.md](03-ralph-wiggum-loops.md) | Iterative autonomous development patterns |
| [04-oh-my-opencode.md](04-oh-my-opencode.md) | oh-my-opencode and oh-my-claudecode analysis |
| [05-existing-plugins.md](05-existing-plugins.md) | Existing multi-model plugins and frameworks |
| [06-browser-testing.md](06-browser-testing.md) | AI browser testing workflows |
| [07-code-review-workflows.md](07-code-review-workflows.md) | Multi-model code review patterns |
| [08-plugin-design-notes.md](08-plugin-design-notes.md) | Design insights for our plugin |

## Key Findings

1. **Native `opusplan` mode** already routes Opus for planning, Sonnet for execution
2. **`CLAUDE_CODE_SUBAGENT_MODEL`** env var controls subagent model selection
3. **oh-my-opencode** is the gold standard with $24k+ of token experimentation baked in
4. **Flow-Next** offers the best plan-first workflow with cross-model review gates
5. **claude-router** provides automatic complexity-based routing (80% savings on simple queries)
6. **Agent Teams** (experimental) enable parallel multi-model work with direct agent messaging
7. **Ralph loops** work best with fresh context per iteration + progress files on disk
8. **Token savings of 60-90%** are achievable through model routing + context management
