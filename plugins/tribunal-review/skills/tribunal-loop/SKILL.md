---
name: tribunal-loop
description: Multi-provider code review workflow with Codex, Gemini, OpenCode (GLM + DeepSeek), and Opus arbitration
---

# Tribunal Loop

Multi-provider code review. Codex (GPT-5.3) + Gemini (3 Pro Preview) + OpenCode GLM-5.1 + OpenCode DeepSeek-V4-Pro review in parallel, Opus arbitrates inline.

3-step workflow: pre-flight, parallel review, inline arbitration.

## Providers
- **Codex** (GPT-5.3) - comprehensive review
- **Gemini** (3 Pro Preview) - comprehensive review + web/CVE search
- **GLM** (opencode-go/glm-5.1) - comprehensive review (OpenCode Go)
- **DeepSeek** (opencode-go/deepseek-v4-pro) - comprehensive review (OpenCode Go)
- **Opus** (4.5) - final arbiter (runs inline, no agent spawn)

---

## STEP 1: Pre-flight

```
Verify:
1. We're on a feature branch, not main. If on main: STOP and ask which branch to review.
2. There is a diff vs origin/main. Run: git diff origin/main...HEAD --stat
   If no diff: STOP and report "No changes to review."
```

Output: "[TRIBUNAL 1/3] On branch: {branch_name}, {N} files changed"

---

## STEP 2: Parallel Review

