# Claude Plugins Repository

## Target

Plugins in this repo are designed for **Estonian SaaS companies** — the primary audience is small Estonian businesses, e-residents, and micro-OÜs. However, all plugins must remain generic: no hardcoded company names, product names, or project-specific paths. Use template variables for anything that varies between projects.

## Mission

The main goal of this repository is to reach fully automatic market-demand satisfaction for SaaS projects: autonomous AI systems should discover real market needs, convert them into production-quality SaaS improvements, and deliver one-shot implementations without requiring user feedback to identify or complete the work.

## Rules

- All plugins in this repo must be generic and project-agnostic
- Project-specific values must use template variables, not hardcoded strings
- No hardcoded project names, paths, stacks, or team conventions in plugin code
- Plugins must work with bash 4+ and standard POSIX tools
- External dependencies (jq, awk, sed) must be documented in README
- Before implementing any fix or enhancement, evaluate whether the change is needed for both plugin surfaces: Claude Code (`commands/`, `skills/`, `agents/`, `hooks/`, README, `.claude-plugin/plugin.json`) and Codex (`.codex-plugin/plugin.json`, generated workflow skills, `.agents/plugins/marketplace.json`). The two surfaces go hand-in-hand; keep behavior equivalent or document any host-specific difference.
- ALWAYS bump the plugin version in BOTH `.claude-plugin/plugin.json` AND the root `.claude-plugin/marketplace.json` before pushing — both must stay in sync
- After cloning, run `git config core.hooksPath .githooks` to enable the pre-push version check hook
- Every plugin's README MUST include an end-user-viewable **Installation** section listing the three recommended scopes:
  - **Install for you** (user scope) — available in all your projects
  - **Install for all collaborators on this repository** (project scope) — committed, shared with the team
  - **Install for you, in this repo only** (local scope) — just you, just this repo
