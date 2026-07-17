# multi-model-orchestrator

Route a software change through fresh, bounded Codex workers with a reasoning effort
chosen for each task, then review the complete diff independently with Opus and GPT-5.6
Sol. The controller verifies every finding against code and tests before changing anything.

Example request:

> Implement this with Codex subagents using appropriate reasoning efforts. Review the
> finished change with Opus and GPT-5.6 Sol Ultra.

The natural-language request activates the orchestration skill. The equivalent explicit
command is:

```text
/multi-model-orchestrator:orchestrate <implementation request> --final-codex-effort ultra
```

## Routing policy

- The controller owns intent, task boundaries, architecture judgment, and final arbitration.
- Fresh GPT-5.6 Sol workers implement one bounded task at a time. `low` is preferred for
  mechanical work, `medium` for ordinary multi-file features, and higher efforts require
  concrete uncertainty or risk.
- Opus is preferred for ambiguous product intent, frontend/UX judgment, architecture, and
  environment/build diagnosis. An Opus advice pass produces constraints for a Codex worker;
  the source edit still belongs to that worker when the user requested Codex implementation.
- Implementation fan-out is sequential unless tasks have disjoint files and state. Research
  and final read-only review may run in parallel.
- Final review is bounded to one initial pass per reviewer and one recheck after validated
  blocking fixes. Reviewers never edit the repository.

Explicit model or effort instructions override defaults. In particular, `ultra` is passed
literally to GPT-5.6 Sol when requested; it is not an alias for `xhigh` or `max`.

The detailed router and its July 2026 Reddit evidence are bundled under
`skills/multi-model-orchestration/references/`. Reddit reports are treated as anecdotal
operational signals, not benchmarks or permanent model rankings.

## Execution posture

Codex workers run with `--dangerously-bypass-approvals-and-sandbox`; the development
container is the security boundary. Opus advice can walk the repository with read-only tools.
Final reviewers receive a strict no-write contract. Start from a clean worktree so the
controller can attribute and review the complete produced diff.

## Prerequisites

- bash 4+
- git and GNU `timeout`
- OpenAI Codex CLI, authenticated
- Claude Code CLI, authenticated, when an Opus advice or review pass is requested

No `jq` dependency is required.

## Configuration

Defaults can be overridden without editing the plugin:

| Variable | Default | Purpose |
|---|---|---|
| `MMO_CODEX_MODEL` | `gpt-5.6-sol` | Codex worker/reviewer model |
| `MMO_OPUS_MODEL` | `opus` | Claude advice/reviewer model |
| `MMO_OPUS_EFFORT` | `xhigh` | Opus advice/review effort |

Per-request model and effort instructions remain authoritative.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install multi-model-orchestrator@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit
  `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in
  `.claude/settings.local.json`.

## Tests

```bash
bash plugins/multi-model-orchestrator/tests/run-tests.sh
```

The tests use stub CLIs; they do not call a model or consume quota.

## License

MIT
