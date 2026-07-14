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
  git diff "$base_ref"...HEAD --no-ext-diff --no-textconv > "$full" || return 1
  git diff --name-only -z "$base_ref"...HEAD --no-ext-diff --no-textconv > "$out.paths" || return 1
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

# Validate one leg's extracted review JSON (read from stdin) and emit it, or
# emit a provider error. A blocking verdict (BLOCK/NEEDS_WORK) with zero findings
# is self-contradictory: per the arbitration contract a blocking verdict must be
# backed by a proven finding, so an empty one means the provider was blind to the
# code (sandboxed/degraded), not that the change is truly blocked. Counting it as
# a real review silently drops the provider from the panel (issue #171).
# $1 provider  $2 optional hint appended to the vacuous-verdict error message.
tribunal_emit_review() {
  local provider="$1" hint="${2:-}" json verdict
  json="$(cat)"
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    tribunal_error "$provider" "unparseable $provider output"
    return
  fi
  if printf '%s' "$json" | jq -e '
      (((.findings // []) | length) == 0)
      and (((.summary.verdict // "APPROVE") | tostring | gsub("^\\s+|\\s+$"; "") | ascii_upcase) as $v
           | ($v == "BLOCK" or $v == "NEEDS_WORK"))
    ' >/dev/null 2>&1; then
    verdict="$(printf '%s' "$json" | jq -r '.summary.verdict // "?"')"
    tribunal_error "$provider" "vacuous verdict ($verdict with 0 findings): a blocking verdict must carry a finding; provider likely blind to the repo (sandbox/degraded), excluded from quorum${hint:+ — $hint}"
    return
  fi
  if ! printf '%s' "$json" | jq -e '(.findings | type) == "array" and (.summary | type) == "object"' >/dev/null 2>&1; then
    tribunal_error "$provider" "provider output omitted the review findings/summary envelope"
    return
  fi
  # Provider identity belongs to the wrapper, not model-authored JSON. The
  # aggregate evidence runner relies on this assignment when it seals each leg.
  printf '%s\n' "$json" | jq -c --arg provider "$provider" '.provider = $provider | del(.status, .error)'
}

# Mark findings whose position cannot exist: a missing/mistyped file field, a
# file outside the reviewed change set, a non-positive/non-integer line, a
# line beyond the target file's length at HEAD, or a positioned finding in a
# file that no longer exists at HEAD. Providers sometimes emit
# unified-diff/prompt-global positions instead of target-file line numbers
# (issue #259); marked findings still flow to the arbiter, but the evidence
# defect is explicit instead of silent. Paths travel NUL-delimited and the
# lookup tables travel via a temp file, so C-quoted/unusual filenames and
# argv size limits cannot corrupt or abort the check.
# $1 repo root  $2 diff file ("$2.paths" holds the NUL-delimited changed list)
# stdin: one leg JSON object  stdout: same object with line_check marks
tribunal_line_check() {
  local root="$1" diff_file="$2" json aux f n
  json="$(cat)"
  if ! printf '%s' "$json" | jq -e '(.findings? | type) == "array"' >/dev/null 2>&1; then
    printf '%s\n' "$json"
    return
  fi
  aux="$(mktemp)"
  {
    if [ -s "$diff_file.paths" ]; then
      jq -Rs 'split("\u0000") | map(select(length > 0))' < "$diff_file.paths"
    else
      printf '[]\n'
    fi
    printf '%s' "$json" | jq -j '[.findings[]?.file? | strings] | unique | map(. + "\u0000") | join("")' \
      | while IFS= read -r -d '' f; do
          case "$f" in /*) continue ;; esac
          case "/$f/" in */../*) continue ;; esac
          if git -C "$root" cat-file -e "HEAD:$f" 2>/dev/null; then
            n="$(git -C "$root" cat-file -p "HEAD:$f" 2>/dev/null | grep -c '')" || n=0
          else
            n=-1
          fi
          jq -cn --arg f "$f" --argjson n "$n" '{($f): $n}'
        done | jq -s 'add // {}'
  } | jq -cs '{changed: .[0], counts: (.[1] // {})}' > "$aux"
  printf '%s' "$json" | jq -c --slurpfile aux "$aux" '
    $aux[0].changed as $changed | $aux[0].counts as $counts |
    .findings = [ .findings[] | . as $f |
      if (($f.file? | type) != "string") then
        .line_check = "malformed finding coordinates"
      elif (($changed | length) > 0) and (($changed | index($f.file)) == null) then
        .line_check = "file not in reviewed diff"
      elif ($f.line? == null) then .
      elif (($f.line | type) != "number") or ($f.line < 1) or ($f.line != ($f.line | floor)) then
        .line_check = "invalid line number"
      elif ($counts[$f.file] == -1) then
        .line_check = "file missing at HEAD"
      elif ($counts[$f.file] != null) and ($f.line > $counts[$f.file]) then
        .line_check = ("line out of bounds: file has " + ($counts[$f.file] | tostring) + " lines")
      else . end ]'
  rm -f "$aux"
}

tribunal_extract_json_object() {
  sed 's/^```json//;s/^```//' | awk '
    BEGIN { seen=0 }
    /\{/ { seen=1 }
    seen { print }
  ' | sed -n 'H;${x;s/^[^{]*//;s/[^}]*$//;p;}'
}
