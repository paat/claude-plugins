# codex-subagent

Drive the **OpenAI Codex CLI** (`codex exec`, GPT-5.6 Sol with task-routed `low` through `xhigh` effort and explicit `max`/`ultra`) as **subagents** from Claude Code, with Claude as the controller. You get an independent second model that reads the repo, edits files, runs tests, and commits — orchestrated task-by-task from a written plan — plus a high-value pre-flight review that catches integration defects a same-model pass rationalizes past.

This plugin packages the non-obvious operational gotchas so you don't re-derive them.

## Mission Fit

`codex-subagent` is implementation infrastructure. It gives a controller agent an
independent Codex worker for plan-driven implementation and review, reducing same-model
blind spots in one-shot SaaS delivery.

## Execution posture: unrestricted inside the development container

Every Codex subprocess uses `--dangerously-bypass-approvals-and-sandbox`. The development container is the security boundary; the wrapper does not expose a weaker sandbox selector. Review and critique roles remain semantically read-only through their prompt contracts. Full rationale: [`skills/codex-subagent-driven-development/SKILL.md`](skills/codex-subagent-driven-development/SKILL.md#execution-posture).

## Prerequisites

1. **Install Codex CLI:**
   ```bash
   npm install -g @openai/codex
   ```
2. **Authenticate** Codex (`codex login` or your configured provider auth) — run it once interactively.
3. Standard tools: `bash` 4+, `git`, `timeout` (GNU coreutils), `awk`, `grep`, `mktemp`.

## Commands

| Command | Role | FS access | Use it for |
|---------|------|-----------|------------|
| `/codex-implement <plan.md> <taskN>` | implementer | yes (edits + commits) | implement ONE plan task with a test gate, then review the diff |
| `/codex-review [<target>]` | reviewer | yes (read-only walk) | independent second-model review of a diff / plan / file |
| `/codex-critique <question>` | pure-reasoning critic | no (context pasted) | poke holes in a methodology, design, or self-contained snippet |

All three call `scripts/codex-run.sh`, which builds the canonical invocation:

```bash
codex exec --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check -C <repo-abs-path> \
  -m gpt-5.6-sol -c 'model_reasoning_effort="high"' -
```

- `-C` sets the working dir (avoids a leading `cd`, which complicates Bash permission matching).
- `--skip-git-repo-check` avoids the repo-check prompt.
- The prompt is fed on **stdin** (`codex exec -`), never as a giant argv string — this dodges the `MAX_ARG_STRLEN` "Argument list too long" trap on large prompts.
- Model and effort are explicit, so `~/.codex/config.toml` cannot silently change unattended behavior. The role-agnostic wrapper defaults to `gpt-5.6-sol` + `high`; `/codex-implement` and `/codex-review` choose the cheapest sufficient `low|medium|high|xhigh` level unless an argument or `CODEX_SUBAGENT_EFFORT` overrides it. `max` and `ultra` are explicit-only; critique remains `high` by default.

### Effort routing

Use `low` for localized mechanical work, `medium` for ordinary well-specified multi-file work,
`high` for cross-module reasoning or hard debugging, and `xhigh` for high-impact security, data,
payments, migrations, or concurrency. `max` is exceptional. `ultra` enables automatic task
delegation and must stay bounded to one task or review pass with a finding cap and hard stop.

## The wrapper: `scripts/codex-run.sh`

A standalone, role-agnostic runner you can also call directly:

```bash
scripts/codex-run.sh [--dir D] [--model M] [--effort E] [--timeout S] [--out F] [--prompt-file F] [PROMPT]
echo "build a prompt" | scripts/codex-run.sh --dir /path/to/repo --timeout 600
```

It encodes every gotcha — the fixed unrestricted execution posture, dual timeouts, output capture, and missing-codex handling. Full list: [`skills/codex-subagent-driven-development/SKILL.md`](skills/codex-subagent-driven-development/SKILL.md#operational-gotchas-all-handled-by-the-wrapper-but-know-them).

`--print-cmd` shows exactly what would run without executing it.

## Skill

`codex-subagent-driven-development` teaches Claude the full controller loop — write the plan → pre-flight `/codex-review` the plan against real source → reconcile task blockers → `/codex-implement` one task → review the diff → at most one targeted correction → ledger → next task. It mirrors superpowers subagent-driven-development but with Codex as the implementer.

## Agent

`codex-reviewer` — a thin Bash-only agent that runs the wrapper for an independent read-only Codex review and returns its findings verbatim.

## The implementer contract (what made it reliable)

`/codex-implement` dispatches Codex with a strict contract: one named task only, exact plan code, an evidence gate for scope expansion, adjacent-issue quarantine, targeted tests, and a stop after the required commit/report when Done passes. Full text: [`commands/codex-implement.md`](commands/codex-implement.md) steps 2-3.

## Minimal-diff scope control

`/codex-implement` includes a post-implementation scope check: reject anything outside the named task — unrelated files, opportunistic refactors, new abstractions, defensive dead code, formatting/import churn, or over-broad tests. Full checklist: [`commands/codex-implement.md`](commands/codex-implement.md) step 5.

## Why the pre-flight review is high-value

Pointed at a written plan + the real source files, GPT-5.6 Sol finds real integration defects a same-model pass misses: line-anchor drift, dispatch-signature mismatches (builder arity/return type), a second validator recomputing totals with the wrong formula, renderers hardcoding old field names. Run `/codex-review <plan.md>` **before** implementing.

## Relationship to other plugins

The `saas-startup-team` plugin also drives `codex exec` workers. Both plugins run Codex unrestricted with the exact bypass flag because the development container is the security boundary. What differs is the **orchestration contract**, which is why the two keep separate scripts rather than sharing code:

| | `codex-subagent` (this plugin) | `saas-startup-team` |
|---|---|---|
| Execution | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-bypass-approvals-and-sandbox` |
| Commits | Codex commits the named files per task | Codex must **not** commit (a handoff hook does) |
| Driven by | a written plan + task id | business→tech handoff files |
| Prompt | role-agnostic | opinionated production contract |

Use this plugin for one generic, plan-driven Codex worker or reviewer; use `multi-model-orchestrator` when the request needs task-by-task effort routing plus independent Opus and Sol final reviews; use `saas-startup-team` for its handoff-driven team loop. Each plugin installs and works standalone.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install codex-subagent@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

## Tests

```bash
bash plugins/codex-subagent/tests/run-tests.sh
```

Unit + integration proofs for the wrapper (no real Codex calls — a stub `codex` on `PATH` verifies the exact bypass invocation and simulates the happy path, fallback parsing, timeout/partial-run, and missing-binary scenarios).

## License

MIT
