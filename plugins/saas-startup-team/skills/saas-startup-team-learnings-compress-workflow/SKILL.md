---
name: saas-startup-team-learnings-compress-workflow
description: "Run /learnings-compress workflow from saas-startup-team; alias /saas-startup-team:learnings-compress."
---

# /saas-startup-team:learnings-compress Codex Workflow

This generated skill is the Codex-native plugin surface for `/saas-startup-team:learnings-compress`.
Also use it when the user invokes `/learnings-compress` or asks for the same workflow by name.

Source command: `../../commands/learnings-compress.md`

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
   - Claude `Task` / `Agent` / `TeamCreate` dispatch -> use Codex-native multi-agent tooling when available, the bundled `scripts/codex-run-role.sh` with an explicit role/profile and task file for a separate process, or a fresh role phase in the current Codex session.
   - `ScheduleWakeup` -> use Codex session continuation or an explicit user-visible status checkpoint; do not depend on a Claude lifecycle hook.

## SaaS Startup Codex Rules

For `saas-startup-team` workflows in Codex:

- Use Codex as the primary and only coding agent.
- Do not invoke `claude`, `claude-code`, Claude Code, TeamCreate, or Claude subagent workflows.
- Do not route implementation to `tech-founder-claude` or `tech-founder-claude-maintain`; use the `tech-founder` skill, direct Codex implementation, or the bundled `scripts/codex-run-role.sh` for a separate process.
- Every separate Codex role launch uses `scripts/codex-run-role.sh` with an explicit semantic profile. The adapter stays model-neutral; the launcher owns model and effort pinning.
- Treat business-founder, tech-founder, growth-hacker, lawyer, UX tester, and review loops as Codex role phases backed by `.startup/` files.
- Keep the file-based handoff protocol intact: every role phase reads the relevant handoff/state files and writes its expected deliverable before the next phase starts.

## Command Metadata

- Plugin: `saas-startup-team`
- Command aliases: `/saas-startup-team:learnings-compress`, `/learnings-compress`
- Source description: Compress one docs/learnings/<topic>.md into the house style behind a semantic-preservation gate - strips over-emphasis, adds canonical labels, routes landmines, promotes general standards, splits docs over 30KB. Non-destructive preview + changelog before any write.
