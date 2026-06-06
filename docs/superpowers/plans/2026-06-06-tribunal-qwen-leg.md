# Tribunal Qwen Reviewer Leg — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a switchable, independent **Qwen** reviewer leg to the tribunal panel so the cheap-reviewer pair becomes decorrelated (`DeepSeek + Qwen`) instead of two lineage-related OpenCode MoEs (GLM + DeepSeek).

**Architecture:** The Qwen leg mirrors the **Gemini** leg, not the DeepSeek/OpenCode leg — it calls the **Qwen Code CLI** (`@qwen-code/qwen-code`, a Gemini-CLI fork with the same `-p` / `-o json` / `--yolo` / `--model` surface) directly over its own transport (DashScope, OpenAI-compatible, or OpenRouter). Running it off the OpenCode backend is the whole point: an `opencode-go` quota/deadlock can't take it down with GLM/DeepSeek. It reviews the **diff only** (DeepSeek already owns the repo-walking lane). It is **off by default** (additive, needs a new key) and flips on with `TRIBUNAL_QWEN=on`, exactly switchable like Gemini/DeepSeek. The arbiter learns `qwen` as a fifth advisory peer.

**Tech Stack:** Bash 4+, `jq`, `curl`, GNU `timeout`, Qwen Code CLI. Markdown skill/agent/README files plus two JSON manifests.

> **⚠️ Live-validation addendum (2026-06-06).** After Tasks 1–2 were committed, the Qwen
> CLI (`@qwen-code/qwen-code` 0.17.1) became available and was tested live on DashScope Intl,
> overriding several plan assumptions. These corrections are authoritative; where this
> addendum conflicts with the task bodies below, follow the addendum:
> - **`-o json` envelope** is a JSON **array** of `{type: system|assistant|result}` objects.
>   The assistant element's `.content` is **null**; the final text is the `result` element's
>   `.result` (fallback: assistant `.message.content[] | select(.type=="text") | .text`). The
>   plan's original `.content`-based extractor returns nothing — **fixed in commit 2e4b1ec**.
> - **Default model** changed `qwen3-coder-plus` → **`qwen3.7-plus`** (newest Plus model, valid
>   and honored on this account; user-selected). `qwen3.6-plus` (1M ctx) is the documented
>   override. qwen-code **silently downgrades an unknown `-m`** to its default with no error,
>   so the leg now rewrites the output `.model` to the model the envelope reports.
> - **Prose-wrapped JSON**: thinking models prepend a preamble; the leg now slices first-`{`
>   .. last-`}` and emits a structured `{"error":...,"raw":...}` if still unparseable.
> - **Task 3 preflight probe**: the planned **curl** probe is WRONG — auth lives in
>   `~/.qwen/settings.json`, not an env var, so a curl-with-env-key probe false-warns. Use a
>   **CLI-based 1-token probe** (`qwen --model … -p … -o json`) that reuses the CLI's own auth
>   and also detects the silent model fallback. **Drop `TRIBUNAL_QWEN_BASE_URL`** (it only
>   existed for the curl probe) from Task 3 and Task 6.
>
> **Why these defaults (from research):**
- **CLI:** Qwen Code CLI — Gemini-CLI fork ⇒ the leg is a near-copy of `gemini-reviewer`'s script (lowest implementation cost, maximal failure-mode decorrelation from the OpenCode legs). OpenCode-transport was rejected: it re-correlates failures with GLM/DeepSeek and re-inherits the documented OpenCode hangs/deadlocks.
- **Billing:** pay-as-you-go DashScope (intl endpoint); the free 1M+1M new-account tier covers the "validate while off" period the issue asks for. Coding Plan Pro ($50/mo) is only worth it at constant high volume.
- **Default model:** `qwen3-coder-plus` (the id the Qwen Code docs use), overridable via `TRIBUNAL_QWEN_MODEL` because Qwen ids churn through 2026.
- **Default state:** **off** (opt-in), per the issue's open question.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `plugins/tribunal-review/agents/qwen-reviewer.md` | **Create** | Standalone Qwen-leg doc + the exact leg script (mirrors `gemini-reviewer.md`). |
| `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` | **Modify** | Add "Bash call 4: Qwen Review"; Step-1 preflight switch + liveness probe + TOTAL accounting; Step-2 collect line; Step-3 arbitration (peer count, disabled handling, `provider_assessment`, `positions`); headers/providers/trust/quick-ref. |
| `plugins/tribunal-review/agents/opus-arbiter.md` | **Modify** | Add `qwen` as a fifth peer: input format, degraded-input, `positions`, `provider_assessment`. |
| `plugins/tribunal-review/README.md` | **Modify** | Prerequisites, config table (`TRIBUNAL_QWEN`, `TRIBUNAL_QWEN_MODEL`, `TRIBUNAL_QWEN_BASE_URL`, `DASHSCOPE_API_KEY`), how-it-works, output/trust. |
| `plugins/tribunal-review/.claude-plugin/plugin.json` | **Modify** | Version `0.7.1 → 0.8.0`, description, keywords. |
| `.claude-plugin/marketplace.json` | **Modify** | Version `0.7.1 → 0.8.0`, description (must match plugin.json). |

**Note on testing:** these are markdown + embedded bash; there is no unit-test harness. "Verification" = `bash -n` (syntax), `jq -e` (every JSON literal parses), `shellcheck` when available, and an end-to-end smoke run of the leg script. Treat each verification step as mandatory before its commit.

---

## Task 0: Confirm the Qwen Code CLI `-o json` envelope (discovery)

The leg must extract the assistant's text from `qwen -o json`. Research left this **ambiguous**: Gemini's `-o json` returns `{ "response": "..." }`, but the Qwen headless docs describe `--output-format json` as an **array of message objects** (`{type, content, ...}`). The leg script (Task 2) ships a tolerant extractor that handles both shapes — but confirm the real shape first so the extractor's primary branch is correct and the smoke test in later tasks is trustworthy.

**Files:** none (investigation only).

- [ ] **Step 1: Verify the CLI is installed and runnable**

Run:
```bash
command -v qwen && qwen --version
```
Expected: a path and a version. If absent: `npm install -g @qwen-code/qwen-code` (Node 20+), then re-run. Record the version in your task notes.

- [ ] **Step 2: Capture the JSON envelope on a trivial prompt**

Run (requires `DASHSCOPE_API_KEY` exported; uses the documented default model):
```bash
printf 'say the single word ok' | timeout -k 5 60 qwen --model qwen3-coder-plus -p "Reply with only the JSON {\"ok\":true} and nothing else." --yolo -o json | tee /tmp/qwen-envelope.json | jq 'type'
```
Expected: prints `"array"` or `"object"`.

- [ ] **Step 3: Identify the assistant-text path**

