# Tribunal OpenCode Reviewers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two OpenCode Go reviewers (GLM-5.1 + DeepSeek-V4-Pro) to the tribunal as a four-reviewer consensus panel, keeping Codex and Gemini, and generalize the Opus arbiter to N providers.

**Architecture:** Two new inline `opencode run` Bash blocks join the existing Codex/Gemini blocks in `SKILL.md` Step 2, run as 4 parallel Bash calls. Each OpenCode reviewer runs read-only (`--agent plan`), receives the diff inline, and emits findings JSON wrapped in sentinels for robust extraction (OpenCode has no `--output-schema`). The Opus arbiter (Step 3 + `opus-arbiter.md`) is generalized from 2 hardcoded providers to a provider-keyed model where a finding flagged by ≥2 reviewers is CONSENSUS.

**Tech Stack:** Bash 4+, `opencode` CLI 1.15.10, `jq`, `sed`. Markdown skill/agent files. No test framework — validation is "run the block, pipe to `jq -e`".

**Spec:** `docs/superpowers/specs/2026-05-25-tribunal-opencode-reviewers-design.md`

**Working dir / files in scope:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md`
- Modify: `plugins/tribunal-review/agents/opus-arbiter.md`
- Create: `plugins/tribunal-review/agents/opencode-reviewer.md`
- Modify: `plugins/tribunal-review/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json` (root)

---

## Task 1: Verify OpenCode output shape and read-only enforcement

This must run first — the extractor in later tasks assumes (a) `opencode run --format default` pipes plain text to stdout, (b) the model obeys the sentinel instruction, and (c) `--agent plan` blocks writes. Confirm all three on a throwaway call. This consumes a few requests from the OpenCode Go quota.

**Files:** none (investigation only).

- [ ] **Step 1: Confirm `--agent plan` is read-only**

Run:
```bash
opencode run --agent plan -m opencode-go/glm-5.1 --pure --format default \
  "Create a file called /tmp/tribunal_write_probe.txt containing the word OK, then tell me whether you succeeded."
