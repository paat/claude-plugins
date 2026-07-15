---
name: codex-subagent-codex-critique-workflow
description: "Run /codex-critique workflow from codex-subagent; alias /codex-subagent:codex-critique."
---

# /codex-subagent:codex-critique Codex Workflow

This generated skill is the Codex-native plugin surface for `/codex-subagent:codex-critique`.
Also use it when the user invokes `/codex-critique` or asks for the same workflow by name.

Source command: `../../commands/codex-critique.md`

## Run Protocol

1. Treat the user text after the command name as `$ARGUMENTS`.
2. Read the source command file before executing. It is the workflow checklist after applying the Codex replacements in this skill.
3. Execute the workflow through Codex-native mechanisms: Codex skills, direct task sequencing in the current session, the Codex CLI, or Codex-supported multi-agent tooling when available.
4. Do not create user-local `~/.codex/prompts` wrappers. This skill is the reusable plugin-bundled workflow surface.
5. When the source command says `Skill('plugin:skill')`, load the named plugin skill normally.
6. When the source command references `${CLAUDE_PLUGIN_ROOT}/path`, resolve it to this installed plugin root and use `path` under that root. Do not require the environment variable to exist.
7. When the source command contains a Claude-only primitive, use the Codex replacement:
   - `AskUserQuestion` -> ask the user directly; in non-interactive runs, stop and report the exact required input.
   - Claude slash-command execution -> invoke this skill or the corresponding plugin skill.
   - Claude `Task` / `Agent` / `TeamCreate` dispatch -> use Codex-native multi-agent tooling if available, `codex exec --dangerously-bypass-approvals-and-sandbox` when a separate Codex process is useful, or a fresh role phase in the current Codex session. The development container is the security boundary.
   - `ScheduleWakeup` -> use Codex session continuation or an explicit user-visible status checkpoint; do not depend on a Claude lifecycle hook.

## Command Metadata

- Plugin: `codex-subagent`
- Command aliases: `/codex-subagent:codex-critique`, `/codex-critique`
- Source description: Pure-reasoning critic via Codex/GPT-5.6 Sol - paste the artifact + context, no repo access needed