Run:
```bash
jq 'if type=="array" then [.[].type] else keys end' /tmp/qwen-envelope.json
```
Record which branch applies:
- **Array of messages** → assistant text is `[.[] | select(.type=="assistant") | .content | ...]`.
- **Object with `response`** → assistant text is `.response`.

The Task 2 extractor already covers both; this step only confirms which branch is primary so you can trust the Task 2 smoke test. **No commit** (no files changed).

---

## Task 1: Create `agents/qwen-reviewer.md`

Standalone documentation + the exact leg script, structured like `gemini-reviewer.md`. The `tribunal-loop` skill runs the script directly (no Task spawn); this file is the standalone/testable copy.

**Files:**
- Create: `plugins/tribunal-review/agents/qwen-reviewer.md`

- [ ] **Step 1: Write the file**

Create `plugins/tribunal-review/agents/qwen-reviewer.md` with EXACTLY this content:

````markdown
---
name: qwen-reviewer
description: Invokes the Qwen Code CLI (Alibaba Qwen, direct transport) for independent, diff-only code review. Decorrelated from the OpenCode GLM/DeepSeek legs. Returns structured JSON findings. Use in tribunal multi-provider review workflow.
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
- **Diff-only**: unlike the DeepSeek leg (which walks the repo), Qwen reviews the diff in
  isolation — the same harness shape as the Gemini leg. DeepSeek already owns the
  repo-walking lane; keeping Qwen diff-only preserves leg diversity.

## Switchability (mirrors the Gemini/DeepSeek pattern, inverted default)

- **Off by default** (additive, needs a new key). `TRIBUNAL_QWEN=on` enables it; the leg emits
  `{"provider":"qwen","status":"disabled","note":"..."}` whenever it is not enabled, and the
  arbiter excludes it from quorum (`provider_assessment.qwen.status="disabled"`). Only the
  literal `on` enables; anything else (or unset) keeps it off.
- `TRIBUNAL_QWEN_MODEL` (default `qwen3-coder-plus`). Qwen model ids change often through 2026
  — override as needed (e.g. `qwen3-coder-next` for a cheaper slot, or a `qwen3.x-plus` id).

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

# Qwen leg is ADDITIVE and OFF by default (opt-in until validated — issue #41).
# Only the literal "on" enables; anything else (or unset) = off → emit disabled marker.
# Note: this standalone path's switch matches tribunal-loop's, so the agent behaves
# identically whether invoked directly or by the skill.
if [ "${TRIBUNAL_QWEN:-off}" != "on" ]; then
  printf '%s\n' '{"provider": "qwen", "status": "disabled", "note": "Qwen leg disabled (default off); set TRIBUNAL_QWEN=on to enable"}'
  exit 0
fi
QWEN_MODEL="${TRIBUNAL_QWEN_MODEL:-qwen3-coder-plus}"

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

printf '%s\n' "$DIFF" | timeout -k 10 600 qwen --model "$QWEN_MODEL" -p "You are a senior code reviewer performing a thorough, comprehensive review.

ANALYZE THIS DIFF FOR:
1. Logic errors - off-by-one, null deref, wrong comparisons, race conditions, division by zero
2. Security vulnerabilities - injection, XSS, CSRF, auth bypass, secrets exposure
3. Architecture - coupling, layering violations, anti-patterns
4. Performance - N+1 queries, memory leaks, blocking in async, unnecessary allocations
5. Edge cases - boundary conditions, empty inputs, integer overflow, unhandled error paths
6. Test coverage gaps - missing edge cases, untested paths

RULES:
- ONLY report findings with confidence >= 0.7
- Use EXACT file paths from the diff headers (e.g., 'a/src/Foo.cs' -> 'src/Foo.cs')
- Use the line number from the diff where the issue occurs
- Each finding must have a concrete, actionable suggestion

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
THE DIFF IS PROVIDED VIA STDIN ABOVE." \
  --yolo \
  -o json \
  >"$TMPDIR/qwen-raw-output.json" 2>"$TMPDIR/qwen-stderr.txt"

