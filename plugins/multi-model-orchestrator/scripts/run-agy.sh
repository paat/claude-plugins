#!/usr/bin/env bash
# run-agy.sh — dispatch a bounded task to the Google Antigravity CLI (agy) in print mode.
#
# implement: YOLO in the repository. review: diff-only from an empty directory. agy print
# mode enforces no read-only mode (`--mode plan` still edits files, and edits by absolute
# path need no permission), so a review leg that changed the repository exits 7.
#
# Exit codes: 0 ok; 2 usage; 3 nothing to review; 4 diff over the cap; 5 empty final
# message; 6 review without APPROVE/NEEDS_WORK; 7 review leg wrote to the repository;
# 75 transient or plan limit; 77 auth; 124 timeout; 127 agy/git/jq missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"

usage() {
  printf '%s\n' 'Usage: run-agy.sh --mode implement|review [--repo DIR|--dir DIR] [--base REF] [--model gemini-3.8-flash] [--effort low|medium|high] [--timeout SECONDS] [--out FILE]'
}

mode=""
repo_dir="$PWD"
base_ref=""
model="${MMO_AGY_MODEL:-gemini-3.8-flash}"
effort="${MMO_AGY_EFFORT:-medium}"
run_timeout=1200
output_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; mode="$2"; shift 2 ;;
    --repo|--dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repo_dir="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; base_ref="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; model="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; effort="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_timeout="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; output_file="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'run-agy: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$mode" in implement|review) ;; *) printf 'run-agy: --mode must be implement or review\n' >&2; exit 2 ;; esac
case "$model" in gemini-3.8-flash) ;; *) printf 'run-agy: unsupported model %s (current catalog: gemini-3.8-flash)\n' "$model" >&2; exit 2 ;; esac
case "$effort" in low|medium|high) ;; *) printf 'run-agy: unsupported effort %s (expected low|medium|high)\n' "$effort" >&2; exit 2 ;; esac
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'run-agy: timeout must be a positive integer\n' >&2; exit 2; }
if [ "$mode" = review ]; then
  [ -n "$base_ref" ] || { printf 'run-agy: review mode needs --base (the reviewer is handed the diff)\n' >&2; exit 2; }
  case "$base_ref" in -*) printf 'run-agy: --base must be a revision, not an option: %s\n' "$base_ref" >&2; exit 2 ;; esac
elif [ -n "$base_ref" ]; then
  printf 'run-agy: --base applies only to --mode review\n' >&2
  exit 2
fi
for tool in git jq agy; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'run-agy: %s not found\n' "$tool" >&2; exit 127; }
done
repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel)" || exit 2
[ "$mode" = review ] || mmo_guard_env_files run-agy "$repo_dir" || exit 2

