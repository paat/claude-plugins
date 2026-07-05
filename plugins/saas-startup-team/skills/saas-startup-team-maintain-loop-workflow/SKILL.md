---
name: saas-startup-team-maintain-loop-workflow
description: "Run /maintain-loop workflow from saas-startup-team; alias /saas-startup-team:maintain-loop."
---

# /saas-startup-team:maintain-loop Codex Workflow

This generated skill is the Codex-native plugin surface for `/saas-startup-team:maintain-loop`.
Also use it when the user invokes `/maintain-loop` or asks for the same workflow by name.

Source command: `../../commands/maintain-loop.md`

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

## Codex Maintain Hard Gates

During each Codex `/maintain-loop` issue-delivery cycle, enforce these merge predicates directly:

- Before implementation, identify the root cause / recurrence class; fix the class, not only the observed instance.
- For bug, monitor, customer, accounting, replay, and incident-class issues, add a locking regression test, durable contract test, monitor assertion, or equivalent guard that would fail on the old behavior.
- The PR body must state the red-before/green-after proof and why the same issue should not recur. If a durable guard is genuinely impossible, split or file a follow-up, or mark the issue human/blocked with the reason.
- Before starting `tribunal-review:closing-tribunal-loop`, run the Codex business-founder QA phase with Playwright on affected browser-visible flows and record the checked flows/evidence in the PR body. If no browser-visible surface changed, record `Business-founder Playwright QA: not applicable - <reason>` before tribunal.
- For every code PR, `tribunal-review:closing-tribunal-loop` is the main merge prerequisite: it runs `tribunal-review:tribunal-loop`, triages findings, applies fixes or follow-ups, and revalidates until the arbiter clears the gate.
- Any code diff, PR body edit that changes validation facts, rebase/update-from-main, or HEAD change invalidates the prior tribunal result and reopens the closing loop.
- Merge is forbidden unless the closing loop's latest arbiter verdict covers the current PR HEAD and latest diff, has zero critical/high findings, and recurrence proof is present when required. Medium/low findings may be triaged per the tribunal plugin.

## Command Metadata

- Plugin: `saas-startup-team`
- Command aliases: `/saas-startup-team:maintain-loop`, `/maintain-loop`
- Source description: Codex-first GitHub issue delivery loop. For each eligible issue, launch a fresh Codex context from the latest default branch, implement the issue, run Playwright acceptance QA, close the tribunal review/fix loop, merge to main, watch deploy, and verify the live app. Flags: --once, --dry-run, --issue N, --label LABEL, --max-issues N, --max-run-minutes N. Usage: /maintain-loop [--once] [--issue N] [--max-issues N]
