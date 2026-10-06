# Provider Policy

- Codex: on by default; disable with `TRIBUNAL_CODEX=off`; defaults to
  `gpt-6-astra` at `medium` effort; override with `TRIBUNAL_CODEX_MODEL` and
  `TRIBUNAL_CODEX_EFFORT`; repo-walking with unrestricted execution inside the
  development-container security boundary; the review prompt prohibits changes.
- DeepSeek: off by default; `TRIBUNAL_DEEPSEEK=on` enables it and makes
  `TRIBUNAL_DEEPSEEK_MODEL` effective; repo-walking read-only.
- Claude: on by default; disable with `TRIBUNAL_CLAUDE=off`; model override
  `TRIBUNAL_CLAUDE_MODEL`; diff-only from a scratch directory with tools disabled.
- Gemini: off by default; enable with `TRIBUNAL_GEMINI=on`; diff plus web/CVE
  lens.
- GLM: off by default; enable with `TRIBUNAL_GLM=on`; OpenCode diff-only leg.
- Qwen: off by default; enable with `TRIBUNAL_QWEN=on`; repo-walking on its own
  transport.
- Grok: on by default; disable with `TRIBUNAL_GROK=off`; model override
  `TRIBUNAL_GROK_MODEL` (default `grok-4.7`); repo-walking on the xAI Grok CLI
  with tools allowlist, sandbox default `none` (`TRIBUNAL_GROK_SANDBOX`),
  `bypassPermissions`, isolated host config, web search off (issue #378).
- Muse: on by default; disable with `TRIBUNAL_MUSE=off`; CLI default model unless
  `TRIBUNAL_MUSE_MODEL` is set (the current default may use content for product
  improvement); repo-walking via `muse exec --yolo` with write, shell, and web tools off.

## Risk tier and effort

`TRIBUNAL_RISK` (environment only: `T1`–`T4`, the multi-model-orchestrator complexity tier)
sets reviewer effort: T1 `low`, T2 `medium`, T3 `high`, T4 `high` with only Codex at `xhigh`
(maximum-effort reviewers over-report speculative findings). Unset keeps each CLI default.
`TRIBUNAL_CODEX_EFFORT`, `TRIBUNAL_CLAUDE_EFFORT`, `TRIBUNAL_GROK_EFFORT`, and
`TRIBUNAL_MUSE_EFFORT` override it.
Panel membership never depends on the tier.

## Plan-limited legs

A leg whose CLI failed on a plan limit (402, usage limit, quota, resource/balance/credits
exhausted; never a timeout) reports an error starting with `plan limit:`. The evidence
collector then runs one backup leg per limited leg from `TRIBUNAL_BACKUP_LEGS` (environment
only; default `deepseek`; `off` disables): an installed leg whose wrapper sat out the run.
The limited leg stays `failed`, so confidence still reflects it.

## APPROVE quorum

`TRIBUNAL_MIN_OK_LEGS` (default `1`, range 1..8) is the per-environment floor
of `ok` provider legs required for `APPROVE`. It is environment-only — never
read from the repository under review — and is sealed into the collection
manifest as `panel_policy` at collect time. A documented lower value is that
environment's degraded quorum; membership still uses the `TRIBUNAL_<PROVIDER>`
toggles.
