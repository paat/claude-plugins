---
name: google-ads-strategist-ads-distill-workflow
description: "Codex workflow for /google-ads-strategist:ads-distill, /ads-distill. Roll the hypothesis log into the learnings file - distill patterns that hold across >= 3 iterations into principles, and propose graduation candidates for project-level auto-memory. Usage: /ads-distill [campaign] Triggers: /google-ads-strategist:ads-distill, /ads-distill"
---

# /google-ads-strategist:ads-distill Codex Workflow

This generated skill is the Codex-native plugin surface for `/google-ads-strategist:ads-distill`.
Also use it when the user invokes `/ads-distill` or asks for the same workflow by name.

Source command: `../../commands/ads-distill.md`

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
   - Claude `Task` / `Agent` / `TeamCreate` dispatch -> use Codex-native multi-agent tooling if available, `codex exec` when a separate Codex process is useful, or a fresh role phase in the current Codex session.
   - `ScheduleWakeup` -> use Codex session continuation or an explicit user-visible status checkpoint; do not depend on a Claude lifecycle hook.

## Command Metadata

- Plugin: `google-ads-strategist`
- Command aliases: `/google-ads-strategist:ads-distill`, `/ads-distill`
- Source description: Roll the hypothesis log into the learnings file - distill patterns that hold across >= 3 iterations into principles, and propose graduation candidates for project-level auto-memory. Usage: /ads-distill [campaign]
