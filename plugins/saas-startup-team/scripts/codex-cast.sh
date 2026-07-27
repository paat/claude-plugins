#!/usr/bin/env bash
# Narrow cross-provider Codex adapter.
#
# codex-cast.sh --worktree PATH --mode implement|review \
#   --provider openai --model MODEL --effort EFFORT --timeout DURATION \
#   --prompt-file FILE [--env KEY]... [--json-out FILE] [--unrestricted]
#
# Defaults honor repository rules, hooks, and sandboxing. Unrestricted
# execution requires an explicit --unrestricted flag (never implicit).
# Review mode is mechanically read-only (-s read-only) and fails if the
# worktree becomes dirty.

set -euo pipefail

WORKTREE="" MODE="" PROVIDER="" MODEL="" EFFORT="" TIMEOUT="" PROMPT_FILE=""
JSON_OUT="" UNRESTRICTED=0
ENV_ALLOW=()

usage() {
  echo "usage: codex-cast.sh --worktree PATH --mode implement|review --provider openai --model MODEL --effort EFFORT --timeout DURATION --prompt-file FILE [--env KEY]... [--json-out FILE] [--unrestricted]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) [ $# -ge 2 ] || usage; WORKTREE=$2; shift 2 ;;
    --mode) [ $# -ge 2 ] || usage; MODE=$2; shift 2 ;;
    --provider) [ $# -ge 2 ] || usage; PROVIDER=$2; shift 2 ;;
    --model) [ $# -ge 2 ] || usage; MODEL=$2; shift 2 ;;
    --effort) [ $# -ge 2 ] || usage; EFFORT=$2; shift 2 ;;
    --timeout) [ $# -ge 2 ] || usage; TIMEOUT=$2; shift 2 ;;
    --prompt-file) [ $# -ge 2 ] || usage; PROMPT_FILE=$2; shift 2 ;;
    --json-out) [ $# -ge 2 ] || usage; JSON_OUT=$2; shift 2 ;;
    --env) [ $# -ge 2 ] || usage; ENV_ALLOW+=("$2"); shift 2 ;;
    --unrestricted) UNRESTRICTED=1; shift ;;
    *) usage ;;
  esac
done

[ -n "$WORKTREE" ] && [ -n "$MODE" ] && [ -n "$PROVIDER" ] && [ -n "$MODEL" ] \
  && [ -n "$EFFORT" ] && [ -n "$TIMEOUT" ] && [ -n "$PROMPT_FILE" ] || usage

case "$MODE" in implement|review) : ;; *) usage ;; esac
case "$PROVIDER" in openai) : ;; *) echo "codex-cast: unsupported provider: $PROVIDER" >&2; exit 2 ;; esac
[[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$ ]] || {
  echo "codex-cast: invalid model" >&2; exit 2; }
case "$EFFORT" in low|medium|high|xhigh|max) : ;; *)
  echo "codex-cast: invalid effort" >&2; exit 2 ;; esac
[[ "$TIMEOUT" =~ ^([1-9][0-9]{0,4})([smh])$ ]] || {
  echo "codex-cast: invalid timeout" >&2; exit 2; }
timeout_unit=${BASH_REMATCH[2]}
timeout_num=${BASH_REMATCH[1]}
case "$timeout_unit" in
  s) TIMEOUT_SECONDS=$timeout_num ;;
  m) TIMEOUT_SECONDS=$((timeout_num * 60)) ;;
  h) TIMEOUT_SECONDS=$((timeout_num * 3600)) ;;
esac
[ "$TIMEOUT_SECONDS" -le 7200 ] || {
  echo "codex-cast: timeout exceeds 2h maximum" >&2; exit 2; }

for key in "${ENV_ALLOW[@]+"${ENV_ALLOW[@]}"}"; do
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "codex-cast: invalid --env name: $key" >&2; exit 2; }
done

command -v codex >/dev/null 2>&1 || { echo "codex-cast: codex CLI not found" >&2; exit 3; }
command -v timeout >/dev/null 2>&1 || { echo "codex-cast: timeout is required" >&2; exit 4; }
command -v jq >/dev/null 2>&1 || { echo "codex-cast: jq is required" >&2; exit 4; }

