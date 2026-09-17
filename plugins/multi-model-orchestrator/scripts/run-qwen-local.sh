#!/usr/bin/env bash
# run-qwen-local.sh — dispatch a bounded task to a LOCAL llama.cpp Qwen worker
# through the subagent-local-qwen3.8-27b plugin wrapper.
#
# A local endpoint serves one request at a time, so this runner refuses rather
# than queues: if the slot is taken (by us or by anything else), it exits 75 and
# the controller routes the task to Grok instead. It never waits for the GPU.
#
# Usage:
#   run-qwen-local.sh --mode implement|review [--repo DIR] [--base REF]
#                     [--timeout SECONDS] [--out FILE] [--prompt-file FILE] [PROMPT]
#
# Exit codes: 0 ok; 2 usage; 75 unavailable (slot busy, server down, or wrapper
# not installed) — route elsewhere; other codes come from the wrapper.
#
# Env:
#   MMO_QWEN_LOCAL_RUN  Path to subagent-local-qwen3.8-27b-run.sh (else discovered on
#                       PATH, then the Claude Code and Codex plugin caches).
#   OPENAI_BASE_URL     llama.cpp OpenAI base; also keys the lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"

usage() {
  printf '%s\n' 'Usage: run-qwen-local.sh --mode implement|review [--repo DIR] [--base REF] [--timeout SECONDS] [--out FILE] [--prompt-file FILE] [PROMPT]'
}

mode=""
repo_dir="$PWD"
base_ref=""
run_timeout=900
output_file=""
prompt_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; mode="$2"; shift 2 ;;
    --repo|--dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repo_dir="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; base_ref="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_timeout="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; output_file="$2"; shift 2 ;;
    --prompt-file) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; prompt_file="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) printf 'run-qwen-local: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

case "$mode" in
  implement|review) ;;
  *) printf 'run-qwen-local: --mode must be implement or review\n' >&2; exit 2 ;;
esac
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'run-qwen-local: timeout must be a positive integer\n' >&2; exit 2; }
[ "$mode" != review ] || [ -n "$base_ref" ] || {
  printf 'run-qwen-local: review mode needs --base (the worker has no shell and cannot run git)\n' >&2
  exit 2
}

# 1. Wrapper discovery. Absent plugin is "unavailable", not an error to debug.
# A candidate counts only if it answers --print-base: older wrappers exit 1 on a
# busy server instead of 75, which would silently disable the Grok fallback.
# Prints "<wrapper path><tab><base url>": --print-base probes the network when
# OPENAI_BASE_URL is unset, so ask once and carry the answer.
mmo_find_wrapper() {
  local candidate base
  for candidate in "${MMO_QWEN_LOCAL_RUN:-}" \
    "$(command -v subagent-local-qwen3.8-27b-run.sh 2>/dev/null || true)" \
    "${HOME}"/.claude/plugins/cache/*/subagent-local-qwen3.8-27b/*/scripts/subagent-local-qwen3.8-27b-run.sh \
    "${HOME}"/.agents/plugins/cache/*/subagent-local-qwen3.8-27b/*/scripts/subagent-local-qwen3.8-27b-run.sh; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    base="$("$candidate" --print-base 2>/dev/null || true)"
    if [ -n "$base" ]; then
      printf '%s\t%s' "$candidate" "$base"
      return 0
    fi
  done
  return 1
}

found="$(mmo_find_wrapper || true)"
if [ -z "$found" ]; then
  printf 'run-qwen-local: no subagent-local-qwen3.8-27b wrapper with --print-base (>= 0.3.3); route elsewhere\n' >&2
  exit 75
fi
wrapper="${found%%$'\t'*}"
base_url="${found#*$'\t'}"
# Pin it: the wrapper must use the endpoint we checked and locked, not re-resolve.
export OPENAI_BASE_URL="$base_url"