runtime_dir="$(mktemp -d)"
trap 'rm -rf "$runtime_dir"' EXIT
request_file="$runtime_dir/request.txt"
prompt_file="$runtime_dir/prompt.txt"
diff_file="$runtime_dir/review.diff"
classify_file="$runtime_dir/provider-failure.txt"
[ -n "$output_file" ] || output_file="$runtime_dir/body.txt"
case "$output_file" in /*) ;; *) output_file="$PWD/$output_file" ;; esac
# Keep the transcript beside --out, as run-codex does, or in its own temp file.
if [ "$output_file" = "$runtime_dir/body.txt" ]; then
  stream_file="$(mktemp)"
else
  stream_file="${output_file}.stream"
fi

cat > "$request_file"
[ -s "$request_file" ] || { printf 'run-agy: empty prompt\n' >&2; exit 2; }

if [ "$mode" = review ]; then
  git -C "$repo_dir" rev-parse --verify "$base_ref^{commit}" >/dev/null || {
    printf 'run-agy: invalid base ref: %s\n' "$base_ref" >&2
    exit 2
  }
  git -C "$repo_dir" diff --no-ext-diff --binary "$base_ref" -- > "$diff_file"
  while IFS= read -r -d '' untracked; do
    # --no-index exits 1 when files differ (expected); 2+ is a real failure.
    set +e
    git -C "$repo_dir" diff --no-ext-diff --no-index --binary -- /dev/null "$untracked" >> "$diff_file" 2>/dev/null
    untracked_rc=$?
    set -e
    if [ "$untracked_rc" -gt 1 ]; then
      printf 'run-agy: failed to include untracked file in review diff: %s\n' "$untracked" >&2
      exit "$untracked_rc"
    fi
  done < <(git -C "$repo_dir" ls-files -z --others --exclude-standard)
  [ -s "$diff_file" ] || { printf 'run-agy: no diff to review\n' >&2; exit 3; }
  max_bytes="${MMO_REVIEW_DIFF_MAX_BYTES:-1048576}"
  [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || { printf 'run-agy: MMO_REVIEW_DIFF_MAX_BYTES must be positive\n' >&2; exit 2; }
  diff_bytes="$(wc -c < "$diff_file" | tr -d ' ')"
  [ "$diff_bytes" -le "$max_bytes" ] || {
    printf 'run-agy: diff is %s bytes; split or raise MMO_REVIEW_DIFF_MAX_BYTES=%s explicitly\n' "$diff_bytes" "$max_bytes" >&2
    exit 4
  }
  {
    printf '%s\n' 'You are an independent, read-only reviewer. Do not create or modify any file.'
    printf '%s\n' 'Return at most 10 actionable findings with severity, file:line, reachable failure, and a test.'
    printf '%s\n' 'End with one terminal line: APPROVE or NEEDS_WORK.'
    printf '\n## Task and acceptance\n'
    cat "$request_file"
    printf '\n## Unified diff from %s\n' "$base_ref"
    cat "$diff_file"
  } > "$prompt_file"
  work_dir="$runtime_dir/empty"
  mkdir "$work_dir"
  agy_args=()
  tree_before="$(mmo_tree_state "$repo_dir" "$(realpath -m "$output_file")")"
else
  {
    printf '%s\n' 'You are one fresh, bounded implementation worker.'
    printf '%s\n' 'Obey the task acceptance, allowed files, and test exactly. Do not broaden scope or commit.'
    printf '%s\n' 'Inspect your diff, run the named test, and stop when acceptance passes.'
    printf '\n## Task packet\n'
    cat "$request_file"
  } > "$prompt_file"
  work_dir="$repo_dir"
  agy_args=(--dangerously-skip-permissions)
fi

# The prompt goes in on stdin: as an argv word a large review diff would exceed MAX_ARG_STRLEN.
jq -cn --rawfile c "$prompt_file" '{event: "user", message: {content: $c}}' > "$runtime_dir/input.jsonl"

set +e
(cd "$work_dir" && mmo_leg_env GEMINI_API_KEY -- timeout -k 10 "$run_timeout" agy --input-format stream-json --output-format stream-json \
  --model "$model-$effort" ${agy_args[@]+"${agy_args[@]}"} \
  < "$runtime_dir/input.jsonl" > "$stream_file" 2> "$runtime_dir/stderr.txt")
rc=$?
set -e

result="$(jq -c 'select(.event == "result") | .result' "$stream_file" 2>/dev/null | tail -n 1 || true)"
status="$(printf '%s' "$result" | jq -r '.status // empty' 2>/dev/null || true)"
printf '%s' "$result" | jq -r '.response // empty' > "$output_file" 2>/dev/null || : > "$output_file"
{
  printf '%s' "$result" | jq -r '.error // empty' 2>/dev/null || true
  cat "$runtime_dir/stderr.txt"
} > "$classify_file"

if [ "$rc" -eq 0 ] && [ "$status" != SUCCESS ]; then
  printf 'run-agy: agy finished with status %s\n' "${status:-missing}" >&2
  rc=1
fi
if [ "$mode" = review ] && [ "$(mmo_tree_state "$repo_dir" "$(realpath -m "$output_file")")" != "$tree_before" ]; then
  printf 'run-agy: the review leg changed %s; inspect git status before trusting it\n' "$repo_dir" >&2
  rc=7
fi
if [ "$rc" -eq 0 ] && [ -z "$(tr -d '[:space:]' < "$output_file")" ]; then
  printf 'run-agy: missing or empty final-message artifact: %s\n' "$output_file" >&2
  rc=5
fi
if [ "$rc" -eq 0 ] && [ "$mode" = review ] && ! mmo_has_review_verdict "$output_file"; then
  printf 'run-agy: review completed without APPROVE or NEEDS_WORK\n' >&2
  rc=6
fi
if [ "$rc" -eq 0 ] || [ "$rc" -eq 6 ]; then
  cat "$output_file"
fi
mmo_finish run-agy "$rc" "$classify_file" \
  "model=$model" "effort=$effort" "mode=$mode" "log=$stream_file"
