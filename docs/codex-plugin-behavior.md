# Codex Plugin Behavior Notes

This repo can publish the same plugin directories to Claude Code and Codex, but some plugins are
intentionally not behavior-identical across runtimes.

## Runtime Differences

| Plugin | Claude Code behavior | Codex behavior |
|---|---|---|
| Marketplace refresh | Claude Code owns its plugin update lifecycle. | Use `scripts/refresh-codex-plugin.sh PLUGIN@MARKETPLACE`; after the Codex install command returns, it restores versioned cache paths used by active sessions and bounds cleanup by age and count. A concurrent read can fail during Codex's replacement window and should be retried after the wrapper returns. Start a new thread to load the new version. If a locator is already missing, use `scripts/resolve-codex-plugin-resource.sh` to resolve the equivalent resource from the same plugin's current Codex version with an explicit warning. Never silently read the Claude plugin cache. |
| Multi-harness hooks (`irreversible-guard`, `silent-failure-scanner`, `multi-model-orchestrator`) | `hooks/hooks.json` with `CLAUDE_PLUGIN_ROOT`, snake_case `tool_name`/`tool_input`, exit 2 or `hookSpecificOutput.permissionDecision`. | Codex and Muse (`MUSE_EXPERIMENTAL_PLUGINS=1`) use the same `hooks/hooks.json` wire format (`CODEX_PLUGIN_ROOT` / `MUSE_PLUGIN_ROOT`). Grok uses `hooks/hooks.json` with `GROK_PLUGIN_ROOT`, camelCase `toolName`/`toolInput` (`run_terminal_command`), `toolInputTruncated` fail-closed checks, and top-level `{"decision":"deny"}` or exit 2; Grok's `SessionStart` uses `new`/`load` (not `compact`) and passive `PostToolUse` stdout is ignored, so post-compaction reanchor and context-watch injection are unavailable on Grok. Antigravity (`agy`) uses `.antigravity-plugin/plugin.json` + root `hooks.json` (`PreToolUse` on `run_command` resolving `toolCall.args.Cwd` before `cwd`, plus `PostInvocation` context-watch; Antigravity exposes no compaction hook event, so `SessionStart:compact` reanchor is omitted on `agy`). Antigravity requires a `decision` on `PreToolUse` (`{}` causes hard denial), so pass paths emit `{"decision":"allow"}` under this repo's dev-container boundary. |
| Hook trust | Claude Code runs an enabled plugin's hooks without a review step. | Codex runs a plugin hook only after a person trusts it in the TUI (`/hooks`), and asks again when a plugin update changes it; until then `codex exec` skips the hook silently, or reports `hook: <event> Failed` for a hook changed since its review. The only documented non-interactive route is the per-invocation flag `--dangerously-bypass-hook-trust`: `multi-model-orchestrator`'s `run-codex.sh` passes it, so worker legs run the installed plugins' hooks. The `tribunal-review` Codex leg stays sealed (`--disable plugins --disable hooks`). Interactive sessions need the flag on their own command line or the TUI review (checked 2026-11-22, codex-cli 0.171.0). |

## Rule

When adding or updating a plugin that intentionally behaves differently in Codex, record the
difference in this file and make the runtime branch explicit in tests.
