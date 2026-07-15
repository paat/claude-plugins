---
name: saas-startup-team-lessons-deliver-workflow
description: "Run /lessons-deliver workflow from saas-startup-team; alias /saas-startup-team:lessons-deliver."
---

# /saas-startup-team:lessons-deliver Codex Workflow

This generated skill is the Codex-native plugin surface for `/saas-startup-team:lessons-deliver`.
Also use it when the user invokes `/lessons-deliver` or asks for the same workflow by name.

Source command: `../../commands/lessons-deliver.md`

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
- Every separate Codex role launch uses `scripts/codex-run-role.sh` with an explicit semantic profile and `--dangerously-bypass-approvals-and-sandbox`; the dev container is the security boundary. The adapter stays model-neutral; the launcher owns model and effort pinning.
- Treat business-founder, tech-founder, growth-hacker, lawyer, UX tester, and review loops as Codex role phases backed by `.startup/` files.
- Keep the file-based handoff protocol intact: every role phase reads the relevant handoff/state files and writes its expected deliverable before the next phase starts.
- If a multi-agent dispatch fails or returns an unknown/missing thread, do not wait or poll that handle. Check its expected artifact once and verify it belongs to the current handoff/run and current HEAD when repository-bound; a stale or unproven artifact counts as absent. Continue without relaunching only when that artifact is complete; otherwise establish that the original dispatch is terminal, then run the role exactly once in the current session or through `scripts/codex-run-role.sh`. Never let an original and fallback worker write the same artifact concurrently.
- Resolve commands and handoff paths from the current Git worktree. Never emit a hardcoded checkout root such as `/workspace`; use repository-relative paths or `git rev-parse --show-toplevel`.

## Command Metadata

- Plugin: `saas-startup-team`
- Command aliases: `/saas-startup-team:lessons-deliver`, `/lessons-deliver`
- Source description: Autonomous implementation of human-approved lessons. Picks up `lesson-approved` issues from the pinned plugin repo and delivers each into this plugin repo end-to-end - claim, implement, mechanical firewall, tribunal gate, test suite, dual version bump, PR with `Closes #N`, merge on green - with no manual trigger. The single human gate stays at approval (`/lessons-review`). Flags: --once, --dry-run (read-only), --max-issues N, --max-merges N, --max-pass-minutes N (default 90), --max-run-minutes N (default 120; 0=unlimited), --repo OWNER/REPO. Usage: /lessons-deliver [--once] [--dry-run]