Run the three scripts below as **three parallel Bash tool calls**. No Task agents -- execute directly. The OpenCode call (Bash call 3) runs its two legs — GLM then DeepSeek — **sequentially within that one call**, because concurrent `opencode run` instances deadlock on the shared `~/.local/share/opencode` data dir (issue #31). It still yields four reviews total.

### Bash call 1: Codex Review

```bash
cd "$(git rev-parse --show-toplevel)"

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

timeout -k 10 600 codex exec - \
  --output-schema "$TMPDIR/codex-review-schema.json" \
  -o "$TMPDIR/codex-review-output.json" \
  --sandbox read-only \
  >/dev/null 2>"$TMPDIR/codex-stderr.txt" <<PROMPT
You are a senior code reviewer. Analyze the diff below for REAL, ACTIONABLE issues only.

## What to Report
1. **Logic errors** — division by zero, off-by-one, null dereference, wrong comparisons, race conditions
2. **Security vulnerabilities** — SQL injection, command injection, XSS, auth bypass, sensitive data exposure
3. **Edge cases** — boundary conditions, empty inputs, integer overflow, unhandled error paths
4. **Performance** — N+1 queries, unnecessary allocations, blocking async calls

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

## Verdict Rules
- **BLOCK**: Any critical-severity finding, OR 2+ high-severity findings
- **NEEDS_WORK**: Any high-severity finding, OR 3+ medium-severity findings
- **APPROVE**: All other cases

## Output
Your response MUST be valid JSON matching the provided output schema.
Set "provider" to "codex" and "model" to the model you are running as.
$([ "$DIFF_TRUNCATED" = true ] && echo "NOTE: Diff was truncated from ${DIFF_SIZE} bytes to 100KB. Review what is provided.")

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

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider": "gemini", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}'
  exit 0
fi

printf '%s\n' "$DIFF" | timeout -k 10 600 gemini --model gemini-3-pro-preview -p "You are a senior code reviewer performing a thorough security-focused review.

ANALYZE THIS DIFF FOR:
1. Security vulnerabilities - injection, XSS, CSRF, auth issues, secrets exposure
2. Architectural issues - coupling, layering violations, anti-patterns
3. Logic errors - race conditions, null refs, wrong comparisons
4. Performance - N+1 queries, memory leaks, blocking in async
5. Test coverage gaps - missing edge cases, untested paths

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
`~/.local/share/opencode` SQLite data dir, hanging until the timeout (issue #31).
The call also runs opencode from a non-repo scratch dir, because `opencode run`
can also deadlock at init when its cwd is inside a git repo (see the `cd "$TMPDIR"`
note below). Codex (Bash call 1) and Gemini (Bash call 2) stay parallel with this call.

```bash
cd "$(git rev-parse --show-toplevel)"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

emit_empty() {  # provider, model
  printf '{"provider": "%s", "model": "%s", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}\n' "$1" "$2"
}

# If OpenCode is not installed, emit an error object for each leg and stop.
if ! command -v opencode >/dev/null 2>&1; then
  printf '%s\n' '{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "glm"}'
  printf '%s\n' '{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "deepseek"}'
  exit 0
fi

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  emit_empty "glm" "opencode-go/glm-5.1"
  emit_empty "deepseek" "opencode-go/deepseek-v4-pro"
  exit 0
fi

# Diff-size guard (GLM/DeepSeek have large context; cap higher than Codex's 100KB)
DIFF_SIZE=${#DIFF}
DIFF_TRUNCATED=false
if [ "$DIFF_SIZE" -gt 204800 ]; then
  DIFF=$(printf '%s' "$DIFF" | head -c 204800)
  DIFF_TRUNCATED=true
fi

# Run OpenCode from a NON-REPO directory. `opencode run` can deadlock at init
# when its cwd is inside a git repository (it hangs after loading internal
# plugins, never reaching model selection — a single instance, no concurrency).
# The diff is already captured above and embedded in the prompt (--pure, "do NOT
# use tools"), so opencode needs no repo/git context. $TMPDIR (mktemp -d) is a
# scratch dir outside any repo.
cd "$TMPDIR"

# Review one OpenCode leg and print its JSON. Args: provider, label, model.
review_opencode_leg() {
  local provider="$1" label="$2" model="$3"
  local raw="$TMPDIR/$provider-raw.txt" err="$TMPDIR/$provider-stderr.txt"
  local oc_exit json safe prompt

  prompt="You are a senior code reviewer performing a thorough, comprehensive review.

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
- Do NOT use any tools. Analyze ONLY the diff provided below.

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
$([ "$DIFF_TRUNCATED" = true ] && echo "NOTE: Diff was truncated to 200KB. Review what is provided.")

THE DIFF:
$DIFF"

  # Retry once on timeout (exit 124) — OpenCode Go latency can transiently spike past the cap
  for attempt in 1 2; do
    timeout -k 10 600 opencode run --agent plan -m "$model" --variant high --format default --pure "$prompt" </dev/null \
      >"$raw" 2>"$err"
    oc_exit=$?
    [ "$oc_exit" -ne 124 ] && break
  done

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

# SEQUENTIAL — the two legs must never overlap (see issue #31). Each is ~8-15s.
review_opencode_leg "glm" "GLM" "opencode-go/glm-5.1"
review_opencode_leg "deepseek" "DeepSeek" "opencode-go/deepseek-v4-pro"
# trap EXIT handles cleanup of $TMPDIR
```

## Error Handling
If `opencode` is not installed, the call emits one error object per leg and exits 0:
```json
{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "glm"}
{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "deepseek"}
```

Collect all four JSON outputs — Codex and Gemini from their calls, GLM and DeepSeek from the single OpenCode call (which prints two JSON objects, GLM first). Parse them. If any returned an error JSON, note it for arbitration.

Output: "[TRIBUNAL 2/3] Reviews complete - Codex: {C}, Gemini: {G}, GLM: {L}, DeepSeek: {D} findings"

---

## STEP 3: Inline Arbitration (Opus)

Do NOT spawn a Task agent. You are already Opus -- perform arbitration directly.

Read both JSON outputs from Step 2 and apply the following protocol:

### 3a: Deduplicate Findings

Two findings are **duplicates** if they describe the same underlying issue in the same file, even if worded differently. For duplicates:
- Keep the finding with higher confidence
- Merge suggestions if both are valuable
- Mark as CONSENSUS when ≥2 providers report the same underlying issue; record all supporting providers in the `providers` array

### 3b: Resolve Conflicts (N providers)

A finding may be reported by any subset of the four reviewers (codex, gemini, glm, deepseek).

| Scenario | Action |
|----------|--------|
| Reported by ≥2 providers | Include, mark CONSENSUS, list supporting providers |
| Reported by exactly 1 provider | Include as SINGLE, evaluate validity |
| Providers contradict each other | Decide and document reasoning, mark ARBITRATED |
| Severities differ for the same finding | **Use the highest severity reported**, note disagreement in arbiter_notes |

**HARD RULE**: When providers report different severities for the same finding, you MUST use the highest severity. No exceptions.

All four reviewers are **equal advisory peers**. Opus has final authority and may override any finding.

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
- If **all four providers failed**: verdict = NEEDS_WORK, confidence = 0.0, rationale = "All review providers failed. Manual review required."
- If **all providers returned zero findings**: verdict = APPROVE, confidence = 0.95.

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
    "suggestion": "...", "confidence": 0.0, "arbiter_notes": "..."
  }],
  "conflicts_resolved": [{
    "issue": "...", "positions": {"codex": "...", "gemini": "...", "glm": "...", "deepseek": "..."},
    "ruling": "...", "reasoning": "..."
  }],
  "provider_assessment": {
    "codex":    { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial" },
    "gemini":   { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial" },
    "glm":      { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial" },
    "deepseek": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial" }
  },
  "summary": "2-3 sentence executive summary of code quality and required actions"
}
```

Output: "[TRIBUNAL 3/3] Verdict: {APPROVE|NEEDS_WORK|BLOCK} - {N} actionable findings"

---

## Trust Hierarchy

```
OPUS 4.5 (Final authority, runs inline)
    |
Codex · Gemini · GLM · DeepSeek (equal advisory peers — verify findings)
```

The four reviewers are equal peers; a finding flagged by ≥2 is CONSENSUS. Opus can override any reviewer finding.

---

## Quick Reference

| Mode | Steps | Tool Calls | Agent Spawns |
|------|-------|------------|-------------|
| Default (review) | 3 | 3 (parallel Bash; OpenCode call runs GLM+DeepSeek sequentially) | 0 |
