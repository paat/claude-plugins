---
name: saas-startup-team-lessons-review-workflow
description: "Run /lessons-review workflow from saas-startup-team; alias /saas-startup-team:lessons-review."
---

# /saas-startup-team:lessons-review Codex Workflow

This generated skill is the Codex-native plugin surface for `/saas-startup-team:lessons-review`.
Also use it when the user invokes `/lessons-review` or asks for the same workflow by name.

Source command: `../../commands/lessons-review.md`

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

## SaaS Startup Codex Rules

For `saas-startup-team` workflows in Codex:

- Use Codex as the primary and only coding agent.
- Do not invoke `claude`, `claude-code`, Claude Code, TeamCreate, or Claude subagent workflows.
- Do not route implementation to `tech-founder-claude` or `tech-founder-claude-maintain`; use the `tech-founder` skill, Codex CLI, or direct Codex implementation instead.
- Treat business-founder, tech-founder, growth-hacker, lawyer, UX tester, and review loops as Codex role phases backed by `.startup/` files.
- Keep the file-based handoff protocol intact: every role phase reads the relevant handoff/state files and writes its expected deliverable before the next phase starts.

## Command Metadata

- Plugin: `saas-startup-team`
- Command aliases: `/saas-startup-team:lessons-review`, `/lessons-review`
- Source description: The single human gate of the self-improvement loop. Lists open `lesson-candidate` issues in the pinned plugin repo and lets the investor approve (mark ready for /lessons-deliver) or close (not generic) each one, before any implementation. Usage: /lessons-review
