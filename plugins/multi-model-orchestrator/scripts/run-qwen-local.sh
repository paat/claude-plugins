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
# A candidate counts only if it answers --print-base: older wrappers exit 1 on a
# busy server instead of 75, which would silently disable the Grok fallback.
mmo_usable_wrapper() {
  [ -x "$1" ] && "$1" --print-base >/dev/null 2>&1
}

mmo_find_wrapper() {
  local candidate
  if [ -n "${MMO_QWEN_LOCAL_RUN:-}" ]; then
    printf '%s' "$MMO_QWEN_LOCAL_RUN"
    return 0
  fi
  candidate="$(command -v subagent-local-qwen3.8-27b-run.sh 2>/dev/null || true)"
  if mmo_usable_wrapper "$candidate"; then
    printf '%s' "$candidate"
    return 0
  fi
  # Both plugin surfaces: Claude Code and Codex keep their own caches.
  for candidate in \
    "${HOME}"/.claude/plugins/cache/*/subagent-local-qwen3.8-27b/*/scripts/subagent-local-qwen3.8-27b-run.sh \
    "${HOME}"/.agents/plugins/cache/*/subagent-local-qwen3.8-27b/*/scripts/subagent-local-qwen3.8-27b-run.sh; do
    if mmo_usable_wrapper "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

wrapper="$(mmo_find_wrapper || true)"
if ! mmo_usable_wrapper "$wrapper"; then
  printf 'run-qwen-local: no subagent-local-qwen3.8-27b wrapper with --print-base (>= 0.3.1); route elsewhere\n' >&2
  exit 75
fi

# Ask the wrapper which endpoint it will actually use: with OPENAI_BASE_URL unset it
# probes localhost, the container host, then the gateway, so guessing here would
# check a server the worker never talks to.
base_url="$("$wrapper" --print-base 2>/dev/null || true)"
[ -n "$base_url" ] || base_url="${OPENAI_BASE_URL:-http://127.0.0.1:8000/v1}"
# Pin it: the wrapper must use the endpoint we checked and locked, not re-resolve.
export OPENAI_BASE_URL="$base_url"

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
# Without flock the no-queue guarantee cannot be kept, so fail closed rather than
# promise it and let two dispatches pile onto one slot.
command -v flock >/dev/null 2>&1 || {
  printf 'run-qwen-local: flock not available; cannot guarantee the single-slot lock, route elsewhere\n' >&2
  exit 75
}
lock_key="$(printf '%s' "$base_url" | cksum | tr -d ' \t' )"
# Own directory: a pre-created symlink in a shared /tmp must not redirect the open.
lock_dir="${TMPDIR:-/tmp}/mmo-qwen-local-$(id -u)"
mkdir -p "$lock_dir" 2>/dev/null || true
lock_file="$lock_dir/${lock_key}.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  printf 'run-qwen-local: another local-qwen dispatch holds the slot; route elsewhere\n' >&2
  exit 75
fi

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
