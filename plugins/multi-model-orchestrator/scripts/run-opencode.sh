#!/usr/bin/env bash
# run-opencode.sh — dispatch a bounded task to the OpenCode CLI (v2, OpenCode Go models).
#
# implement: `--auto` in the repository. review: diff-only and advisory, `--agent plan`
# (edit tool denied) from an empty directory; a review leg that changed the repository
# exits 7. OpenCode v1 has a different CLI and is refused. Effort is the model variant.
#
# Exit codes: 0 ok; 2 usage; 3 nothing to review; 4 diff over the cap; 5 empty final
# message; 6 review without APPROVE/NEEDS_WORK; 7 review leg wrote to the repository;
# 75 plan/usage limit, transient, or model/variant/credential not routable; 77 auth;
# 124 timeout; 127 opencode v2/git/jq missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"
# shellcheck source=lib-outcomes.sh
. "$SCRIPT_DIR/lib-outcomes.sh"

usage() {
  printf '%s\n' 'Usage: run-opencode.sh --mode implement|review [--repo DIR|--dir DIR] [--base REF] [--model GO_MODEL] [--effort default|VARIANT] [--timeout SECONDS] [--out FILE]'
}

mode=""
repo_dir="$PWD"
base_ref=""
model="${MMO_OPENCODE_MODEL:-kimi-k3.1-pro}"
effort="${MMO_OPENCODE_EFFORT:-high}"
run_timeout=1200
output_file=""

mmo_outcome_init opencode

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; mode="$2"; shift 2 ;;
    --repo|--dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repo_dir="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; base_ref="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; model="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; effort="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_timeout="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; output_file="$2"; shift 2 ;;
    -h|--help) trap - EXIT; usage; exit 0 ;;
    *) printf 'run-opencode: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$mode" in implement|review) ;; *) printf 'run-opencode: --mode must be implement or review\n' >&2; exit 2 ;; esac
[[ "$model" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { printf 'run-opencode: unsupported model %s (expected a bare OpenCode Go model id)\n' "$model" >&2; exit 2; }
[ "$effort" = default ] || [[ "$effort" =~ ^[a-z]+$ ]] || { printf 'run-opencode: unsupported effort %s (expected default or a lowercase variant)\n' "$effort" >&2; exit 2; }
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'run-opencode: timeout must be a positive integer\n' >&2; exit 2; }
if [ "$mode" = review ]; then
  [ -n "$base_ref" ] || { printf 'run-opencode: review mode needs --base (the reviewer is handed the diff)\n' >&2; exit 2; }
  case "$base_ref" in -*) printf 'run-opencode: --base must be a revision, not an option: %s\n' "$base_ref" >&2; exit 2 ;; esac
elif [ -n "$base_ref" ]; then
  printf 'run-opencode: --base applies only to --mode review\n' >&2
  exit 2
fi
for tool in git jq opencode; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'run-opencode: %s not found\n' "$tool" >&2; exit 127; }
done
repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel)" || exit 2
mmo_guard_env_files run-opencode "$repo_dir" || exit 2
ver="$(mmo_leg_env 'OPENCODE_*' 'XDG_*' -- opencode --version 2>/dev/null)" || ver=""
if ! [[ "$ver" =~ ^[^0-9]*([0-9]+)\. ]] || [ "${BASH_REMATCH[1]}" -lt 2 ]; then
  printf 'run-opencode: needs OpenCode v2 (@opencode/cli); found %s\n' "${ver:-none}" >&2
  exit 127
fi

runtime_dir="$(mktemp -d)"
trap 'mmo_outcome_exit "$?"; rm -rf "$runtime_dir"' EXIT
request_file="$runtime_dir/request.txt"
prompt_file="$runtime_dir/prompt.txt"
diff_file="$runtime_dir/review.diff"
classify_file="$runtime_dir/provider-failure.txt"
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
[ -s "$request_file" ] || { printf 'run-opencode: empty prompt\n' >&2; exit 2; }