ls -l /tmp/tribunal_write_probe.txt 2>&1
```
Expected: the file does NOT exist (`ls` reports "No such file"), confirming the `plan` agent cannot write. If the file IS created, `--agent plan` is not read-only in this version — STOP and switch the safety mechanism to a custom read-only agent before continuing (note it in the plan and ask).

- [ ] **Step 2: Confirm sentinel-wrapped JSON output on a tiny diff**

Run:
```bash
printf 'diff --git a/x.sh b/x.sh\n--- a/x.sh\n+++ b/x.sh\n@@ -1 +1,2 @@\n echo hi\n+rm -rf "$1"\n' \
| { D=$(cat); opencode run --agent plan -m opencode-go/glm-5.1 --pure --format default \
"Output ONLY a JSON object between the markers ===TRIBUNAL_JSON_BEGIN=== and ===TRIBUNAL_JSON_END===. The JSON must have keys provider (set to \"glm\"), model (\"opencode-go/glm-5.1\"), findings (array), summary (object). Review this diff:
$D"; }
```
Expected: stdout contains `===TRIBUNAL_JSON_BEGIN===`, a JSON object, then `===TRIBUNAL_JSON_END===`. Note whether there is TUI chrome around it and whether the markers appear verbatim.

- [ ] **Step 3: Record findings**

Confirm: markers obeyed? stdout is plain (not an event stream needing `--format json`)? If markers are reliably present, the sentinel extractor in Task 2 works as written. If the model ignored the markers, the brace-slice fallback in Task 2 covers it — no code change needed. No commit (investigation only).

---

## Task 2: Add the GLM-5.1 reviewer block to SKILL.md Step 2

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (Step 2, after the Gemini block ~line 231)

- [ ] **Step 1: Insert the GLM reviewer block**

In `SKILL.md`, immediately after the Gemini "Bash call 2" fenced block and before the "Collect both JSON outputs" line, add a new subsection:

````markdown
### Bash call 3: OpenCode GLM Review

```bash
cd "$(git rev-parse --show-toplevel)"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider": "glm", "model": "opencode-go/glm-5.1", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}'
  exit 0
fi

# Diff-size guard (GLM has large context; cap higher than Codex's 100KB)
DIFF_SIZE=${#DIFF}
DIFF_TRUNCATED=false
if [ "$DIFF_SIZE" -gt 204800 ]; then
  DIFF=$(printf '%s' "$DIFF" | head -c 204800)
  DIFF_TRUNCATED=true
fi

PROMPT="You are a senior code reviewer performing a thorough, comprehensive review.

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
  \"provider\": \"glm\",
  \"model\": \"opencode-go/glm-5.1\",
  \"findings\": [
    {\"severity\": \"critical|high|medium|low\", \"category\": \"logic|security|performance|quality|edge-case|architecture|testing\", \"file\": \"path\", \"line\": 42, \"title\": \"...\", \"description\": \"...\", \"suggestion\": \"...\", \"confidence\": 0.9}
  ],
  \"summary\": {\"total_findings\": 1, \"critical\": 0, \"high\": 1, \"medium\": 0, \"low\": 0, \"quality_score\": 7.5, \"verdict\": \"APPROVE|NEEDS_WORK|BLOCK\"}
}
===TRIBUNAL_JSON_END===
$([ "$DIFF_TRUNCATED" = true ] && echo "NOTE: Diff was truncated to 200KB. Review what is provided.")

THE DIFF:
$DIFF"

opencode run --agent plan -m opencode-go/glm-5.1 --variant high --format default --pure "$PROMPT" \
  >"$TMPDIR/glm-raw.txt" 2>"$TMPDIR/glm-stderr.txt"
OC_EXIT=$?

if [ $OC_EXIT -eq 0 ] && [ -s "$TMPDIR/glm-raw.txt" ]; then
  # Extract between sentinels; fall back to first-{ .. last-} slice
  JSON=$(sed -n '/===TRIBUNAL_JSON_BEGIN===/,/===TRIBUNAL_JSON_END===/p' "$TMPDIR/glm-raw.txt" \
    | sed '/===TRIBUNAL_JSON_BEGIN===/d;/===TRIBUNAL_JSON_END===/d;s/^```json//;s/^```//')
  if ! printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
    JSON=$(tr -d '\r' < "$TMPDIR/glm-raw.txt" | sed -n 'H;${x;s/^[^{]*//;s/[^}]*$//;p;}')
  fi
  if printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$JSON" | jq -c .
  else
    SAFE=$(jq -Rs . < "$TMPDIR/glm-raw.txt" 2>/dev/null || echo '"capture failed"')
    printf '{"error": "OpenCode GLM produced unparseable output", "provider": "glm", "raw": %s}\n' "$SAFE"
  fi
else
  STDERR_CONTENT=$(cat "$TMPDIR/glm-stderr.txt" 2>/dev/null)
  SAFE_STDERR=$(printf '%s' "$STDERR_CONTENT" | jq -Rs . 2>/dev/null || echo '"stderr encoding failed"')
  printf '{"error": "OpenCode GLM execution failed", "provider": "glm", "exit_code": %d, "stderr": %s}\n' "$OC_EXIT" "$SAFE_STDERR"
fi
# trap EXIT handles cleanup of $TMPDIR
```

## Error Handling
If `opencode` is not installed, the block emits:
```json
{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "glm"}
```
````

- [ ] **Step 2: Test the block on the current branch diff**

Run (paste the block body into a shell from the repo root on the feature branch):
```bash
bash -c 'cd "$(git rev-parse --show-toplevel)"; DIFF=$(git diff origin/main...HEAD); echo "diff bytes: ${#DIFF}"'
```
Then execute the full GLM block and pipe its output:
```bash
# (run the block) | jq -e '.provider == "glm" and (has("findings") or has("error"))'
```
Expected: output is a single valid JSON object (either findings or a structured `error`), `jq -e` returns true (exit 0). If it errors with "unparseable output", inspect `raw` and adjust the sentinel/slice — do not proceed until valid JSON is produced.

- [ ] **Step 3: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): add OpenCode GLM-5.1 reviewer block"
```

---

## Task 3: Add the DeepSeek-V4-Pro reviewer block to SKILL.md Step 2

Identical structure to the GLM block, with `provider` = `deepseek`, model = `opencode-go/deepseek-v4-pro`, and temp filenames `deepseek-*`.

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` (after the GLM block from Task 2)

- [ ] **Step 1: Insert the DeepSeek reviewer block**

After the GLM "Bash call 3" block, add:

````markdown
### Bash call 4: OpenCode DeepSeek Review

```bash
cd "$(git rev-parse --show-toplevel)"

# Parallel-safe: unique temp dir per invocation
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT

DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider": "deepseek", "model": "opencode-go/deepseek-v4-pro", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs origin/main"}}'
  exit 0
