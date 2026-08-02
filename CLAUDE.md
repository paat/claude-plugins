# Claude Plugins Repository

## Target

Plugins in this repo are designed for **Estonian SaaS companies** — the primary audience is small Estonian businesses, e-residents, and micro-OÜs. However, all plugins must remain generic: no hardcoded company names, product names, or project-specific paths. Use template variables for anything that varies between projects.

## Mission

The main goal of this repository is to reach fully automatic market-demand satisfaction for SaaS projects: autonomous AI systems should discover real market needs, convert them into production-quality SaaS improvements, and deliver one-shot implementations without requiring user feedback to identify or complete the work.

## Efficiency & Anti-Slop

The Mission above stays primary. These rules exist because it fails two ways:
token burn makes autonomy uneconomical, and slop makes one-shot delivery
untrustworthy. Never skip needed work to save tokens — cut waste, not scope.

### Runtime — how plugins behave on target projects

- Plugins are intended to run inside development containers with the AI coding
  agent in full unrestricted ("YOLO") mode; the container is the security boundary
- Every command, skill, and agent prompt must instruct its agents to be
  token-frugal: read only what the task needs, use targeted ranges instead of
  full-file dumps, never re-read content already in context
- Subagent fan-out must pay for itself — one pass by default; parallelize only
  when the work is independent and the extra coverage is needed
- Autonomous loops must detect "no work to do" early and exit — a no-op cycle
  should cost near-zero tokens

### Output — the code, PRs, issues, and reports plugins produce

- Follow KISS, YAGNI, and DRY: use the simplest sufficient design, add no
  speculative capability, and remove meaningful duplication without forcing
  premature abstractions
- Diffs touch only what the task requires: no drive-by refactors, no
  speculative abstractions, no defensive boilerplate
- No comments that restate the code, no prose that restates the diff, no
  padded summaries, no emoji. A PR body states what changed, why, and how it
  was verified — nothing else
- Issues and reports must be skimmable in 30 seconds: conclusion first, then
  only detail that changes what the reader does next

### This repo — plugin markdown is a token budget

- Every line of a command or skill prompt is loaded into every session that
  uses it; treat prompt length as a recurring cost, not documentation
- When a prompt outgrows ~150 lines, move static reference material into files
  loaded on demand, or cut it
- Never duplicate guidance across a plugin's commands and skills — state it
  once, reference it elsewhere
- When editing plugins, delete obsolete instructions instead of layering
  corrections on top of them

## Rules

- All plugins in this repo must be generic and project-agnostic
- Project-specific values must use template variables, not hardcoded strings
- No hardcoded project names, paths, stacks, or team conventions in plugin code
- Plugins must work with bash 4+ and standard POSIX tools
- External dependencies (jq, awk, sed) must be documented in README
- Before implementing any fix or enhancement, evaluate whether the change is needed for both plugin surfaces: Claude Code (`commands/`, `skills/`, `agents/`, `hooks/`, README, `.claude-plugin/plugin.json`) and Codex (`.codex-plugin/plugin.json`, generated workflow skills, `.agents/plugins/marketplace.json`). The two surfaces go hand-in-hand; keep behavior equivalent or document any host-specific difference.
- ALWAYS bump the plugin version in BOTH `.claude-plugin/plugin.json` AND the root `.claude-plugin/marketplace.json` before pushing — both must stay in sync
- After cloning, run `git config core.hooksPath .githooks` to enable the pre-push version check hook
- AGENTS.md is a symlink to CLAUDE.md — edit CLAUDE.md only
- Every plugin's README MUST include an end-user-viewable **Installation** section listing the three recommended scopes:
  - **Install for you** (user scope) — available in all your projects
  - **Install for all collaborators on this repository** (project scope) — committed, shared with the team
  - **Install for you, in this repo only** (local scope) — just you, just this repo

<!-- saas-startup-team:engineering-principles:start -->
## Engineering principles

Follow KISS, YAGNI, and DRY on every change:

- **KISS** — simplest design that fully ships the product need. Prefer boring, managed infrastructure one founder can run alone. Do not add enterprise machinery (service splits, self-operated brokers, SSO/SAML/SCIM hierarchies, multi-region HA, heavyweight observability) unless `Done` or a concrete security, legal, reliability, or operability requirement needs it.
- **YAGNI** — no speculative features, premature abstractions, unused config, or defensive branches for states that cannot happen. Do not expand scope because a future idea might need it.
- **DRY** — remove *meaningful* duplication (copy-pasted logic or restated rules that will drift). Do not invent frameworks for two similar lines, and keep intentional decorrelated variants (e.g. independent review legs) separate.

These apply to product code, tests, docs, prompts, and agent workflows. Completeness of authentication, validation, payments/data correctness, backups/recovery, and honest failure states is never cut for "simplicity."
<!-- saas-startup-team:engineering-principles:end -->
