# codex-subagent

Drive the **OpenAI Codex CLI** (`codex exec`, gpt-5.5) as implementer, reviewer, and critic **subagents** from Claude Code, with Claude as the controller. You get an independent second model that reads the repo, edits files, runs tests, and commits — orchestrated task-by-task from a written plan — plus a high-value pre-flight review that catches integration defects a same-model pass rationalizes past.

This plugin packages the non-obvious operational gotchas so you don't re-derive them.

## Mission Fit

`codex-subagent` is implementation infrastructure. It gives a controller agent an
independent Codex worker for plan-driven implementation and review, reducing same-model
blind spots in one-shot SaaS delivery.

## The one unlock: `-s danger-full-access`, not `--dangerously-bypass-*`

Codex's own sandbox fails inside containers, and Codex's documented bypass flag is blocked by Claude Code's permission classifier. `-s danger-full-access` sidesteps both. The bundled wrapper defaults to this — you generally won't touch the flag. Full rationale: [`skills/codex-subagent-driven-development/SKILL.md`](skills/codex-subagent-driven-development/SKILL.md#the-one-unlock-you-must-know).

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
codex exec -s danger-full-access --skip-git-repo-check -C <repo-abs-path> -
```

- `-C` sets the working dir (avoids a leading `cd`, which complicates Bash permission matching).
- `--skip-git-repo-check` avoids the repo-check prompt.
- The prompt is fed on **stdin** (`codex exec -`), never as a giant argv string — this dodges the `MAX_ARG_STRLEN` "Argument list too long" trap on large prompts.
- Default model is Codex's default (gpt-5.5); override with `--model`.

## The wrapper: `scripts/codex-run.sh`

A standalone, role-agnostic runner you can also call directly:

```bash
scripts/codex-run.sh [--dir D] [--model M] [--sandbox MODE] [--timeout S] [--out F] [--prompt-file F] [PROMPT]
echo "build a prompt" | scripts/codex-run.sh --dir /path/to/repo --timeout 600
```

It encodes every gotcha — dual timeouts, output capture, bwrap detection, missing-codex handling. Full list: [`skills/codex-subagent-driven-development/SKILL.md`](skills/codex-subagent-driven-development/SKILL.md#operational-gotchas-all-handled-by-the-wrapper-but-know-them).

`--print-cmd` shows exactly what would run without executing it.

## Skill

`codex-subagent-driven-development` teaches Claude the full controller loop — write the plan → pre-flight `/codex-review` the plan against real source → reconcile drift → `/codex-implement` one task → review the diff → fix/re-dispatch → ledger → next task. It mirrors superpowers subagent-driven-development but with Codex as the implementer.

## Agent

`codex-reviewer` — a thin Bash-only agent that runs the wrapper for an independent read-only Codex review and returns its findings verbatim.

## The implementer contract (what made it reliable)

`/codex-implement` dispatches Codex with a strict contract: one named task only, exact plan code, a test gate, commit with the required trailer, and stop-and-report on any code-anchor mismatch. Full text: [`commands/codex-implement.md`](commands/codex-implement.md) steps 2-3.

## Minimal-diff scope control

`/codex-implement` includes a post-implementation scope check: reject anything outside the named task — unrelated files, opportunistic refactors, new abstractions, defensive dead code, formatting/import churn, or over-broad tests. Full checklist: [`commands/codex-implement.md`](commands/codex-implement.md) step 5.

## Why the pre-flight review is high-value

Pointed at a written plan + the real source files, gpt-5.5 finds real integration defects a same-model pass misses: line-anchor drift, dispatch-signature mismatches (builder arity/return type), a second validator recomputing totals with the wrong formula, renderers hardcoding old field names. Run `/codex-review <plan.md>` **before** implementing.

## Relationship to other plugins

The `saas-startup-team` plugin also drives `codex exec` (its `tech-founder-codex` agent). Both plugins now share the **same sandbox posture** — `-s danger-full-access`, no bypass flag — because it sidesteps the broken bwrap *and* passes Claude Code's classifier (see "The one unlock" above). What differs is the **orchestration contract**, which is why the two keep separate scripts rather than sharing code:

| | `codex-subagent` (this plugin) | `saas-startup-team` |
|---|---|---|
| Sandbox | `-s danger-full-access` | `-s danger-full-access` (same) |
| Commits | Codex commits the named files per task | Codex must **not** commit (a handoff hook does) |
| Driven by | a written plan + task id | business→tech handoff files |
| Prompt | role-agnostic | opinionated production contract |

Use this plugin for generic, plan-driven Codex orchestration; use `saas-startup-team` for its handoff-driven team loop. The shared, reusable asset is the **posture and operational knowledge** (this README + the `codex-subagent-driven-development` skill), not a shared runtime script — each plugin must install and work standalone.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install codex-subagent@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

## Tests

```bash
bash plugins/codex-subagent/tests/run-tests.sh
```

Unit + integration proofs for the wrapper (no real Codex calls — a stub `codex` on `PATH` simulates the happy path, fallback parsing, bwrap failure, timeout/partial-run, and missing-binary scenarios).

## License

MIT
