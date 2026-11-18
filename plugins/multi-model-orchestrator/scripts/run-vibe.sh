#!/usr/bin/env bash
# run-vibe.sh — dispatch a bounded task to the Mistral Vibe CLI (`vibe`, headless).
#
# implement runs --auto-approve in the trusted repository. advise and review enable
# read_file only and do not trust the folder: vibe's default agent edits files without
# asking, a headless run denies every call that needs approval, and an untrusted folder
# loads no project .vibe/ config or hooks. They have no shell and no search: the reviewer
# is handed the diff and reads files by path. A non-implement leg that changed the
# repository exits 7.
#
# Unset passes neither --model nor --thinking, so the installed CLI selects both.
# Flags and the export/stream shapes were checked against vibe 3.1.3 on 2026-11-18.
#
# Exit codes: 0 ok; 2 usage; 3 nothing to review; 4 diff over the cap; 5 empty final
# message; 6 review without APPROVE/NEEDS_WORK; 7 leg wrote to the repository; 75 transient
# or plan limit; 76 implement leg hit the turn cap (work may be partial); 77 auth or no
# API key; 78 any other leg hit the turn cap without a report; 124 timeout; 127 vibe 3+,
# git or jq missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"
# shellcheck source=lib-outcomes.sh
. "$SCRIPT_DIR/lib-outcomes.sh"

usage() {
  printf '%s\n' 'Usage: run-vibe.sh --mode advise|implement|review [--repo DIR|--dir DIR] [--base REF] [--model default|ALIAS] [--effort default|off|low|medium|high|xhigh|max] [--max-turns N] [--timeout SECONDS] [--out FILE]'
}

mode=""
repo_dir="$PWD"
base_ref="HEAD"
model="${MMO_VIBE_MODEL:-default}"
effort="${MMO_VIBE_EFFORT:-default}"
max_turns="${MMO_VIBE_MAX_TURNS:-50}"
run_timeout=1200
output_file=""

mmo_outcome_init vibe

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; mode="$2"; shift 2 ;;
    --repo|--dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repo_dir="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; base_ref="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; model="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; effort="$2"; shift 2 ;;
    --max-turns) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; max_turns="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_timeout="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; output_file="$2"; shift 2 ;;
    -h|--help) trap - EXIT; usage; exit 0 ;;
    *) printf 'run-vibe: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

mmo_clear_out "$output_file"
case "$mode" in advise|implement|review) ;; *) printf 'run-vibe: --mode must be advise, implement, or review\n' >&2; exit 2 ;; esac
[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { printf 'run-vibe: unsupported model %s (expected default or a vibe model alias)\n' "$model" >&2; exit 2; }
case "$effort" in default|off|low|medium|high|xhigh|max) ;; *) printf 'run-vibe: unsupported effort %s (expected default|off|low|medium|high|xhigh|max)\n' "$effort" >&2; exit 2 ;; esac
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'run-vibe: timeout must be a positive integer\n' >&2; exit 2; }
[[ "$max_turns" =~ ^[1-9][0-9]*$ ]] && [ "$max_turns" -le 200 ] || { printf 'run-vibe: max turns must be an integer from 1 to 200\n' >&2; exit 2; }
case "$base_ref" in -*) printf 'run-vibe: --base must be a revision, not an option: %s\n' "$base_ref" >&2; exit 2 ;; esac
for tool in git jq vibe; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'run-vibe: %s not found\n' "$tool" >&2; exit 127; }
done
repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel)" || exit 2
# Every mode: read_file reaches an untracked .env* in the repository.
mmo_guard_env_files run-vibe "$repo_dir" || exit 2
# vibe 2 has no --prompt-file, --output-dir or run export.
ver="$(mmo_leg_env 'VIBE_*' -- vibe --version 2>/dev/null)" || ver=""
if ! [[ "$ver" =~ ^[^0-9]*([0-9]+)\. ]] || [ "${BASH_REMATCH[1]}" -lt 3 ]; then
  printf 'run-vibe: needs Mistral Vibe 3 or newer; found %s\n' "${ver:-none}" >&2
  exit 127
fi