fi

DIFF_SIZE=${#DIFF}
DIFF_TRUNCATED=false
if [ "$DIFF_SIZE" -gt 204800 ]; then
  DIFF=$(printf '%s' "$DIFF" | head -c 204800)
  DIFF_TRUNCATED=true
fi

PROMPT="You are a senior code reviewer performing a thorough, comprehensive review.

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
  \"provider\": \"deepseek\",
  \"model\": \"opencode-go/deepseek-v4-pro\",
  \"findings\": [
    {\"severity\": \"critical|high|medium|low\", \"category\": \"logic|security|performance|quality|edge-case|architecture|testing\", \"file\": \"path\", \"line\": 42, \"title\": \"...\", \"description\": \"...\", \"suggestion\": \"...\", \"confidence\": 0.9}
  ],
  \"summary\": {\"total_findings\": 1, \"critical\": 0, \"high\": 1, \"medium\": 0, \"low\": 0, \"quality_score\": 7.5, \"verdict\": \"APPROVE|NEEDS_WORK|BLOCK\"}
}
===TRIBUNAL_JSON_END===
$([ "$DIFF_TRUNCATED" = true ] && echo "NOTE: Diff was truncated to 200KB. Review what is provided.")

THE DIFF:
$DIFF"

opencode run --agent plan -m opencode-go/deepseek-v4-pro --variant high --format default --pure "$PROMPT" \
  >"$TMPDIR/deepseek-raw.txt" 2>"$TMPDIR/deepseek-stderr.txt"
OC_EXIT=$?

if [ $OC_EXIT -eq 0 ] && [ -s "$TMPDIR/deepseek-raw.txt" ]; then
  JSON=$(sed -n '/===TRIBUNAL_JSON_BEGIN===/,/===TRIBUNAL_JSON_END===/p' "$TMPDIR/deepseek-raw.txt" \
    | sed '/===TRIBUNAL_JSON_BEGIN===/d;/===TRIBUNAL_JSON_END===/d;s/^```json//;s/^```//')
  if ! printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
    JSON=$(tr -d '\r' < "$TMPDIR/deepseek-raw.txt" | sed -n 'H;${x;s/^[^{]*//;s/[^}]*$//;p;}')
  fi
  if printf '%s' "$JSON" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$JSON" | jq -c .
  else
    SAFE=$(jq -Rs . < "$TMPDIR/deepseek-raw.txt" 2>/dev/null || echo '"capture failed"')
    printf '{"error": "OpenCode DeepSeek produced unparseable output", "provider": "deepseek", "raw": %s}\n' "$SAFE"
  fi
else
  STDERR_CONTENT=$(cat "$TMPDIR/deepseek-stderr.txt" 2>/dev/null)
  SAFE_STDERR=$(printf '%s' "$STDERR_CONTENT" | jq -Rs . 2>/dev/null || echo '"stderr encoding failed"')
  printf '{"error": "OpenCode DeepSeek execution failed", "provider": "deepseek", "exit_code": %d, "stderr": %s}\n' "$OC_EXIT" "$SAFE_STDERR"
fi
# trap EXIT handles cleanup of $TMPDIR
```

## Error Handling
If `opencode` is not installed, the block emits:
```json
{"error": "OpenCode CLI not found. Install from: https://opencode.ai", "provider": "deepseek"}
```
````

- [ ] **Step 2: Test the block**

Execute the DeepSeek block from the repo root and pipe:
```bash
# (run the block) | jq -e '.provider == "deepseek" and (has("findings") or has("error"))'
```
Expected: single valid JSON object, `jq -e` exit 0.

- [ ] **Step 3: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): add OpenCode DeepSeek-V4-Pro reviewer block"
```

---

## Task 4: Update Step 2 orchestration text (2 → 4 parallel calls)

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md:34` and the Step 2 closing lines (~232-235)

- [ ] **Step 1: Update the parallel-call instruction**

Replace the line:
```
Run both scripts below as **two parallel Bash tool calls**. No Task agents -- execute directly.
```
with:
```
Run all four scripts below as **four parallel Bash tool calls**. No Task agents -- execute directly.
```

- [ ] **Step 2: Update the collect + output lines**

Replace:
```
Collect both JSON outputs. Parse them. If either returned an error JSON, note it for arbitration.