# 2. Take the slot first, so our own dispatches never race each other into the
# window between a check and the lock. Everything that cannot be guaranteed here
# exits 75: the controller routes elsewhere rather than queueing on one GPU.
for tool in flock curl; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'run-qwen-local: %s not available; cannot guarantee the single-slot contract, route elsewhere\n' "$tool" >&2
    exit 75
  }
done
# Normalize first: .../v1 and .../v1/ address the same GPU and must share a lock.
lock_key="$(printf '%s' "${base_url%/}" | cksum | tr -d ' \t' )"
# Own directory: a pre-created symlink in a shared /tmp must not redirect the open.
lock_dir="${TMPDIR:-/tmp}/mmo-qwen-local-$(id -u)"
mkdir -p "$lock_dir" 2>/dev/null || true
lock_file="$lock_dir/${lock_key}.lock"
# Brace group: without it the redirect would apply to this shell for the rest of
# the run and swallow the wrapper's own diagnostics.
{ exec 9>"$lock_file"; } 2>/dev/null || {
  printf 'run-qwen-local: cannot open the lock file %s; route elsewhere\n' "$lock_file" >&2
  exit 75
}
if ! flock -n 9; then
  printf 'run-qwen-local: another local-qwen dispatch holds the slot; route elsewhere\n' >&2
  exit 75
fi

# 3. A request from anything else on the GPU counts as busy (llama.cpp /slots).
# An unreachable endpoint is unavailable; a 404 only means this server has no
# /slots route, which is not evidence that the GPU is occupied.
slots_url="${base_url%/}"
slots_url="${slots_url%/v1}/slots"
slots_body="$(curl -sS -m 3 -w '\n%{http_code}' "$slots_url" 2>/dev/null)" || {
  printf 'run-qwen-local: local endpoint %s unreachable; route elsewhere\n' "$slots_url" >&2
  exit 75
}
if [ "$(printf '%s' "$slots_body" | tail -n1)" = "200" ] \
  && printf '%s' "$slots_body" | grep -q '"is_processing"[[:space:]]*:[[:space:]]*true'; then
  printf 'run-qwen-local: local model busy with another request; route elsewhere\n' >&2
  exit 75
fi

runtime_dir="$(mktemp -d)"
trap 'rm -rf "$runtime_dir"' EXIT
body_file="${output_file:-$runtime_dir/body.txt}"

# One prompt source, always delivered on stdin: argv, --prompt-file, or a heredoc.
# Never as an argv word, so a prompt starting with a dash stays prompt text.
prompt_text=""
if [ -n "$prompt_file" ]; then
  [ -r "$prompt_file" ] || { printf 'run-qwen-local: cannot read prompt file: %s\n' "$prompt_file" >&2; exit 2; }
  prompt_text="$(cat "$prompt_file")"
elif [ "$#" -gt 0 ]; then
  prompt_text="$*"
elif [ ! -t 0 ]; then
  prompt_text="$(cat)"
fi
[ -n "${prompt_text//[[:space:]]/}" ] || { printf 'run-qwen-local: empty prompt\n' >&2; exit 2; }

wrapper_args=(--dir "$repo_dir" --timeout "$run_timeout" --out "$body_file")
if [ "$mode" = review ]; then
  wrapper_args+=(--approval-mode plan --diff "$base_ref")
  prompt_text="$prompt_text

End with one terminal line: APPROVE or NEEDS_WORK."
else
  wrapper_args+=(--yolo)
fi

rc=0
printf '%s\n' "$prompt_text" | "$wrapper" "${wrapper_args[@]}" > "$runtime_dir/stdout.txt" || rc=$?
cat "$runtime_dir/stdout.txt"

# Same contract as the sibling runners: a review without a terminal verdict is
# not a review, however much prose it returned.
if [ "$rc" -eq 0 ] && [ "$mode" = review ] && ! mmo_has_review_verdict "$runtime_dir/stdout.txt"; then
  printf 'run-qwen-local: review completed without APPROVE or NEEDS_WORK\n' >&2
  rc=6
fi
exit "$rc"