QWEN_EXIT=$?
if [ $QWEN_EXIT -eq 0 ] && [ -f "$TMPDIR/qwen-raw-output.json" ]; then
  # qwen -o json envelope varies by version. Extract the assistant text robustly:
  #   (a) array of message objects [{type:"assistant",content:[{text}]|"..."},...]
  #   (b) Gemini-style {"response":"..."}
  #   (c) fall back to the raw file.
  RESPONSE=$(jq -r '
    if type=="array" then
      ([ .[] | select(.type=="assistant") | .content |
         (if type=="array" then (map(.text? // empty) | join("")) else (. // "") end) ] | join(""))
    elif (type=="object" and has("response")) then .response
    else empty end
  ' "$TMPDIR/qwen-raw-output.json" 2>/dev/null)
  if [ -n "$RESPONSE" ]; then
    echo "$RESPONSE" | sed 's/^```json//;s/^```//;/^$/d' | jq . 2>/dev/null || echo "$RESPONSE"
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
````

- [ ] **Step 2: Verify the embedded script is syntactically valid**

Extract the script body and syntax-check it. Run:
```bash
awk '/^```bash$/{f=1;next} /^```$/{f=0} f' plugins/tribunal-review/agents/qwen-reviewer.md > /tmp/qwen-leg.sh && bash -n /tmp/qwen-leg.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK` (no output from `bash -n`).

- [ ] **Step 3: Verify both JSON literals in the script parse**

Run:
```bash
printf '%s\n' '{"provider": "qwen", "status": "disabled", "note": "Qwen leg disabled (default off); set TRIBUNAL_QWEN=on to enable"}' | jq -e . >/dev/null && \
printf '%s\n' '{"provider": "qwen", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}' | jq -e . >/dev/null && echo "JSON OK"
```
Expected: `JSON OK`.

- [ ] **Step 4: Smoke-test the disabled path (no key/CLI needed)**

Run from any feature branch with a diff vs `origin/main`:
```bash
( unset TRIBUNAL_QWEN; bash /tmp/qwen-leg.sh ) | jq -e 'select(.provider=="qwen" and .status=="disabled")' && echo "DISABLED-PATH OK"
```
Expected: the disabled JSON echoes back and prints `DISABLED-PATH OK`.

- [ ] **Step 5: Commit**

```bash
git add plugins/tribunal-review/agents/qwen-reviewer.md
git commit -m "feat(tribunal): add standalone qwen-reviewer leg (Qwen Code CLI, diff-only, off by default) (#41)"
```

---

## Task 2: Add "Bash call 4: Qwen Review" to SKILL.md Step 2

Insert the Qwen leg as the fourth parallel Bash call, after "Bash call 3: OpenCode Review", and before the "## Error Handling" heading that currently follows it (the OpenCode error-handling block at SKILL.md line ~583).

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (insert after the Bash-call-3 fenced block, before `## Error Handling`)

- [ ] **Step 1: Insert the new section**

Find this exact line (the closing of Bash call 3 and start of error handling):
```markdown
# trap EXIT handles cleanup of $TMPDIR
```
````
````
(the final `# trap EXIT handles cleanup of $TMPDIR` inside Bash call 3, immediately followed by the ```` ``` ```` fence and then `## Error Handling`).

Immediately **after** that Bash-call-3 closing fence and **before** `## Error Handling`, insert:

````markdown
### Bash call 4: Qwen Review

Independent, **diff-only** leg on its OWN CLI (Qwen Code, `@qwen-code/qwen-code`) — NOT the
`opencode` backend GLM/DeepSeek share, so it cannot fail in lockstep with them (issue #41).
**Off by default** (additive, needs a new key); `TRIBUNAL_QWEN=on` enables it. Runs as a
fourth parallel Bash call alongside Codex (call 1), Gemini (call 2), and OpenCode (call 3).

```bash
cd "$(git rev-parse --show-toplevel)"

# Qwen leg is ADDITIVE and OFF by default (opt-in — issue #41). Only the literal "on"
# enables; anything else (or unset) = off → emit the disabled marker so the arbiter
# accounts for qwen as a (disabled) fifth peer. TRIBUNAL_QWEN_MODEL overrides the model.
if [ "${TRIBUNAL_QWEN:-off}" != "on" ]; then
  printf '%s\n' '{"provider": "qwen", "status": "disabled", "note": "Qwen leg disabled (default off); set TRIBUNAL_QWEN=on to enable"}'
  exit 0
fi
QWEN_MODEL="${TRIBUNAL_QWEN_MODEL:-qwen3-coder-plus}"

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

printf '%s\n' "$DIFF" | timeout -k 10 600 qwen --model "$QWEN_MODEL" -p "You are a senior code reviewer performing a thorough, comprehensive review.

ANALYZE THIS DIFF FOR:
1. Logic errors - off-by-one, null deref, wrong comparisons, race conditions, division by zero
2. Security vulnerabilities - injection, XSS, CSRF, auth bypass, secrets exposure
3. Architecture - coupling, layering violations, anti-patterns
4. Performance - N+1 queries, memory leaks, blocking in async, unnecessary allocations
5. Edge cases - boundary conditions, empty inputs, integer overflow, unhandled error paths
6. Test coverage gaps - missing edge cases, untested paths

RULES:
- ONLY report findings with confidence >= 0.7
- Use EXACT file paths from the diff headers (e.g., 'a/src/Foo.cs' -> 'src/Foo.cs')
- Use the line number from the diff where the issue occurs
- Each finding must have a concrete, actionable suggestion

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
THE DIFF IS PROVIDED VIA STDIN ABOVE." \
  --yolo \
  -o json \
  >"$TMPDIR/qwen-raw-output.json" 2>"$TMPDIR/qwen-stderr.txt"

QWEN_EXIT=$?
if [ $QWEN_EXIT -eq 0 ] && [ -f "$TMPDIR/qwen-raw-output.json" ]; then
  # qwen -o json envelope varies by version. Extract the assistant text robustly:
  #   (a) array of message objects [{type:"assistant",content:[{text}]|"..."},...]
  #   (b) Gemini-style {"response":"..."}
  #   (c) fall back to the raw file.
  RESPONSE=$(jq -r '
    if type=="array" then
      ([ .[] | select(.type=="assistant") | .content |
         (if type=="array" then (map(.text? // empty) | join("")) else (. // "") end) ] | join(""))
    elif (type=="object" and has("response")) then .response
    else empty end
  ' "$TMPDIR/qwen-raw-output.json" 2>/dev/null)
  if [ -n "$RESPONSE" ]; then
    echo "$RESPONSE" | sed 's/^```json//;s/^```//;/^$/d' | jq . 2>/dev/null || echo "$RESPONSE"
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
````

- [ ] **Step 2: Verify the inserted script is valid bash**

Run (extracts the Bash-call-4 block by its provider marker and syntax-checks it):
```bash
awk '/### Bash call 4: Qwen Review/{s=1} s&&/^```bash$/{f=1;next} s&&/^```$/{exit} f' plugins/tribunal-review/skills/tribunal-loop/SKILL.md > /tmp/qwen-call4.sh && bash -n /tmp/qwen-call4.sh && echo "CALL4 SYNTAX OK"
```
Expected: `CALL4 SYNTAX OK`.

- [ ] **Step 3: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal): add Bash call 4 (Qwen diff-only leg) to tribunal-loop Step 2 (#41)"
```

---

## Task 3: Add the Qwen switch + liveness probe to SKILL.md Step 1 preflight

The preflight must (a) add `qwen` to the CLI list and TOTAL **only when enabled**, and (b) when enabled, confirm an auth key is present and do a fast 1-token liveness probe so a missing/expired key fails here, not mid-review (issue #41, mirroring #38).

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (Step 1 preflight block, lines ~46–116)

- [ ] **Step 1: Add the Qwen switch before TOTAL is computed**

Find this exact block (SKILL.md ~lines 46–50):
```bash
if [ "${TRIBUNAL_GEMINI:-on}" = "off" ]; then
  CLIS="codex opencode"
  WARN="${WARN}\n  - gemini: disabled via TRIBUNAL_GEMINI=off — leg will be skipped"
fi
TOTAL=$(set -- $CLIS; echo $#)
```
Replace it with:
```bash
if [ "${TRIBUNAL_GEMINI:-on}" = "off" ]; then
  CLIS="codex opencode"
  WARN="${WARN}\n  - gemini: disabled via TRIBUNAL_GEMINI=off — leg will be skipped"
fi

# Qwen leg switch (issue #41). ADDITIVE leg on its OWN CLI/transport (Qwen Code CLI),
# decorrelated from the OpenCode legs. OFF by default (opt-in). Only the literal "on"
# enables. When on, `qwen` joins the CLI list (and TOTAL) so the generic PATH loop counts
# it and the "N/TOTAL providers" accounting stays correct; when off it is an INTENTIONAL
# skip — not probed, not counted.
QWEN_MODEL="${TRIBUNAL_QWEN_MODEL:-qwen3-coder-plus}"
QWEN_ON=off
if [ "${TRIBUNAL_QWEN:-off}" = "on" ]; then
  QWEN_ON=on
  CLIS="$CLIS qwen"
else
  WARN="${WARN}\n  - qwen: disabled (default off) — set TRIBUNAL_QWEN=on to enable"
fi
TOTAL=$(set -- $CLIS; echo $#)
```

- [ ] **Step 2: Add the auth + liveness probe**

Find this exact block (SKILL.md ~lines 107–108, the Gemini auth note that closes the checks):
```bash
# Gemini auth note: a stale key surfaces only mid-review. We cannot cheaply verify it
# here without a billable call, so just remind to rotate if Gemini fails in Step 2.
```
Insert this **immediately before** it:
```bash
# Qwen leg preflight (issue #41): only when enabled. The generic PATH loop above already
# counted `qwen` and warned if it is missing, so here we only verify auth + liveness.
if [ "$QWEN_ON" = on ] && command -v qwen >/dev/null 2>&1; then
  if [ -z "${DASHSCOPE_API_KEY:-}${OPENAI_API_KEY:-}${OPENROUTER_API_KEY:-}" ]; then
    WARN="${WARN}\n  - qwen: enabled (TRIBUNAL_QWEN=on) but no DASHSCOPE_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY set — leg will likely fail; export a key or run \`qwen\` auth"
  elif [ -n "${DASHSCOPE_API_KEY:-}" ]; then
    # Best-effort 1-token liveness probe to the DashScope OpenAI-compatible endpoint.
    # Non-fatal: a probe failure only WARNS — the leg still attempts in Step 2 (the user
    # may be on a different transport). A 4xx is the fast, useful signal (bad key/model).
    QWEN_BASE="${TRIBUNAL_QWEN_BASE_URL:-https://dashscope-intl.aliyuncs.com/compatible-mode/v1}"
    QWEN_PROBE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "Authorization: Bearer ${DASHSCOPE_API_KEY}" -H 'Content-Type: application/json' \
      -d "{\"model\":\"${QWEN_MODEL}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}" \
      "${QWEN_BASE}/chat/completions" 2>/dev/null)
    case "$QWEN_PROBE" in
      2*) : ;;  # alive
      4*) WARN="${WARN}\n  - qwen: liveness probe returned HTTP ${QWEN_PROBE} (auth/model rejected) — check DASHSCOPE_API_KEY and TRIBUNAL_QWEN_MODEL=${QWEN_MODEL}; leg will likely fail in Step 2" ;;
      *)  WARN="${WARN}\n  - qwen: liveness probe inconclusive (HTTP '${QWEN_PROBE}') — continuing; leg will attempt in Step 2" ;;
    esac
  fi
fi

```

- [ ] **Step 3: Update the Step-1 output accounting note**

Find (SKILL.md ~line 123):
```markdown
Output: "[TRIBUNAL 1/3] On branch: {branch_name}, {N} files changed — {USABLE}/{TOTAL} providers ready{, warnings if any}" (TOTAL is 2 when Gemini is disabled via TRIBUNAL_GEMINI=off, else 3)
```
Replace with:
```markdown
Output: "[TRIBUNAL 1/3] On branch: {branch_name}, {N} files changed — {USABLE}/{TOTAL} providers ready{, warnings if any}" (TOTAL counts reviewer CLIs on PATH: base is 3 — codex, gemini, opencode; subtract 1 if Gemini is disabled via TRIBUNAL_GEMINI=off; add 1 if Qwen is enabled via TRIBUNAL_QWEN=on. The opencode CLI covers both the GLM and DeepSeek legs, so disabling DeepSeek does not change TOTAL.)
```

- [ ] **Step 4: Verify the whole preflight block is valid bash**

Run (extracts the first bash block in Step 1 — the preflight — and syntax-checks it):
```bash
awk '/## STEP 1: Pre-flight/{s=1} s&&/^```bash$/{f=1;next} s&&f&&/^```$/{exit} f' plugins/tribunal-review/skills/tribunal-loop/SKILL.md > /tmp/preflight.sh && bash -n /tmp/preflight.sh && echo "PREFLIGHT SYNTAX OK"
```
Expected: `PREFLIGHT SYNTAX OK`.

- [ ] **Step 5: Verify TOTAL accounting by executing the switch logic in isolation**

Run (simulates the CLIS/TOTAL math for the three cases):
```bash
for cfg in "off:-" "on:codex gemini opencode" ; do :; done
# default off → 3 ; qwen on → 4 ; gemini off + qwen on → 3
chk(){ CLIS="codex gemini opencode"; [ "$1" = off2 ] && CLIS="codex opencode"; [ "$2" = on ] && CLIS="$CLIS qwen"; set -- $CLIS; echo "$#"; }
test "$(chk geminiOn off)"  = 3 && test "$(chk geminiOn on)" = 4 && test "$(chk off2 on)" = 3 && echo "TOTAL MATH OK"
```
Expected: `TOTAL MATH OK`.

- [ ] **Step 6: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal): preflight qwen switch, liveness probe, and TOTAL accounting (#41)"
```

---

## Task 4: Update SKILL.md headers, provider list, collect line, and arbitration

Teach the rest of the skill that there is a fifth (default-disabled) peer.

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (front-matter description; intro; Providers; Step-2 intro + collect/output lines; Step-3 3b/3e/3f; Trust Hierarchy; Quick Reference)

- [ ] **Step 1: Front-matter description (line 3)**

Find:
```markdown
description: Multi-provider code review workflow with Codex, Gemini, OpenCode (GLM + DeepSeek), and Opus arbitration
```
Replace with:
```markdown
description: Multi-provider code review workflow with Codex, Gemini, OpenCode (GLM + DeepSeek), optional Qwen, and Opus arbitration
```

- [ ] **Step 2: Providers list (after line 16, the DeepSeek bullet)**

Find:
```markdown
- **DeepSeek** (deepseek/deepseek-v4-pro) - comprehensive review on the **direct DeepSeek API**, **repo-walking** read-only; independently switchable via `TRIBUNAL_DEEPSEEK` / `TRIBUNAL_DEEPSEEK_MODEL`
- **Opus** (4.5) - final arbiter (runs inline, no agent spawn)
```
Replace with:
```markdown
- **DeepSeek** (deepseek/deepseek-v4-pro) - comprehensive review on the **direct DeepSeek API**, **repo-walking** read-only; independently switchable via `TRIBUNAL_DEEPSEEK` / `TRIBUNAL_DEEPSEEK_MODEL`
- **Qwen** (qwen3-coder-plus) - comprehensive review via the **Qwen Code CLI** (own transport, decorrelated from the OpenCode legs), **diff-only**; **off by default**, enable with `TRIBUNAL_QWEN=on`, model via `TRIBUNAL_QWEN_MODEL`
- **Opus** (4.5) - final arbiter (runs inline, no agent spawn)
```

- [ ] **Step 3: Step-2 intro (line 127)**

Find:
```markdown
Run the three scripts below as **three parallel Bash tool calls**. No Task agents -- execute directly.
```
Replace with:
```markdown
Run the scripts below as **parallel Bash tool calls** — three by default (Codex, Gemini, OpenCode), plus a fourth (Qwen) when `TRIBUNAL_QWEN=on`. No Task agents -- execute directly. The Qwen call self-emits a `disabled` marker when not enabled, so it is safe to always dispatch it as a fourth parallel call.
```

- [ ] **Step 4: Step-2 collect line (line 600)**

Find:
```markdown
Collect all four JSON outputs — Codex and Gemini from their calls, GLM and DeepSeek from the single OpenCode call (which prints two JSON objects, GLM first). Parse them. If any returned an error JSON, note it for arbitration. A `{"status": "disabled"}` marker (Gemini emits one when `TRIBUNAL_GEMINI=off`; DeepSeek when `TRIBUNAL_DEEPSEEK=off`) is an INTENTIONAL skip, not a failure and not a finding source — it has no `findings` key; report that leg as `disabled` rather than a count, and hand it to Step 3 as a disabled provider.
```
Replace with:
```markdown
Collect all five JSON outputs — Codex, Gemini, and Qwen from their calls, GLM and DeepSeek from the single OpenCode call (which prints two JSON objects, GLM first). Parse them. If any returned an error JSON, note it for arbitration. A `{"status": "disabled"}` marker (Gemini emits one when `TRIBUNAL_GEMINI=off`; DeepSeek when `TRIBUNAL_DEEPSEEK=off`; Qwen whenever `TRIBUNAL_QWEN` is not `on`, i.e. by default) is an INTENTIONAL skip, not a failure and not a finding source — it has no `findings` key; report that leg as `disabled` rather than a count, and hand it to Step 3 as a disabled provider.
```

- [ ] **Step 5: Step-2 output line (line 602)**

Find:
```markdown
Output: "[TRIBUNAL 2/3] Reviews complete - Codex: {C}, Gemini: {G or 'disabled'}, GLM: {L}, DeepSeek: {D or 'disabled'} findings"
```
Replace with:
```markdown
Output: "[TRIBUNAL 2/3] Reviews complete - Codex: {C}, Gemini: {G or 'disabled'}, GLM: {L}, DeepSeek: {D or 'disabled'}, Qwen: {Q or 'disabled'} findings"
```

- [ ] **Step 6: Step-3b conflict scope (line 621)**

Find:
```markdown
A finding may be reported by any subset of the four reviewers (codex, gemini, glm, deepseek).
```
Replace with:
```markdown
A finding may be reported by any subset of the five reviewers (codex, gemini, glm, deepseek, qwen). Some are commonly disabled (Qwen is off by default; Gemini/DeepSeek may be off) — treat disabled providers as absent, not as failures.
```

- [ ] **Step 7: Step-3e disabled handling (line 655)**

Find:
```markdown
- If a provider returned `{"status": "disabled"}` (operator set `TRIBUNAL_GEMINI=off` for Gemini, or `TRIBUNAL_DEEPSEEK=off` for DeepSeek): this is an INTENTIONAL skip, NOT a failure. Exclude that provider from quorum entirely, set its `provider_assessment.<provider>.status` to `"disabled"`, and do not count it toward the "all providers failed" branch — the verdict is computed from the remaining (non-disabled) providers.
```
Replace with:
```markdown
- If a provider returned `{"status": "disabled"}` (operator set `TRIBUNAL_GEMINI=off` for Gemini, `TRIBUNAL_DEEPSEEK=off` for DeepSeek, or left Qwen off — `TRIBUNAL_QWEN` not `on`, the default): this is an INTENTIONAL skip, NOT a failure. Exclude that provider from quorum entirely, set its `provider_assessment.<provider>.status` to `"disabled"`, and do not count it toward the "all providers failed" branch — the verdict is computed from the remaining (non-disabled) providers.
```

- [ ] **Step 8: Step-3f `positions` and `provider_assessment` (lines 675 and 682)**

Find:
```markdown
    "issue": "...", "positions": {"codex": "...", "gemini": "...", "glm": "...", "deepseek": "..."},
```
Replace with:
```markdown
    "issue": "...", "positions": {"codex": "...", "gemini": "...", "glm": "...", "deepseek": "...", "qwen": "..."},
```

Then find:
```markdown
    "deepseek": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" }
  },
  "summary": "2-3 sentence executive summary of code quality and required actions"
```
Replace with:
```markdown
    "deepseek": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" },
    "qwen":     { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" }
  },
  "summary": "2-3 sentence executive summary of code quality and required actions"
```

- [ ] **Step 9: Trust Hierarchy (line 697)**

Find:
```markdown
Codex · Gemini · GLM · DeepSeek (equal advisory peers — verify findings)
```
Replace with:
```markdown
Codex · Gemini · GLM · DeepSeek · Qwen (equal advisory peers — verify findings)
```

- [ ] **Step 10: Quick Reference (line 708)**

Find:
```markdown
| Default (review) | 3 | 3 (parallel Bash; OpenCode call runs GLM+DeepSeek sequentially) | 0 |
```
Replace with:
```markdown
| Default (review) | 3 | 3–4 (parallel Bash; OpenCode call runs GLM+DeepSeek sequentially; +1 Qwen call when `TRIBUNAL_QWEN=on`) | 0 |
```

- [ ] **Step 11: Verify no stray "four reviewers" / count drift remains**

Run:
```bash
grep -nE 'the four reviewers|all four JSON|four total|four parallel' plugins/tribunal-review/skills/tribunal-loop/SKILL.md
```
Expected: only intentional historical references inside Bash-call-3's comments about the *OpenCode* legs (GLM+DeepSeek) remain, if any. There must be **no** remaining claim that the *panel* has exactly four reviewers in the arbitration/collect prose. Manually confirm any hits are OpenCode-internal, not panel-wide.

- [ ] **Step 12: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal): teach tribunal-loop arbitration about the fifth (qwen) peer (#41)"
```

---

## Task 5: Update `agents/opus-arbiter.md`

The standalone arbiter doc must recognize `qwen` as a fifth peer in the same four spots.

**Files:**
- Modify: `plugins/tribunal-review/agents/opus-arbiter.md`

- [ ] **Step 1: Input format (lines 15–21)**

Find:
```markdown
You receive JSON reviews from up to four providers, passed inline:
1. **Codex** (OpenAI Codex CLI)
2. **Gemini** (Gemini CLI)
3. **GLM** (OpenCode Go — opencode-go/glm-5.1)
4. **DeepSeek** (direct DeepSeek API — deepseek/deepseek-v4-pro)

All four are equal advisory peers. A finding reported by ≥2 providers is CONSENSUS.
```
Replace with:
```markdown
You receive JSON reviews from up to five providers, passed inline:
1. **Codex** (OpenAI Codex CLI)
2. **Gemini** (Gemini CLI)
3. **GLM** (OpenCode Go — opencode-go/glm-5.1)
4. **DeepSeek** (direct DeepSeek API — deepseek/deepseek-v4-pro)
5. **Qwen** (Qwen Code CLI — qwen3-coder-plus; diff-only, off by default)

All are equal advisory peers. A finding reported by ≥2 providers is CONSENSUS. Some providers
are commonly disabled (Qwen off by default; Gemini/DeepSeek may be off) — see Degraded Input.
```

- [ ] **Step 2: Degraded-input disabled clause (lines 30–33)**

Find:
```markdown
If a provider returned `{"status": "disabled"}` (operator set `TRIBUNAL_GEMINI=off` or
`TRIBUNAL_DEEPSEEK=off`): this is an INTENTIONAL skip, NOT a failure. Exclude it from quorum,
set its `provider_assessment.<provider>.status` to `"disabled"`, and do not count it toward
the "all providers failed" branch.
```
Replace with:
```markdown
If a provider returned `{"status": "disabled"}` (operator set `TRIBUNAL_GEMINI=off`,
`TRIBUNAL_DEEPSEEK=off`, or left Qwen off — `TRIBUNAL_QWEN` not `on`, the default): this is an
INTENTIONAL skip, NOT a failure. Exclude it from quorum, set its
`provider_assessment.<provider>.status` to `"disabled"`, and do not count it toward the
"all providers failed" branch.
```

- [ ] **Step 3: Step-2 conflict scope (line 50)**

Find:
```markdown
A finding may be reported by any subset of the four reviewers (codex, gemini, glm, deepseek).
```
Replace with:
```markdown
A finding may be reported by any subset of the five reviewers (codex, gemini, glm, deepseek, qwen).
```

- [ ] **Step 4: Output schema `positions` + `provider_assessment` (lines 103 and 110)**

Find:
```markdown
    "issue": "...", "positions": {"codex": "...", "gemini": "...", "glm": "...", "deepseek": "..."},
```
Replace with:
```markdown
    "issue": "...", "positions": {"codex": "...", "gemini": "...", "glm": "...", "deepseek": "...", "qwen": "..."},
```

Then find:
```markdown
    "deepseek": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" }
  },
  "summary": "2-3 sentence executive summary of code quality and required actions"
```
Replace with:
```markdown
    "deepseek": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" },
    "qwen":     { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled" }
  },
  "summary": "2-3 sentence executive summary of code quality and required actions"
```

- [ ] **Step 5: Verify the output-schema JSON block still parses**

Run (extracts the JSON inside the Output Format fenced block and validates it):
```bash
awk '/## Output Format/{s=1} s&&/^```json$/{f=1;next} s&&f&&/^```$/{exit} f' plugins/tribunal-review/agents/opus-arbiter.md | jq -e . >/dev/null && echo "ARBITER SCHEMA JSON OK"
```
Expected: `ARBITER SCHEMA JSON OK`.

- [ ] **Step 6: Commit**

```bash
git add plugins/tribunal-review/agents/opus-arbiter.md
git commit -m "feat(tribunal): add qwen as fifth peer in opus-arbiter (#41)"
```

---

## Task 6: Update `README.md`

Document prerequisites, the new env vars, and the fifth peer.

**Files:**
- Modify: `plugins/tribunal-review/README.md`

- [ ] **Step 1: Headline (line 3)**

Find:
```markdown
Multi-provider code review plugin for Claude Code. Runs four reviewers — Codex (GPT-5.3), Gemini (3 Pro Preview), OpenCode Go GLM-5.1, and DeepSeek-V4-Pro on the **direct DeepSeek API** — then uses Opus as the final arbiter to deduplicate findings, resolve conflicts, and issue a single authoritative verdict. DeepSeek runs decoupled from the OpenCode Go backend (so its quota can't take GLM down with it) and is the one leg that **walks the repo** read-only, providing context the diff-only legs cannot.
```
Replace with:
```markdown
Multi-provider code review plugin for Claude Code. Runs up to five reviewers — Codex (GPT-5.3), Gemini (3 Pro Preview), OpenCode Go GLM-5.1, DeepSeek-V4-Pro on the **direct DeepSeek API**, and an optional **Qwen** leg via the Qwen Code CLI — then uses Opus as the final arbiter to deduplicate findings, resolve conflicts, and issue a single authoritative verdict. DeepSeek runs decoupled from the OpenCode Go backend (so its quota can't take GLM down with it) and is the one leg that **walks the repo** read-only; Qwen runs on its own CLI/transport (decorrelated from the OpenCode legs) and is **off by default**.
```

- [ ] **Step 2: Prerequisites (after line 12, the `jq` bullet)**

Find:
```markdown
- `jq` (used to parse and validate reviewer JSON output)
```
Replace with:
```markdown
- [Qwen Code CLI](https://github.com/QwenLM/qwen-code) (`npm install -g @qwen-code/qwen-code`, Node 20+) — **optional**, only needed if you enable the Qwen leg (`TRIBUNAL_QWEN=on`). Auth via `DASHSCOPE_API_KEY` (pay-as-you-go DashScope; new accounts get a free 1M+1M-token tier — enough to validate the leg before spending), or an OpenAI-compatible / OpenRouter key (see Configuration).
- `jq` (used to parse and validate reviewer JSON output)
- `curl` (used by the Step-1 Qwen liveness probe when the leg is enabled)
```

- [ ] **Step 3: Config intro (line 38)**

Find:
```markdown
The Gemini and DeepSeek reviewers are configurable via environment variables (export them
in your shell before launching `claude`). All default to the current behavior, so leaving
them unset changes nothing.
```
Replace with:
```markdown
The Gemini, DeepSeek, and Qwen reviewers are configurable via environment variables (export
them in your shell before launching `claude`). All default to the current behavior, so leaving
them unset changes nothing — in particular the Qwen leg stays **off** until you opt in.
```

- [ ] **Step 4: Config table — add Qwen rows (after line 48, the `DEEPSEEK_API_KEY` row)**

Find:
```markdown
| `DEEPSEEK_API_KEY` | _(unset)_ | DeepSeek direct-API credential (alternative to `opencode auth login`). |
```
Replace with:
```markdown
| `DEEPSEEK_API_KEY` | _(unset)_ | DeepSeek direct-API credential (alternative to `opencode auth login`). |
| `TRIBUNAL_QWEN` | `off` | Set to `on` to enable the Qwen leg (additive, needs a key). Adds a fifth provider to the quorum; when off the arbiter reports Qwen as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_QWEN_MODEL` | `qwen3-coder-plus` | Model passed to `qwen --model`. Qwen ids change often through 2026 — override as needed (e.g. `qwen3-coder-next` for a cheaper slot). |
| `TRIBUNAL_QWEN_BASE_URL` | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | OpenAI-compatible base URL used only by the Step-1 liveness probe. Point at another region/endpoint if not on DashScope International. |
| `DASHSCOPE_API_KEY` | _(unset)_ | Qwen DashScope credential (primary transport). The Qwen Code CLI also accepts `OPENAI_API_KEY`+`OPENAI_BASE_URL` (OpenAI-compatible) or `OPENROUTER_API_KEY` (`qwen/...` ids). |
```

- [ ] **Step 5: Config example (lines 51–52)**

Find:
```bash
export TRIBUNAL_GEMINI=off                          # skip Gemini this session
export TRIBUNAL_DEEPSEEK_MODEL=deepseek/deepseek-v4-flash  # cheaper/faster DeepSeek leg
```
Replace with:
```bash
export TRIBUNAL_GEMINI=off                          # skip Gemini this session
export TRIBUNAL_DEEPSEEK_MODEL=deepseek/deepseek-v4-flash  # cheaper/faster DeepSeek leg
export TRIBUNAL_QWEN=on                             # enable the decorrelated Qwen leg
export DASHSCOPE_API_KEY=sk-...                     # Qwen auth (DashScope, pay-as-you-go)
```

- [ ] **Step 6: Standalone-agents note (lines 55–57)**

Find:
```markdown
These knobs apply to the `tribunal-loop` workflow. (The standalone `gemini-reviewer` and
`deepseek-reviewer` agents honor their `_MODEL` overrides but have no disable switch —
invoking the agent always means a review is wanted.)
```
Replace with:
```markdown
These knobs apply to the `tribunal-loop` workflow. The standalone `gemini-reviewer` and
`deepseek-reviewer` agents honor their `_MODEL` overrides but have no disable switch —
invoking the agent always means a review is wanted. The standalone `qwen-reviewer` is the
exception: because Qwen is opt-in, it honors `TRIBUNAL_QWEN` (and `TRIBUNAL_QWEN_MODEL`) and
emits the `disabled` marker unless `TRIBUNAL_QWEN=on`.
```

- [ ] **Step 7: How-it-works Step 2 (line 65)**

Find:
```markdown
Runs Codex, Gemini, and OpenCode as **three parallel Bash calls**.
```
Replace with:
```markdown
Runs Codex, Gemini, and OpenCode as parallel Bash calls — plus a fourth **Qwen** call when `TRIBUNAL_QWEN=on` (Qwen reviews the diff only, on its own CLI/transport, decorrelated from the OpenCode legs).
```

- [ ] **Step 8: Output-format example `provider_assessment` (lines 97–102)**

Find:
```markdown
  "provider_assessment": {
    "codex":    { "findings_accepted": 2, "findings_rejected": 1, "status": "ok" },
    "gemini":   { "findings_accepted": 3, "findings_rejected": 0, "status": "ok" },
    "glm":      { "findings_accepted": 2, "findings_rejected": 0, "status": "ok" },
    "deepseek": { "findings_accepted": 1, "findings_rejected": 1, "status": "ok" }
  },
```
Replace with:
```markdown
  "provider_assessment": {
    "codex":    { "findings_accepted": 2, "findings_rejected": 1, "status": "ok" },
    "gemini":   { "findings_accepted": 3, "findings_rejected": 0, "status": "ok" },
    "glm":      { "findings_accepted": 2, "findings_rejected": 0, "status": "ok" },
    "deepseek": { "findings_accepted": 1, "findings_rejected": 1, "status": "ok" },
    "qwen":     { "findings_accepted": 0, "findings_rejected": 0, "status": "disabled" }
  },
```

- [ ] **Step 9: Trust Hierarchy (lines 112 and 115)**

Find:
```markdown
Codex · Gemini · GLM · DeepSeek (equal advisory peers — verify findings)
```
Replace with:
```markdown
Codex · Gemini · GLM · DeepSeek · Qwen (equal advisory peers — verify findings)
```

Then find:
```markdown
The four reviewers are equal peers; a finding flagged by ≥2 is CONSENSUS. Opus can override any reviewer finding.
```
Replace with:
```markdown
The reviewers are equal peers (up to five; Qwen is off by default); a finding flagged by ≥2 is CONSENSUS. Opus can override any reviewer finding.
```

- [ ] **Step 10: Verify the README output-format JSON still parses**

Run:
```bash
awk '/## Output Format/{s=1} s&&/^```json$/{f=1;next} s&&f&&/^```$/{exit} f' plugins/tribunal-review/README.md | jq -e . >/dev/null && echo "README JSON OK"
```
Expected: `README JSON OK`.

- [ ] **Step 11: Commit**

```bash
git add plugins/tribunal-review/README.md
git commit -m "docs(tribunal): document the optional Qwen leg and its env vars (#41)"
```

---

## Task 7: Bump version (both manifests, in sync)

Per CLAUDE.md: bump the version in BOTH `plugin.json` AND `marketplace.json`. This is a feature → `0.7.1 → 0.8.0`.

**Files:**
- Modify: `plugins/tribunal-review/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: plugin.json — version, description, keywords**

In `plugins/tribunal-review/.claude-plugin/plugin.json`:

Find:
```json
  "version": "0.7.1",
  "description": "Multi-provider code review with Codex, Gemini, OpenCode GLM, direct-API DeepSeek (repo-walking), and Opus arbitration",
```
Replace with:
```json
  "version": "0.8.0",
  "description": "Multi-provider code review with Codex, Gemini, OpenCode GLM, direct-API DeepSeek (repo-walking), optional Qwen, and Opus arbitration",
```

Then find:
```json
  "keywords": ["code-review", "multi-provider", "codex", "gemini", "opencode", "glm", "deepseek", "tribunal"]
```
Replace with:
```json
  "keywords": ["code-review", "multi-provider", "codex", "gemini", "opencode", "glm", "deepseek", "qwen", "tribunal"]
```

- [ ] **Step 2: marketplace.json — version + description (must match plugin.json)**

In `.claude-plugin/marketplace.json`, within the `tribunal-review` entry, find:
```json
      "name": "tribunal-review",
      "description": "Multi-provider code review with Codex, Gemini, OpenCode GLM, direct-API DeepSeek (repo-walking), and Opus arbitration",
      "version": "0.7.1",
```
Replace with:
```json
      "name": "tribunal-review",
      "description": "Multi-provider code review with Codex, Gemini, OpenCode GLM, direct-API DeepSeek (repo-walking), optional Qwen, and Opus arbitration",
      "version": "0.8.0",
```

- [ ] **Step 3: Verify both manifests parse and versions match**

Run:
```bash
jq -e . plugins/tribunal-review/.claude-plugin/plugin.json >/dev/null && jq -e . .claude-plugin/marketplace.json >/dev/null && \
P=$(jq -r .version plugins/tribunal-review/.claude-plugin/plugin.json) && \
M=$(jq -r '.plugins[] | select(.name=="tribunal-review") | .version' .claude-plugin/marketplace.json) && \
echo "plugin=$P marketplace=$M" && test "$P" = "0.8.0" && test "$M" = "0.8.0" && echo "VERSIONS IN SYNC"
```
Expected: `plugin=0.8.0 marketplace=0.8.0` then `VERSIONS IN SYNC`.

- [ ] **Step 4: Commit**

```bash
git add plugins/tribunal-review/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(tribunal): bump to 0.8.0 for the Qwen leg (#41)"
```

---

## Task 8: End-to-end verification

Final gate before declaring done. Two paths: the always-runnable **disabled-default** smoke (no key), and the **enabled live** smoke (needs `DASHSCOPE_API_KEY` + `qwen` installed). Do the live smoke if you have a key; otherwise document that it was skipped.

**Files:** none (verification only).

- [ ] **Step 1: All embedded bash blocks are syntactically valid**

Run:
```bash
for f in plugins/tribunal-review/agents/qwen-reviewer.md plugins/tribunal-review/skills/tribunal-loop/SKILL.md; do
  awk -v out="/tmp/chk.sh" 'BEGIN{n=0} /^```bash$/{n++; fn=sprintf("/tmp/chk_%d.sh",n); f=1; next} /^```$/{f=0; next} f{print > fn}' "$f"
done
ok=1; for s in /tmp/chk_*.sh; do bash -n "$s" || { echo "FAIL: $s"; ok=0; }; done
test "$ok" = 1 && echo "ALL BASH BLOCKS OK"; rm -f /tmp/chk_*.sh
```
Expected: `ALL BASH BLOCKS OK`.

- [ ] **Step 2: `shellcheck` the Qwen leg (if available)**

Run:
```bash
command -v shellcheck >/dev/null && awk '/^```bash$/{f=1;next} /^```$/{f=0} f' plugins/tribunal-review/agents/qwen-reviewer.md > /tmp/qwen-leg.sh && shellcheck -S warning /tmp/qwen-leg.sh; echo "shellcheck done (exit $?)"
```
Expected: no errors (SC2086-style warnings on intentional unquoted `$CLIS` word-splitting in the preflight are acceptable and pre-existing; the leg script itself should be clean). If shellcheck is absent, note it as skipped.

- [ ] **Step 3: Disabled-default smoke (no key required)**

On a feature branch with a diff vs `origin/main`, run the Bash-call-4 block with Qwen unset:
```bash
awk '/### Bash call 4: Qwen Review/{s=1} s&&/^```bash$/{f=1;next} s&&/^```$/{exit} f' plugins/tribunal-review/skills/tribunal-loop/SKILL.md > /tmp/qwen-call4.sh
( unset TRIBUNAL_QWEN; bash /tmp/qwen-call4.sh ) | jq -e 'select(.provider=="qwen" and .status=="disabled")' && echo "DEFAULT-OFF SMOKE OK"
```
Expected: the disabled marker prints and `DEFAULT-OFF SMOKE OK`.

- [ ] **Step 4: Enabled live smoke (needs `DASHSCOPE_API_KEY` + `qwen`)**

Only if you have a key and the CLI installed:
```bash
TRIBUNAL_QWEN=on bash /tmp/qwen-call4.sh | tee /tmp/qwen-live.json | jq -e '.provider=="qwen" and ((.findings|type=="array") or (.error|type=="string"))' && echo "LIVE SMOKE OK"
```
Expected: a well-formed findings object (or a clean `error` object) and `LIVE SMOKE OK`. If it returns the raw envelope instead of the contract JSON, the Task-0 extractor branch was wrong — fix the `jq` extractor in BOTH `qwen-reviewer.md` and SKILL.md Bash call 4, re-run, and amend the relevant commits. If you have no key, write "live smoke SKIPPED — no DASHSCOPE_API_KEY" in your report (do not claim it passed).

- [ ] **Step 5: Preflight integration check**

Run the Step-1 preflight with Qwen enabled but `qwen` possibly absent — confirm it degrades gracefully (warns, doesn't crash):
```bash
awk '/## STEP 1: Pre-flight/{s=1} s&&/^```bash$/{f=1;next} s&&f&&/^```$/{exit} f' plugins/tribunal-review/skills/tribunal-loop/SKILL.md > /tmp/preflight.sh
TRIBUNAL_QWEN=on bash /tmp/preflight.sh; echo "preflight exit=$?"
```
Expected: prints `PREFLIGHT OK: N/TOTAL ...` (TOTAL reflects qwen when on) or `PREFLIGHT FAIL` only if zero CLIs exist; a missing `qwen` shows up as a warning line, not a crash. Exit 0 unless zero providers.

- [ ] **Step 6: Final grep for residual "four"-isms across all touched files**

Run:
```bash
grep -rnE 'four reviewers|four providers|up to four|four equal' plugins/tribunal-review/ | grep -v 'GLM\|DeepSeek leg'
```
Expected: no panel-wide "four" claims remain (OpenCode-internal references to its two legs are fine). Fix any stragglers, then re-run the relevant Task's commit as an amend.

---

## Self-Review (performed against the issue's acceptance criteria)

- **New `agents/qwen-reviewer.md` (direct API, mirrors gemini-reviewer.md)** → Task 1. ✅
- **SKILL.md Step-1 preflight (key check + liveness probe)** → Task 3. ✅
- **SKILL.md Step-2 dispatch** → Task 2 (Bash call 4). ✅
- **SKILL.md Step-3 collect + N/TOTAL accounting + disabled-leg handling** → Tasks 3 (TOTAL) & 4 (collect/3e/3f). ✅
- **`opus-arbiter.md`: provider list, positions, provider_assessment, quorum/consensus** → Task 5 + Task 4 (inline arbiter). ✅
- **README: `TRIBUNAL_QWEN`, `TRIBUNAL_QWEN_MODEL`, auth env var** → Task 6 (plus `TRIBUNAL_QWEN_BASE_URL`). ✅
- **Bump version in BOTH plugin.json and marketplace.json** → Task 7. ✅
- **Switchable like Gemini (off→disabled marker, arbiter excludes, status=disabled)** → Tasks 1/2 (marker), 4/5 (arbiter). ✅
- **Default on or off?** → Resolved to **off** (opt-in), the issue's own proposal; documented and reversible via one env default. ✅

**Type/name consistency:** provider key is `qwen` everywhere; model default `qwen3-coder-plus` everywhere; env vars `TRIBUNAL_QWEN` / `TRIBUNAL_QWEN_MODEL` / `TRIBUNAL_QWEN_BASE_URL` / `DASHSCOPE_API_KEY` consistent across SKILL.md, agent, and README; disabled-marker JSON identical in the standalone agent and Bash call 4.

**Open risk (flagged, not hidden):** the `qwen -o json` envelope shape is confirmed in Task 0 and consumed by a tolerant extractor; if the live smoke (Task 8 Step 4) shows the extractor missing the assistant text, fix it in the two mirrored spots before merge.
