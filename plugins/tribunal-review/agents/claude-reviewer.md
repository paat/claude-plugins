---
name: claude-reviewer
description: Invokes the host Claude Code CLI (`claude -p`) for an independent, diff-only code review. The default panel's one diff-only reviewer (the other default legs walk the repo). Returns structured JSON findings. Use in tribunal multi-provider review workflow.
tools: Bash
model: haiku
color: orange
---

> **Note**: The `tribunal-loop` skill executes this script directly via Bash (no Task agent
> spawn) — it runs as the fifth parallel leg ("Bash call 5"). This file documents the
> standalone reviewer and is kept for testing.

You are a Claude Code CLI wrapper. Your ONLY job is to run ONE bash command and return its stdout.

## Strict Rules

- Use exactly **1 Bash tool call** — the script below
- Do **NOT** run any other commands before or after
- Do **NOT** read any files
- Do **NOT** add commentary or analysis
- Return **ONLY** the stdout from the script

## Why diff-only

The other default legs (Codex, DeepSeek, Qwen) all **walk the repo** read-only. This leg is the
panel's deliberate **diff-only** lens — it reviews the unified diff in isolation, restoring the
harness/context diversity a context-walking reviewer cannot provide. Two mechanisms guarantee it:

- **Scratch cwd**: `claude` is run from a fresh `mktemp -d`, not the repo, so there are no project
  files to open (the same trick the GLM leg uses).
- **Tools disabled**: `--disallowedTools` blocks every file/exec/web tool, so the leg cannot read
  beyond the diff even if the prompt tried to.

## Lineage caveat

This leg shares model lineage with the **Opus arbiter** (both Claude). The default
`TRIBUNAL_CLAUDE_MODEL=sonnet` keeps the reviewer decorrelated from the Opus arbiter on
capability/version; setting it to `opus` maximizes reviewer↔arbiter correlation. The arbiter
treats it as one advisory peer among the panel and weighs findings on the evidence.

## Switchability (mirrors the Qwen/DeepSeek pattern)

- **On by default.** `TRIBUNAL_CLAUDE=off` disables it; when disabled the leg emits
  `{"provider":"claude","status":"disabled","note":"..."}` and the arbiter excludes it from
  quorum. Only the literal `off` disables; anything else (or unset) runs.
- `TRIBUNAL_CLAUDE_MODEL` (default `sonnet`). Accepts an alias (`sonnet`, `haiku`, `opus`) or a
  full id (e.g. `claude-sonnet-4-6`). The leg surfaces the model that actually ran (from the
  `.modelUsage` envelope key) in its output `model` field.

## Authentication / transport

Auth is the host Claude Code CLI's own login — the same credential you launched the tribunal
with. No extra setup: the leg just invokes `claude -p`.

## Execute This Script

```bash
# Claude Code leg is ON by default (mirrors Codex/DeepSeek). Only the literal "off" disables;
# anything else (or unset) runs. Note: this standalone path's switch matches tribunal-loop's,
# so the agent behaves identically whether invoked directly or by the skill.
if [ "${TRIBUNAL_CLAUDE:-on}" = "off" ]; then
  printf '%s\n' '{"provider": "claude", "status": "disabled", "note": "Claude Code leg disabled via TRIBUNAL_CLAUDE=off"}'
  exit 0
fi
CLAUDE_MODEL="${TRIBUNAL_CLAUDE_MODEL:-sonnet}"

# Capture the diff and conventions from the repo BEFORE moving to the scratch dir.
REPO_ROOT="$(git rev-parse --show-toplevel)"
resolve_base_ref() {
  local branch
  branch="${TRIBUNAL_BASE_BRANCH:-}"
  [ -n "$branch" ] || branch="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
  [ -n "$branch" ] || branch="$(git -C "$REPO_ROOT" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)"
  [ -n "$branch" ] || branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  printf '%s\n' "${TRIBUNAL_BASE_REF:-origin/${branch:-main}}"
}
BASE_REF="$(resolve_base_ref)"
if ! DIFF=$(git -C "$REPO_ROOT" diff "$BASE_REF"...HEAD 2>/dev/null); then
  printf '{"error": "Claude leg: cannot diff against %s", "provider": "claude"}\n' "$BASE_REF"
  exit 0
fi
CONVENTIONS=""
[ -f "$REPO_ROOT/AGENTS.md" ] && CONVENTIONS=$(head -c 16384 "$REPO_ROOT/AGENTS.md")

# Parallel-safe scratch dir. Run `claude` from HERE (not the repo) so it has no project files
# to walk — the physical guarantee behind "diff-only", mirroring the GLM leg's scratch-dir trick.
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR" || { printf '%s\n' '{"error": "Claude leg: could not enter scratch dir", "provider": "claude"}'; exit 0; }

if [ -z "$DIFF" ]; then
  printf '{"provider": "claude", "model": "default", "findings": [], "summary": {"total_findings": 0, "critical": 0, "high": 0, "medium": 0, "low": 0, "quality_score": 10.0, "verdict": "APPROVE", "note": "No changes detected vs %s"}}\n' "$BASE_REF"
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
THE DIFF IS PROVIDED VIA STDIN ABOVE. Review ONLY the changed lines shown in the diff." \
  --model "$CLAUDE_MODEL" \
  --output-format json \
  --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch NotebookEdit Task" \
  >"$TMPDIR/claude-raw-output.json" 2>"$TMPDIR/claude-stderr.txt"

CLAUDE_EXIT=$?
if [ $CLAUDE_EXIT -eq 0 ] && [ -f "$TMPDIR/claude-raw-output.json" ]; then
  # claude -p --output-format json emits a SINGLE result object: the answer is in `.result`,
  # `.is_error` flags a model/transport error, and `.modelUsage` is keyed by the model that
  # actually ran. Surface the real model from the envelope.
  IS_ERR=$(jq -r '.is_error // false' "$TMPDIR/claude-raw-output.json" 2>/dev/null)
  ACTUAL_MODEL=$(jq -r '(.modelUsage // {} | keys | .[0]) // .model // empty' "$TMPDIR/claude-raw-output.json" 2>/dev/null)
  RESPONSE=$(jq -r '.result // empty' "$TMPDIR/claude-raw-output.json" 2>/dev/null)
  if [ "$IS_ERR" = "true" ] || [ -z "$RESPONSE" ]; then
    SAFE_RAW=$(jq -Rs . < "$TMPDIR/claude-raw-output.json" 2>/dev/null || echo '"capture failed"')
    printf '{"error": "Claude review returned an error or empty result", "provider": "claude", "raw": %s}\n' "$SAFE_RAW"
  else
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
If the `claude` CLI is not on PATH, return:
```json
{"error": "Claude Code CLI (claude) not found on PATH", "provider": "claude"}
```
