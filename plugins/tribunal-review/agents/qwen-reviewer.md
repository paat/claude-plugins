---
name: qwen-reviewer
description: Invokes the Qwen Code CLI (Alibaba Qwen, direct transport) for independent, repo-walking (read-only) code review. Decorrelated from the OpenCode GLM/DeepSeek legs. Returns structured JSON findings. Use in tribunal multi-provider review workflow.
tools: Bash, Read
model: haiku
color: cyan
---

> **Note**: The `tribunal-loop` skill executes this script directly via Bash (no Task agent
> spawn) — it runs as the fourth parallel leg ("Bash call 4"). This file documents the
> standalone reviewer and is kept for testing.

You are a Qwen Code CLI wrapper. Your ONLY job is to run ONE bash command and return its stdout.

## Strict Rules

- Use exactly **1 Bash tool call** — the script below
- Do **NOT** run any other commands before or after
- Do **NOT** read any files
- Do **NOT** add commentary or analysis
- Return **ONLY** the stdout from the script

## Transport & Independence

Qwen is a **first-class, additive** reviewer with its OWN transport — the **Qwen Code CLI**
(`@qwen-code/qwen-code`), NOT the `opencode` backend the GLM/DeepSeek legs share:

- **Why a separate CLI**: the panel's value is decorrelated failure modes. GLM and DeepSeek
  share architectural lineage and the OpenCode backend; an `opencode-go` quota/429 or a
  shared-data-dir deadlock can degrade both at once. Qwen on its own CLI/transport cannot
  fail in lockstep with them, so `DeepSeek + Qwen` is the most decorrelated cheap pair.
- **Repo-walking (read-only)**: like the DeepSeek leg, Qwen `cd`s to the repo root and runs
  with `--yolo`, so its read-only tools (read/grep/glob/list) are available; the prompt permits
  opening related files to verify framework semantics, variable scope, and call sites, avoiding
  the context-gap false positives a diff-only pass produces (issue #44). Findings are still
  reported only against the changed lines. Transport diversity (separate Qwen Code CLI) is
  preserved even though the context scope now matches DeepSeek's.

## Switchability (mirrors the Gemini/DeepSeek pattern)

- **Off by default** (issue #46: ungrounded diff-text reasoning → repeated false positives;
  disabled pending the mandatory-verification fix). `TRIBUNAL_QWEN=on` enables it; otherwise the
  leg emits `{"provider":"qwen","status":"disabled","note":"..."}` and the arbiter excludes it
  from quorum (`provider_assessment.qwen.status="disabled"`). Only the literal `on` enables;
  anything else (or unset) skips.
- `TRIBUNAL_QWEN_MODEL` (default `qwen3.7-plus` — newest Plus model, validated on DashScope Intl).
  Qwen model ids change often through 2026 AND vary by account/region — **override as needed**
  (e.g. `qwen3.6-plus` for a 1M-context window, or a coder slot like `qwen3-coder-plus` if your
  account enables it).
  ⚠️ qwen-code **silently downgrades an unknown `-m` to its default model** (no error), so the
  leg rewrites the output's `model` field to the model that actually ran — check it if unsure.

## Authentication / transport

Auth is handled by the Qwen Code CLI's own env, so the leg stays transport-agnostic:

- **DashScope (default)**: `DASHSCOPE_API_KEY`. Free 1M+1M tokens for new accounts — enough
  to validate the leg before any spend.
- **OpenAI-compatible**: `OPENAI_API_KEY` + `OPENAI_BASE_URL=https://dashscope-intl.aliyuncs.com/compatible-mode/v1`
  and `OPENAI_MODEL=<id>`.
- **OpenRouter**: `OPENROUTER_API_KEY` with a `qwen/...` model id.

## Execute This Script

```bash
cd "$(git rev-parse --show-toplevel)"

# Qwen leg is OFF by default (issue #46: ungrounded diff-text reasoning → repeated false
# positives). Only the literal "on" enables; anything else (or unset) skips. Note: this
# standalone path's switch matches tribunal-loop's, so the agent behaves identically whether
# invoked directly or by the skill.
if [ "${TRIBUNAL_QWEN:-off}" != "on" ]; then
  printf '%s\n' '{"provider": "qwen", "status": "disabled", "note": "Qwen leg disabled (default off, issue #46); set TRIBUNAL_QWEN=on to enable"}'
  exit 0
fi
QWEN_MODEL="${TRIBUNAL_QWEN_MODEL:-qwen3.7-plus}"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

resolve_base_ref() {
  local branch
  branch="${TRIBUNAL_BASE_BRANCH:-}"
  [ -n "$branch" ] || branch="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
  [ -n "$branch" ] || branch="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)"
  [ -n "$branch" ] || branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  printf '%s\n' "${TRIBUNAL_BASE_REF:-origin/${branch:-main}}"
}
BASE_REF="$(resolve_base_ref)"
if ! DIFF=$(git diff "$BASE_REF"...HEAD 2>/dev/null); then
  printf '{"error": "Qwen leg: cannot diff against %s", "provider": "qwen"}\n' "$BASE_REF"
  exit 0
fi

if [ -z "$DIFF" ]; then
  printf '{"provider": "qwen", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs %s"}}\n' "$BASE_REF"
  exit 0
fi

# Optional: inject the repo's AGENTS.md so every reviewer judges the diff against
# the same project conventions (capped; absent file => no injection).
CONVENTIONS=""
[ -f AGENTS.md ] && CONVENTIONS=$(head -c 16384 AGENTS.md)

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

## Error Handling
If the script fails because Qwen Code is not installed, return:
```json
{"error": "Qwen Code CLI not found. Install with: npm install -g @qwen-code/qwen-code", "provider": "qwen"}
```
