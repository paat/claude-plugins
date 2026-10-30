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

## OpenCode Go (checked 2026-10-30)

| Source | What it supports | What it does not establish |
|---|---|---|
| [OpenCode Go limits](https://opencode.ai/docs/go) | 30 Go models; per-model monthly dollar allowances with 20% per 5h and 50% per week (Go Plus: GLM-5.3-Flash $180, GLM-5.3 $120, Kimi K3.1 Pro $60). | Remaining allowance through an API key: responses report only each request's charge. |
| [Terminal-Bench 4.0](https://www.tbench.ai/) leaderboard rows | GLM-5.3 `max` 41.8% and GLM-5.3-Flash 35.8% (Claude Code harness), above Grok 4.7 `xhigh` 37.6% and GPT-6 Luna `max` 16.4%; GLM-5.3-Flash's run cost $119. | Results in this plugin's OpenCode harness; Kimi K3.1 Pro has no row. |
| [Arena agent and WebDev](https://huggingface.co/datasets/lmarena-ai/leaderboard-dataset) (published 2026-10-28) | Kimi K3.1 Pro (Max) is the highest Go-only model: agent #13 (above GPT-5.6 Sol), WebDev #9; GLM-5.3 agent #29. | Agentic task success; Arena is preference. |

Live `opencode models` (v2.2.4) listed every routed id, and minimal GLM-5.3-Flash runs succeeded.
Go also serves Argon, Grok 4.7, Luna and Haiku; those keep their own provider routes here.

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
Keep provider/infra failures separate and require repeated comparable gains before changing
default preference. No new training service, mandatory benchmark run or extra telemetry is
required by this policy.
