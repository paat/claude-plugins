---
name: tribunal-loop
description: Multi-provider code review workflow — Codex + DeepSeek (repo-walking) + Claude (diff-only) by default (Gemini, OpenCode GLM and Qwen opt-in), with Opus arbitration
---

# Tribunal Loop

Multi-provider code review. **By default** Codex (GPT-5.5) + DeepSeek-V4-Pro (repo-walking) + Claude (sonnet, diff-only) review in parallel, Opus arbitrates inline. The two default walking legs **walk the repo** read-only: Codex (in-container, no sandbox flag) and DeepSeek (**direct** DeepSeek API) may each open related files to verify cross-file effects. The **Claude** leg (host `claude` CLI) is the panel's one **diff-only** reviewer — it reviews the diff in isolation (run from a scratch dir with all tools disabled), deliberately restoring the harness/context diversity the walking legs give up. **Gemini** (web/CVE search), the OpenCode **GLM** leg, and **Qwen** (qwen3.7-plus) are available opt-in (`TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on` / `TRIBUNAL_QWEN=on`) but **off by default** — GLM shares architectural lineage with DeepSeek and tends to fail in lockstep, and Qwen reasons over the diff text rather than grounding in files (repeated false positives — phantom whitespace, nonexistent symbols, hallucinated line numbers; issue #46), so the default panel keeps the decorrelated, low-false-positive set.

3-step workflow: pre-flight, parallel review, inline arbitration.

