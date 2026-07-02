#!/usr/bin/env bash
# Shared tribunal-review script helpers.
set -u

tribunal_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

tribunal_default_branch() {
  local branch
  branch="${TRIBUNAL_BASE_BRANCH:-}"
  [ -n "$branch" ] || branch="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
  [ -n "$branch" ] || branch="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)"
  [ -n "$branch" ] || branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  printf '%s\n' "${branch:-main}"
}

tribunal_base_ref() {
  local branch
  branch="$(tribunal_default_branch)"
  printf '%s\n' "${TRIBUNAL_BASE_REF:-origin/$branch}"
}

tribunal_json_string() {
  jq -Rn --arg v "$1" '$v'
}

tribunal_disabled() {
  local provider="$1" note="$2"
  jq -nc --arg p "$provider" --arg n "$note" '{provider:$p,status:"disabled",note:$n}'
}

tribunal_error() {
  local provider="$1" message="$2"
  jq -nc --arg p "$provider" --arg e "$message" '{provider:$p,error:$e}'
}

tribunal_empty() {
  local provider="$1" model="${2:-default}" base_ref="${3:-}"
  jq -nc --arg p "$provider" --arg m "$model" --arg b "$base_ref" \
    '{provider:$p,model:$m,findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10.0,verdict:"APPROVE",note:("No changes detected vs " + $b)}}'
}

tribunal_prepare_diff() {
  local out="$1" base_ref
  base_ref="$(tribunal_base_ref)"
  if ! git rev-parse --verify --quiet "$base_ref" >/dev/null; then
    git fetch origin "$(tribunal_default_branch)" --quiet 2>/dev/null || return 2
  fi
  local full max size
  full="$out.full"
  max="${TRIBUNAL_DIFF_LIMIT_BYTES:-524288}"
  git diff "$base_ref"...HEAD > "$full" || return 1
  size="$(wc -c < "$full" | tr -d ' ')"
  if [ -n "$size" ] && [ "$size" -gt "$max" ]; then
    head -c "$max" "$full" > "$out"
    printf '%s\n' "$size" > "$out.truncated"
  else
    mv "$full" "$out"
    rm -f "$out.truncated"
  fi
  rm -f "$full"
}

tribunal_context_block() {
  local repo_root="$1" out="$2"
  : > "$out"
  if [ -f "$repo_root/AGENTS.md" ]; then
    {
      printf '## Project Conventions (from AGENTS.md)\n'
      head -c 16384 "$repo_root/AGENTS.md"
      printf '\n'
    } >> "$out"
  fi
  if [ -f "$repo_root/reachability.md" ]; then
    {
      printf '\n## Production Reachability (from reachability.md)\n'
      head -c 8192 "$repo_root/reachability.md"
      printf '\n'
    } >> "$out"
  fi
}

tribunal_review_prompt() {
  local provider="$1" diff_path="$2" context_path="$3" mode="$4"
  local trunc_note=""
  if [ -f "$diff_path.truncated" ]; then
    trunc_note="NOTE: Diff was truncated from $(cat "$diff_path.truncated") bytes to ${TRIBUNAL_DIFF_LIMIT_BYTES:-524288} bytes for context size. Review what is provided."
  fi
  cat <<PROMPT
You are a senior code reviewer for the tribunal-review panel.

Provider: $provider
Mode: $mode
Diff file: $diff_path

First read the unified diff from the diff file above, an attached file, or STDIN as provided by the runner. Review only changed lines. In repo-walking mode you may open related files read-only to verify cross-file effects. Do not modify files.

$trunc_note

Report JSON only:
{
  "provider": "$provider",
  "model": "default",
  "findings": [
    {
      "severity": "critical|high|medium|low",
      "category": "logic|security|performance|quality|edge-case|architecture|testing",
      "file": "path/to/file",
      "line": 42,
      "title": "brief title",
      "description": "what is wrong and why it matters",
      "suggestion": "concrete fix",
      "confidence": 0.9
    }
  ],
  "summary": {
    "total_findings": 0,
    "critical": 0,
    "high": 0,
    "medium": 0,
    "low": 0,
    "quality_score": 10.0,
    "verdict": "APPROVE|NEEDS_WORK|BLOCK"
  }
}

Rules:
- Only report actionable findings with confidence >= 0.7.
- Critical/high findings must prove production reachability, material impact, and that the change caused or exposed the issue.
- Watch for logic, security, performance, architecture, edge cases, testing gaps, silent failures, unawaited async, webhook/payment traps, and money-as-float.
- Use exact file paths from diff headers and line numbers from the changed hunk.
- In repo-walking mode, open only the files needed to verify a finding — do not scan the tree.
- If context is insufficient, lower confidence or omit the finding.

$(cat "$context_path" 2>/dev/null)
PROMPT
}

tribunal_extract_json_object() {
  sed 's/^```json//;s/^```//' | awk '
    BEGIN { seen=0 }
    /\{/ { seen=1 }
    seen { print }
  ' | sed -n 'H;${x;s/^[^{]*//;s/[^}]*$//;p;}'
}
