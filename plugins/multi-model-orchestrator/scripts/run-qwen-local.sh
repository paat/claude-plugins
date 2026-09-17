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
# Exit codes: 0 ok; 2 usage; 3 nothing to review; 4 diff over the cap; 5 empty
# final message; 6 review without a terminal
# APPROVE/NEEDS_WORK; 75 unavailable (slot busy, server down, or no wrapper) —
# route elsewhere; other codes come from the wrapper.
#
# Env:
# Requires flock, curl and jq; without any of them the contract cannot be kept and
# the runner reports unavailable (75).
#
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

command -v git >/dev/null 2>&1 || { printf 'run-qwen-local: git not found\n' >&2; exit 127; }
repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'run-qwen-local: not a git repository: %s\n' "$repo_dir" >&2
  exit 2
}

case "$mode" in
  implement|review) ;;
  *) printf 'run-qwen-local: --mode must be implement or review\n' >&2; exit 2 ;;
esac
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'run-qwen-local: timeout must be a positive integer\n' >&2; exit 2; }
[ "$mode" != review ] || [ -n "$base_ref" ] || {
  printf 'run-qwen-local: review mode needs --base (the worker has no shell and cannot run git)\n' >&2
  exit 2
}
# A ref must not be able to turn into a git option (e.g. --output=<path>).
case "$base_ref" in
  -*) printf 'run-qwen-local: --base must be a revision or range, not an option: %s\n' "$base_ref" >&2; exit 2 ;;
esac

# 1. Wrapper discovery. Absent plugin is "unavailable", not an error to debug.
# A candidate counts only if it answers --print-base: older wrappers exit 1 on a
# busy server instead of 75, which would silently disable the Grok fallback.
# Prints "<wrapper path><tab><base url>". A candidate must support every flag this
# runner sends (--print-base and --diff-file); a stale cached copy that predates
# one of them would fail dispatch with a usage error instead of the 75 the
# fallback contract expects. --print-base probes the network when OPENAI_BASE_URL
# is unset, so ask once and carry the answer.
mmo_find_wrapper() {
  local candidate base help
  # Unmatched cache globs must disappear, not survive as literal candidates.
  shopt -s nullglob
  for candidate in "${MMO_QWEN_LOCAL_RUN:-}" \
    "$(command -v subagent-local-qwen3.8-27b-run.sh 2>/dev/null || true)" \
    "${HOME}"/.claude/plugins/cache/*/subagent-local-qwen3.8-27b/*/scripts/subagent-local-qwen3.8-27b-run.sh \
    "${HOME}"/.agents/plugins/cache/*/subagent-local-qwen3.8-27b/*/scripts/subagent-local-qwen3.8-27b-run.sh; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    help="$("$candidate" --help 2>/dev/null || true)"
    case "$help" in *--diff-file*) ;; *) continue ;; esac
    base="$("$candidate" --print-base 2>/dev/null || true)"
    if [ -n "$base" ]; then
      printf '%s\t%s' "$candidate" "$base"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

found="$(mmo_find_wrapper || true)"
if [ -z "$found" ]; then
  printf 'run-qwen-local: no subagent-local-qwen3.8-27b wrapper supporting --print-base and --diff-file (>= 0.4.0); route elsewhere\n' >&2
  exit 75
fi
wrapper="${found%%$'\t'*}"
base_url="${found#*$'\t'}"
# Pin it: the wrapper must use the endpoint we checked and locked, not re-resolve.
export OPENAI_BASE_URL="$base_url"

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

runtime_dir="$(mktemp -d)"
# Keep the worker's stream and stderr when something went wrong: the wrapper only
# prints their paths, and a failed or timed-out leg is diagnosed from them.
cleanup() { [ "${keep_runtime:-0}" = 1 ] || rm -rf "$runtime_dir"; }
trap cleanup EXIT

# Review preflight before the slot: an invalid ref, an empty diff, or an oversized
# one is a usage problem, not slot unavailability, and must not lock the GPU.
# Codes match the sibling runners: 2 usage, 3 nothing to review, 4 over the cap.
if [ "$mode" = review ]; then
  # Same invocation as the sibling review legs: a repo-configured external differ
  # must not decide what the reviewer sees. Untracked files are folded in below.
  review_patch="$runtime_dir/review.patch"
  git -C "$repo_dir" --no-pager diff --no-ext-diff --binary "$base_ref" > "$review_patch" 2>/dev/null || {
    printf 'run-qwen-local: cannot diff %s in %s\n' "$base_ref" "$repo_dir" >&2
    exit 2
  }
  # Fold in untracked files, as the sibling review legs do: a brand-new file is
  # part of the change under review. --no-index exits 1 when files differ
  # (expected); 2+ is a real failure and must not be swallowed.
  while IFS= read -r -d '' untracked; do
    set +e
    git -C "$repo_dir" diff --no-ext-diff --no-index --binary -- /dev/null "$untracked" \
      >> "$review_patch" 2>/dev/null
    untracked_rc=$?
    set -e
    if [ "$untracked_rc" -gt 1 ]; then
      printf 'run-qwen-local: failed to include untracked file in review diff: %s\n' "$untracked" >&2
      exit "$untracked_rc"
    fi
  done < <(git -C "$repo_dir" ls-files -z --others --exclude-standard)
  [ -s "$review_patch" ] || { printf 'run-qwen-local: no diff to review\n' >&2; exit 3; }
  max_bytes="${MMO_REVIEW_DIFF_MAX_BYTES:-1048576}"
  [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || { printf 'run-qwen-local: MMO_REVIEW_DIFF_MAX_BYTES must be positive\n' >&2; exit 2; }
  diff_bytes="$(wc -c < "$review_patch" | tr -d ' ')"
  [ "$diff_bytes" -le "$max_bytes" ] || {
    printf 'run-qwen-local: diff is %s bytes; split or raise MMO_REVIEW_DIFF_MAX_BYTES=%s explicitly\n' "$diff_bytes" "$max_bytes" >&2
    exit 4
  }
fi

# 2. Take the slot first, so our own dispatches never race each other into the
# window between a check and the lock. Everything that cannot be guaranteed here
# exits 75: the controller routes elsewhere rather than queueing on one GPU.
# jq is required too: without it the wrapper cannot extract the final message from
# qwen's JSON stream, and the verdict gate would reject a perfectly good review.
for tool in flock curl jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'run-qwen-local: %s not available; cannot guarantee the single-slot contract, route elsewhere\n' "$tool" >&2
    exit 75
  }
