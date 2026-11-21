# Codex Plugin Behavior Notes

This repo can publish the same plugin directories to Claude Code and Codex, but some plugins are
intentionally not behavior-identical across runtimes.

## Runtime Differences

| Plugin | Claude Code behavior | Codex behavior |
|---|---|---|
| Marketplace refresh | Claude Code owns its plugin update lifecycle. | Use `scripts/refresh-codex-plugin.sh PLUGIN@MARKETPLACE`; after the Codex install command returns, it restores versioned cache paths used by active sessions and bounds cleanup by age and count. A concurrent read can fail during Codex's replacement window and should be retried after the wrapper returns. Start a new thread to load the new version. If a locator is already missing, use `scripts/resolve-codex-plugin-resource.sh` to resolve the equivalent resource from the same plugin's current Codex version with an explicit warning. Never silently read the Claude plugin cache. |
| Multi-harness hooks (`irreversible-guard`, `silent-failure-scanner`, `multi-model-orchestrator`) | `hooks/hooks.json` with `CLAUDE_PLUGIN_ROOT`, snake_case `tool_name`/`tool_input`, exit 2 or `hookSpecificOutput.permissionDecision`. | Codex and Muse (`MUSE_EXPERIMENTAL_PLUGINS=1`) use the same `hooks/hooks.json` wire format (`CODEX_PLUGIN_ROOT` / `MUSE_PLUGIN_ROOT`). Grok uses `hooks/hooks.json` with `GROK_PLUGIN_ROOT`, camelCase `toolName`/`toolInput` (`run_terminal_command`), `toolInputTruncated` fail-closed checks, and top-level `{"decision":"deny"}` or exit 2; Grok's `SessionStart` uses `new`/`load` (not `compact`) and passive `PostToolUse` stdout is ignored, so post-compaction reanchor and context-watch injection are unavailable on Grok. Antigravity (`agy`) uses `.antigravity-plugin/plugin.json` + root `hooks.json` (`run_command`, `PostInvocation`, `SessionStart`), protojson `toolCall.args.CommandLine`, and `{"decision":"allow"|"deny"}` / `{"injectSteps":[...]}` (Antigravity requires a `decision` on `PreToolUse` — `{}` causes hard denial — so pass paths emit `{"decision":"allow"}` under this repo's dev-container boundary). |

## Rule

When adding or updating a plugin that intentionally behaves differently in Codex, record the
difference in this file and make the runtime branch explicit in tests.
