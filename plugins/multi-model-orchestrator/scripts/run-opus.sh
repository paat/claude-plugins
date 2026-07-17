#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: run-opus.sh --mode advise|review [--repo DIR] [--base REF] [--model MODEL] [--effort LEVEL] [--timeout SECONDS] [--out FILE]'
}

valid_effort() {
  case "$1" in low|medium|high|xhigh|max) return 0 ;; *) return 1 ;; esac
}

mode=""
repo_dir="$PWD"
base_ref="HEAD"
model="${MMO_OPUS_MODEL:-opus}"
effort="${MMO_OPUS_EFFORT:-xhigh}"
run_timeout=1200
output_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; mode="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repo_dir="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; base_ref="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; model="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; effort="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_timeout="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; output_file="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'run-opus: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$mode" in advise|review) ;; *) printf 'run-opus: --mode must be advise or review\n' >&2; exit 2 ;; esac
valid_effort "$effort" || { printf 'run-opus: unsupported effort: %s\n' "$effort" >&2; exit 2; }
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'run-opus: timeout must be a positive integer\n' >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'run-opus: git not found\n' >&2; exit 127; }
command -v claude >/dev/null 2>&1 || { printf 'run-opus: claude CLI not found\n' >&2; exit 127; }
repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel)" || exit 2

request_file="$(mktemp)"
prompt_file="$(mktemp)"
diff_file="$(mktemp)"
[ -n "$output_file" ] || output_file="$(mktemp)"
trap 'rm -f "$request_file" "$prompt_file" "$diff_file"' EXIT
cat > "$request_file"
[ -s "$request_file" ] || { printf 'run-opus: empty prompt\n' >&2; exit 2; }

if [ "$mode" = review ]; then
  git -C "$repo_dir" rev-parse --verify "$base_ref^{commit}" >/dev/null || {
    printf 'run-opus: invalid base ref: %s\n' "$base_ref" >&2
    exit 2
  }
  git -C "$repo_dir" diff --no-ext-diff --binary "$base_ref" -- > "$diff_file"
  while IFS= read -r -d '' untracked; do
    git -C "$repo_dir" diff --no-index --binary -- /dev/null "$untracked" >> "$diff_file" 2>/dev/null || true
  done < <(git -C "$repo_dir" ls-files -z --others --exclude-standard)
  [ -s "$diff_file" ] || { printf 'run-opus: no diff to review\n' >&2; exit 3; }
  max_bytes="${MMO_REVIEW_DIFF_MAX_BYTES:-1048576}"
  [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || { printf 'run-opus: MMO_REVIEW_DIFF_MAX_BYTES must be positive\n' >&2; exit 2; }
  diff_bytes="$(wc -c < "$diff_file" | tr -d ' ')"
  [ "$diff_bytes" -le "$max_bytes" ] || {
    printf 'run-opus: diff is %s bytes; split or raise MMO_REVIEW_DIFF_MAX_BYTES=%s explicitly\n' "$diff_bytes" "$max_bytes" >&2
    exit 4
  }
  {
    printf '%s\n' 'You are an independent, semantically read-only Opus reviewer. Do not modify files.'
    printf '%s\n' 'Review only the supplied task and diff. Return at most 10 actionable findings.'
    printf '%s\n' 'Each finding needs severity, file:line, realistic reachable failure, and a validating test.'
    printf '%s\n' 'Do not invent speculative edge cases or resolve contradictions outside scope. End APPROVE or NEEDS_WORK.'
    printf '\n## Task and acceptance\n'
    cat "$request_file"
    printf '\n## Unified diff from %s\n' "$base_ref"
    cat "$diff_file"
  } > "$prompt_file"
else
  {
    printf '%s\n' 'You are a semantically read-only Opus adviser. Do not modify files.'
    printf '%s\n' 'Inspect only the repository context needed to answer. Return constraints, risks, and a minimal file map.'
    printf '%s\n' 'Do not implement, refactor, or broaden the request.'
    printf '\n## Question\n'
    cat "$request_file"
  } > "$prompt_file"
fi

set +e
(cd "$repo_dir" && timeout -k 10 "$run_timeout" claude -p \
  --model "$model" --effort "$effort" --output-format text \
  --dangerously-skip-permissions --disable-slash-commands \
  --allowedTools 'Read,Glob,Grep' \
  --disallowedTools 'Bash,Write,Edit,NotebookEdit,Task,WebFetch,WebSearch' \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-session-persistence \
  < "$prompt_file" > "$output_file" 2> "${output_file}.stderr")
rc=$?
set -e
[ -s "$output_file" ] && cat "$output_file"
printf 'run-opus: exit=%s model=%s effort=%s mode=%s log=%s\n' "$rc" "$model" "$effort" "$mode" "$output_file" >&2
exit "$rc"