done
# http://h:8000, .../v1 and .../v1/ all address the same GPU, so they share a lock.
lock_base="${base_url%/}"; lock_base="${lock_base%/v1}"
# cksum prints "<checksum> <bytes>"; keep a separator so the two fields cannot
# merge into the same key for different URLs.
lock_key="$(printf '%s' "$lock_base" | cksum | awk '{print $1 "-" $2}')"
# Own directory, created without -p: mkdir -p stats through a symlink, so a path
# planted in a shared /tmp before the first run could redirect the lock open.
lock_dir="${TMPDIR:-/tmp}/mmo-qwen-local-$(id -u)"
mkdir "$lock_dir" 2>/dev/null || true
if [ ! -d "$lock_dir" ] || [ -L "$lock_dir" ] || [ ! -O "$lock_dir" ]; then
  printf 'run-qwen-local: lock directory %s is missing, a symlink, or not owned by us; route elsewhere\n' "$lock_dir" >&2
  exit 75
fi
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
slots_code="$(printf '%s' "$slots_body" | tail -n1)"
case "$slots_code" in
  # The server says it is saturated.
  503|429)
    printf 'run-qwen-local: local server reports it is busy (HTTP %s); route elsewhere\n' "$slots_code" >&2
    exit 75
    ;;
  200)
    if printf '%s' "$slots_body" | grep -q '"is_processing"[[:space:]]*:[[:space:]]*true'; then
      printf 'run-qwen-local: local model busy with another request; route elsewhere\n' >&2
      exit 75
    fi
    ;;
  # Anything else (404 and friends): this server exposes no slot state, which is
  # not evidence of a busy GPU. The lock still covers our own dispatches.
esac

# --out holds the FINAL MESSAGE, as in the sibling runners; the wrapper's raw
# stream goes to a temp file. meta-orchestration reads --out to resume a leg.
stream_file="$runtime_dir/stream.json"
[ -n "$output_file" ] || output_file="$runtime_dir/body.txt"
case "$output_file" in /*) ;; *) output_file="$PWD/$output_file" ;; esac

wrapper_args=(--dir "$repo_dir" --timeout "$run_timeout" --out "$stream_file")
if [ "$mode" = review ]; then
  # Hand over the patch we just validated: re-diffing in the wrapper would be a
  # second source of truth that the size gate never saw.
  wrapper_args+=(--approval-mode plan --diff-file "$review_patch")
  prompt_text="$prompt_text

End with one terminal line: APPROVE or NEEDS_WORK."
else
  wrapper_args+=(--yolo)
fi

rc=0
printf '%s\n' "$prompt_text" | "$wrapper" "${wrapper_args[@]}" > "$output_file" 2>"$runtime_dir/err.txt" || rc=$?
cat "$runtime_dir/err.txt" >&2

# The wrapper reports a missing/too-old qwen CLI as 127: that is the local engine
# being unavailable, which this contract expresses as 75.
if [ "$rc" -eq 127 ]; then
  printf 'run-qwen-local: qwen CLI missing or too old; route elsewhere\n' >&2
  rc=75
fi
if [ "$rc" -eq 0 ] && [ -z "$(tr -d '[:space:]' < "$output_file")" ]; then
  printf 'run-qwen-local: missing or empty final-message artifact: %s\n' "$output_file" >&2
  rc=5
fi
# Same contract as the sibling runners: a review without a terminal verdict is
# not a review, however much prose it returned.
if [ "$rc" -eq 0 ] && [ "$mode" = review ] && ! mmo_has_review_verdict "$output_file"; then
  printf 'run-qwen-local: review completed without APPROVE or NEEDS_WORK\n' >&2
  rc=6
fi
# Body on success and on a verdict-format failure, as the siblings do.
if [ "$rc" -eq 0 ] || [ "$rc" -eq 6 ]; then
  cat "$output_file"
fi
if [ "$rc" -ne 0 ] && [ "$rc" -ne 6 ]; then
  keep_runtime=1
  printf 'run-qwen-local: worker logs kept in %s\n' "$runtime_dir" >&2
fi
mmo_finish run-qwen-local "$rc" "$runtime_dir/err.txt" "model=local-qwen" "mode=$mode"
