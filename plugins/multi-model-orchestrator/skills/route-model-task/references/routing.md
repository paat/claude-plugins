# Strict model and effort router

Use only this catalog. Names stay within the requested generations; the Haiku alias deliberately
tracks the latest Haiku 4.5 release instead of pinning an earlier dated snapshot.

| Provider | Model | Start here for | Supported effort in this plugin |
|---|---|---|---|
| Claude Code | `claude-haiku-4-5` | Fast, high-volume triage, file maps, simple checks | `n/a`; Haiku 4.5 has manual thinking, not the current effort control |
| Claude Code | `claude-sonnet-5` | Ordinary coding, tool use, browser/visual work, cost-aware agents | `low`–`max` |
| Claude Code | `claude-opus-5-5` | Current Opus: complex agentic coding, hard review, large refactors, vision-heavy work | `low`–`max` |
| Claude Code | `claude-opus-5` | Prior-generation Opus compatibility route | `low`–`max` |
| Claude Code | `claude-fable-5-1` | Current Fable: highest-capability, long-running or unusually hard coding and knowledge work | `low`–`max` |
| Claude Code | `claude-fable-5` | Prior-generation Fable compatibility route | `low`–`max` |
| Codex | `gpt-5.6-luna` | Fast mechanical edits, extraction, classification, narrow checks | `low`–`max` |
| Codex | `gpt-5.6-terra` | Balanced everyday implementation and bounded investigation | `low`–`max` |
| Codex | `gpt-6-astra` | Hard technical implementation, debugging, adversarial review, security | `low`–`max`; `ultra` only as below |
| Grok Build | `grok-4.7` | Default Grok route: fast bounded agentic implementation, independent reproduction, extra review lens | `low`, `medium`, `high`, `xhigh` |
| Grok Build | `grok-4.6` | Prior-generation Grok compatibility route | `low`, `medium`, `high`, `xhigh` |
| Grok Build | `grok-4.5` | Older Grok compatibility route | `low`, `medium`, `high` |
| Local Qwen | `qwen3.8-27b-local` | Free bounded mechanical edits with a named test, and a cheap second review lens — only when the local endpoint answers | `n/a` (the wrapper pins `medium`) |
| agy (Antigravity) | `gemini-3.8-flash` | Cheap, fast bounded edits; an advisory diff-only review lens | `low`, `medium`, `high` |

Astra replaces only Sol. Keep Terra and Luna as lower-cost routes: use Luna for mechanical tasks
and narrow checks, Terra for ordinary bounded implementation, and Astra for hard technical work.
A newer flagship does not retire the cheaper tiers. Explicit model requests still take precedence.
Only catalogued models are allowed; unavailable models do not authorize an unlisted fallback.

## Complexity tiers

Complexity picks the tier. `scripts/pool-tiers.tsv` lists each tier's workers in order, and
`scripts/pool.sh pick|run --tier <T>` drops the ones that cannot take the task now (not allowed,
CLI not installed, an advisory engine on a review, or a plan window near its limit) and tries the
rest in order. A T1 or T2 tier with nobody left escalates upward; T3 and T4 never fall to a weaker
tier — park until the reset `pool.sh` prints. An explicit model pin bypasses the pool.

| Task evidence | Tier | Pool flags |
|---|---|---|
| Exact rename, fixture, file map, focused check | T1 | |
| Well-specified everyday change with known tests | T2 | |
| Bounded independent implementation or reproduction | T2 | `--prefer grok` |
| Cross-module backend/data/API work or hard root cause | T3 | |
| Large refactor, long tool loop, complex system design | T3 | `--prefer claude` |
| Ambiguous product intent, UX, copy, or visual replication | T3 | `--prefer claude` |
| Security, payments, destructive migration, subtle concurrency | T4 | review: T4 `--mode review --deny <worker provider>` |
| Technical adversarial review | the item's tier, at least T2 | `--mode review --deny <worker provider>` |
| Mechanical verification after a model-authored change | T1 | run the deterministic check directly when no judgment is needed |
| Days-long or unusually hard work where marginal capability matters | outside the pool | pin Fable 5.1 `high` or `xhigh` |

Task evidence outranks the table. A clear, localized payment copy edit stays T1 or T2 because the
change is local; a subtle idempotency change is T4. Escalate a tier after a failed gate with new
evidence, not because the product matters.

