# Model routing evidence — checked 2026-10-28

This note records candidate-selection evidence, not a measured leaderboard. No controlled
comparison of this plugin's exact model versions, tools and task distribution was performed.
The operational policy is in `task-fit.md`; refresh sources when a model, runner or repeated
local result changes a routing decision, not on every dispatch.

## Primary guidance and its limits

| Source | What it supports | What it does not establish |
|---|---|---|
| [OpenAI model selection](https://developers.openai.com/api/docs/guides/model-selection) | Luna/low for small edits; Sol 6.1/medium for technical work, xhigh for demanding visual systems and conflicting evidence; Astra/medium for broad projects. Compare effort on identical inputs. | A universal OpenAI advantage over other providers, or that every frontend task requires xhigh. |
| [Codex models](https://developers.openai.com/codex/models) and [model discovery](https://learn.chatgpt.com/docs/app-server#list-models-modellist) | Available models, defaults and efforts depend on client/account; max/ultra are exceptional. | API settings, app defaults and wrapper policy being interchangeable. |
| [Claude model selection](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model) and [effort](https://platform.claude.com/docs/en/build-with-claude/effort) | Sonnet 5.5 medium for specified agentic coding, high for harder work; Opus 5.5 starts at medium. Re-evaluate effort when generations change. | Claude being inherently best at architecture, copy or UX; inheriting Opus 5 effort settings without evaluation. |
| [Grok reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning) | Low for simple calls, medium for analysis, high for difficult reasoning; xhigh available from 4.6. | Equal effort labels meaning equal compute across vendors. The wrapper rejects unsupported efforts rather than accepting upstream downgrades. |
| [Grok 4.7 guide](https://docs.x.ai/developers/grok-4-7) | Coding/agent capability; Fast is the same model with faster serving. | Faster serving implying better reasoning; authorization to add premium Fast to the catalog. |
| [agy effort](https://antigravity.google/docs/cli/commands/effort) and [Argon engineering examples](https://antigravity.google/blog/gemini-4-argon-in-google-antigravity) | Low/medium/high task guidance; vendor debugging, migration and engineering reports support trying Argon for complex code. | Controlled superiority over peers, a visual-design winner, or permission to remove the wrapper's advisory-review restriction. |
| [Meta workload selection](https://dev.meta.ai/docs/models) and [Wonder/Full](https://dev.meta.ai/resources/blog/build-with-muse-wonder) | Spark for economical short workloads; Wonder family/Full for sustained complex coding. Full has distinct subscription access. | Plain Wonder at max being Full; benchmark ranks measured at max transferring to high. Existing Spark/Full pins remain authoritative. |
| [Meta reasoning](https://dev.meta.ai/docs/reasoning) and [Muse Code configuration](https://dev.meta.ai/docs/muse-code/configuration#reasoning-effort) | Effort trades reasoning budget against latency/output budget; CLI and API contributor settings differ. | A CLI alias/default identifying a stable model, or a universal effort optimum. |

## Availability and harness evidence

- Live `agy models` listed Argon low/medium/high and Flash on 2026-10-28; a minimal Argon-low
  request succeeded. This proves access in the checked environment, not coding quality or
  availability for every account. Recheck availability at dispatch; preserve failure handling.
- [Carbon's announcement](https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-gemini-4-carbon/)
  describes restricted initial access. It was absent from the checked agy list; no executable
  Carbon route is inferred from the announcement.
- Current agy review receives a diff outside the repository; local review is advisory. Neither
  can become the required executing review by selecting a stronger model or higher effort.
- The local `default` route serves whichever model the endpoint exposes. Record that actual
  identity; historical provider/plugin names do not establish its current task capabilities.

## Calibrating preferences

[SWE-bench](https://www.swebench.com/) separates model-only comparisons using a fixed agent from
full agent submissions. [Terminal-Bench 2.1](https://www.tbench.ai/news/terminal-bench-2-1)
documents task/test corrections that change results. The primary preprint
[Harness Effects](https://arxiv.org/abs/2609.32459) studies model/task-dependent harness effects;
it does not benchmark this plugin's exact hosted-model catalog. These sources justify
controlling harness and benchmark version, not copying their rankings into this router.

The [xAI effort-evaluation example](https://docs.x.ai/cookbook/examples/reasoning-effort-evals)
shows why more reasoning need not improve a short classification workload. Its small sample
does not rank coding models. For local calibration, reuse the existing task ledger: freeze
inputs, repository state, tools and acceptance tests; compare repeated completion and total
time/cost including repairs, then vary effort on the same model. Unknown cost stays unknown.
Keep provider/infra failures separate. Change a default when public evidence makes it more likely
better than worse (see the 2026-11-20 block); contradicting local records override it. No new training service, mandatory benchmark run or extra telemetry is
required by this policy.

## Public evidence behind the 2026-11-20 pool table (as of 2026-11-20)

Public shortlisting sources applied under the owner's rule (2026-11-20): act when a change is more
likely better than worse; local outcome and leg-check records override when they contradict it.
Bug Hunt Bench is one bug-finding task, not a coding-quality ranking; it counts here only where a
second source agrees or the margin is clear.

- [Bug Hunt Bench](https://github.com/phuryn/bug-hunt-bench) `results/runs.csv` (fixes out of 105,
  same harness per vendor): GPT-6.2 Sol medium 45.7, high 49.7 vs GPT-6.1 Sol medium 28-29, high
  36.5-38; GPT-6.2 Astra high 59.6 vs GPT-6 Astra high 35; GPT-6.1 Terra medium 7.3, high 9.7;
  GPT-6 Sol medium 14; Sonnet 5 high 9 vs Sonnet 5.5 medium 18-23; Gemini 4 Hydrogen medium 24.7
  at about one fifth of Sonnet 5.5 medium's list cost, Gemini 3.8 Flash high 18-20; Muse Spark 1.3
  medium 9-13; Mistral Large 4 high 15.
- Terminal-Bench 4.x leaderboard (max-effort rows): Sonnet 5 12.4% vs Sonnet 5.5 61.8%; GPT-6 Sol
  49.4% vs GPT-6.1 Sol 58.2%; GPT-5.6 Terra 21.5%; Muse Spark 1.3 (xhigh) 14.6%.
- Terra: OpenAI's models page positions GPT-6.1 Terra for "visual reasoning, precise computer use,
  and clear, natural writing", not coding; openai/codex#61538 and #60133 report it ending coding
  turns early.
- Hydrogen: Google's Antigravity models page positions it for "fast, everyday coding and
  maintenance tasks".

Result: 6.2 Sol/Astra lead the Codex rows with 6.1 Sol and 6 Astra behind them as fallbacks;
`gpt-6-sol`, both Sonnet 5 rows and both Terra rows left the pool (still pinnable); Hydrogen
`medium` enters T2 ahead of Flash `high`; Muse Spark moves to the end of T2 before Vibe.

## Gemini 4 Neon enters T3 (as of 2026-11-22)

- Google's [launch post](https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-gemini-4-neon/)
  (2026-11-18): Neon sits between Carbon ("hardest, long-horizon projects") and Hydrogen ("fast
  everyday execution"), "handles multi-file debugging and refactoring across repositories", four
  thinking levels with `high` the default, and "a 32% lower cost per task than Carbon". Reported
  scores: Terminal-Bench 4.1 65.2%, Artificial Analysis Coding Agent Index 58.6 (first), SWE-sweep
  12.8% on mini-SWE and 39.0% inside Antigravity. The post publishes no Neon-vs-Argon or
  Neon-vs-Hydrogen number, and its comparison tables are images that were not read.
- The [Antigravity post](https://antigravity.google/blog/gemini-4-neon-in-google-antigravity/)
  (2026-11-18): paid Pro and Ultra plans get Neon in the CLI; it states no rate limit or quota pool.
- Live `agy models` on 2026-11-22 listed `gemini-4-neon-low`/`medium`/`high`/`xhigh`; a minimal
  Neon-low request succeeded. `agy /usage` returned only the Gemini and Claude/GPT pools that day.

Result: Neon `high` enters T3 ahead of Argon, as the newer model Google positions above Hydrogen
for complex coding. This is vendor positioning, not a measured ranking; local records override it.
Argon, Hydrogen and Carbon keep their relative order. No T2 or T4 row: Hydrogen stays the T2
Gemini worker and agy has no T4 route.