Output: "[TRIBUNAL 2/3] Reviews complete - Codex: {N} findings, Gemini: {M} findings"
```
with:
```
Collect all four JSON outputs. Parse them. If any returned an error JSON, note it for arbitration.

Output: "[TRIBUNAL 2/3] Reviews complete - Codex: {C}, Gemini: {G}, GLM: {L}, DeepSeek: {D} findings"
```

- [ ] **Step 3: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "docs(tribunal-review): Step 2 runs four parallel reviewers"
```

---

## Task 5: Generalize the arbiter in SKILL.md Step 3 to N providers

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md` Step 3 (~239-315)

- [ ] **Step 1: Replace the conflict-resolution table (3b)**

Replace the "3b: Resolve Conflicts" table and its HARD RULE with:
```markdown
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
```

- [ ] **Step 2: Replace the 3d confidence-range table**

Replace the "3d: Confidence Ranges" table with:
```markdown
### 3d: Confidence Ranges

| Finding type | Confidence range |
|-------------|-----------------|
| CONSENSUS (≥2 providers) | 0.85 - 0.99 |
| SINGLE (one provider) | 0.60 - 0.80 |
| ARBITRATED (conflict resolved) | 0.50 - 0.70 |
| Self-added (arbiter-originated) | 0.50 - 0.65 |
```

- [ ] **Step 3: Replace the 3e degraded-input rules**

Replace "3e: Degraded Input" with:
```markdown
### 3e: Degraded Input

- If a subset of providers returned invalid JSON or failed: proceed with the remaining providers' findings. Note each failure in `provider_assessment`.
- If **all four providers failed**: verdict = NEEDS_WORK, confidence = 0.0, rationale = "All review providers failed. Manual review required."
- If **all providers returned zero findings**: verdict = APPROVE, confidence = 0.95.
```

- [ ] **Step 4: Replace the Step 3f output JSON schema**

Replace the `tribunal_verdict` JSON example with the provider-keyed version:
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

- [ ] **Step 5: Update the 3a dedup text**

In "3a: Deduplicate Findings" change "Mark as CONSENSUS" to: "Mark as CONSENSUS when ≥2 providers report the same underlying issue; record all supporting providers in the `providers` array. Keep the highest-confidence wording and merge suggestions."

- [ ] **Step 6: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "feat(tribunal-review): generalize arbiter to N providers with consensus rule"
```

---

## Task 6: Update opus-arbiter.md to match the generalized arbiter

**Files:**
- Modify: `plugins/tribunal-review/agents/opus-arbiter.md`

- [ ] **Step 1: Update the input-format section**

Replace the "Input Format" list (currently "1. Codex ... 2. Gemini ...") with:
```markdown
You receive JSON reviews from up to four providers, passed inline:
1. **Codex** (OpenAI Codex CLI)
2. **Gemini** (Gemini CLI)
3. **GLM** (OpenCode Go — opencode-go/glm-5.1)
4. **DeepSeek** (OpenCode Go — opencode-go/deepseek-v4-pro)

All four are equal advisory peers. A finding reported by ≥2 providers is CONSENSUS.
```

- [ ] **Step 2: Update Step 2 conflict table, degraded-input, confidence ranges, and output schema**

Apply the same replacements as SKILL.md Task 5 Steps 1-4 to the corresponding sections of `opus-arbiter.md` (conflict table with ≥2 = CONSENSUS, degraded input for "subset/all failed", confidence ranges with SINGLE, and the provider-keyed output JSON schema with `providers` array). Use the identical text/JSON shown in Task 5 so the two files stay in sync.

- [ ] **Step 3: Commit**

```bash
git add plugins/tribunal-review/agents/opus-arbiter.md
git commit -m "docs(tribunal-review): sync opus-arbiter.md with N-provider arbiter"
```

---

## Task 7: Add the opencode-reviewer.md documentation stub

**Files:**
- Create: `plugins/tribunal-review/agents/opencode-reviewer.md`

- [ ] **Step 1: Create the file**

