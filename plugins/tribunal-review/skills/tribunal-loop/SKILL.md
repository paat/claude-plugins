---
name: tribunal-loop
description: Multi-provider code review workflow with Codex, Gemini, and Opus arbitration
---

# Tribunal Loop

Multi-provider code review. Codex (GPT-5.3) + Gemini (3 Pro Preview) review in parallel, Opus arbitrates inline.

3-step workflow: pre-flight, parallel review, inline arbitration.

## Providers
- **Codex** (GPT-5.3) - Logic, edge cases, code quality
- **Gemini** (3 Pro Preview) - Security, architecture, patterns
- **Opus** (4.5) - Final arbiter (runs inline, no agent spawn)

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

Run both scripts below as **two parallel Bash tool calls**. No Task agents -- execute directly.

### Bash call 1: Codex Review

```bash
cd "$(git rev-parse --show-toplevel)"

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

cat > /tmp/codex-review-schema.json << 'SCHEMA'
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

codex exec - \
  --model gpt-5.3-codex \
  --output-schema /tmp/codex-review-schema.json \
  -o /tmp/codex-review-output.json \
  --sandbox read-only \
  >/dev/null 2>/tmp/codex-stderr.txt <<PROMPT
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

if [ $CODEX_EXIT -eq 0 ] && [ -f /tmp/codex-review-output.json ]; then
  cat /tmp/codex-review-output.json
else
  STDERR_CONTENT=$(cat /tmp/codex-stderr.txt 2>/dev/null || echo "no stderr captured")
  SAFE_STDERR=$(echo "$STDERR_CONTENT" | jq -Rs . 2>/dev/null || echo '"stderr encoding failed"')
  printf '{"error": "Codex execution failed", "exit_code": %d, "stderr": %s}\n' "$CODEX_EXIT" "$SAFE_STDERR"
fi

rm -f /tmp/codex-review-schema.json /tmp/codex-review-output.json /tmp/codex-stderr.txt
```

### Bash call 2: Gemini Review

```bash
cd "$(git rev-parse --show-toplevel)"

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider": "gemini", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}'
  exit 0
fi

printf '%s\n' "$DIFF" | gemini --model gemini-3-pro-preview -p "You are a senior code reviewer performing a thorough security-focused review.

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
  >/tmp/gemini-raw-output.json 2>/tmp/gemini-stderr.txt

GEMINI_EXIT=$?
if [ $GEMINI_EXIT -eq 0 ] && [ -f /tmp/gemini-raw-output.json ]; then
  # Gemini -o json wraps output in session envelope; extract .response and strip markdown fences
  RESPONSE=$(jq -r '.response // empty' /tmp/gemini-raw-output.json 2>/dev/null)
  if [ -n "$RESPONSE" ]; then
    echo "$RESPONSE" | sed 's/^```json//;s/^```//;/^$/d' | jq . 2>/dev/null || echo "$RESPONSE"
  else
    cat /tmp/gemini-raw-output.json
  fi
else
  STDERR_CONTENT=$(cat /tmp/gemini-stderr.txt 2>/dev/null)
  SAFE_STDERR=$(echo "$STDERR_CONTENT" | jq -Rs . 2>/dev/null || echo '"stderr encoding failed"')
  printf '{"error": "Gemini execution failed", "exit_code": %d, "stderr": %s}\n' "$GEMINI_EXIT" "$SAFE_STDERR"
fi
rm -f /tmp/gemini-stderr.txt /tmp/gemini-raw-output.json
```

Collect both JSON outputs. Parse them. If either returned an error JSON, note it for arbitration.

Output: "[TRIBUNAL 2/3] Reviews complete - Codex: {N} findings, Gemini: {M} findings"

---

## STEP 3: Inline Arbitration (Opus)

Do NOT spawn a Task agent. You are already Opus -- perform arbitration directly.

Read both JSON outputs from Step 2 and apply the following protocol:

### 3a: Deduplicate Findings

Two findings are **duplicates** if they describe the same underlying issue in the same file, even if worded differently. For duplicates:
- Keep the finding with higher confidence
- Merge suggestions if both are valuable
- Mark as "CONSENSUS"

### 3b: Resolve Conflicts

| Scenario | Action |
|----------|--------|
| Both agree | Include, mark CONSENSUS |
| Severity differs | **Use higher severity**, note disagreement in arbiter_notes |
| Only Codex found it | Include as CODEX, evaluate validity |
| Only Gemini found it | Include as GEMINI, evaluate validity |
| Providers contradict | Decide and document reasoning, mark ARBITRATED |

**HARD RULE**: When providers report different severities for the same finding, you MUST use the higher severity. No exceptions.

### 3c: Evaluate Each Finding

For each finding, assess:
- Is this a real issue or a false positive?
- Is the suggested fix correct and complete?
- Does your software engineering expertise suggest a different conclusion?

Override provider findings when they are clearly wrong. Add new findings if both providers missed something obvious.

### 3d: Confidence Ranges

| Finding type | Confidence range |
|-------------|-----------------|
| CONSENSUS | 0.85 - 0.99 |
| Single-provider (CODEX/GEMINI) | 0.60 - 0.80 |
| ARBITRATED (conflict resolved) | 0.50 - 0.70 |
| Self-added (arbiter-originated) | 0.50 - 0.65 |

### 3e: Degraded Input

- If one provider returned invalid JSON or failed: proceed with the other provider's findings alone. Note the failure.
- If **both providers failed**: verdict = NEEDS_WORK, confidence = 0.0, rationale = "Both review providers failed. Manual review required."
- If **both providers returned zero findings**: verdict = APPROVE, confidence = 0.95.

### 3f: Issue Verdict

Assign finding IDs as T-001, T-002, etc., ordered by severity (critical first).

Output the tribunal verdict as JSON:

```json
{
  "tribunal_verdict": { "decision": "APPROVE|NEEDS_WORK|BLOCK", "confidence": 0.0, "rationale": "..." },
  "findings": [{
    "id": "T-001", "consensus": "CONSENSUS|CODEX|GEMINI|ARBITRATED",
    "severity": "critical|high|medium|low", "category": "logic|security|performance|quality|architecture",
    "file": "path/to/file", "line": 0, "title": "...", "description": "...",
    "suggestion": "...", "confidence": 0.0, "arbiter_notes": "..."
  }],
  "conflicts_resolved": [{
    "issue": "...", "codex_position": "...", "gemini_position": "...",
    "ruling": "...", "reasoning": "..."
  }],
  "provider_assessment": {
    "codex": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial" },
    "gemini": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial" }
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
CODEX (Trusted for logic)
    |
GEMINI (Advisory, verify findings)
```

Opus can override any Codex or Gemini finding.

---

## Quick Reference

| Mode | Steps | Tool Calls | Agent Spawns |
|------|-------|------------|-------------|
| Default (review) | 3 | 2 (parallel Bash) | 0 |
