---
name: google-ads-strategist-ads-diff-workflow
description: "Run /ads-diff workflow from google-ads-strategist; alias /google-ads-strategist:ads-diff."
---

# /google-ads-strategist:ads-diff Codex Workflow

This generated skill is the Codex-native plugin surface for `/google-ads-strategist:ads-diff`.
Also use it when the user invokes `/ads-diff` or asks for the same workflow by name.

Source command: `../../commands/ads-diff.md`

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
- Command aliases: `/google-ads-strategist:ads-diff`, `/ads-diff`
- Source description: Show what changed between two iterations of a campaign - the diff across keywords, copy, targeting, bids, and landing pages - plus the hypothesis that drove the change. Usage: /ads-diff [campaign] <v_a> <v_b>