WORKTREE=$(cd -- "$WORKTREE" && pwd -P) || {
  echo "codex-cast: worktree is not a directory" >&2; exit 4; }
git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "codex-cast: worktree is not a git worktree" >&2; exit 4; }
WT_TOP=$(cd -- "$(git -C "$WORKTREE" rev-parse --show-toplevel)" && pwd -P) || {
  echo "codex-cast: could not resolve worktree root" >&2; exit 4; }
[ "$WT_TOP" = "$WORKTREE" ] || {
  echo "codex-cast: worktree mismatch: expected root $WORKTREE got $WT_TOP" >&2
  exit 4
}

case "$PROMPT_FILE" in /*) : ;; *) PROMPT_FILE=$WORKTREE/$PROMPT_FILE ;; esac
[ -f "$PROMPT_FILE" ] && [ -r "$PROMPT_FILE" ] && [ ! -L "$PROMPT_FILE" ] || {
  echo "codex-cast: prompt file unreadable" >&2; exit 4; }
PROMPT_BYTES=$(stat -Lc '%s' -- "$PROMPT_FILE") || exit 4
[ "$PROMPT_BYTES" -le 1048576 ] || {
  echo "codex-cast: prompt file exceeds 1 MiB" >&2; exit 4; }
PROMPT=$(LC_ALL=C head -c 1048576 -- "$PROMPT_FILE") || {
  echo "codex-cast: could not read prompt file" >&2; exit 4; }
[ -n "$(printf '%s' "$PROMPT" | tr -d '[:space:]')" ] || {
  echo "codex-cast: prompt file is empty" >&2; exit 4; }

COMMIT_SHA=$(git -C "$WORKTREE" rev-parse HEAD) || {
  echo "codex-cast: could not read HEAD" >&2; exit 4; }
DIRTY_BEFORE=$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)

if [ "$UNRESTRICTED" -eq 1 ]; then
  SANDBOX_ARGS=(--dangerously-bypass-approvals-and-sandbox)
else
  case "$MODE" in
    review) SANDBOX_ARGS=(-s read-only) ;;
    implement) SANDBOX_ARGS=(-s workspace-write) ;;
  esac
fi

# Core environment only, plus caller allowlist. No ambient secret inheritance.
ENV_ARGS=(
  "PATH=${PATH:-/usr/bin:/bin}"
  "HOME=${HOME:-/tmp}"
  "USER=${USER:-codex}"
  "LANG=${LANG:-C.UTF-8}"
  "LC_ALL=${LC_ALL:-C.UTF-8}"
  "TERM=${TERM:-dumb}"
  "TMPDIR=${TMPDIR:-/tmp}"
)
for key in "${ENV_ALLOW[@]+"${ENV_ALLOW[@]}"}"; do
  [ -n "${!key+x}" ] || {
    echo "codex-cast: --env $key is not set in the parent environment" >&2
    exit 2
  }
  ENV_ARGS+=("$key=${!key}")
done

EVIDENCE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-cast.XXXXXX")
chmod 700 "$EVIDENCE_DIR"
JSONL=$EVIDENCE_DIR/events.jsonl
STDERR=$EVIDENCE_DIR/stderr.txt
LAST=$EVIDENCE_DIR/last-message.txt
: >"$JSONL" >"$STDERR" >"$LAST"

cleanup() {
  rm -rf -- "$EVIDENCE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

TIMEOUT_OUTCOME=none
OUTCOME=failure
RC=0

set +e
(
  ulimit -S -c 0 || true
  exec env -i "${ENV_ARGS[@]}" \
    timeout --signal=TERM --kill-after=2s "$TIMEOUT" \
    codex exec --json --ephemeral \
      "${SANDBOX_ARGS[@]}" \
      -m "$MODEL" \
      -c "model_reasoning_effort=\"$EFFORT\"" \
      -C "$WORKTREE" \
      -o "$LAST" \
      - <<<"$PROMPT"
) >"$JSONL" 2>"$STDERR"
RC=$?
set -e

case "$RC" in
  124|137) TIMEOUT_OUTCOME=timed_out; OUTCOME=timeout ;;
  0) TIMEOUT_OUTCOME=completed ;;
  *) TIMEOUT_OUTCOME=completed ;;
esac

# Bound evidence.
for pair in "$JSONL:8388608" "$STDERR:1048576" "$LAST:1048576"; do
  path=${pair%%:*}; max=${pair##*:}
  size=$(stat -Lc '%s' -- "$path" 2>/dev/null || echo 0)
  if [ "$size" -gt "$max" ]; then
    truncate -s "$max" -- "$path" || true
    RC=1
    OUTCOME=failure
  fi
done

terminal_ok=0
if [ "$RC" -eq 0 ]; then
  if timeout --signal=KILL 5s jq -ne '
    reduce inputs as $event (
      {count:0,objects:true,last:null};
      {count:(.count + 1),objects:(.objects and (($event | type) == "object")),last:$event}
    )
    | .count > 0 and .objects
      and (.last.type == "turn.completed")
      and (.last.usage | type == "object")' "$JSONL" >/dev/null 2>&1; then
    terminal_ok=1
  fi
  if [ "$terminal_ok" -ne 1 ]; then
    RC=1
    OUTCOME=malformed_output
    printf 'codex-cast: missing or invalid turn.completed terminal event\n' >>"$STDERR"
  elif [ ! -s "$LAST" ] || ! grep -q '[^[:space:]]' "$LAST"; then
    RC=1
    OUTCOME=malformed_output
    printf 'codex-cast: empty final message\n' >>"$STDERR"
  else
    OUTCOME=success
  fi
fi

DIRTY_AFTER=$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)
MUTATION_REJECTED=false
if [ "$MODE" = review ]; then
  if [ "$DIRTY_AFTER" != "$DIRTY_BEFORE" ]; then
    MUTATION_REJECTED=true
    RC=1
    OUTCOME=mutation_rejected
    printf 'codex-cast: review mode forbids worktree mutation\n' >>"$STDERR"
  fi
fi

RESULT=$(jq -cn \
  --arg mode "$MODE" \
  --arg commit_sha "$COMMIT_SHA" \
  --arg worktree "$WORKTREE" \
  --arg provider "$PROVIDER" \
  --arg model "$MODEL" \
  --arg effort "$EFFORT" \
  --arg timeout "$TIMEOUT" \
  --arg timeout_outcome "$TIMEOUT_OUTCOME" \
  --arg outcome "$OUTCOME" \
  --argjson exit_code "$RC" \
  --argjson unrestricted "$([ "$UNRESTRICTED" -eq 1 ] && echo true || echo false)" \
  --argjson mutation_rejected "$MUTATION_REJECTED" \
  --argjson sandbox_read_only "$([ "$MODE" = review ] && [ "$UNRESTRICTED" -eq 0 ] && echo true || echo false)" \
  '{
    schema_version: 1,
    mode: $mode,
    commit_sha: $commit_sha,
    worktree: $worktree,
    provider: $provider,
    model: $model,
    effort: $effort,
    timeout: $timeout,
    timeout_outcome: $timeout_outcome,
    outcome: $outcome,
    exit_code: $exit_code,
    unrestricted: $unrestricted,
    mutation_rejected: $mutation_rejected,
    sandbox_read_only: $sandbox_read_only
  }')

if [ -n "$JSON_OUT" ]; then
  case "$JSON_OUT" in /*) : ;; *) JSON_OUT=$WORKTREE/$JSON_OUT ;; esac
  printf '%s\n' "$RESULT" >"$JSON_OUT"
fi

printf '%s\n' "$RESULT"
if [ -s "$LAST" ] && [ "$OUTCOME" = success ]; then
  printf 'codex-cast: trailing message\n'
  tail -c 8192 "$LAST" | tail -n 40
fi
if [ "$RC" -ne 0 ] && [ -s "$STDERR" ]; then
  printf 'codex-cast: diagnostic (tail)\n' >&2
  tail -c 4096 "$STDERR" | tail -n 40 >&2
fi

exit "$RC"
