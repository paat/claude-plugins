# Codex Plugin Behavior Notes

This repo can publish the same plugin directories to Claude Code and Codex, but some plugins are
intentionally not behavior-identical across runtimes.

## Runtime Differences

| Plugin | Claude Code behavior | Codex behavior |
|---|---|---|
| `agent-sync` | `CLAUDE.md`, `.claude/**`, and `sources.json` are the source of truth; the hook regenerates `AGENTS.md`. | `AGENTS.md` is the source of truth; the hook mirrors root `AGENTS.md` to root `CLAUDE.md`. Codex ignores `CLAUDE.md` edits. |
| Marketplace refresh | Claude Code owns its plugin update lifecycle. | Use `scripts/refresh-codex-plugin.sh PLUGIN@MARKETPLACE`; after the Codex install command returns, it restores versioned cache paths used by active sessions and bounds cleanup by age and count. A concurrent read can fail during Codex's replacement window and should be retried after the wrapper returns. Start a new thread to load the new version. If a locator is already missing, use `scripts/resolve-codex-plugin-resource.sh` to resolve the equivalent resource from the same plugin's current Codex version with an explicit warning. Never silently read the Claude plugin cache. |

## Rule

When adding or updating a plugin that intentionally behaves differently in Codex, record the
difference in this file and make the runtime branch explicit in tests.