## Providers
- **Codex** (GPT-5.5) - comprehensive review, **repo-walking** read-only (runs in-container, no `--sandbox` flag); **on by default**, disable with `TRIBUNAL_CODEX=off`, model via `TRIBUNAL_CODEX_MODEL` (unset = codex CLI's own default)
- **Gemini** (3 Pro Preview) - comprehensive review + web/CVE search; **off by default**, enable with `TRIBUNAL_GEMINI=on`, model via `TRIBUNAL_GEMINI_MODEL`
- **GLM** (opencode-go/glm-5.1) - comprehensive review (OpenCode Go), diff-only; **off by default** (shares lineage with DeepSeek — fails in lockstep), enable with `TRIBUNAL_GLM=on`, model via `TRIBUNAL_GLM_MODEL`
- **DeepSeek** (opencode-go/deepseek-v4-pro) - comprehensive review via the **OpenCode Go** backend (subscription → credits on overage), **repo-walking** read-only; independently switchable via `TRIBUNAL_DEEPSEEK` / `TRIBUNAL_DEEPSEEK_MODEL` (set the latter to `deepseek/deepseek-v4-pro` for the direct DeepSeek API)
- **Qwen** (qwen3.7-plus) - comprehensive review via the **Qwen Code CLI** (own transport, decorrelated from the OpenCode legs), **repo-walking** read-only (issue #44); **off by default** (issue #46: ungrounded diff-text reasoning → repeated false positives; pending the mandatory-verification fix), enable with `TRIBUNAL_QWEN=on`, model via `TRIBUNAL_QWEN_MODEL`
- **Claude** (sonnet) - comprehensive review via the host **Claude Code CLI** (`claude -p`), **diff-only** (scratch dir + all tools disabled) — the panel's diff-only lens; **on by default**, disable with `TRIBUNAL_CLAUDE=off`, model via `TRIBUNAL_CLAUDE_MODEL`
- **Opus** (4.5) - final arbiter (runs inline, no agent spawn)

---

## STEP 1: Pre-flight

First verify the diff is reviewable:

```
1. We're on a feature branch, not main. If on main: STOP and ask which branch to review.
2. There is a diff vs origin/main. Run: git diff origin/main...HEAD --stat
   If no diff: STOP and report "No changes to review."
```

Then run the **environment preflight** below as a single Bash call. It checks each
reviewer up front — CLI on PATH, free disk, and (for OpenCode) that the model IDs
resolve — so a missing CLI, full disk, or cold/stale model cache fails fast here
instead of hanging a launched reviewer for minutes. Reviewers that fail preflight
are skipped and the run degrades to the available quorum; only if **zero** providers
are usable do we STOP.

```bash
WARN=""
USABLE=0

# Codex leg switch (issue #43). Codex (GPT-5.5) is a default repo-walking reviewer. ON by
# default; only the literal "off" disables. When on, `codex` seeds the CLI list (and TOTAL);
# when off it is an INTENTIONAL skip — not probed, not counted. Model overridable via
# TRIBUNAL_CODEX_MODEL; when UNSET the leg passes NO -m so codex uses its own configured
# default (which the codex CLI keeps current — no stale pinned id), preserving prior behaviour.
CODEX_MODEL="${TRIBUNAL_CODEX_MODEL:-}"
CODEX_ON=on
CLIS=""
if [ "${TRIBUNAL_CODEX:-on}" = "off" ]; then
  CODEX_ON=off
  WARN="${WARN}\n  - codex: disabled via TRIBUNAL_CODEX=off — leg will be skipped"
else
  CLIS="codex"
fi

# Gemini leg is OFF by default (opt-in via TRIBUNAL_GEMINI=on). When disabled it is an
# INTENTIONAL skip — not probed on PATH and not counted toward the zero-usable check.
# Only the literal "on" enables; anything else (or unset) = off. opencode is added below ONLY
# when an OpenCode leg (DeepSeek or GLM) is actually enabled, so a fully-disabled OpenCode call
# is not miscounted as a usable provider.
if [ "${TRIBUNAL_GEMINI:-off}" = "on" ]; then
  CLIS="$CLIS gemini"
else
  WARN="${WARN}\n  - gemini: disabled (default off) — set TRIBUNAL_GEMINI=on to enable"
fi

# Qwen leg switch (issue #41, #46). Independent leg on its OWN CLI/transport (Qwen Code CLI),
# decorrelated from the OpenCode legs. OFF by default (opt-in via TRIBUNAL_QWEN=on) — a real-
# world audit found the leg reasons over the diff text rather than grounding in files, emitting
# repeated false positives (phantom whitespace, nonexistent symbols/SQL, hallucinated line
# numbers; issue #46). Disabled pending the mandatory-verification fix. Only the literal "on"
# enables; anything else (or unset) = off — an INTENTIONAL skip, not probed and not counted.
QWEN_MODEL="${TRIBUNAL_QWEN_MODEL:-qwen3.7-plus}"
QWEN_ON=off
if [ "${TRIBUNAL_QWEN:-off}" = "on" ]; then
  QWEN_ON=on
  CLIS="$CLIS qwen"
else
  WARN="${WARN}\n  - qwen: disabled (default off, issue #46) — set TRIBUNAL_QWEN=on to enable"
fi

# Claude Code leg switch. The default panel's one DIFF-ONLY reviewer (the other default legs —
# Codex/DeepSeek/Qwen — all walk the repo), on the host `claude` CLI. ON by default; only the
# literal "off" disables. When on, `claude` joins the CLI list (and TOTAL) so the generic PATH
# loop counts it; when off it is an INTENTIONAL skip — not probed, not counted.
CLAUDE_MODEL="${TRIBUNAL_CLAUDE_MODEL:-sonnet}"
CLAUDE_ON=on
if [ "${TRIBUNAL_CLAUDE:-on}" = "off" ]; then
  CLAUDE_ON=off
  WARN="${WARN}\n  - claude: disabled via TRIBUNAL_CLAUDE=off — leg will be skipped"
else
  CLIS="$CLIS claude"
fi

# GLM leg switch (issue #41). The opencode-go GLM leg shares architectural lineage with
# DeepSeek and tends to fail in lockstep, so it is OFF by default (opt-in) — the default
# panel keeps the decorrelated set (Codex + DeepSeek + Qwen). Only the literal "on" enables.
GLM_MODEL="${TRIBUNAL_GLM_MODEL:-opencode-go/glm-5.1}"
GLM_ON=off
if [ "${TRIBUNAL_GLM:-off}" = "on" ]; then
  GLM_ON=on
else
  WARN="${WARN}\n  - glm: disabled (default off) — set TRIBUNAL_GLM=on to enable"
fi

# DeepSeek leg switch (mirrors TRIBUNAL_GEMINI). The DeepSeek leg runs through the
# `opencode-go/` reseller backend (OpenCode Go subscription, then credits on overage) —
# the same backend GLM uses. This trades the old #40/#38 decorrelation (DeepSeek was on the
# direct `deepseek/` API so an opencode-go 429 couldn't take both OpenCode legs down) for
# OpenCode Go billing: in the default panel only DeepSeek runs here (GLM is off), so the
# correlation only bites if you also opt GLM in. For an independent transport set
# TRIBUNAL_DEEPSEEK_MODEL=deepseek/deepseek-v4-pro (direct API; needs DEEPSEEK_API_KEY or
# `opencode auth login` → DeepSeek). On by default; only "off" disables.
DEEPSEEK_MODEL="${TRIBUNAL_DEEPSEEK_MODEL:-opencode-go/deepseek-v4-pro}"
DEEPSEEK_ON=on
if [ "${TRIBUNAL_DEEPSEEK:-on}" = "off" ]; then
  DEEPSEEK_ON=off
  WARN="${WARN}\n  - deepseek: disabled via TRIBUNAL_DEEPSEEK=off — leg will be skipped"
fi

# The `opencode` CLI is shared by the GLM and DeepSeek legs. Count it as a usable provider
# ONLY when at least one of them is enabled — otherwise a present-but-unused opencode would
# falsely satisfy the zero-usable check while contributing no active reviewer. DeepSeek is on
# by default, so by default opencode IS counted.
if [ "$DEEPSEEK_ON" = on ] || [ "$GLM_ON" = on ]; then
  CLIS="$CLIS opencode"
fi
TOTAL=$(set -- $CLIS; echo $#)

# Each reviewer CLI on PATH?
for cli in $CLIS; do
  if command -v "$cli" >/dev/null 2>&1; then
    USABLE=$((USABLE + 1))
  else
    WARN="${WARN}\n  - ${cli}: NOT on PATH — that provider will be skipped"
  fi
done

# Free disk (OpenCode + Codex write temp/session state; a full disk hangs them).
# Warn under ~2 GiB available on the home/tmp filesystem.
AVAIL_KB=$(df -Pk "${TMPDIR:-/tmp}" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 2097152 ]; then
  WARN="${WARN}\n  - disk: only $((AVAIL_KB / 1024)) MiB free on ${TMPDIR:-/tmp} — reviewers may stall on writes"
fi

# OpenCode model registry: warm once, then confirm BOTH leg models resolve. A cold/stale
# cache silently downgrades `-m` to an unauthenticated fallback (issue #32) — catch it here.
if command -v opencode >/dev/null 2>&1; then
  opencode models >/dev/null 2>&1 || true
  OC_MODELS=$(opencode models 2>/dev/null)
  # GLM leg model (opencode-go reseller backend) — only when enabled (off by default).
  if [ "$GLM_ON" = on ]; then
    printf '%s\n' "$OC_MODELS" | grep -qxF "$GLM_MODEL" || \
      WARN="${WARN}\n  - opencode model ${GLM_MODEL}: not in registry (cold/stale cache) — GLM leg will be skipped; run \`opencode models\` to refresh"
  fi
  # DeepSeek leg model — unless disabled. The provider only lists its models once
  # authenticated, so this registry check doubles as a liveness/config probe (folds in #38):
  # a missing model or missing credential surfaces here as a fast skip instead of a mid-review
  # hang. The auth-list hint below is provider-aware (opencode-go vs direct deepseek/).
  if [ "$DEEPSEEK_ON" = on ]; then
    # This model-in-registry check is the ACTUAL skip condition — it mirrors Bash call 3's
    # enforcement exactly (review_opencode_leg skips iff the model is absent from $OC_MODELS).
    printf '%s\n' "$OC_MODELS" | grep -qxF "$DEEPSEEK_MODEL" || \
      WARN="${WARN}\n  - opencode model ${DEEPSEEK_MODEL}: not in registry — DeepSeek leg will be skipped; check TRIBUNAL_DEEPSEEK_MODEL, run \`opencode auth login\`, or \`opencode models\` to refresh"
    # Auth HINT only (not a separate skip decision): a missing credential surfaces as the
    # model-miss above. Tailor the hint to the configured provider so the suggested fix is
    # right — opencode-go uses the OpenCode Go credential; deepseek/ uses the direct API.
    case "$DEEPSEEK_MODEL" in
      opencode-go/*)
        if ! opencode auth list 2>/dev/null | grep -Eqi 'opencode[- ]?go'; then
          WARN="${WARN}\n  - deepseek: OpenCode Go may not be authenticated (not in \`opencode auth list\`) — if the model check above failed, run \`opencode auth login\` and select OpenCode Go"
        fi
        ;;
      deepseek/*)
        if [ -z "${DEEPSEEK_API_KEY:-}" ] && ! opencode auth list 2>/dev/null | grep -qi deepseek; then
          WARN="${WARN}\n  - deepseek: direct API may not be authenticated (no DEEPSEEK_API_KEY and not in \`opencode auth list\`) — if the model check above failed, run \`opencode auth login\` (select DeepSeek) or set DEEPSEEK_API_KEY"
        fi
        ;;
    esac
  fi
fi

# Qwen leg preflight (issue #41): only when enabled. The generic PATH loop above already
# counted `qwen` and warned if it is missing, so here we only verify auth + liveness via a
# 1-token probe through the CLI itself — which reuses whatever auth qwen is configured with
# (env DASHSCOPE_API_KEY/OPENAI_API_KEY/OPENROUTER_API_KEY OR ~/.qwen/settings.json). A bad
# key/endpoint fails fast here instead of mid-review. The probe also detects a SILENT model
# fallback: qwen-code accepts an unknown -m and quietly downgrades to its default model.
if [ "$QWEN_ON" = on ] && command -v qwen >/dev/null 2>&1; then
  QWEN_PROBE=$(printf 'ok' | QWEN_CODE_SUPPRESS_YOLO_WARNING=1 timeout -k 5 45 qwen --model "$QWEN_MODEL" -p "Reply with the single token: ok" --yolo -o json 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$QWEN_PROBE" ]; then
    WARN="${WARN}\n  - qwen: liveness probe failed (timeout or no output) — check auth (DASHSCOPE_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY, or \`qwen\` settings) and connectivity; leg may fail in Step 2"
  else
    QWEN_ERR=$(printf '%s' "$QWEN_PROBE" | jq -r '[ .[]? | select(.type=="result") | .is_error ] | last // "unknown"' 2>/dev/null)
    QWEN_ACTUAL=$(printf '%s' "$QWEN_PROBE" | jq -r '[ .[]? | (.model // .message.model // empty) ] | map(select(. != null)) | last // "unknown"' 2>/dev/null)
    if [ "$QWEN_ERR" = "true" ]; then
      WARN="${WARN}\n  - qwen: liveness probe returned is_error=true — auth/model rejected; check DASHSCOPE_API_KEY and TRIBUNAL_QWEN_MODEL=${QWEN_MODEL}; leg may fail in Step 2"
    elif [ "$QWEN_ACTUAL" != "unknown" ] && [ "$QWEN_ACTUAL" != "$QWEN_MODEL" ]; then
      WARN="${WARN}\n  - qwen: requested model '${QWEN_MODEL}' but server used '${QWEN_ACTUAL}' (qwen-code silently downgraded an unknown -m). Set TRIBUNAL_QWEN_MODEL to a valid id for your account."
    fi
  fi
fi

# Claude Code leg preflight: only when enabled. The generic PATH loop already counted `claude`
# and warned if missing; here a 1-token probe (from a scratch dir, tools disabled) verifies the
# model alias resolves and auth works, so a bad TRIBUNAL_CLAUDE_MODEL or broken login fails fast
# here instead of mid-review. `.is_error=true` in the JSON envelope flags a model/auth rejection.
if [ "$CLAUDE_ON" = on ] && command -v claude >/dev/null 2>&1; then
  CLAUDE_PROBE=$( (cd "$(mktemp -d)" && printf 'ok' | timeout -k 5 45 claude -p "Reply with the single token: ok" --model "$CLAUDE_MODEL" --output-format json --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Task" 2>/dev/null) )
  if [ $? -ne 0 ] || [ -z "$CLAUDE_PROBE" ]; then
    WARN="${WARN}\n  - claude: liveness probe failed (timeout or no output) — check \`claude\` auth/login and connectivity; leg may fail in Step 2"
  else
    CLAUDE_ERR=$(printf '%s' "$CLAUDE_PROBE" | jq -r '.is_error // "unknown"' 2>/dev/null)
    if [ "$CLAUDE_ERR" = "true" ]; then
      WARN="${WARN}\n  - claude: liveness probe returned is_error=true — auth/model rejected; check \`claude\` login and TRIBUNAL_CLAUDE_MODEL=${CLAUDE_MODEL}; leg may fail in Step 2"
    fi
  fi
fi

# Gemini auth note: a stale key surfaces only mid-review. We cannot cheaply verify it
# here without a billable call, so just remind to rotate if Gemini fails in Step 2.
if [ -n "$WARN" ]; then
  printf 'PREFLIGHT WARNINGS:%b\n' "$WARN"
fi
if [ "$USABLE" -eq 0 ]; then
  echo "PREFLIGHT FAIL: no reviewer CLIs found on PATH. Cannot run tribunal."
  exit 1
fi
echo "PREFLIGHT OK: ${USABLE}/${TOTAL} reviewer CLIs available."
```

If preflight exits non-zero (no usable providers): STOP and report. Otherwise note any
warnings — the affected provider(s) will be skipped in Step 2 and arbitration treats the
result as a degraded quorum.

Output: "[TRIBUNAL 1/3] On branch: {branch_name}, {N} files changed — {USABLE}/{TOTAL} providers ready{, warnings if any}" (TOTAL counts reviewer CLIs on PATH. By default that is codex + opencode + claude (DeepSeek on ⇒ opencode counted; Claude on); add gemini when TRIBUNAL_GEMINI=on and qwen when TRIBUNAL_QWEN=on; subtract claude when TRIBUNAL_CLAUDE=off. The opencode CLI carries both the GLM and DeepSeek legs, so it is counted whenever EITHER is enabled and is dropped only if BOTH are off.)

---

## STEP 2: Parallel Review

Run the scripts below as **five parallel Bash tool calls** (Codex, Gemini, OpenCode, Qwen, Claude). No Task agents -- execute directly. Each leg self-emits a `disabled` marker when its switch is off, so all five are always safe to dispatch — by default only Codex, the OpenCode DeepSeek leg, and the Claude diff-only leg actually review (Gemini, GLM, and Qwen are opt-in). The OpenCode call (Bash call 3) runs its two legs **sequentially within that one call**, because concurrent `opencode run` instances deadlock on the shared `~/.local/share/opencode` data dir (issue #31). It yields up to two reviews (GLM + DeepSeek) — but **GLM is off by default** (`TRIBUNAL_GLM=on` to enable), so by default that call yields only DeepSeek. The two legs differ in cwd/context: **GLM** runs diff-only from a scratch dir; **DeepSeek** runs from the **repo root** so it can walk the tree. Both now run on the **opencode-go** backend by default (DeepSeek bills against the OpenCode Go subscription, then credits) — so the issue-#40 decorrelation is given up, but it only matters if you also opt GLM in, and GLM is off by default. Point `TRIBUNAL_DEEPSEEK_MODEL` at `deepseek/deepseek-v4-pro` to put DeepSeek back on the independent direct API.

Each reviewer is given the repo's `AGENTS.md` (if present, capped at 16KB) as a **Project Conventions** block, so all judge the diff against the same project standards. The two default walking legs **read beyond the diff** read-only — **Codex** (in-container, no `--sandbox` flag) and **DeepSeek** (`--agent plan`, on the opencode-go backend) — opening related files and tracing cross-file effects to avoid the context-gap false positives a diff-only pass produces; the opt-in **Qwen** leg (Qwen Code CLI, `--yolo`, issue #44) also walks when enabled. The default **Claude** leg and the opt-in GLM and Gemini legs remain diff-only.

### Bash call 1: Codex Review

```bash
cd "$(git rev-parse --show-toplevel)"

# Codex leg switch (issue #43). ON by default; only the literal "off" disables. When off this
# is an INTENTIONAL skip — emit a disabled marker the arbiter excludes from quorum (mirrors the
# Gemini/DeepSeek/Qwen/Claude legs), NOT a failure. Re-read here because each leg runs in its
# own Bash process (the Step-1 preflight var does not carry over).
if [ "${TRIBUNAL_CODEX:-on}" = "off" ]; then
  printf '%s\n' '{"provider": "codex", "status": "disabled", "note": "Codex leg disabled via TRIBUNAL_CODEX=off"}'
  exit 0
fi

# Model override (issue #43). When TRIBUNAL_CODEX_MODEL is set, pass it via `-m`; when UNSET,
# pass NO -m so codex uses its own configured default (kept current by the codex CLI — no stale
# pinned id). Built as an array so -m is either absent or exactly one argv pair (SC2086-clean).
CODEX_MODEL_ARGS=()
[ -n "${TRIBUNAL_CODEX_MODEL:-}" ] && CODEX_MODEL_ARGS=(-m "$TRIBUNAL_CODEX_MODEL")

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider": "codex", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}'
  exit 0
fi

# Guard against massive diffs (~100KB limit)
DIFF_SIZE=${#DIFF}
if [ "$DIFF_SIZE" -gt 102400 ]; then
  DIFF=$(echo "$DIFF" | head -c 102400)
  DIFF_TRUNCATED=true
else
  DIFF_TRUNCATED=false
fi

# Optional: inject the repo's AGENTS.md so every reviewer judges the diff against
# the same project conventions (capped; absent file => no injection).
CONVENTIONS=""
[ -f AGENTS.md ] && CONVENTIONS=$(head -c 16384 AGENTS.md)
# Deployment/reachability facts a diff cannot reveal (worker model, concurrency,
# single-user-per-session, money/data-loss paths). Capped; absent => no injection.
REACHABILITY=""
[ -f reachability.md ] && REACHABILITY=$(head -c 8192 reachability.md)

cat > "$TMPDIR/codex-review-schema.json" << 'SCHEMA'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["provider", "model", "findings", "summary"],
  "additionalProperties": false,
  "properties": {
    "provider": { "type": "string", "const": "codex" },
    "model": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["severity", "category", "file", "line", "title", "description", "suggestion", "confidence"],
        "additionalProperties": false,
        "properties": {
          "severity": { "type": "string", "enum": ["critical", "high", "medium", "low"] },
          "category": { "type": "string", "enum": ["logic", "security", "performance", "quality", "edge-case", "architecture", "testing"] },
          "file": { "type": "string" },
          "line": { "type": "integer" },
          "title": { "type": "string" },
          "description": { "type": "string" },
          "suggestion": { "type": "string" },
          "confidence": { "type": "number" }
        }
      }
    },
    "summary": {
      "type": "object",
      "required": ["total_findings", "critical", "high", "medium", "low", "quality_score", "verdict"],
      "additionalProperties": false,
      "properties": {
        "total_findings": { "type": "integer" },
        "critical": { "type": "integer" },
        "high": { "type": "integer" },
        "medium": { "type": "integer" },
        "low": { "type": "integer" },
        "quality_score": { "type": "number" },
        "verdict": { "type": "string", "enum": ["APPROVE", "NEEDS_WORK", "BLOCK"] }
      }
    }
  }
}
SCHEMA

timeout -k 10 600 codex exec - "${CODEX_MODEL_ARGS[@]}" \
  --output-schema "$TMPDIR/codex-review-schema.json" \
  -o "$TMPDIR/codex-review-output.json" \
  >/dev/null 2>"$TMPDIR/codex-stderr.txt" <<PROMPT
You are a senior code reviewer. Analyze the diff below for REAL, ACTIONABLE issues only.

## What to Report
1. **Logic errors** — division by zero, off-by-one, null dereference, wrong comparisons, race conditions
2. **Security vulnerabilities** — SQL injection, command injection, XSS, auth bypass, sensitive data exposure
3. **Edge cases** — boundary conditions, empty inputs, integer overflow, unhandled error paths
4. **Performance** — N+1 queries, unnecessary allocations, blocking async calls
5. **Silent failures & payment-path traps** — when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions / broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, and money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.

## What NOT to Report
- Style preferences or naming opinions
- Missing documentation or comments
- Minor code quality issues that don't affect correctness
- Theoretical concerns without concrete evidence in the diff

## Rules
- ONLY report findings with confidence >= 0.7
- Use EXACT file paths from the diff headers (e.g., "a/src/Foo.cs" -> "src/Foo.cs")
- Use the line number from the diff where the issue occurs
- Each finding must have a concrete, actionable suggestion
- You are running inside the project repository. You MAY open OTHER files in the project to trace how the changed code is called elsewhere and verify framework/library semantics, variable scope, and call sites before reporting, to catch cross-file breakage and avoid context-gap false positives. This is review-only — do NOT modify any files.

## Verdict Rules
- **BLOCK**: Any critical-severity finding, OR 2+ high-severity findings
- **NEEDS_WORK**: Any high-severity finding, OR 3+ medium-severity findings
- **APPROVE**: All other cases

## Output
Your response MUST be valid JSON matching the provided output schema.
Set "provider" to "codex" and "model" to the model you are running as.
$([ "$DIFF_TRUNCATED" = true ] && echo "NOTE: Diff was truncated from ${DIFF_SIZE} bytes to 100KB. Review what is provided.")
$([ -n "$CONVENTIONS" ] && printf '\n## Project Conventions (from AGENTS.md)\nUse these ONLY to judge whether the diff violates project standards; report findings only against the diff.\n\n%s\n' "$CONVENTIONS")
$([ -n "$REACHABILITY" ] && printf '\n## Production Reachability (from reachability.md)\nUse to judge whether a finding is reachable in production. A critical/high finding must still independently prove a reachable path; this file is supporting context, not a severity override.\n\n%s\n' "$REACHABILITY")

The changed lines are in THE DIFF below. You are running inside the project repository — read related files as needed to understand context and verify cross-file effects, but report findings only against the changed lines.

THE DIFF:
$DIFF
PROMPT
CODEX_EXIT=$?

if [ $CODEX_EXIT -eq 0 ] && [ -f "$TMPDIR/codex-review-output.json" ]; then
  cat "$TMPDIR/codex-review-output.json"
else
  STDERR_CONTENT=$(cat "$TMPDIR/codex-stderr.txt" 2>/dev/null || echo "no stderr captured")
  SAFE_STDERR=$(echo "$STDERR_CONTENT" | jq -Rs . 2>/dev/null || echo '"stderr encoding failed"')
  printf '{"error": "Codex execution failed", "exit_code": %d, "stderr": %s}\n' "$CODEX_EXIT" "$SAFE_STDERR"
fi
# trap EXIT handles cleanup of $TMPDIR
```

### Bash call 2: Gemini Review

```bash
cd "$(git rev-parse --show-toplevel)"

# Config: the Gemini leg can be disabled (TRIBUNAL_GEMINI=off) or pointed at a
# different model (TRIBUNAL_GEMINI_MODEL). Only the literal "off" disables; anything
# else (or unset) runs as normal. Defaults reproduce the original behavior exactly.
if [ "${TRIBUNAL_GEMINI:-off}" != "on" ]; then
  printf '%s\n' '{"provider": "gemini", "status": "disabled", "note": "Gemini leg disabled (default off); set TRIBUNAL_GEMINI=on to enable"}'
  exit 0
fi
GEMINI_MODEL="${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider": "gemini", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}'
  exit 0
fi

# Optional: inject the repo's AGENTS.md so every reviewer judges the diff against
# the same project conventions (capped; absent file => no injection).
CONVENTIONS=""
[ -f AGENTS.md ] && CONVENTIONS=$(head -c 16384 AGENTS.md)
# Deployment/reachability facts a diff cannot reveal (worker model, concurrency,
# single-user-per-session, money/data-loss paths). Capped; absent => no injection.
REACHABILITY=""
[ -f reachability.md ] && REACHABILITY=$(head -c 8192 reachability.md)

printf '%s\n' "$DIFF" | timeout -k 10 600 gemini --model "$GEMINI_MODEL" -p "You are a senior code reviewer performing a thorough security-focused review.

ANALYZE THIS DIFF FOR:
1. Security vulnerabilities - injection, XSS, CSRF, auth issues, secrets exposure
2. Architectural issues - coupling, layering violations, anti-patterns
3. Logic errors - race conditions, null refs, wrong comparisons
4. Performance - N+1 queries, memory leaks, blocking in async
5. Test coverage gaps - missing edge cases, untested paths
6. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.

USE YOUR SEARCH CAPABILITY to check for:
- Known CVEs in any dependencies mentioned
- Security best practices for patterns used
- Current recommendations for the frameworks detected

RESPOND WITH ONLY THIS JSON (no markdown, no explanation):
{
  \"provider\": \"gemini\",
  \"model\": \"default\",
  \"findings\": [
    {
      \"severity\": \"critical|high|medium|low\",
      \"category\": \"security|architecture|logic|performance|testing\",
      \"file\": \"path/to/file\",
      \"line\": 42,
      \"title\": \"Brief descriptive title\",
      \"description\": \"What is wrong and why it matters\",
      \"suggestion\": \"Concrete fix recommendation\",
      \"confidence\": 0.95
    }
  ],
  \"summary\": {
    \"total_findings\": 3,
    \"critical\": 0,
    \"high\": 1,
    \"medium\": 2,
    \"low\": 0,
    \"quality_score\": 7.5,
    \"verdict\": \"APPROVE|NEEDS_WORK|BLOCK\"
  }
}
$([ -n "$CONVENTIONS" ] && printf '\nPROJECT CONVENTIONS (from AGENTS.md) — use ONLY to judge whether the diff violates project standards; report findings only against the diff:\n%s\n' "$CONVENTIONS")
$([ -n "$REACHABILITY" ] && printf '\n## Production Reachability (from reachability.md)\nUse to judge whether a finding is reachable in production. A critical/high finding must still independently prove a reachable path; this file is supporting context, not a severity override.\n\n%s\n' "$REACHABILITY")
THE DIFF IS PROVIDED VIA STDIN ABOVE." \
  --yolo \
  -o json \
  >"$TMPDIR/gemini-raw-output.json" 2>"$TMPDIR/gemini-stderr.txt"

GEMINI_EXIT=$?
if [ $GEMINI_EXIT -eq 0 ] && [ -f "$TMPDIR/gemini-raw-output.json" ]; then
  # Gemini -o json wraps output in session envelope; extract .response and strip markdown fences
  RESPONSE=$(jq -r '.response // empty' "$TMPDIR/gemini-raw-output.json" 2>/dev/null)
  if [ -n "$RESPONSE" ]; then
    echo "$RESPONSE" | sed 's/^```json//;s/^```//;/^$/d' | jq . 2>/dev/null || echo "$RESPONSE"
  else
    cat "$TMPDIR/gemini-raw-output.json"
  fi
else
  STDERR_CONTENT=$(cat "$TMPDIR/gemini-stderr.txt" 2>/dev/null)
  SAFE_STDERR=$(echo "$STDERR_CONTENT" | jq -Rs . 2>/dev/null || echo '"stderr encoding failed"')
  printf '{"error": "Gemini execution failed", "exit_code": %d, "stderr": %s}\n' "$GEMINI_EXIT" "$SAFE_STDERR"
fi
# trap EXIT handles cleanup of $TMPDIR
```

### Bash call 3: OpenCode Review (GLM + DeepSeek, sequential)

Runs both OpenCode legs **back-to-back inside a single Bash call** and prints
**two** JSON objects on stdout (GLM first, then DeepSeek). The two legs must NOT
overlap: concurrent `opencode run` processes deadlock on the shared
`~/.local/share/opencode` SQLite data dir, hanging until the timeout (issue #31) —
this single-call serialization is why they stay decoupled in *transport* yet share a
Bash call. The legs differ in **backend, cwd, and context scope**:

- **GLM** — opencode-go backend, **diff-only** (no tools), run from the non-repo scratch
  `$TMPDIR`. **Off by default** (opt-in via `TRIBUNAL_GLM=on`): it shares lineage with DeepSeek
  and tends to fail in lockstep (issue #41), so the default panel drops it. `opencode run` can
  deadlock at init when its cwd is inside a git repo on older builds (issue #4-class), so this
  diff-only leg keeps using the scratch dir.
- **DeepSeek** — `opencode-go/…` backend (OpenCode Go subscription → credits on overage),
  **repo-walking** read-only, run from the **repo root** so `--agent plan` can open related
  files. Verified safe on opencode ≥ 1.15 (the git-cwd init deadlock no longer reproduces);
  a leg that does hang is bounded by the 360s cap and degrades to quorum. Switchable via
  `TRIBUNAL_DEEPSEEK`; point `TRIBUNAL_DEEPSEEK_MODEL` at `deepseek/deepseek-v4-pro` to use
  the direct DeepSeek API instead (decorrelated transport, separate billing).

Before the legs run it warms the model registry and asserts each leg's model resolves,
so a cold/stale `~/.cache/opencode/models.json` (or an unauthenticated provider)
fails loudly instead of silently downgrading `-m` to an unauthenticated fallback model
(issue #32). Codex (Bash call 1) and Gemini (Bash call 2) stay parallel with this call.

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

# DeepSeek leg config (mirrors the Gemini switch). Runs through the opencode-go backend
# (OpenCode Go subscription → credits on overage). Override with `deepseek/deepseek-v4-pro`
# for the direct DeepSeek API (decorrelated from opencode-go; see Step-1 rationale, issue #40).
DEEPSEEK_MODEL="${TRIBUNAL_DEEPSEEK_MODEL:-opencode-go/deepseek-v4-pro}"

# DeepSeek leg's "intentional skip" marker (emitted when TRIBUNAL_DEEPSEEK=off). Shaped
# exactly like Gemini's disabled marker so Step 3 treats it as a disabled provider, not a failure.
emit_deepseek_disabled() {
  printf '%s\n' '{"provider": "deepseek", "status": "disabled", "note": "DeepSeek leg disabled via TRIBUNAL_DEEPSEEK=off"}'
}

# GLM leg config + "intentional skip" marker. GLM is OFF by default (opt-in): it shares
# architectural lineage with DeepSeek and tends to fail in lockstep, so the default panel
# drops it (issue #41). Model overridable via TRIBUNAL_GLM_MODEL.
GLM_MODEL="${TRIBUNAL_GLM_MODEL:-opencode-go/glm-5.1}"
emit_glm_disabled() {
  printf '%s\n' '{"provider": "glm", "status": "disabled", "note": "GLM leg disabled (default off); set TRIBUNAL_GLM=on to enable"}'
}

emit_empty() {  # provider, model
  printf '{"provider": "%s", "model": "%s", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}\n' "$1" "$2"
}

# If OpenCode is not installed, emit an object for each leg (error if enabled, disabled marker
# if its switch is off) and stop.
if ! command -v opencode >/dev/null 2>&1; then
  if [ "${TRIBUNAL_GLM:-off}" = "on" ]; then
    printf '%s\n' '{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "glm"}'
  else emit_glm_disabled; fi
  if [ "${TRIBUNAL_DEEPSEEK:-on}" = "off" ]; then emit_deepseek_disabled; else
    printf '%s\n' '{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "deepseek"}'
  fi
  exit 0
fi

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  if [ "${TRIBUNAL_GLM:-off}" = "on" ]; then emit_empty "glm" "$GLM_MODEL"; else emit_glm_disabled; fi
  if [ "${TRIBUNAL_DEEPSEEK:-on}" = "off" ]; then emit_deepseek_disabled; else
    emit_empty "deepseek" "$DEEPSEEK_MODEL"
  fi
  exit 0
fi

# Optional: inject the repo's AGENTS.md so every reviewer judges the diff against
# the same project conventions (capped; absent file => no injection). Read while
# still in the repo, before the cd below.
CONVENTIONS=""
[ -f AGENTS.md ] && CONVENTIONS=$(head -c 16384 AGENTS.md)
# Deployment/reachability facts a diff cannot reveal (worker model, concurrency,
# single-user-per-session, money/data-loss paths). Capped; absent => no injection.
REACHABILITY=""
[ -f reachability.md ] && REACHABILITY=$(head -c 8192 reachability.md)

# Pass the diff as a FILE ATTACHMENT (`-f`), NOT inline in the prompt argv. Earlier
# versions embedded the whole diff in the prompt string, which `opencode run` passes as
# a SINGLE argv element — and Linux caps any one argv string at MAX_ARG_STRLEN = 131072
# bytes (128 KiB) regardless of the much larger total ARG_MAX. A diff past that limit made
# execve fail with E2BIG ("Argument list too long"), silently dropping both OpenCode legs.
# `-f` sidesteps the argv limit entirely (the file is read by opencode, not exec'd), so no
# truncation is needed for argv reasons. We still apply a generous context-window guard so a
# pathological diff cannot blow the model context; GLM/DeepSeek have large windows, so cap high.
DIFF_SIZE=${#DIFF}
DIFF_TRUNCATED=false
if [ "$DIFF_SIZE" -gt 524288 ]; then          # 512 KiB context guard (NOT an argv limit)
  DIFF=$(printf '%s' "$DIFF" | head -c 524288)
  DIFF_TRUNCATED=true
fi
DIFF_FILE="$TMPDIR/review.diff"
printf '%s' "$DIFF" > "$DIFF_FILE"

# NOTE: each leg sets its OWN cwd (see review_opencode_leg's `workdir` arg), so there is
# no global `cd` here. GLM runs from the non-repo scratch `$TMPDIR` (diff-only, dodges the
# git-cwd init deadlock on older opencode builds); DeepSeek runs from `$REPO_ROOT` so its
# read-only `--agent plan` can walk the tree. The commands below (`opencode models`,
# `opencode run --help`) only LIST/print — they do not start the agent runtime that the
# git-cwd deadlock affects — so they are safe to run from the repo root.

# Warm the OpenCode model registry. A cold/stale ~/.cache/opencode/models.json
# makes `opencode run -m <model>` silently DROP the -m arg and fall back to an
# unauthenticated default model — surfacing as a misleading "Missing Authentication
# header" error and quietly downgrading the tribunal quorum (issue #32).
# Refresh once, then snapshot the list so each leg can assert its model resolved.
opencode models >/dev/null 2>&1 || true
OC_MODELS=$(opencode models 2>/dev/null)

# Feature-detect `--pure` (runs the model WITHOUT external plugins — this is what
# avoids the plugin-load deadlock noted above, not the -f attachment). Older opencode
# (e.g. 1.2.4) has no such flag and, on the unknown argument, aborts the WHOLE run by
# printing `run` help to stdout and exiting 1 with empty stderr — which the leg catches
# as a generic "OpenCode ... failed", silently degrading the tribunal quorum
# (issue #36). Probe once and append it only when this opencode advertises it.
# Built as an array so the flag is either absent or passed as exactly one argv
# element — no reliance on unquoted word-splitting (ShellCheck SC2086-clean).
OC_PURE_ARGS=()
if opencode run --help 2>&1 | grep -qE '(^|[[:space:]])--pure([[:space:]]|$)'; then
  OC_PURE_ARGS=(--pure)
fi

# Review one OpenCode leg and print its JSON.
# Args: provider, label, model, workdir, walk(0|1)
#   workdir — cwd to run `opencode run` from. GLM uses the scratch $TMPDIR (diff-only, no
#             repo context needed). DeepSeek uses $REPO_ROOT so it can walk the tree.
#   walk    — 1 lets the leg use read-only tools (read/grep/glob) to open related files;
#             0 forbids tools (diff-only). Legs run SEQUENTIALLY regardless (issue #31).
review_opencode_leg() {
  local provider="$1" label="$2" model="$3" workdir="$4" walk="$5"
  local raw="$TMPDIR/$provider-raw.txt" err="$TMPDIR/$provider-stderr.txt"
  local oc_exit json safe prompt ctx_rule ctx_close diff_attach

  # Assert the requested model is in the (warmed) registry. If it is absent, a cold cache
  # (or, for the direct `deepseek/` provider, a missing credential — its models only list
  # once authenticated) would silently downgrade this leg to an unauthenticated fallback
  # model, so emit a distinct, actionable error and skip the run rather than disguise it.
  if ! printf '%s\n' "$OC_MODELS" | grep -qxF "$model"; then
    printf '{"error": "OpenCode model %s not in registry (cold/stale cache, or provider not authenticated) — run `opencode models` / `opencode auth login`; leg skipped to avoid silent downgrade to an unauthenticated fallback model", "provider": "%s"}\n' "$model" "$provider"
    return
  fi

  # Context scope differs per leg: diff-only (GLM) vs repo-walking read-only (DeepSeek).
  if [ "$walk" = "1" ]; then
    ctx_rule="- You MAY use your read-only tools (read, grep, glob, list) to open OTHER files in the project and trace how the changed code is called elsewhere, to catch cross-file breakage. You CANNOT modify files."
    ctx_close="The changed lines are in the ATTACHED FILE (review.diff). You are running inside the project repository — read related files as needed to understand context and verify cross-file effects, but report findings only against the changed lines."
  else
    ctx_rule="- Do NOT use any tools. Analyze ONLY the attached diff file."
    ctx_close="The unified diff to review is in the ATTACHED FILE (review.diff)."
  fi

  prompt="You are a senior code reviewer performing a thorough, comprehensive review.

ANALYZE THIS DIFF FOR:
1. Logic errors - off-by-one, null deref, wrong comparisons, race conditions, division by zero
2. Security vulnerabilities - injection, XSS, CSRF, auth bypass, secrets exposure
3. Architecture - coupling, layering violations, anti-patterns
4. Performance - N+1 queries, memory leaks, blocking in async, unnecessary allocations
5. Edge cases - boundary conditions, empty inputs, integer overflow, unhandled error paths
6. Test coverage gaps - missing edge cases, untested paths
7. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.

RULES:
- ONLY report findings with confidence >= 0.7
- Use EXACT file paths from the diff headers (e.g., 'a/src/Foo.cs' -> 'src/Foo.cs')
- Use the line number from the diff where the issue occurs
- Each finding must have a concrete, actionable suggestion
$ctx_rule

VERDICT RULES:
- BLOCK: any critical-severity finding, OR 2+ high-severity findings
- NEEDS_WORK: any high-severity finding, OR 3+ medium-severity findings
- APPROVE: all other cases

OUTPUT:
Output ONLY a JSON object, wrapped EXACTLY between these markers on their own lines:
===TRIBUNAL_JSON_BEGIN===
{
  \"provider\": \"$provider\",
  \"model\": \"$model\",
  \"findings\": [
    {\"severity\": \"critical|high|medium|low\", \"category\": \"logic|security|performance|quality|edge-case|architecture|testing\", \"file\": \"path\", \"line\": 42, \"title\": \"...\", \"description\": \"...\", \"suggestion\": \"...\", \"confidence\": 0.9}
  ],
  \"summary\": {\"total_findings\": 1, \"critical\": 0, \"high\": 1, \"medium\": 0, \"low\": 0, \"quality_score\": 7.5, \"verdict\": \"APPROVE|NEEDS_WORK|BLOCK\"}
}
===TRIBUNAL_JSON_END===
$([ "$DIFF_TRUNCATED" = true ] && echo "NOTE: Diff was truncated for context size. Review what is provided.")
$([ -n "$CONVENTIONS" ] && printf '\n## Project Conventions (from AGENTS.md)\nUse these ONLY to judge whether the diff violates project standards; report findings only against the diff.\n\n%s\n' "$CONVENTIONS")
$([ -n "$REACHABILITY" ] && printf '\n## Production Reachability (from reachability.md)\nUse to judge whether a finding is reachable in production. A critical/high finding must still independently prove a reachable path; this file is supporting context, not a severity override.\n\n%s\n' "$REACHABILITY")

$ctx_close"

  # Fail fast: single attempt, 360s cap. The two legs run SEQUENTIALLY (issue #31), so a
  # per-leg timeout bounds the worst case at ~360s+360s ≈ 12 min. The previous 600s cap WITH
  # a timeout-retry could stack to ~40 min on a genuinely-hung provider — the multi-minute
  # "hung review" stall users reported. A timed-out leg simply degrades to the available
  # quorum, which arbitration (Step 3e) already handles gracefully.
  #
  # `--variant high`: keep maximum reasoning depth. The variant is NOT a meaningful latency
  # lever for these reasoning models — measured minimal vs high at 21/24/23s vs 24/21/23s on
  # the same diff (no reliable difference; the cost is inherent generation time with a heavy
  # tail, not reasoning effort). So high costs nothing extra in wall-clock and buys more depth.
  # The genuine latency lever is switching to faster NON-reasoning models (e.g. a *-flash slot),
  # which is a quality/reliability tradeoff left to the operator. The 360s cap below bounds the
  # heavy tail; a leg that exceeds it degrades to quorum. Diff is passed via `-f` (file attach),
  # never inline in argv — see the file-attachment note above.
  # Run from $workdir in a SUBSHELL so the cwd change cannot leak between legs (GLM in
  # $TMPDIR, DeepSeek in $REPO_ROOT). Diff via -f (file attach), never inline argv.
  #
  # Stage the diff attachment INSIDE $workdir so it falls within `--agent plan`'s read
  # sandbox (reads are confined to cwd). The diff-only legs already run from $TMPDIR, so
  # $DIFF_FILE is in-sandbox for them; but the repo-walking leg's cwd is $REPO_ROOT, and
  # the shared $TMPDIR/review.diff lives OUTSIDE it — plan auto-rejects the external read
  # and the leg cannot read the very diff it must review (issue #45). Stage a copy at the
  # top of cwd (guaranteed in-sandbox; works for linked git worktrees too, unlike .git/),
  # dot-prefixed + provider-named so it never collides and stays out of `git status` long
  # — the legs are serialized and we remove it immediately after the run.
  diff_attach="$DIFF_FILE"
  if [ "$walk" = "1" ]; then
    diff_attach="$workdir/.tribunal-review-$provider.diff"
    # If staging fails (disk full, RO workdir), don't run opencode against a missing -f
    # path and surface a misleading "file not found" — emit an actionable error and
    # degrade this leg to the quorum, mirroring the not-in-registry early return above.
    if ! cp "$DIFF_FILE" "$diff_attach" 2>/dev/null; then
      printf '{"error": "OpenCode %s: failed to stage diff into workdir %s (disk full / read-only?) — leg skipped", "provider": "%s"}\n' "$label" "$workdir" "$provider"
      return
    fi
  fi
  ( cd "$workdir" && timeout -k 10 360 opencode run --agent plan -m "$model" --variant high --format default "${OC_PURE_ARGS[@]}" "$prompt" -f "$diff_attach" </dev/null ) \
    >"$raw" 2>"$err"
  oc_exit=$?
  [ "$walk" = "1" ] && rm -f "$diff_attach"

  if [ "$oc_exit" -eq 0 ] && [ -s "$raw" ]; then
    # Extract between sentinels; fall back to first-{ .. last-} slice
    json=$(sed -n '/===TRIBUNAL_JSON_BEGIN===/,/===TRIBUNAL_JSON_END===/p' "$raw" \
      | sed '/===TRIBUNAL_JSON_BEGIN===/d;/===TRIBUNAL_JSON_END===/d;s/^```json//;s/^```//')
    if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
      json=$(tr -d '\r' < "$raw" | sed -n 'H;${x;s/^[^{]*//;s/[^}]*$//;p;}')
    fi
    if printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$json" | jq -c .
    else
      safe=$(jq -Rs . < "$raw" 2>/dev/null || echo '"capture failed"')
      printf '{"error": "OpenCode %s produced unparseable output", "provider": "%s", "raw": %s}\n' "$label" "$provider" "$safe"
    fi
  else
    safe=$(jq -Rs . < "$err" 2>/dev/null || echo '"stderr encoding failed"')
    printf '{"error": "OpenCode %s execution failed", "provider": "%s", "exit_code": %d, "stderr": %s}\n' "$label" "$provider" "$oc_exit" "$safe"
  fi
}

# SEQUENTIAL — the two legs must never overlap (see issue #31).
# GLM: opencode-go backend, diff-only (walk=0), from the scratch dir — OFF by default (opt-in).
if [ "${TRIBUNAL_GLM:-off}" = "on" ]; then
  review_opencode_leg "glm" "GLM" "$GLM_MODEL" "$TMPDIR" 0
else
  emit_glm_disabled
fi
# DeepSeek: DIRECT DeepSeek API, repo-walking (walk=1), from the repo root — unless disabled.
# Repo-walking can take longer than a diff-only pass; the 360s cap bounds the tail.
if [ "${TRIBUNAL_DEEPSEEK:-on}" = "off" ]; then
  emit_deepseek_disabled
else
  review_opencode_leg "deepseek" "DeepSeek" "$DEEPSEEK_MODEL" "$REPO_ROOT" 1
fi
# trap EXIT handles cleanup of $TMPDIR
```

### Bash call 4: Qwen Review

Independent, **repo-walking** read-only leg on its OWN CLI (Qwen Code, `@qwen-code/qwen-code`) —
NOT the `opencode` backend GLM/DeepSeek share, so it cannot fail in lockstep with them (issue #41).
It `cd`s to the repo root and runs with `--yolo`, so its read-only tools (read/grep/glob/list) are
available; the prompt permits opening related files to verify cross-file effects (issue #44), while
findings are still reported only against the changed lines.
**Off by default** (opt-in via `TRIBUNAL_QWEN=on`; disabled pending the issue #46 false-positive
fix). When enabled, runs as a fourth parallel Bash call alongside Codex (call 1), Gemini (call 2),
and OpenCode (call 3).

```bash
cd "$(git rev-parse --show-toplevel)"

# Qwen leg is OFF by default (issue #46: ungrounded diff-text reasoning → repeated false
# positives). Only the literal "on" enables; anything else (or unset) skips. When off, emit the
# disabled marker so the arbiter accounts for qwen as a (disabled) fifth peer. TRIBUNAL_QWEN_MODEL
# overrides the model.
if [ "${TRIBUNAL_QWEN:-off}" != "on" ]; then
  printf '%s\n' '{"provider": "qwen", "status": "disabled", "note": "Qwen leg disabled (default off, issue #46); set TRIBUNAL_QWEN=on to enable"}'
  exit 0
fi
QWEN_MODEL="${TRIBUNAL_QWEN_MODEL:-qwen3.7-plus}"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider": "qwen", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}'
  exit 0
fi

# Optional: inject the repo's AGENTS.md so every reviewer judges the diff against
# the same project conventions (capped; absent file => no injection).
CONVENTIONS=""
[ -f AGENTS.md ] && CONVENTIONS=$(head -c 16384 AGENTS.md)
# Deployment/reachability facts a diff cannot reveal (worker model, concurrency,
# single-user-per-session, money/data-loss paths). Capped; absent => no injection.
REACHABILITY=""
[ -f reachability.md ] && REACHABILITY=$(head -c 8192 reachability.md)

printf '%s\n' "$DIFF" | QWEN_CODE_SUPPRESS_YOLO_WARNING=1 timeout -k 10 600 qwen --model "$QWEN_MODEL" -p "You are a senior code reviewer performing a thorough, comprehensive review.

ANALYZE THIS DIFF FOR:
1. Logic errors - off-by-one, null deref, wrong comparisons, race conditions, division by zero
2. Security vulnerabilities - injection, XSS, CSRF, auth bypass, secrets exposure
3. Architecture - coupling, layering violations, anti-patterns
4. Performance - N+1 queries, memory leaks, blocking in async, unnecessary allocations
5. Edge cases - boundary conditions, empty inputs, integer overflow, unhandled error paths
6. Test coverage gaps - missing edge cases, untested paths
7. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.

RULES:
- ONLY report findings with confidence >= 0.7
- Use EXACT file paths from the diff headers (e.g., 'a/src/Foo.cs' -> 'src/Foo.cs')
- Use the line number from the diff where the issue occurs
- Each finding must have a concrete, actionable suggestion
- You MAY use your read-only tools (read, grep, glob, list) to open OTHER files in the project and trace how the changed code is called elsewhere, to catch cross-file breakage and verify framework/library semantics, variable scope, and call sites before reporting. You CANNOT modify files.

VERDICT RULES:
- BLOCK: any critical-severity finding, OR 2+ high-severity findings
- NEEDS_WORK: any high-severity finding, OR 3+ medium-severity findings
- APPROVE: all other cases

RESPOND WITH ONLY THIS JSON (no markdown, no explanation):
{
  \"provider\": \"qwen\",
  \"model\": \"default\",
  \"findings\": [
    {
      \"severity\": \"critical|high|medium|low\",
      \"category\": \"security|architecture|logic|performance|quality|edge-case|testing\",
      \"file\": \"path/to/file\",
      \"line\": 42,
      \"title\": \"Brief descriptive title\",
      \"description\": \"What is wrong and why it matters\",
      \"suggestion\": \"Concrete fix recommendation\",
      \"confidence\": 0.95
    }
  ],
  \"summary\": {
    \"total_findings\": 3,
    \"critical\": 0,
    \"high\": 1,
    \"medium\": 2,
    \"low\": 0,
    \"quality_score\": 7.5,
    \"verdict\": \"APPROVE|NEEDS_WORK|BLOCK\"
  }
}
$([ -n "$CONVENTIONS" ] && printf '\nPROJECT CONVENTIONS (from AGENTS.md) — use ONLY to judge whether the diff violates project standards; report findings only against the diff:\n%s\n' "$CONVENTIONS")
$([ -n "$REACHABILITY" ] && printf '\n## Production Reachability (from reachability.md)\nUse to judge whether a finding is reachable in production. A critical/high finding must still independently prove a reachable path; this file is supporting context, not a severity override.\n\n%s\n' "$REACHABILITY")
THE DIFF IS PROVIDED VIA STDIN ABOVE. You are running inside the project repository — read related files as needed to understand context and verify cross-file effects, but report findings only against the changed lines." \
  --yolo \
  -o json \
  >"$TMPDIR/qwen-raw-output.json" 2>"$TMPDIR/qwen-stderr.txt"

