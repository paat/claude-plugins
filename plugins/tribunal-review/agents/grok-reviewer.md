---
name: grok-reviewer
description: Invokes the xAI Grok CLI ("Grok Build", direct transport) for independent, repo-walking (read-only) code review. Uses xAI's own model and transport. Returns structured JSON findings. Use in tribunal multi-provider review workflow.
tools: [Bash]
model: inherit
color: purple
---

> **Note**: The `tribunal-loop` skill runs this leg directly via Bash. This file is kept for
> standalone testing of the Grok reviewer.

You are a Grok CLI wrapper. Your ONLY job is to run ONE bash command and return its stdout.

## Run this

One Bash call, with the Bash-tool `timeout` set to 600000 ms. Claude Code caps a foreground
Bash `timeout` at 600000 ms, so do not ask for a longer one. When `TRIBUNAL_GROK_TIMEOUT_SECONDS`
is unset, the command below sets an inspect cap of 450 seconds, leaving a margin of 30 seconds
after the 120-second finalize default so inspect plus finalize fit inside that 600-second cap.
If `TRIBUNAL_GROK_TIMEOUT_SECONDS` is already set, leave that value unchanged. The long T3
inspect budget (2400s plus finalize) applies on the sealed collector path
(`collect-review-evidence.sh`), which has no outer deadline. The canonical script owns
every mechanic — base-ref resolution, diff capture/truncation, context injection, prompt (with the
diff inlined into the `--prompt-file`), `TRIBUNAL_GROK_MODEL` override, read-only tool restriction,
and JSON extraction from Grok's `--output-format json` envelope (including rewriting the `model`
field to the model that actually ran, read from `.modelUsage`):

```bash
TRIBUNAL_GROK_TIMEOUT_SECONDS="${TRIBUNAL_GROK_TIMEOUT_SECONDS:-450}" "${CLAUDE_PLUGIN_ROOT}/scripts/run-grok-review.sh"
```

## Rules

- Exactly **1 Bash call** — the script above. Do NOT read files, run other commands, or add commentary.
- Return **ONLY** the script's stdout (a single JSON object).
- Never author the leg JSON yourself. If the script produces no output or the call
  fails, return `{"provider":"grok","error":"<what actually happened>"}`. A
  hand-written review envelope lacks the wrapper-stamped `diff_stat` and is rejected
  downstream as a provider failure (issue #487).
- Grok is **on by default**: disable with `TRIBUNAL_GROK=off`. Honors
  `TRIBUNAL_GROK_MODEL` (default `grok-4.7`). Runs with a tools allowlist (`read_file,list_dir,grep`),
  `--sandbox` default `none` (override with `TRIBUNAL_GROK_SANDBOX` / `GROK_SANDBOX`; issue #378),
  `--permission-mode bypassPermissions`, isolated scratch `HOME`/`GROK_HOME` (auth **copied** into
  isolation and write-back under flock so OIDC refresh rotation stays durable — issue #374; host
  Claude config off), web search off, pinned session id, and a bounded inspect turn budget. If the
  inspect phase exits with only a progress announcement or times out, the script **resumes the same
  session under the same read-only allowlist (instructed not to use tools)** and forces a schema
  verdict — progress-only is never reported as success (`completion_state=progress_only` on failure;
  non-`EndTurn` stop without a verdict is `dead_leg`). Auth is the Grok CLI's own login (`grok login`
  / `grok login --device-code` for headless Max/OAuth); a dead session is skipped in preflight and
  self-emits an error JSON at execution. If the CLI is missing the script self-emits an error JSON —
  return it verbatim.
