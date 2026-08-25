# multi-model-orchestrator

Route each software task to a current Claude Code, Codex, or Grok Build model with the cheapest
sufficient reasoning effort, then verify the result deterministically and review it independently
when the risk justifies another pass.

The standalone `route-model-task` skill can return route cards without executing work. The
`multi-model-orchestration` skill and `/multi-model-orchestrator:orchestrate` command use those
cards to dispatch bounded workers.

Example requests:

> Implement this change. Choose the model and effort per task.

> Use Codex only. Do not call Claude or Grok.

> Do not use Claude. Use Grok for the bounded implementation and GPT-5.6 Sol for review.

Natural-language restrictions are hard constraints. The router never silently substitutes a
denied provider, model, or unsupported effort.

## Current model catalog

Older generations are intentionally excluded.

| Provider | Models | Typical role |
|---|---|---|
| Claude Code | `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5`, `claude-fable-5` | Fast triage through highest-capability long-running work |
| Codex | `gpt-5.6-luna`, `gpt-5.6-terra`, `gpt-5.6-sol` | Mechanical work through hard technical implementation and review |
| Grok Build | `grok-4.5` | Fast bounded implementation, reproduction, and independent review |

Haiku 4.5 is the latest Haiku and does not use Claude's current effort parameter. Claude Fable 5,
Opus 5, and Sonnet 5 support `low` through `max`; GPT-5.6 supports `low` through `max`, with
Sol-only `ultra` available for bounded internal fan-out; Grok 4.5 supports `low`, `medium`, and
`high`.

## Routing policy

The router first applies provider/model restrictions, then scores task role, ambiguity,
scope/coupling, risk, deterministic validation, modality, latency, and expected duration.

| Task | Starting route |
|---|---|
| File map, exact rename, focused check | Haiku 4.5 or GPT-5.6 Luna |
| Ordinary well-specified coding | Sonnet 5 or GPT-5.6 Terra at medium |
| Fast bounded implementation or reproduction | Grok 4.5 at medium |
| Hard backend/data work, debugging, security, technical review | GPT-5.6 Sol at high or xhigh |
| Large refactor, architecture, UX/visual work, long tool loop | Opus 5 at high |
| Unusually hard or days-long work | Fable 5 at high or xhigh |

These are starting hypotheses, not a universal leaderboard. Local completion, latency,
scope-control, and test data should override them. Higher effort is not a repair for unclear
acceptance criteria. `max` and `ultra` require exceptional evidence or an explicit request.

The detailed router and dated evidence notes live under `skills/route-model-task/references/` and
`skills/multi-model-orchestration/references/`. Vendor benchmark claims are not compared as if
their harnesses and token budgets were identical.

## Meta orchestration

`/multi-model-orchestrator:meta-orchestrate <mission brief>` runs the show over a queue of
work. The brief is free-form and describes WHAT to achieve — an epic issue, an issue list to
prioritize and implement, a goal to discover tasks for, or "scan for new workitems" — plus any
autonomy bounds and model restrictions. HOW is the orchestrator's job: per-item worker legs
routed through the model catalog, adversarial review plus a bounded delta re-review by a
different provider, merge only on a literal ready signal, and a crash-safe handoff file updated
after every decision. `--resume [handoff-path]` continues from the newest (or named) handoff;
trailing text is treated as pre-answered decisions. A scan that finds nothing new writes
nothing and stops; recurrence belongs to `/loop` or cron.

When an item depends on out-of-repo facts, a read-only research leg records tiered evidence in a
tracked memo. Unknowns are researched before they are escalated as human decisions.

Delivery chains `tribunal-review:closing-tribunal-loop` (epic PR in epic mode, per-item PRs
otherwise), so that plugin must be installed. Code delivers through GitHub branches/PRs;
additional workitem trackers (e.g. Plane) and model constraints for orchestrator legs are
configured per repo in `.claude/multi-model-orchestrator.local.md`:

```yaml
---
sources:
  - name: plane
    list: "curl -s -H \"X-API-Key: $PLANE_API_KEY\" $PLANE_URL/.../issues/ | jq -r '...'"
    close: "curl -s -X PATCH ..."
models:
  allow: [gpt-5.6-terra, grok-4.5]
  worker: "gpt-5.6-terra high"
---
```

Model constraints bind worker/reviewer/advise/research legs; the tribunal panel keeps its own
`TRIBUNAL_*` configuration.

## Execution posture

- The controller owns intent, restrictions, architecture judgment, task boundaries, and final
  arbitration.
- One fresh worker owns one bounded task. Writes are sequential unless files and generated state
  are disjoint.
- Every CLI leg runs in YOLO mode inside the development-container security boundary: Codex uses
  `--dangerously-bypass-approvals-and-sandbox`, Claude uses `--dangerously-skip-permissions`, and
  Grok uses `--sandbox none --permission-mode bypassPermissions`. Advice and review legs still
  receive semantic no-write contracts and read-only tool allowlists. Research legs receive the
  no-write contract with read-only repo tools and web tools enabled.
- Every task names allowed files and an exact gate. Reviewer prose is advisory until verified
  against code, tests, or rendered output.
- Final review defaults to the tribunal flow: push, PR, `tribunal-review:closing-tribunal-loop`
  until zero critical/high. Inline reviewer legs are the fallback when tribunal-review is not
  installed or the run is explicitly local/no-PR; there, ordinary nontrivial work gets at most
  one independent provider review and a second must pay for itself through risk or conflicting
  evidence. User provider restrictions remain authoritative.
- Grok legs use an isolated configuration to avoid inheriting host agents, plugins, hooks, and
  MCPs. OAuth `auth.json` and authentication environment variables are preserved; config-only
  enterprise authentication should use Grok's equivalent `GROK_*` environment variables.

## Prerequisites

- bash 4+
- git and GNU `timeout`
- The authenticated CLI for each selected route:
  - Claude Code (`claude`)
  - OpenAI Codex CLI (`codex`)
  - latest Grok Build (`grok`), using Grok 4.5

Only selected providers are required. No `jq` dependency is used.

## Configuration

Defaults can be overridden without editing the plugin. Overrides must remain in the strict current
catalog.

| Variable | Default | Purpose |
|---|---|---|
| `MMO_CLAUDE_MODEL` | `claude-opus-5` | Claude worker/reviewer model |
| `MMO_CLAUDE_EFFORT` | `high` | Claude effort except Haiku |
| `MMO_CODEX_MODEL` | `gpt-5.6-sol` | Codex worker/reviewer model |
| `MMO_GROK_MODEL` | `grok-4.5` | Grok worker/reviewer model |
| `MMO_GROK_EFFORT` | `medium` | Grok reasoning effort |
| `MMO_GROK_MAX_TURNS` | `30` | Grok tool-loop cap, from 1 to 100 |
| `MMO_REVIEW_DIFF_MAX_BYTES` | `1048576` | Maximum diff supplied to Claude/Grok review |
| `MMO_HANDOFF_DIR` | `.claude/handoffs` | Handoff directory in the target repository |

`MMO_OPUS_MODEL` and `MMO_OPUS_EFFORT` remain compatibility variables for `run-opus.sh`. The old
moving value `MMO_OPUS_MODEL=opus` maps explicitly to `claude-opus-5`; earlier versioned IDs are
still rejected. The default is `claude-opus-5` at `high`.

## Research basis

The routing policy was checked against current primary guidance for
[Claude model selection](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model),
[Claude effort](https://platform.claude.com/docs/en/build-with-claude/effort),
[GPT-5.6 model selection](https://developers.openai.com/api/docs/guides/latest-model),
[Grok 4.5 reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning), and the
[Grok Build CLI](https://docs.x.ai/build/cli/reference). Existing Reddit evidence remains clearly
marked as anecdotal and is used only as an operational signal.

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

The tests stub all model execution and, when Grok Build is installed, also inspect `grok --help`;
they do not call a model or consume quota.

## License

MIT