QWEN_EXIT=$?
if [ $QWEN_EXIT -eq 0 ] && [ -f "$TMPDIR/qwen-raw-output.json" ]; then
  # qwen -o json emits an ARRAY of message objects (system / assistant / result). The final
  # answer is the `result` element's `.result`; fall back to concatenated assistant text
  # (`.message.content[].text`), then a Gemini-style {"response":...}, then the raw file.
  # (Confirmed against qwen-code 0.17.1 — the assistant `.content` field is null; text lives
  # in `.message.content` and the canonical final string in the `result` element.)
  ACTUAL_MODEL=$(jq -r '[ .[]? | (.model // .message.model // empty) ] | map(select(. != null)) | last // empty' "$TMPDIR/qwen-raw-output.json" 2>/dev/null)
  RESPONSE=$(jq -r '
    if type=="array" then
      ( ([ .[] | select(.type=="result") | .result // empty ] | last) as $r
        | if ($r != null and $r != "") then $r
          else ([ .[] | select(.type=="assistant") | (.message.content // [])[] | select(.type=="text") | .text ] | join("")) end )
    elif (type=="object" and has("response")) then .response
    else empty end
  ' "$TMPDIR/qwen-raw-output.json" 2>/dev/null)
  if [ -n "$RESPONSE" ]; then
    # Strip markdown fences; if the model wrapped the JSON in prose (thinking models sometimes
    # add a preamble despite the instruction), slice from the first { to the last }.
    CLEAN=$(printf '%s\n' "$RESPONSE" | sed 's/^```json//;s/^```//')
    if ! printf '%s' "$CLEAN" | jq -e . >/dev/null 2>&1; then
      CLEAN=$(printf '%s' "$CLEAN" | tr -d '\r' | sed -n 'H;${x;s/^[^{]*//;s/[^}]*$//;p;}')
    fi
    # Overwrite the placeholder "model" with the ACTUAL model the envelope reports — qwen-code
    # silently downgrades an unknown -m, so surface what really ran.
    if printf '%s' "$CLEAN" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$CLEAN" | jq --arg m "${ACTUAL_MODEL:-unknown}" '.model = $m'
    else
      SAFE_RAW=$(jq -Rs . < "$TMPDIR/qwen-raw-output.json" 2>/dev/null || echo '"capture failed"')
      printf '{"error": "Qwen produced unparseable output", "provider": "qwen", "raw": %s}\n' "$SAFE_RAW"
    fi
  else
    cat "$TMPDIR/qwen-raw-output.json"
  fi
else
  STDERR_CONTENT=$(cat "$TMPDIR/qwen-stderr.txt" 2>/dev/null)
  SAFE_STDERR=$(echo "$STDERR_CONTENT" | jq -Rs . 2>/dev/null || echo '"stderr encoding failed"')
  printf '{"error": "Qwen execution failed", "exit_code": %d, "stderr": %s}\n' "$QWEN_EXIT" "$SAFE_STDERR"
fi
# trap EXIT handles cleanup of $TMPDIR
```

### Bash call 5: Claude Code Review

Independent, **diff-only** leg on the **Claude Code CLI** (`claude -p`). It is the default
panel's one diff-only reviewer — the three other default legs (Codex, DeepSeek, Qwen) now all
walk the repo, so this leg deliberately restores the harness/context diversity a diff-only pass
provides: it reviews the unified diff in isolation, with no repository access. To guarantee that,
the leg runs from a scratch `$TMPDIR` (no repo to walk) **and** passes `--disallowedTools` for
every file/exec/web tool, so it cannot read beyond the diff even if asked. **On by default**
(mirrors Qwen/DeepSeek); `TRIBUNAL_CLAUDE=off` disables it; model via `TRIBUNAL_CLAUDE_MODEL`
(default `sonnet` — fast/cheap and decorrelated from the Opus arbiter). Runs as a fifth parallel
Bash call alongside Codex (1), Gemini (2), OpenCode (3), and Qwen (4).

> **Lineage note**: this leg shares model lineage with the Opus arbiter (both Claude). The default
> `sonnet` model keeps the reviewer decorrelated from the Opus arbiter on capability/version; if
> you set `TRIBUNAL_CLAUDE_MODEL=opus` the reviewer↔arbiter correlation is highest. The arbiter
> still treats it as one advisory peer among the panel.

```bash
# Claude Code leg is ON by default (mirrors Codex/DeepSeek). Only the literal "off" disables;
# anything else (or unset) runs. When off, emit the disabled marker so the arbiter accounts
# for claude as a (disabled) peer. TRIBUNAL_CLAUDE_MODEL overrides the model (default sonnet).
if [ "${TRIBUNAL_CLAUDE:-on}" = "off" ]; then
  printf '%s\n' '{"provider": "claude", "status": "disabled", "note": "Claude Code leg disabled via TRIBUNAL_CLAUDE=off"}'
  exit 0
fi
CLAUDE_MODEL="${TRIBUNAL_CLAUDE_MODEL:-sonnet}"

# Capture the diff and conventions from the repo BEFORE moving to the scratch dir.
REPO_ROOT="$(git rev-parse --show-toplevel)"
DIFF=$(git -C "$REPO_ROOT" diff origin/main...HEAD)
CONVENTIONS=""
[ -f "$REPO_ROOT/AGENTS.md" ] && CONVENTIONS=$(head -c 16384 "$REPO_ROOT/AGENTS.md")
# Deployment/reachability facts a diff cannot reveal (worker model, concurrency,
# single-user-per-session, money/data-loss paths). Capped; absent => no injection.
REACHABILITY=""
[ -f "$REPO_ROOT/reachability.md" ] && REACHABILITY=$(head -c 8192 "$REPO_ROOT/reachability.md")

# Parallel-safe scratch dir. Run `claude` from HERE (not the repo) so it has no project files
# to walk — the physical guarantee behind "diff-only", mirroring the GLM leg's scratch-dir trick.
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR" || { printf '%s\n' '{"error": "Claude leg: could not enter scratch dir", "provider": "claude"}'; exit 0; }

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider": "claude", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}'
  exit 0
fi

# Diff via STDIN (no argv length limit). --disallowedTools blocks every tool so the leg cannot
# read files / run commands / search the web — it is strictly a diff reviewer.
printf '%s\n' "$DIFF" | timeout -k 10 600 claude -p "You are a senior code reviewer performing a thorough, comprehensive review.

ANALYZE THIS DIFF FOR:
1. Logic errors - off-by-one, null deref, wrong comparisons, race conditions, division by zero
2. Security vulnerabilities - injection, XSS, CSRF, auth bypass, secrets exposure
3. Architecture - coupling, layering violations, anti-patterns
4. Performance - N+1 queries, memory leaks, blocking in async, unnecessary allocations
5. Edge cases - boundary conditions, empty inputs, integer overflow, unhandled error paths
6. Test coverage gaps - missing edge cases, untested paths
7. Silent failures & payment-path traps - when the diff touches error handling, async code, webhooks, or money handling: swallowed exceptions/broadened catch blocks, unawaited promises (a removed or missing await), webhook handlers that are non-idempotent or skip signature verification, money handled as float/decimal instead of integer cents. Do NOT invent payment concerns on diffs that have none.

RULES:
- ONLY report findings with confidence >= 0.7
- Use EXACT file paths from the diff headers (e.g., 'a/src/Foo.cs' -> 'src/Foo.cs')
- Use the line number from the diff where the issue occurs
- Each finding must have a concrete, actionable suggestion
- Do NOT use any tools. You have NO repository access — review ONLY the diff below. This is a deliberately diff-only lens; if a concern depends on context not present in the diff, lower your confidence or omit it rather than assuming.

VERDICT RULES:
- BLOCK: any critical-severity finding, OR 2+ high-severity findings
- NEEDS_WORK: any high-severity finding, OR 3+ medium-severity findings
- APPROVE: all other cases

RESPOND WITH ONLY THIS JSON (no markdown, no explanation):
{
  \"provider\": \"claude\",
  \"model\": \"default\",
  \"findings\": [
    {
      \"severity\": \"critical|high|medium|low\",
      \"category\": \"security|architecture|logic|performance|quality|edge-case|testing\",
      \"file\": \"path/to/file\",
      \"line\": 42,
      \"title\": \"Brief descriptive title\",
      \"description\": \"What is wrong and why it matters\",
      \"suggestion\": \"Concrete fix recommendation\",
      \"confidence\": 0.95
    }
  ],
  \"summary\": {
    \"total_findings\": 3,
    \"critical\": 0,
    \"high\": 1,
    \"medium\": 2,
    \"low\": 0,
    \"quality_score\": 7.5,
    \"verdict\": \"APPROVE|NEEDS_WORK|BLOCK\"
  }
}
$([ -n "$CONVENTIONS" ] && printf '\nPROJECT CONVENTIONS (from AGENTS.md) — use ONLY to judge whether the diff violates project standards; report findings only against the diff:\n%s\n' "$CONVENTIONS")
$([ -n "$REACHABILITY" ] && printf '\n## Production Reachability (from reachability.md)\nUse to judge whether a finding is reachable in production. A critical/high finding must still independently prove a reachable path; this file is supporting context, not a severity override.\n\n%s\n' "$REACHABILITY")
THE DIFF IS PROVIDED VIA STDIN ABOVE. Review ONLY the changed lines shown in the diff." \
  --model "$CLAUDE_MODEL" \
  --output-format json \
  --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Task" \
  >"$TMPDIR/claude-raw-output.json" 2>"$TMPDIR/claude-stderr.txt"

CLAUDE_EXIT=$?
if [ $CLAUDE_EXIT -eq 0 ] && [ -f "$TMPDIR/claude-raw-output.json" ]; then
  # claude -p --output-format json emits a SINGLE result object: the answer is in `.result`,
  # `.is_error` flags a model/transport error, and `.modelUsage` is keyed by the model that
  # actually ran (confirmed against this CLI). Unlike qwen-code, claude does NOT silently
  # downgrade an unknown -m, but we still surface the real model from the envelope.
  IS_ERR=$(jq -r '.is_error // false' "$TMPDIR/claude-raw-output.json" 2>/dev/null)
  ACTUAL_MODEL=$(jq -r '(.modelUsage // {} | keys | .[0]) // .model // empty' "$TMPDIR/claude-raw-output.json" 2>/dev/null)
  RESPONSE=$(jq -r '.result // empty' "$TMPDIR/claude-raw-output.json" 2>/dev/null)
  if [ "$IS_ERR" = "true" ] || [ -z "$RESPONSE" ]; then
    SAFE_RAW=$(jq -Rs . < "$TMPDIR/claude-raw-output.json" 2>/dev/null || echo '"capture failed"')
    printf '{"error": "Claude review returned an error or empty result", "provider": "claude", "raw": %s}\n' "$SAFE_RAW"
  else
    # Strip markdown fences; if the model wrapped JSON in prose, slice from first { to last }.
    CLEAN=$(printf '%s\n' "$RESPONSE" | sed 's/^```json//;s/^```//')
    if ! printf '%s' "$CLEAN" | jq -e . >/dev/null 2>&1; then
      CLEAN=$(printf '%s' "$CLEAN" | tr -d '\r' | sed -n 'H;${x;s/^[^{]*//;s/[^}]*$//;p;}')
    fi
    if printf '%s' "$CLEAN" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$CLEAN" | jq --arg m "${ACTUAL_MODEL:-$CLAUDE_MODEL}" '.model = $m'
    else
      SAFE_RAW=$(jq -Rs . < "$TMPDIR/claude-raw-output.json" 2>/dev/null || echo '"capture failed"')
      printf '{"error": "Claude produced unparseable output", "provider": "claude", "raw": %s}\n' "$SAFE_RAW"
    fi
  fi
else
  STDERR_CONTENT=$(cat "$TMPDIR/claude-stderr.txt" 2>/dev/null)
  SAFE_STDERR=$(echo "$STDERR_CONTENT" | jq -Rs . 2>/dev/null || echo '"stderr encoding failed"')
  printf '{"error": "Claude execution failed", "exit_code": %d, "stderr": %s}\n' "$CLAUDE_EXIT" "$SAFE_STDERR"
fi
# trap EXIT handles cleanup of $TMPDIR
```

## Error Handling
If `opencode` is not installed, the call emits one error object for GLM and one for DeepSeek
(or DeepSeek's `disabled` marker if `TRIBUNAL_DEEPSEEK=off`) and exits 0:
```json
{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "glm"}
{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "deepseek"}
```

If OpenCode is installed but a leg's model is missing from the (warmed) registry — a
cold/stale `~/.cache/opencode/models.json`, OR a missing credential for the leg's provider
(opencode-go or direct `deepseek/`), since models only list once authenticated — that leg is
skipped with a distinct error so the 4→3 degradation is explicit rather than disguised as a
credential failure (issue #32):
```json
{"error": "OpenCode model opencode-go/deepseek-v4-pro not in registry (cold/stale cache, or provider not authenticated) — run `opencode models` / `opencode auth login`; leg skipped to avoid silent downgrade to an unauthenticated fallback model", "provider": "deepseek"}
```

Collect all five JSON outputs — Codex, Gemini, and Qwen from their calls, GLM and DeepSeek from the single OpenCode call (which prints two JSON objects, GLM first). Parse them. If any returned an error JSON, note it for arbitration. A `{"status": "disabled"}` marker (Gemini and GLM emit one unless enabled — `TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on`, both off by default; Codex when `TRIBUNAL_CODEX=off`; DeepSeek when `TRIBUNAL_DEEPSEEK=off`; Qwen when `TRIBUNAL_QWEN=off`) is an INTENTIONAL skip, not a failure and not a finding source — it has no `findings` key; report that leg as `disabled` rather than a count, and hand it to Step 3 as a disabled provider.

Output: "[TRIBUNAL 2/3] Reviews complete - Codex: {C}, Gemini: {G or 'disabled'}, GLM: {L or 'disabled'}, DeepSeek: {D or 'disabled'}, Qwen: {Q or 'disabled'} findings"

---

## STEP 3: Inline Arbitration (Opus)

Do NOT spawn a Task agent. You are already Opus -- perform arbitration directly.

Read both JSON outputs from Step 2 and apply the following protocol:

Also read `reachability.md` from the repo root if present (capped at 8 KB):
it states deployment facts (worker/process model, whether the same
session/resource can be acted on concurrently, single-user assumptions,
money/data-loss paths) used when applying the **3b-0** standard. Treat it as
**rebuttable** — cross-check any claim a finding hinges on against the actual
code/config before relying on it, and lower your confidence in it when its
`last-verified:` marker is old relative to the area under review.

### 3a: Deduplicate Findings

Two findings are **duplicates** if they describe the same underlying issue in the same file, even if worded differently. For duplicates:
- Keep the finding with higher confidence
- Merge suggestions if both are valuable
- Mark as CONSENSUS when ≥2 providers report the same underlying issue; record all supporting providers in the `providers` array

**Same-class merge (every round):** Beyond exact duplicates, collapse
findings that are *variants of the same underlying concern* — e.g. several
different "ordering window" or "unawaited write" findings on the same
mechanism — into ONE finding for the round, keeping the strongest statement
and listing the rest under `arbiter_notes`. N rephrasings of one concern
count as one finding, so a reviewer cannot keep the loop open by restating.

### 3b-0: Blocking-finding standard (severity eligibility — apply FIRST)

Before resolving severities, gate each finding's *eligibility* to be rated
critical or high. A finding may be rated **critical or high only if it
demonstrates ALL THREE**:

1. **Production-reachable path** — a concrete actor + trigger + state
   transition. "An interleaving exists", "a malformed file could…", or a
   race that needs two concurrent operations on the same single-user
   resource is NOT sufficient unless the path shows how a real caller
   reaches that state.
2. **Material impact** — money, data-loss, legal/compliance, or
   user-visible correctness.
3. **Caused or exposed by THIS change** — a pre-existing, untouched code
   path that a repo-walking reviewer merely *found* is at most low/follow-up.

The **burden of proof is on the finding**. If any leg is absent or unproven,
cap the finding at **medium** (informational / triage). Use `reachability.md`
(if injected) as supporting context, but a missing/stale reachability.md does
NOT lower the bar — a blocking finding must independently prove reachability.

### 3b: Resolve Conflicts (N providers)

A finding may be reported by any subset of the five reviewers (codex, gemini, glm, deepseek, qwen) plus the diff-only claude leg. By default only codex, deepseek, and claude run — gemini, glm, and qwen are off by default, and any leg can be turned off — so treat disabled providers as absent, not as failures.

| Scenario | Action |
|----------|--------|
| Reported by ≥2 providers | Include, mark CONSENSUS, list supporting providers |
| Reported by exactly 1 provider | Include as SINGLE, evaluate validity |
| Providers contradict each other | Decide and document reasoning, mark ARBITRATED |
| Severities differ for the same finding | **Use the highest severity reported**, note disagreement in arbiter_notes |

**HARD RULE (severity)**: First apply **3b-0** to decide whether the finding is *eligible* for critical/high. THEN, among the eligible severities providers reported, use the highest. The highest-severity rule never overrides 3b-0: a finding that fails 3b-0 is medium even if a provider rated it critical.

All reviewers are **equal advisory peers** (up to five; by default codex + deepseek + qwen, with gemini and glm opt-in). Opus has final authority and may override any finding.

### 3c: Evaluate Each Finding

For each finding, assess:
- Is this a real issue or a false positive?
- Is the suggested fix correct and complete?
- Does your software engineering expertise suggest a different conclusion?

Override provider findings when they are clearly wrong. Add new findings if the providers missed something obvious.

### 3d: Confidence Ranges

| Finding type | Confidence range |
|-------------|-----------------|
| CONSENSUS (≥2 providers) | 0.85 - 0.99 |
| SINGLE (one provider) | 0.60 - 0.80 |
| ARBITRATED (conflict resolved) | 0.50 - 0.70 |
| Self-added (arbiter-originated) | 0.50 - 0.65 |

### 3e: Degraded Input

- If a subset of providers returned invalid JSON or failed: proceed with the remaining providers' findings. Note each failure in `provider_assessment`.
- If a provider returned `{"status": "disabled"}` (Gemini and GLM are off by default unless `TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on`; Codex is disabled by `TRIBUNAL_CODEX=off`; DeepSeek by `TRIBUNAL_DEEPSEEK=off`; Qwen by `TRIBUNAL_QWEN=off`): this is an INTENTIONAL skip, NOT a failure. Exclude that provider from quorum entirely, set its `provider_assessment.<provider>.status` to `"disabled"`, and do not count it toward the "all providers failed" branch — the verdict is computed from the remaining (non-disabled) providers.
- If **all non-disabled providers failed**: verdict = NEEDS_WORK, confidence = 0.0, rationale = "All review providers failed. Manual review required."
- If **all non-disabled providers returned zero findings**: verdict = APPROVE, confidence = 0.95.

### 3f: Issue Verdict

Assign finding IDs as T-001, T-002, etc., ordered by severity (critical first).

Output the tribunal verdict as JSON:

```json
{
  "tribunal_verdict": { "decision": "APPROVE|NEEDS_WORK|BLOCK", "confidence": 0.0, "rationale": "..." },
  "findings": [{
    "id": "T-001", "consensus": "CONSENSUS|SINGLE|ARBITRATED", "providers": ["codex", "glm"],
    "severity": "critical|high|medium|low", "category": "logic|security|performance|quality|architecture|edge-case|testing",
    "file": "path/to/file", "line": 0, "title": "...", "description": "...",
    "suggestion": "...", "confidence": 0.0, "arbiter_notes": "...",
    "blocking_proof": { "reachable_path": "actor+trigger+state transition, or null", "material_impact": "money|data-loss|legal|correctness, or null", "caused_by_change": true }
  }],
  "conflicts_resolved": [{
    "issue": "...", "positions": {"codex": "...", "gemini": "...", "glm": "...", "deepseek": "...", "qwen": "..."},
    "ruling": "...", "reasoning": "..."
  }],
  "provider_assessment": {
    "codex":    { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" },
    "gemini":   { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" },
    "glm":      { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" },
    "deepseek": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" },
    "qwen":     { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" }
  },
  "summary": "2-3 sentence executive summary of code quality and required actions"
}
```

**Required for critical/high:** every finding rated `critical` or `high` MUST
carry a `blocking_proof` whose three legs are all non-null/true (per 3b-0). If
you cannot fill all three, downgrade the finding to `medium` and set
`blocking_proof` legs to null where unproven. `medium`/`low` findings may omit
`blocking_proof`.

Output: "[TRIBUNAL 3/3] Verdict: {APPROVE|NEEDS_WORK|BLOCK} - {N} actionable findings"

---

## Trust Hierarchy

```
OPUS 4.5 (Final authority, runs inline)
    |
Codex · Gemini · GLM · DeepSeek · Qwen (equal advisory peers — verify findings)
```

The reviewers are equal peers (up to five; by default codex + deepseek + qwen, with gemini and glm opt-in); a finding flagged by ≥2 is CONSENSUS. Opus can override any reviewer finding.

---

## Quick Reference

| Mode | Steps | Tool Calls | Agent Spawns |
|------|-------|------------|-------------|
| Default (review) | 3 | 4 (parallel Bash: Codex, Gemini, OpenCode, Qwen; the OpenCode call runs GLM+DeepSeek sequentially. By default Gemini & GLM self-skip, so active reviewers = Codex + DeepSeek + Qwen) | 0 |
