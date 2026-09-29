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

> Do not use Claude. Use Grok for the bounded implementation and GPT-6 Astra for review.

Natural-language restrictions are hard constraints. The router never silently substitutes a
denied provider, model, or unsupported effort.

## Current model catalog

Only the previous Claude generation (Opus 5, Fable 5) is kept for compatibility and is never routed by default; older generations are excluded.

| Provider | Models | Typical role |
|---|---|---|
| Claude Code | `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5-5`, `claude-fable-5-1`; prior-generation `claude-opus-5`, `claude-fable-5` | Fast triage through highest-capability long-running work |
| Codex | `gpt-5.6-luna`, `gpt-5.6-terra`, `gpt-6-astra` | Mechanical work through hard technical implementation and review |
| Grok Build | `grok-4.7` (default), `grok-4.6`, `grok-4.5` | Fast bounded implementation, reproduction, and independent review |
| Local Qwen | `qwen3.8-27b-local` | Free mechanical edits and a cheap second review lens; one GPU slot, falls back to Grok when busy (needs the `subagent-local-qwen3.8-27b` plugin) |

Haiku 4.5 is the latest Haiku and does not use Claude's current effort parameter. Claude Fable 5.1,
Fable 5, Opus 5.5, Opus 5, and Sonnet 5 support `low` through `max`; GPT-5.6 and GPT-6 support `low` through `max`, with
Astra-only `ultra` available for bounded internal fan-out; Grok 4.7 and Grok 4.6 support `low`,
`medium`, `high`, and `xhigh`; Grok 4.5 supports `low`, `medium`, and `high`.

## Routing policy

The router first applies provider/model restrictions, then scores task role, ambiguity,
scope/coupling, risk, deterministic validation, modality, latency, and expected duration.

| Task | Starting route |
|---|---|
| File map, exact rename, focused check | Local Qwen when its endpoint answers, else Haiku 4.5 or GPT-5.6 Luna |
| Ordinary well-specified coding | Sonnet 5 or GPT-5.6 Terra at medium |
| Fast bounded implementation or reproduction | Grok 4.7 at medium |
| Hard backend/data work, debugging, security, technical review | GPT-6 Astra at high or xhigh |
| Large refactor, architecture, UX/visual work, long tool loop | Opus 5.5 at high |
| Unusually hard or days-long work | Fable 5.1 at high or xhigh |

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
trailing text is treated as overrides of decided judgment calls and brief deltas. A scan that finds nothing new writes
nothing and stops; recurrence belongs to `/loop` or cron.

In the Claude desktop app the orchestrator resets its own context at each item boundary: it
writes the handoff and a `.reset-pending` marker, calls `clear_session`, and a `SessionStart`
`clear` hook (`asyncRewake`) wakes the fresh session to resume from that handoff. Elsewhere, or
when the clear is refused, long runs reset through compaction: the handoff is always current, and after a
compaction the re-attached skill plus a `SessionStart` `compact` hook send the orchestrator back to
the newest handoff (modified within 24 hours) to continue as `--resume`. The default window lets a
1M-context session grow to ~967k tokens before that happens, so every turn re-sends up to that
much. Cap it in the dev container's user settings so resets happen early:
`"autoCompactWindow": 500000` in `~/.claude/settings.json` (Claude Code) and
`model_auto_compact_token_limit = 200000` in `~/.codex/config.toml` (Codex, whose window is ~258k). The same hook
runs on Codex, which also re-runs `SessionStart` hooks after compaction.

A `PostToolUse` hook (`hooks/context-watch.sh`, needs `jq`) reads the last usage record from the
session transcript and, once context crosses `MMO_CONTEXT_WARN_TOKENS` (default 400000), tells a
meta-orchestrator to bring its handoff current, keep the item lean and reset at the next boundary.
It warns once per crossing and re-arms after compaction. With the recommended 500k Claude window it
fires ~65k tokens before compaction (~467k); below a ~435k window it never fires.

The orchestrator reads plan limits (percent used and reset time per 5-hour, weekly and per-model
window) at start, resume and every item boundary: the desktop app's `get_usage` tool for Claude, or
`scripts/usage.sh`, which reads Codex session logs and Claude `rate_limit_event`s (a run-claude
stream log, or one tiny `--probe-claude` call). A window at 90% or more that resets after the next
leg would finish reroutes that provider's legs; when no allowed route has headroom, or the host
itself passes 95%, the run stops at the item boundary with the reset time in the handoff. Grok
exposes no limit data and is left to the exit-75 fallback.

