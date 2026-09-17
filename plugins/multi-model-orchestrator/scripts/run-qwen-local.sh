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
#   MMO_QWEN_LOCAL_RUN  Path to subagent-local-qwen3.8-27b-run.sh (else discovered).
#   OPENAI_BASE_URL     llama.cpp OpenAI base; also keys the lock.
set -euo pipefail

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
mmo_find_wrapper() {
  if [ -n "${MMO_QWEN_LOCAL_RUN:-}" ]; then
    printf '%s' "$MMO_QWEN_LOCAL_RUN"
    return 0
  fi
  local found
  found="$(command -v subagent-local-qwen3.8-27b-run.sh 2>/dev/null || true)"
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  local candidate
  for candidate in "${HOME}"/.claude/plugins/cache/*/subagent-local-qwen3.8-27b/*/scripts/subagent-local-qwen3.8-27b-run.sh; do
    [ -x "$candidate" ] && printf '%s' "$candidate" && return 0
  done
  return 1
}

wrapper="$(mmo_find_wrapper || true)"
if [ -z "$wrapper" ] || [ ! -x "$wrapper" ]; then
  printf 'run-qwen-local: subagent-local-qwen3.8-27b wrapper not installed; route elsewhere\n' >&2
  exit 75
fi

base_url="${OPENAI_BASE_URL:-http://127.0.0.1:8000/v1}"

# 2. Someone else's request on the GPU counts as busy too (llama.cpp /slots).
slots_url="${base_url%/}"
slots_url="${slots_url%/v1}/slots"
if command -v curl >/dev/null 2>&1; then
  if curl -fsS -m 3 "$slots_url" 2>/dev/null | grep -q '"is_processing"[[:space:]]*:[[:space:]]*true'; then
    printf 'run-qwen-local: local model busy with another request; route elsewhere\n' >&2
    exit 75
  fi
fi

# 3. One dispatch at a time per endpoint. Non-blocking: we refuse, never queue.
lock_key="$(printf '%s' "$base_url" | cksum | tr -d ' \t' )"
lock_file="${TMPDIR:-/tmp}/mmo-qwen-local-${lock_key}.lock"
exec 9>"$lock_file"
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    printf 'run-qwen-local: another local-qwen dispatch holds the slot; route elsewhere\n' >&2
    exit 75
  fi
fi

set -- "$@"
wrapper_args=(--dir "$repo_dir" --timeout "$run_timeout")
[ -n "$output_file" ] && wrapper_args+=(--out "$output_file")
[ -n "$prompt_file" ] && wrapper_args+=(--prompt-file "$prompt_file")
if [ "$mode" = review ]; then
  wrapper_args+=(--approval-mode plan --diff "$base_ref")
else
  wrapper_args+=(--yolo)
fi

rc=0
"$wrapper" "${wrapper_args[@]}" "$@" || rc=$?
exit "$rc"
