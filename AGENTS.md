# paat-plugins

Claude Code and Codex plugin marketplace (`paat/claude-plugins`) for autonomous SaaS delivery loops. Audience: Estonian SaaS companies, e-residents, micro-OUs. Every plugin stays generic: no hardcoded company, product or project names, paths or stacks; project-specific values are template variables.

## North star

Agents turn real market demand into merged, production-quality SaaS improvements with no human in the delivery loop. No human reviews PRs: automated gates are the review; the only human signals are customer feedback and the owner's validation of the live product.

- Facts that change (model rankings, tool/API versions, laws and rates, standards) live in skills and knowledge stores that cite a public source and an as-of date, are loaded on demand, and are never frozen into prompts. Project conventions stay in the target project.
- Scheduled jobs refresh that knowledge; a per-task decision such as model routing is a lookup, not a research run.
- Act on public evidence when a change is more likely better than worse; local records override it when they contradict it.

## Code ownership
AI agents own this codebase: they write, review, merge and maintain it under this repo's gates and
invariants, and there is no human developer who will catch what you miss. The owner sets product direction
and judges results, not code. Ownership covers code, tests, CI and docs; it adds no authority over data,
production, secrets or spend.
- You answer for the whole codebase, including what earlier agents wrote. A defect you find is yours to
  handle: fix the root cause when it causes or blocks your task, otherwise record it where this repo tracks
  work. "Pre-existing" or "not my change" is never a reason to walk past it.
- Security and customer-data findings never go into a public issue, PR or commit: flag them to the
  owner privately.
- A TODO or "needs human review" note finishes nothing: complete the work, or record the blocker and its
  unblock condition.
- Report to the owner in product terms (what works, what does not), not in code.

## Commands

```bash
git config core.hooksPath .githooks            # once per clone: pre-push version-bump check
python3 -m pip install -r requirements-dev.txt # PyYAML for the checks
python3 scripts/check-plugin-catalog.py
python3 scripts/check-plugin-content.py
python3 scripts/test_check_plugin_content.py
python3 scripts/test_check_plugin_catalog.py
python3 scripts/test_refresh_model_versions.py
python3 scripts/sync-codex-marketplace.py          # regenerate Codex manifests + .agents/plugins/marketplace.json
python3 scripts/sync-codex-marketplace.py --check  # what CI runs
bash plugins/<name>/tests/run-tests.sh             # one plugin's suite (saas-startup-team, saas-operations, ...)
```

CI (`.github/workflows/plugin-checks.yml`) also checks the shared script copies between `saas-startup-team`, `lawyer` and `saas-operations` with `cmp`, and the LOC budgets of `saas-startup-team` and `saas-operations`, and runs the `saas-operations` suite and (on a PR, only when that plugin changed) the `tribunal-review` suite. Edit one copy and the other must change identically.

## Layout

- `plugins/<name>/` holds one plugin: `.claude-plugin/plugin.json`, generated `.codex-plugin/plugin.json`, `skills/`, `commands/`, `hooks/`, `agents/`, `scripts/`, `tests/`.
- `.claude-plugin/marketplace.json` is the source of truth for the plugin list; `.agents/plugins/marketplace.json` is generated from it.
- `docs/` holds plans, research and runbooks; `docs/codex-plugin-behavior.md` records intentional Claude/Codex differences. Treat `docs/superpowers/` and research memos as history.
- Per-plugin READMEs and `scripts/*` header comments hold the detail; do not duplicate them here.

## Rules

- Both plugin surfaces go together: for every fix or feature, decide whether Claude Code (`commands/`, `skills/`, `agents/`, `hooks/`, README, `.claude-plugin/plugin.json`) and Codex (`.codex-plugin/plugin.json`, generated workflow skills, `.agents/plugins/marketplace.json`) both need it; keep behavior equivalent or document the difference in `docs/codex-plugin-behavior.md`.
- Bump the plugin version in both `plugins/<name>/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` before pushing, then run `scripts/sync-codex-marketplace.py`. The pre-push hook rejects a changed plugin without a bump or with mismatched versions.
- Plugins run on bash 4+ and standard POSIX tools; external dependencies (jq, awk, sed) go in the plugin README.
- Every plugin README has an end-user **Installation** section with three scopes: **Install for you** (user), **Install for all collaborators on this repository** (project), **Install for you, in this repo only** (local).
- Plugins run inside dev containers with the agent in unrestricted mode; the container is the security boundary.
- Plugin markdown is a token budget: every command or skill line loads into each session that uses it.
  - Prompts over ~150 lines: move static reference into files loaded on demand, or cut it.
  - State guidance once; do not duplicate across a plugin's commands and skills.
  - Delete obsolete instructions instead of layering corrections on top.
  - Every command, skill and agent prompt tells its agents to be token-frugal (targeted reads, no re-reads) and to exit early when there is no work. Subagent fan-out only where the work is independent and the coverage is needed.
- Output plugins produce (code, PRs, issues, reports): diffs touch only what the task requires; no comments that restate code; PR bodies say what changed, why, how verified; issues and reports lead with the conclusion.
- Instruction files plugins create or maintain in target projects are `AGENTS.md` only, never `CLAUDE.md`.