if [ "$mode" = review ]; then
  git -C "$repo_dir" rev-parse --verify "$base_ref^{commit}" >/dev/null || {
    printf 'run-opencode: invalid base ref: %s\n' "$base_ref" >&2
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
      printf 'run-opencode: failed to include untracked file in review diff: %s\n' "$untracked" >&2
      exit "$untracked_rc"
    fi
  done < <(git -C "$repo_dir" ls-files -z --others --exclude-standard)
  [ -s "$diff_file" ] || { printf 'run-opencode: no diff to review\n' >&2; exit 3; }
  max_bytes="${MMO_REVIEW_DIFF_MAX_BYTES:-1048576}"
  [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || { printf 'run-opencode: MMO_REVIEW_DIFF_MAX_BYTES must be positive\n' >&2; exit 2; }
  diff_bytes="$(wc -c < "$diff_file" | tr -d ' ')"
  [ "$diff_bytes" -le "$max_bytes" ] || {
    printf 'run-opencode: diff is %s bytes; split or raise MMO_REVIEW_DIFF_MAX_BYTES=%s explicitly\n' "$diff_bytes" "$max_bytes" >&2
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
  oc_args=(--agent plan)
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
  oc_args=(--auto)
fi

model_arg="opencode-go/$model"
[ "$effort" = default ] || model_arg="$model_arg#$effort"

run_cli() {
  cd "$work_dir" || return
  mmo_leg_env 'OPENCODE_*' 'XDG_*' -- timeout -k 10 "$run_timeout" opencode run --standalone --format json -m "$model_arg" "${oc_args[@]}" \
  < "$prompt_file" > "$stream_file" 2> "$runtime_dir/stderr.txt"
}
set +e
mmo_run direct "" "" run_cli
rc=$?
set -e

summary="$(jq -Rn '
  [inputs | fromjson? | objects] as $ev
  | ([$ev[] | select(.type == "step_start")] | last | .part.messageID) as $last
  | [$ev[] | select(.type == "step_finish")] as $fin
  | ([$ev[] | select(.type == "error")] | last | .error) as $err
  | {text: (if $last == null then "" else ([$ev[] | select(.type == "text" and .part.messageID == $last) | .part.text // ""] | join("\n")) end),
     finish: ([$fin[] | select(.part.messageID == $last)] | last | .part.reason // ""),
     err_type: ($err.type // ""),
     err_line: (if $err == null then "" else [$err.type, $err.status, $err.message | select(. != null) | tostring] | join(" ") end),
     steps: ($fin | length),
     tokens: ([$fin[] | .part.tokens // {} | (.input // 0) + (.output // 0) + (.reasoning // 0) + (.cache.read // 0) + (.cache.write // 0)] | add // 0)}
' "$stream_file" 2>/dev/null || true)"
sj() { printf '%s' "$summary" | jq -r "$1" 2>/dev/null || true; }
finish_reason="$(sj '.finish')"
err_type="$(sj '.err_type')"
[ "$(sj '.steps')" -gt 0 ] 2>/dev/null && mmo_outcome_tokens="$(sj '.tokens')"
sj '.text' > "$output_file"
{
  sj '.err_line'
  cat "$runtime_dir/stderr.txt"
} > "$classify_file"

if [ "$rc" -eq 0 ] && { [ -n "$err_type" ] || [ "$finish_reason" != stop ]; }; then
  printf 'run-opencode: opencode finished with %s\n' "${err_type:-finish reason ${finish_reason:-missing}}" >&2
  rc=1
fi
if [ "$rc" -eq 1 ] && [ "$err_type" = provider.auth ]; then
  rc=77
elif [ "$rc" -eq 1 ] && [ "$err_type" = provider.no-route ]; then
  printf 'run-opencode: model or variant %s is not routable here (unknown id or variant, or no OpenCode Go credential)\n' "$model_arg" >&2
  rc=75
fi
if [ "$mode" = review ] && [ "$(mmo_tree_state "$repo_dir" "$(realpath -m "$output_file")")" != "$tree_before" ]; then
  printf 'run-opencode: the review leg changed %s; inspect git status before trusting it\n' "$repo_dir" >&2
  rc=7
fi
if [ "$rc" -eq 0 ] && [ -z "$(tr -d '[:space:]' < "$output_file")" ]; then
  printf 'run-opencode: missing or empty final-message artifact: %s\n' "$output_file" >&2
  rc=5
fi
if [ "$rc" -eq 0 ] && [ "$mode" = review ] && ! mmo_has_review_verdict "$output_file"; then
  printf 'run-opencode: review completed without APPROVE or NEEDS_WORK\n' >&2
  rc=6
fi
if [ "$rc" -eq 0 ] || [ "$rc" -eq 6 ]; then
  if [ -n "$out_dev" ]; then cat "$output_file" > "$out_dev"; else cat "$output_file"; fi
fi
mmo_finish run-opencode "$rc" "$classify_file" \
  "model=$model" "effort=$effort" "mode=$mode" "log=$stream_file"
