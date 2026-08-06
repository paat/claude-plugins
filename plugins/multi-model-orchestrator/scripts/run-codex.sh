#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"

usage() {
  printf '%s\n' 'Usage: run-codex.sh [--mode implement|review] [--dir DIR] [--model MODEL] [--effort LEVEL] [--timeout SECONDS] [--out FILE] [--stream-log FILE]'
}

valid_effort() {
  case "$1" in low|medium|high|xhigh|max|ultra) return 0 ;; *) return 1 ;; esac
}

valid_model() {
  case "$1" in gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna) return 0 ;; *) return 1 ;; esac
}

repo_dir="$PWD"
mode=implement
model="${MMO_CODEX_MODEL:-gpt-5.6-sol}"
effort="medium"
run_timeout=1200
final_file=""
stream_file=""
stream_log_set=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; mode="$2"; shift 2 ;;
    --dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repo_dir="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; model="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; effort="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_timeout="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; final_file="$2"; shift 2 ;;
    --stream-log) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; stream_file="$2"; stream_log_set=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'run-codex: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$mode" in implement|review) ;; *) printf 'run-codex: --mode must be implement or review\n' >&2; exit 2 ;; esac
valid_effort "$effort" || {
  printf 'run-codex: unsupported effort %s (expected low|medium|high|xhigh|max|ultra)\n' "$effort" >&2
  exit 2
}
valid_model "$model" || {
  printf 'run-codex: unsupported model %s (current catalog: gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna)\n' "$model" >&2
  exit 2
}
[ "$effort" != ultra ] || [ "$model" = gpt-5.6-sol ] || {
  printf 'run-codex: ultra is supported only with gpt-5.6-sol\n' >&2
  exit 2
}
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'run-codex: timeout must be a positive integer\n' >&2; exit 2; }
[ -d "$repo_dir" ] || { printf 'run-codex: directory not found: %s\n' "$repo_dir" >&2; exit 2; }
command -v codex >/dev/null 2>&1 || { printf 'run-codex: codex CLI not found\n' >&2; exit 127; }

prompt_file="$(mktemp)"
user_final=0
if [ -n "$final_file" ]; then
  user_final=1
else
  final_file="$(mktemp)"
fi
if [ "$stream_log_set" -eq 0 ]; then
  if [ "$user_final" -eq 1 ]; then
    stream_file="${final_file}.stream"
  else
    stream_file="$(mktemp)"
  fi
fi
if [ "$user_final" -eq 1 ]; then
  trap 'rm -f "$prompt_file"' EXIT
else
  trap 'rm -f "$prompt_file" "$final_file"' EXIT
fi
cat > "$prompt_file"
[ -s "$prompt_file" ] || { printf 'run-codex: empty prompt\n' >&2; exit 2; }

if [ "$mode" = review ]; then
  combined_file="$(mktemp)"
  {
    printf '%s\n' 'You are an independent, semantically read-only reviewer. Do not modify files or commit.'
    printf '%s\n' 'End with APPROVE or NEEDS_WORK.'
    printf '\n'
    cat "$prompt_file"
  } > "$combined_file"
  mv "$combined_file" "$prompt_file"
fi

set +e
timeout -k 10 "$run_timeout" codex exec \
  --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
  -C "$repo_dir" -m "$model" -c "model_reasoning_effort=\"$effort\"" \
  -o "$final_file" - < "$prompt_file" > "$stream_file" 2> "${stream_file}.stderr"
rc=$?
set -e

if [ "$rc" -eq 0 ] && [ ! -s "$final_file" ]; then
  printf 'run-codex: provider exited 0 without a final result\n' >&2
  rc=5
fi
if [ "$rc" -eq 0 ] && [ "$mode" = review ] && ! mmo_has_review_verdict "$final_file"; then
  printf 'run-codex: review completed without APPROVE or NEEDS_WORK\n' >&2
  rc=6
fi

# Expose body on success and on verdict-format failure (rc=6) so controllers
# can inspect useful review text; --out already holds the body either way.
if [ "$rc" -eq 0 ] || [ "$rc" -eq 6 ]; then
  cat "$final_file"
fi
printf 'run-codex: exit=%s model=%s effort=%s mode=%s log=%s\n' "$rc" "$model" "$effort" "$mode" "$stream_file" >&2
exit "$rc"
