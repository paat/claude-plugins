# Codex Plugin Behavior Notes

This repo can publish the same plugin directories to Claude Code and Codex, but some plugins are
intentionally not behavior-identical across runtimes.

## Runtime Differences

| Plugin | Claude Code behavior | Codex behavior |
|---|---|---|
| `agent-sync` | `CLAUDE.md`, `.claude/**`, and `sources.json` are the source of truth; the hook regenerates `AGENTS.md`. | `AGENTS.md` is the source of truth; the hook mirrors root `AGENTS.md` to root `CLAUDE.md`. Codex ignores `CLAUDE.md` edits. |

## Rule

When adding or updating a plugin that intentionally behaves differently in Codex, record the
difference in this file and make the runtime branch explicit in tests.
