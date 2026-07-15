---
name: maintain-loop
description: "Run /maintain-loop workflow from saas-startup-team; alias /saas-startup-team:maintain-loop."
---

# /saas-startup-team:maintain-loop Codex Workflow

This generated skill is the Codex-native plugin surface for `/saas-startup-team:maintain-loop`.
Also use it when the user invokes `/maintain-loop` or asks for the same workflow by name.

Source command: `../../commands/maintain-loop.md`

## Run Protocol

1. Treat the user text after the command name as `$ARGUMENTS`.
2. Read the source command file before executing. It is the workflow checklist after applying the Codex replacements in this skill.
3. Execute only as a thin coordinator using fresh Codex subagents. Never run the delegated maintain pass in the current session. Require a collaboration-capable, non-ephemeral coordinator session so each spawned child returns a stable identity.
4. Do not create user-local `~/.codex/prompts` wrappers. This skill is the reusable plugin-bundled workflow surface.
5. When the source command says `Skill('plugin:skill')`, load the named plugin skill normally.
6. When the source command references `${CLAUDE_PLUGIN_ROOT}/path`, resolve it to this installed plugin root and use `path` under that root. Do not require the environment variable to exist.
7. When the source command contains a Claude-only primitive, use the Codex replacement:
   - `AskUserQuestion` -> ask the user directly; in non-interactive runs, stop and report the exact required input.
   - Claude slash-command execution -> invoke this skill or the corresponding plugin skill.
   - Claude `Task` / `Agent` / `TeamCreate` dispatch -> spawn exactly one fresh Codex subagent and retain its returned identity; wait only after an identity is returned. Any spawn error stops `pass-blocked` without waiting or retrying. If the thread is missing before one terminal result, stop unknown-terminal without reaping; one received terminal result is authoritative and is never polled again. Never substitute current-session execution
   - `ScheduleWakeup` -> use Codex session continuation or an explicit user-visible status checkpoint; do not depend on a Claude lifecycle hook.

## Command Metadata

- Plugin: `saas-startup-team`
- Command aliases: `/saas-startup-team:maintain-loop`, `/maintain-loop`
- Source description: Sequential fresh-subagent maintenance. Usage: /maintain-loop [flags]