```markdown
---
name: opencode-reviewer
description: Invokes OpenCode Go models (GLM-5.1, DeepSeek-V4-Pro) for independent code review. Returns structured JSON findings. Use in tribunal multi-provider review workflow.
tools: Bash
model: haiku
color: cyan
---

> **Note**: The `tribunal-loop` skill executes the OpenCode review scripts directly via Bash
> (no Task agent spawn). This file documents the standalone reviewer and is kept for testing.

You are an OpenCode CLI wrapper. Your ONLY job is to run ONE bash command and return its stdout.

## Strict Rules

- Use exactly **1 Bash tool call** — the script below
- Do **NOT** run any other commands before or after
- Do **NOT** read any files
- Return **ONLY** the stdout from the script

## Models

Two reviewers run via the user's OpenCode Go subscription:
- `opencode-go/glm-5.1` (provider field: `glm`)
- `opencode-go/deepseek-v4-pro` (provider field: `deepseek`)

Each runs read-only via `--agent plan`, receives the diff inline, and emits findings JSON
wrapped between `===TRIBUNAL_JSON_BEGIN===` / `===TRIBUNAL_JSON_END===` markers. See the
`tribunal-loop` SKILL.md "Bash call 3" and "Bash call 4" blocks for the exact scripts.

## Error Handling
If the script fails because OpenCode is not installed, return:
```json
{"error": "OpenCode CLI not found. Install from: https://opencode.ai"}
```
```

- [ ] **Step 2: Commit**

```bash
git add plugins/tribunal-review/agents/opencode-reviewer.md
git commit -m "docs(tribunal-review): add opencode-reviewer agent stub"
```

---

## Task 8: Update SKILL.md prose (providers, trust hierarchy, quick reference)

**Files:**
- Modify: `plugins/tribunal-review/skills/tribunal-loop/SKILL.md:1-16, 319-337`

- [ ] **Step 1: Update the description + intro + Providers list**

Replace the intro lines (8-15) so they read:
```markdown
Multi-provider code review. Codex (GPT-5.3) + Gemini (3 Pro Preview) + OpenCode GLM-5.1 + OpenCode DeepSeek-V4-Pro review in parallel, Opus arbitrates inline.

3-step workflow: pre-flight, parallel review, inline arbitration.

## Providers
- **Codex** (GPT-5.3) - comprehensive review
- **Gemini** (3 Pro Preview) - comprehensive review + web/CVE search
- **GLM** (opencode-go/glm-5.1) - comprehensive review (OpenCode Go)
- **DeepSeek** (opencode-go/deepseek-v4-pro) - comprehensive review (OpenCode Go)
- **Opus** (4.5) - final arbiter (runs inline, no agent spawn)
```

- [ ] **Step 2: Replace the Trust Hierarchy section**

Replace the "Trust Hierarchy" ascii block + sentence with:
```markdown
## Trust Hierarchy

```
OPUS 4.5 (Final authority, runs inline)
    |
Codex · Gemini · GLM · DeepSeek (equal advisory peers — verify findings)
```

The four reviewers are equal peers; a finding flagged by ≥2 is CONSENSUS. Opus can override any reviewer finding.
```

- [ ] **Step 3: Update the Quick Reference table**

Replace the table row so "Tool Calls" reads `4 (parallel Bash)`:
```markdown
| Mode | Steps | Tool Calls | Agent Spawns |
|------|-------|------------|-------------|
| Default (review) | 3 | 4 (parallel Bash) | 0 |
```

- [ ] **Step 4: Commit**

```bash
git add plugins/tribunal-review/skills/tribunal-loop/SKILL.md
git commit -m "docs(tribunal-review): update prose for four-reviewer panel"
```

---

## Task 9: Version bump and metadata