## Effort meanings

- `low`: localized, explicit, reversible, and gated by a deterministic check.
- `medium`: several known files or ordinary agentic work with clear contracts.
- `high`: real ambiguity, cross-module reasoning, hard debugging, visual judgment, or broad review.
- `xhigh`: long-horizon or high-impact correctness with competing explanations to reconcile.
- `max`: exceptional quality-first work after a representative `xhigh` run leaves a measurable gap.
- `ultra`: GPT-6 Astra CLI orchestration with internal subagents. Use only when explicit or when a
  bounded, high-impact task has genuinely independent workstreams. Cap fan-out, name one gate, and
  prohibit recursive review/fix loops.
- `n/a`: the selected model does not support the provider's current effort parameter. Do not pass
  an effort flag.

Grok 4.7 and Grok 4.6 accept `low`, `medium`, `high`, and `xhigh`. Grok 4.5 does not accept
`xhigh`, `max`, or `ultra`. Claude models do not accept `ultra`. Never map an unsupported effort
silently; select a supported level or return an incompatibility.

## Restrictions and fallbacks

- `Codex only`: choose Luna, Terra, or Astra by task complexity; Astra Ultra is not the default.
- `Claude only`: choose Haiku 4.5, Sonnet 5, Opus 5.5, or Fable 5.1; use `n/a` for Haiku.
- `Grok only`: use Grok 4.7 by default (or Grok 4.6 or Grok 4.5 when explicitly pinned) and scale
  only across that model's supported efforts.
- `No Claude`: route between GPT-5.6/GPT-6 and Grok 4.7; any independence check must use the other one.
- A pinned allowed model wins over defaults. A pinned unsupported effort produces a blocker unless
  the user also authorized automatic effort adjustment.
- Local Qwen (`qwen`) and agy are providers like any other: an allow/deny list that excludes them
  removes them from the pool, and a provider-only restriction (`Codex only`, `Claude only`,
  `Grok only`) excludes them too. Pass restrictions to `pool.sh` as `--allow`/`--deny` lists of
  providers or models.

## Availability

Every runner exits `75` when its worker cannot take the task now: a transient provider error or
plan limit, or — for `scripts/run-qwen-local.sh` — the one GPU slot busy, the server down or
serving another model, or no wrapper. Local Qwen is never queued. `pool.sh run` moves to the next
worker on `75`, `77`, or `127`; if that leg changed the repository it exits `55` instead (salvage
or reset first). Its own `75` means nobody in the tier chain was available. Local Qwen and agy are mechanical-work engines and advisory
reviewers only: architecture, security, and ambiguous design stay on the hosted catalog.

## Evidence basis, 2026-08-02

- Anthropic describes Fable 5 as its highest-capability long-running model, Opus 5 for complex
  agentic coding, Sonnet 5 as the speed/intelligence balance, and Haiku 4.5 as its fastest current
  tier. Its effort guidance favors high as a baseline, lower settings where evals hold, and xhigh
  or max only for demanding work.
- OpenAI describes Astra as the GPT-6 flagship, Terra as the balanced GPT-5.6 tier, and Luna as the
  fast, high-volume GPT-5.6 tier. It recommends medium as a baseline and higher efforts only for measured gains.
- The Grok Build CLI (1.0.40) defaults to grok-4.7. grok-4.7 and grok-4.6 accept low, medium, high,
  and xhigh; grok-4.5 accepts low, medium, and high. xAI reports strong coding performance and high
  serving speed; treat those vendor measurements as hypotheses.
- Antigravity CLI 1.2.14 serves `gemini-3.8-flash-{low,medium,high}` and answers `/usage` locally.
  Its print mode enforces no read-only mode (`--mode plan` still edits files), so `run-agy.sh`
  reviews diff-only from an empty directory and fails with 7 if the repository changed.
- Cross-vendor benchmark numbers are not directly comparable when model dates, harnesses, tools,
  token budgets, and reasoning settings differ. Prefer controlled local task results.

Primary sources:

- [Anthropic model selection](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model)
- [Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Claude Opus 5 prompting](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5)
- [OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model)
- [xAI Grok reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning)
- [Grok Build CLI reference](https://docs.x.ai/build/cli/reference)
