---
name: maintain-loop
description: "Expeditor + safety coordinator for /maintain-loop; alias /saas-startup-team:maintain-loop."
---

# /saas-startup-team:maintain-loop Codex Workflow

This generated skill is the Codex-native plugin surface for `/saas-startup-team:maintain-loop`.
Also use it when the user invokes `/maintain-loop` or asks for the same workflow by name.

Role: **expeditor and intelligence safety manager** — heal friction, keep the slot
moving, protect irreversible gates. Not a party stopper: do not multi-hour soft-block
on path aliases, preservable worktrees, or receipt bookkeeping.

Source command: `../../commands/maintain-loop.md`

## Run Protocol

1. Treat the user text after the command name as `$ARGUMENTS`.
2. Read the source command file before executing. It is the workflow checklist after applying the Codex replacements in this skill.
3. Execute only as a thin coordinator using fresh Codex subagents. Never run the delegated maintain pass in the current session. Require a collaboration-capable, non-ephemeral coordinator session so each spawned child returns a stable identity. Require the child to send its parent a compact collaboration message only when issue/PR, delivery, blocker, or status changes.
4. Do not create user-local `~/.codex/prompts` wrappers. This skill is the reusable plugin-bundled workflow surface.
5. When the source command says `Skill('plugin:skill')`, load the named plugin skill normally.
6. When the source command references `${CLAUDE_PLUGIN_ROOT}/path`, resolve it to this installed plugin root and use `path` under that root. Do not require the environment variable to exist.
7. When the source command contains a Claude-only primitive, use the Codex replacement:
   - `AskUserQuestion` -> ask the user directly; in non-interactive runs, stop and report the exact required input.
   - Claude slash-command execution -> invoke this skill or the corresponding plugin skill.
   - Claude `Task` / `Agent` / `TeamCreate` dispatch -> spawn exactly one fresh Codex subagent and retain its returned identity; wait only after an identity is returned. Call `wait_agent` with `timeout_ms: 3600000`; never shorten waits to meet commentary cadence. After an empty timeout, emit at most one compact hourly heartbeat, then wait again. Follow the source command's referenced coordinator contract for every dispatch or terminal anomaly. Preserve its exact child bindings `--lease-run-id "$SAAS_INVOCATION_ID" --invocation-command maintain-loop`; never assume a fresh child inherits coordinator environment. Never substitute current-session execution
   - `ScheduleWakeup` -> use Codex session continuation or an explicit user-visible status checkpoint; do not depend on a Claude lifecycle hook.

## Command Metadata

- Plugin: `saas-startup-team`
- Command aliases: `/saas-startup-team:maintain-loop`, `/maintain-loop`
- Source description: Expeditor + safety coordinator for sequential maintenance. Usage: /maintain-loop [flags]