**Files:**
- Modify: `plugins/tribunal-review/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump plugin.json**

Set `"version": "0.2.0"`, update description and keywords:
```json
{
  "name": "tribunal-review",
  "version": "0.2.0",
  "description": "Multi-provider code review with Codex, Gemini, OpenCode (GLM + DeepSeek), and Opus arbitration",
  "author": { "name": "Andre Paat" },
  "repository": "https://github.com/paat/claude-plugins",
  "license": "MIT",
  "keywords": ["code-review", "multi-provider", "codex", "gemini", "opencode", "glm", "deepseek", "tribunal"]
}
```

- [ ] **Step 2: Bump marketplace.json**

In the root `.claude-plugin/marketplace.json`, find the `tribunal-review` entry and set its `version` to `0.2.0` (and `description` to match plugin.json if the entry carries one).

- [ ] **Step 3: Verify the two versions match**

Run:
```bash
python3 -c "import json; a=json.load(open('plugins/tribunal-review/.claude-plugin/plugin.json'))['version']; b=[p['version'] for p in json.load(open('.claude-plugin/marketplace.json'))['plugins'] if p['name']=='tribunal-review'][0]; print(a,b); assert a==b=='0.2.0'"
```
Expected: prints `0.2.0 0.2.0`, no assertion error.

- [ ] **Step 4: Commit**

```bash
git add plugins/tribunal-review/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(tribunal-review): bump to 0.2.0 for OpenCode reviewers"
```

---

## Task 10: Integration test — four reviewers + arbiter on a synthetic diff

**Files:** none (verification); creates and discards a scratch commit.

- [ ] **Step 1: Create a synthetic diff with a planted bug**

```bash
cat > /tmp/tribunal_demo.sh <<'EOF'
#!/bin/bash
process() { rm -rf "$1"/; }      # planted: unquoted/dangerous + no validation
divide() { echo $(( $1 / $2 )); } # planted: division by zero
EOF
git add /tmp/tribunal_demo.sh 2>/dev/null || true
# Stage inside the repo instead so it appears in the diff:
cp /tmp/tribunal_demo.sh plugins/tribunal-review/DEMO_DELETE_ME.sh
git add plugins/tribunal-review/DEMO_DELETE_ME.sh
git commit -q -m "test: planted-bug scratch file (to be reverted)"
```

- [ ] **Step 2: Run all four reviewer blocks**

Execute each of the four blocks (Codex, Gemini, GLM, DeepSeek) from the repo root and save outputs:
```bash
# Run each block, redirecting stdout to /tmp/rev-codex.json, /tmp/rev-gemini.json,
# /tmp/rev-glm.json, /tmp/rev-deepseek.json respectively, then:
for f in codex gemini glm deepseek; do
  echo "== $f =="; jq -e '.provider and (has("findings") or has("error"))' "/tmp/rev-$f.json" \
    && echo OK || echo "INVALID JSON: $f";
done
```
Expected: each file is valid JSON; at least GLM and DeepSeek (Go subscription present) return findings flagging the `rm -rf`/division-by-zero. Codex/Gemini may error if those CLIs aren't installed — that is acceptable and exercises degraded-input handling.

- [ ] **Step 3: Run arbitration inline**

Read the four JSON files and apply Step 3 of the skill manually (you are Opus). Confirm:
- The `rm -rf` finding reported by ≥2 providers is marked `CONSENSUS` with a `providers` array listing them.
- `provider_assessment` has all four keys; any failed CLI shows `"status": "failed"`.
- Verdict is BLOCK or NEEDS_WORK given the planted critical/high issues.

- [ ] **Step 4: Revert the scratch commit**

```bash
git revert --no-edit HEAD   # or: git reset --hard HEAD~1 if not yet pushed
rm -f /tmp/tribunal_demo.sh
ls plugins/tribunal-review/DEMO_DELETE_ME.sh 2>&1   # expect: No such file
```
Expected: the demo file is gone from the working tree and history is clean.

- [ ] **Step 5: Final verification**

Run:
```bash
git log --oneline origin/main..HEAD
git diff --stat origin/main...HEAD
```
Expected: commits for spec + each task; diff touches only `SKILL.md`, `opus-arbiter.md`, `opencode-reviewer.md`, `plugin.json`, `marketplace.json`, and the two docs files. No leftover demo file.

---

## Self-Review Notes

- **Spec coverage:** model selection (Tasks 2-3), 4 parallel reviewers (Tasks 2-4), same comprehensive prompt (Tasks 2-3), N-provider arbiter generalization (Tasks 5-6), read-only safety + JSON extraction (Tasks 1-3), metadata/docs (Tasks 7-9), testing (Tasks 1, 2, 3, 10). All spec sections map to a task.
- **Provider field values** are consistent everywhere: `codex`, `gemini`, `glm`, `deepseek`.
- **Model ids** consistent: `opencode-go/glm-5.1`, `opencode-go/deepseek-v4-pro`.
- **Sentinels** identical across blocks: `===TRIBUNAL_JSON_BEGIN===` / `===TRIBUNAL_JSON_END===`.
- **Truncation cap** consistent at 204800 bytes (200KB) for both OpenCode blocks; Codex keeps its existing 100KB cap (unchanged).
