---
name: google-ads-strategist-ads-monitor-workflow
description: "Run /ads-monitor workflow from google-ads-strategist; alias /google-ads-strategist:ads-monitor."
---

# /google-ads-strategist:ads-monitor Codex Workflow

This generated skill is the Codex-native plugin surface for `/google-ads-strategist:ads-monitor`.
Also use it when the user invokes `/ads-monitor` or asks for the same workflow by name.

Source command: `../../commands/ads-monitor.md`

## Run Protocol

1. Treat the user text after the command name as `$ARGUMENTS`.
2. Read the source command file before executing. It is the workflow checklist after applying the Codex replacements in this skill.
3. Execute this as a semantically read-only role while Codex runs unrestricted inside the development-container security boundary. Do not modify repository or account state; if the required browser/integration is unavailable, stop and report that limitation.
4. Do not create user-local `~/.codex/prompts` wrappers. This skill is the reusable plugin-bundled workflow surface.
5. When the source command says `Skill('plugin:skill')`, load the named plugin skill normally.
6. When the source command references `${CLAUDE_PLUGIN_ROOT}/path`, resolve it to this installed plugin root and use `path` under that root. Do not require the environment variable to exist.
7. When the source command contains a Claude-only primitive, use the Codex replacement:
   - `AskUserQuestion` -> ask the user directly; in non-interactive runs, stop and report the exact required input.
   - Claude slash-command execution -> invoke this skill or the corresponding plugin skill.
   - Claude `Task` / `Agent` / `TeamCreate` dispatch -> use Codex-native multi-agent tooling or `codex exec --dangerously-bypass-approvals-and-sandbox`; the role prompt must prohibit repository and account mutations. The dev container, not a nested Codex sandbox, is the security boundary.
   - `ScheduleWakeup` -> use Codex session continuation or an explicit user-visible status checkpoint; do not depend on a Claude lifecycle hook.

## Command Metadata

- Plugin: `google-ads-strategist`
- Command aliases: `/google-ads-strategist:ads-monitor`, `/ads-monitor`
- Source description: Read live Google Ads metrics without repository or account writes. Requires a Google Ads user with server-enforced read-only access. Usage: /ads-monitor [campaign] [--range 7d|30d]
