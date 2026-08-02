# Strict model and effort router

Use only this catalog. Names stay within the requested generations; the Haiku alias deliberately
tracks the latest Haiku 4.5 release instead of pinning an earlier dated snapshot.

| Provider | Model | Start here for | Supported effort in this plugin |
|---|---|---|---|
| Claude Code | `claude-haiku-4-5` | Fast, high-volume triage, file maps, simple checks | `n/a`; Haiku 4.5 has manual thinking, not the current effort control |
| Claude Code | `claude-sonnet-5` | Ordinary coding, tool use, browser/visual work, cost-aware agents | `low`–`max` |
| Claude Code | `claude-opus-5` | Complex agentic coding, hard review, large refactors, vision-heavy work | `low`–`max` |
| Claude Code | `claude-fable-5` | Highest-capability, long-running or unusually hard coding and knowledge work | `low`–`max` |
| Codex | `gpt-5.6-luna` | Fast mechanical edits, extraction, classification, narrow checks | `low`–`max` |
| Codex | `gpt-5.6-terra` | Balanced everyday implementation and bounded investigation | `low`–`max` |
| Codex | `gpt-5.6-sol` | Hard technical implementation, debugging, adversarial review, security | `low`–`max`; `ultra` only as below |
| Grok Build | `grok-4.5` | Fast bounded agentic implementation, independent reproduction, extra review lens | `low`, `medium`, `high` |

No earlier Claude, GPT, or Grok model is a fallback. Haiku 4.5 is included because it is the
latest Haiku. Treat unavailable subscription models as unavailable routes, not as permission to
use an older generation.

## Task starting points

| Task evidence | Primary route | Default effort | Useful allowed alternative |
|---|---|---|---|
| Exact rename, fixture, file map, focused check | Haiku 4.5 or Luna | `n/a` or `low` | Grok 4.5 `low` |
| Well-specified everyday change with known tests | Terra or Sonnet 5 | `medium` | Grok 4.5 `medium` when turnaround matters |
| Bounded independent implementation or reproduction | Grok 4.5 | `medium` | Terra `medium` |
| Cross-module backend/data/API work or hard root cause | Sol | `high` | Opus 5 `high` |
| Large refactor, long tool loop, complex system design | Opus 5 | `high` | Sol `high` |
| Ambiguous product intent, UX, copy, or visual replication | Opus 5 | `high` | Sonnet 5 `high` for a well-specified version |
| Days-long or unusually hard work where marginal capability matters | Fable 5 | `high` or `xhigh` | Opus 5 `xhigh` |
| Security, payments, destructive migration, subtle concurrency | Sol implementation plus Opus 5 independent advice/review | `xhigh` each | Fable 5 only when the remaining uncertainty justifies it |
| Technical adversarial review | A provider different from the implementer: Sol or Opus 5 | `high` | Grok 4.5 `high` as a fast third lens only when it pays for itself |
| Mechanical verification after a model-authored change | Haiku 4.5 or Luna | `n/a` or `low` | Run the deterministic check directly when no model judgment is needed |

Task evidence outranks the table. A clear, localized payment copy edit does not become `xhigh`
because the product handles payments; a subtle idempotency change does.

## Effort meanings

- `low`: localized, explicit, reversible, and gated by a deterministic check.
- `medium`: several known files or ordinary agentic work with clear contracts.
- `high`: real ambiguity, cross-module reasoning, hard debugging, visual judgment, or broad review.
- `xhigh`: long-horizon or high-impact correctness with competing explanations to reconcile.
- `max`: exceptional quality-first work after a representative `xhigh` run leaves a measurable gap.
- `ultra`: GPT-5.6 Sol CLI orchestration with internal subagents. Use only when explicit or when a
  bounded, high-impact task has genuinely independent workstreams. Cap fan-out, name one gate, and
  prohibit recursive review/fix loops.
- `n/a`: the selected model does not support the provider's current effort parameter. Do not pass
  an effort flag.

Grok 4.5 does not accept `xhigh`, `max`, or `ultra`. Claude models do not accept `ultra`. Never map
an unsupported effort silently; select a supported level or return an incompatibility.

## Restrictions and fallbacks

- `Codex only`: choose Luna, Terra, or Sol by task complexity; Sol Ultra is not the default.
- `Claude only`: choose Haiku 4.5, Sonnet 5, Opus 5, or Fable 5; use `n/a` for Haiku.
- `Grok only`: use Grok 4.5 and scale only across low/medium/high.
- `No Claude`: route between GPT-5.6 and Grok 4.5; any independence check must use the other one.
- A pinned allowed model wins over defaults. A pinned unsupported effort produces a blocker unless
  the user also authorized automatic effort adjustment.

## Evidence basis, 2026-08-02

- Anthropic describes Fable 5 as its highest-capability long-running model, Opus 5 for complex
  agentic coding, Sonnet 5 as the speed/intelligence balance, and Haiku 4.5 as its fastest current
  tier. Its effort guidance favors high as a baseline, lower settings where evals hold, and xhigh
  or max only for demanding work.
- OpenAI describes Sol as the GPT-5.6 flagship, Terra as the balanced tier, and Luna as the fast,
  high-volume tier. It recommends medium as a baseline and higher efforts only for measured gains.
- xAI exposes Grok 4.5 in Grok Build with low, medium, and high reasoning. xAI reports strong
  coding performance and high serving speed; treat those vendor measurements as hypotheses.
- Cross-vendor benchmark numbers are not directly comparable when model dates, harnesses, tools,
  token budgets, and reasoning settings differ. Prefer controlled local task results.

Primary sources:

- [Anthropic model selection](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model)
- [Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Claude Opus 5 prompting](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5)
- [OpenAI GPT-5.6 model guidance](https://developers.openai.com/api/docs/guides/latest-model)
- [xAI Grok 4.5 reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning)
- [Grok Build CLI reference](https://docs.x.ai/build/cli/reference)
