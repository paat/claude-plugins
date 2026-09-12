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
  `TRIBUNAL_GROK_MODEL` (default `grok-4.5`); repo-walking on the xAI Grok CLI
  with tools allowlist, sandbox default `none` (`TRIBUNAL_GROK_SANDBOX`),
  `bypassPermissions`, isolated host config, web search off (issue #378).

## APPROVE quorum

`TRIBUNAL_MIN_OK_LEGS` (default `1`, range 1..7) is the per-environment floor
of `ok` provider legs required for `APPROVE`. It is environment-only — never
read from the repository under review — and is sealed into the collection
manifest as `panel_policy` at collect time. A documented lower value is that
environment's degraded quorum; membership still uses the `TRIBUNAL_<PROVIDER>`
toggles.
