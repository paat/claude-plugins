#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: run-codex.sh [--dir DIR] [--model MODEL] [--effort LEVEL] [--timeout SECONDS] [--out FILE]'
}

valid_effort() {
  case "$1" in low|medium|high|xhigh|max|ultra) return 0 ;; *) return 1 ;; esac
}

repo_dir="$PWD"
model="${MMO_CODEX_MODEL:-gpt-5.6-sol}"
effort="medium"
run_timeout=1200
stream_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repo_dir="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; model="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; effort="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_timeout="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; stream_file="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'run-codex: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

valid_effort "$effort" || {
  printf 'run-codex: unsupported effort %s (expected low|medium|high|xhigh|max|ultra)\n' "$effort" >&2
  exit 2
}
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'run-codex: timeout must be a positive integer\n' >&2; exit 2; }
[ -d "$repo_dir" ] || { printf 'run-codex: directory not found: %s\n' "$repo_dir" >&2; exit 2; }
command -v codex >/dev/null 2>&1 || { printf 'run-codex: codex CLI not found\n' >&2; exit 127; }

prompt_file="$(mktemp)"
final_file="$(mktemp)"
[ -n "$stream_file" ] || stream_file="$(mktemp)"
trap 'rm -f "$prompt_file" "$final_file"' EXIT
cat > "$prompt_file"
[ -s "$prompt_file" ] || { printf 'run-codex: empty prompt\n' >&2; exit 2; }

set +e
timeout -k 10 "$run_timeout" codex exec \
  --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
  -C "$repo_dir" -m "$model" -c "model_reasoning_effort=\"$effort\"" \
  -o "$final_file" - < "$prompt_file" > "$stream_file" 2> "${stream_file}.stderr"
rc=$?
set -e

if [ -s "$final_file" ]; then
  cat "$final_file"
elif [ -s "$stream_file" ]; then
  tail -n 200 "$stream_file"
fi
printf 'run-codex: exit=%s model=%s effort=%s log=%s\n' "$rc" "$model" "$effort" "$stream_file" >&2
exit "$rc"