runtime_dir="$(mktemp -d)"
trap 'mmo_outcome_exit "$?"; rm -rf "$runtime_dir"' EXIT
request_file="$runtime_dir/request.txt"
prompt_file="$runtime_dir/prompt.txt"
diff_file="$runtime_dir/review.diff"
classify_file="$runtime_dir/provider-failure.txt"
export_file="$runtime_dir/export/export.json"
[ -n "$output_file" ] || output_file="$runtime_dir/body.txt"
out_dev=""
case "$output_file" in
  /dev/*) out_dev="$output_file"; output_file="$runtime_dir/body.txt" ;;
  /*) ;;
  *) output_file="$PWD/$output_file" ;;
esac
# Keep the event stream beside --out, as run-agy does, or in its own temp file.
if [ "$output_file" = "$runtime_dir/body.txt" ]; then
  stream_file="$(mktemp)"
else
  stream_file="${output_file}.stream"
fi

cat > "$request_file"
[ -s "$request_file" ] || { printf 'run-vibe: empty prompt\n' >&2; exit 2; }

case "$mode" in
  review)
    mmo_review_diff run-vibe "$repo_dir" "$base_ref" "$diff_file" "$output_file"
    {
      printf '%s\n' 'You are an independent, read-only reviewer. Do not create or modify any file.'
      printf '%s\n' 'Your only tool is read_file: read context by path; there is no shell and no search.'
      printf '%s\n' 'Return at most 10 actionable findings with severity, file:line, reachable failure, and a test.'
      printf '%s\n' 'End with one terminal line: APPROVE or NEEDS_WORK.'
      printf '\n## Task and acceptance\n'
      cat "$request_file"
      printf '\n## Unified diff from %s\n' "$base_ref"
      cat "$diff_file"
    } > "$prompt_file"
    ;;
  advise)
    {
      printf '%s\n' 'You are a read-only adviser. Do not create or modify any file.'
      printf '%s\n' 'Your only tool is read_file: read context by path; there is no shell and no search.'
      printf '%s\n' 'Return only constraints, risks, and the minimal file map needed for the question.'
      printf '\n## Question\n'
      cat "$request_file"
    } > "$prompt_file"
    ;;
  implement)
    {
      printf '%s\n' 'You are one fresh, bounded implementation worker.'
      printf '%s\n' 'Obey the task acceptance, allowed files, and test exactly. Do not broaden scope or commit.'
      printf '%s\n' 'Inspect your diff, run the named test, and stop when acceptance passes.'
      printf '\n## Task packet\n'
      cat "$request_file"
    } > "$prompt_file"
    ;;
esac

vibe_args=(--prompt-file "$prompt_file" --output streaming --max-turns "$max_turns"
  --output-dir "$runtime_dir/export")
if [ "$mode" = implement ]; then
  vibe_args+=(--trust --auto-approve)
else
  vibe_args+=(--enabled-tools read_file)
  tree_before="$(mmo_tree_state "$repo_dir" "$output_file")"
fi
[ "$model" = default ] || vibe_args+=(--model "$model")
[ "$effort" = default ] || vibe_args+=(--thinking "$effort")

run_cli() {
  cd "$repo_dir" || return
  mmo_leg_env 'VIBE_*' MISTRAL_API_KEY -- timeout -k 10 "$run_timeout" vibe "${vibe_args[@]}" \
  < /dev/null > "$stream_file" 2> "$runtime_dir/stderr.txt"
}
set +e
mmo_run direct "" "" run_cli
rc=$?
set -e
# Provider exits must not impersonate runner validation codes.
rc=$(mmo_provider_rc "$rc")

xj() { jq -r "$1" "$export_file" 2>/dev/null || true; }
outcome="$(xj '.outcome // empty')"
served="$(xj '.config.active_model // empty')"
mmo_outcome_served_model="$served"
mmo_outcome_tokens="$(xj '.usage.total_tokens // empty')"
# The stream holds every assistant message of the run; the last committed one is the answer.
: > "$output_file"
if [ "$outcome" = finished ]; then
  jq -rs '[.[] | select(.type == "message" and .role == "assistant" and .outcome.type == "committed")] | last
    | [.content[]? | select(.type == "text") | .text] | join("")' "$stream_file" > "$output_file" 2>/dev/null || : > "$output_file"
fi
err_msg="$(xj '.error.message // empty')"
{
  printf '%s\n' "$err_msg"
  cat "$runtime_dir/stderr.txt"
} > "$classify_file"
denied="$(grep -c '^Tool call denied: ' "$runtime_dir/stderr.txt" || true)"
[ "$denied" -eq 0 ] || printf 'run-vibe: vibe denied %s tool call(s) in --mode %s\n' "$denied" "$mode" >&2

if [ "$rc" -eq 0 ] && [ "$outcome" != finished ]; then
  printf 'run-vibe: vibe exited 0 without a finished run export (outcome: %s)\n' "${outcome:-missing}" >&2
  rc=1
fi
if [ "$rc" -eq 1 ] && [ "$outcome" = turn_limit ]; then
  if [ "$mode" = implement ]; then
    printf 'run-vibe: turn cap reached (%s); work may be partial and uncommitted — salvage like a timeout, or raise --max-turns\n' "$max_turns" >&2
    rc=76
  else
    printf 'run-vibe: turn cap reached (%s) in --mode %s; no report — raise --max-turns or narrow the packet\n' "$max_turns" "$mode" >&2
    rc=78
  fi
elif [ "$rc" -eq 1 ] && grep -q 'Missing MISTRAL_API_KEY' "$classify_file"; then
  printf 'run-vibe: no Mistral API key in this home; run `vibe --setup` once\n' >&2
  rc=77
elif [ "$rc" -eq 1 ]; then
  # Name the cause: an unknown --model alias, a config error, a provider failure.
  [ -n "$err_msg" ] || err_msg="$(tail -n 1 "$runtime_dir/stderr.txt")"
  printf 'run-vibe: vibe failed (outcome: %s): %s\n' "${outcome:-no export}" "${err_msg:0:500}" >&2
fi
if [ "$mode" != implement ] && [ "$(mmo_tree_state "$repo_dir" "$output_file")" != "$tree_before" ]; then
  printf 'run-vibe: the %s leg changed %s; inspect git status before trusting it\n' "$mode" "$repo_dir" >&2
  rc=7
fi
if [ "$rc" -eq 0 ] && [ -z "$(tr -d '[:space:]' < "$output_file")" ]; then
  printf 'run-vibe: missing or empty final-message artifact: %s\n' "$output_file" >&2
  rc=5
fi
if [ "$rc" -eq 0 ] && [ "$mode" = review ] && ! mmo_has_review_verdict "$output_file"; then
  printf 'run-vibe: review completed without APPROVE or NEEDS_WORK\n' >&2
  rc=6
fi
if [ "$rc" -eq 0 ] || [ "$rc" -eq 6 ]; then
  if [ -n "$out_dev" ]; then cat "$output_file" > "$out_dev"; else cat "$output_file"; fi
fi
mmo_finish run-vibe "$rc" "$classify_file" \
  "model=${served:-$model}" "effort=$effort" "mode=$mode" "log=$stream_file"