When an item depends on out-of-repo facts, a research leg records tiered evidence in a tracked
memo. Unknowns are researched before a judgment call is decided with the recommended default and recorded.

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
  allow: [gpt-5.6-terra, grok-4.7]
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
  receive semantic no-write contracts and read-only tool allowlists. Claude and Grok research legs
  have web-only tool allowlists with no file access. The Codex CLI has no per-tool allowlist and
  keeps shell access, so Codex research runs from a scratch working root instead of the repository,
  bounded by that root and its prompt contract. This bounds blast radius rather than enforcing
  read-only.
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

## Review gate

`scripts/review-gate.sh --leg <provider>=<final-message-file> [--leg ...]` combines reviewer legs
into one verdict taken from each leg's last verdict line: `0` APPROVE, `1` NEEDS_WORK, `2` a missing
file or a leg without a terminal verdict, and `3` when no leg is from an independent hosted provider.
Classification is fail-closed: only labels naming a hosted catalog provider or model (Claude, Codex,
GPT, Grok and their model names) count as independent; `Local Qwen`, `qwen3.8-27b-local`, or an
unrecognized label are advisory. The local reviewer reads the diff and has no shell, so it can never
be the only reviewer — the gate enforces that rather than trusting a prompt to say so.

## Prerequisites

- bash 4+
- git and GNU `timeout`
- The authenticated CLI for each selected route:
  - Claude Code (`claude`)
  - OpenAI Codex CLI (`codex`)
  - latest Grok Build (`grok`), using Grok 4.7 by default
- Optional local engine: the `subagent-local-qwen3.8-27b` plugin, a llama.cpp endpoint, the `qwen`
  CLI, `curl`, `jq`, and `flock`. Missing any of them makes local routes report unavailable (exit 75) and
  work goes to Grok.

Only selected providers are required. `jq` is required for `run-claude.sh --stream-log` and for the local-Qwen route, both of which extract a final message from a JSON stream; `usage.sh` also needs it. `run-claude.sh --mcp` also uses `jq` to encode each server URL.

## Configuration

Defaults can be overridden without editing the plugin. Overrides must remain in the strict current
catalog.

| Variable | Default | Purpose |
|---|---|---|
| `MMO_CLAUDE_MODEL` | `claude-opus-5-5` | Claude worker/reviewer model |
| `MMO_CLAUDE_EFFORT` | `high` | Claude effort except Haiku |
| `MMO_CODEX_MODEL` | `gpt-6-astra` | Codex worker/reviewer model |
| `MMO_GROK_MODEL` | `grok-4.7` | Grok worker/reviewer model |
| `MMO_GROK_EFFORT` | `medium` | Grok reasoning effort |
| `MMO_GROK_MAX_TURNS` | `30` | Grok tool-loop cap, from 1 to 100 |
| `MMO_REVIEW_DIFF_MAX_BYTES` | `1048576` | Maximum diff supplied to Claude/Grok/local-Qwen review |
| `MMO_CONTEXT_WARN_TOKENS` | `400000` | Context size at which the context-watch hook warns a meta-orchestrator |
| `MMO_HANDOFF_DIR` | `.claude/handoffs` | Repo-relative handoff directory in the target repository |
| `MMO_QWEN_LOCAL_RUN` | discovered | Path to the `subagent-local-qwen3.8-27b` wrapper when it is not on `PATH` or in a plugin cache |

`MMO_OPUS_MODEL` and `MMO_OPUS_EFFORT` remain compatibility variables for `run-opus.sh`. The old
moving value `MMO_OPUS_MODEL=opus` maps explicitly to `claude-opus-5-5`; versioned IDs older than the previous generation are
still rejected. The default is `claude-opus-5-5` at `high`.

`run-claude.sh` accepts repeatable `--mcp NAME=URL` to attach named HTTP MCP servers to that leg
(for example a local browser server). Each server is `{"type":"http","url":URL}` inside
`--mcp-config`, `--strict-mcp-config` stays on, and `mcp__NAME` is appended to the active mode's
`--allowedTools`. `NAME` must match `[A-Za-z0-9_-]+`. With no `--mcp`, the MCP config stays
`{"mcpServers":{}}`. Encoding `--mcp` uses `jq`.

## Research basis

The routing policy was checked against current primary guidance for
[Claude model selection](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model),
[Claude effort](https://platform.claude.com/docs/en/build-with-claude/effort),
[OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model),
[Grok reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning), and the
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
