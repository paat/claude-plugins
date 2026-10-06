#!/usr/bin/env bash
# Muse tribunal leg: repo-walking read-only review through `muse exec`.
# --yolo is required headless (an approval prompt would block until the timeout);
# --disable-write/--disable-shell leave only read and search tools.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_MUSE:-on}" = "off" ]; then tribunal_disabled muse "Muse leg disabled via TRIBUNAL_MUSE=off"; exit 0; fi
command -v muse >/dev/null 2>&1 || { tribunal_error muse "Muse CLI not on PATH"; exit 0; }

# Unset runs the CLI default model; a pinned model must be the one the run configured.
MUSE_MODEL="${TRIBUNAL_MUSE_MODEL:-}"
model_args=()
[ -z "$MUSE_MODEL" ] || model_args=(--model "$MUSE_MODEL")
RISK_EFFORT="$(tribunal_risk_effort muse 2>&1)" || { tribunal_error muse "$RISK_EFFORT"; exit 0; }
MUSE_EFFORT="${TRIBUNAL_MUSE_EFFORT:-$RISK_EFFORT}"
effort_args=()
[ -z "$MUSE_EFFORT" ] || effort_args=(--reasoning-effort "$MUSE_EFFORT")
TIMEOUT="${TRIBUNAL_MUSE_TIMEOUT_SECONDS:-600}"
MAX_STEPS="${TRIBUNAL_MUSE_MAX_STEPS:-40}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=600 ;; esac
case "$MAX_STEPS" in ''|*[!0-9]*) MAX_STEPS=40 ;; esac
[ "$TIMEOUT" -ge 30 ] || TIMEOUT=30
[ "$TIMEOUT" -le 1800 ] || TIMEOUT=1800
[ "$MAX_STEPS" -ge 1 ] || MAX_STEPS=1
[ "$MAX_STEPS" -le 80 ] || MAX_STEPS=80

BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
PROMPT_FILE="$TMPDIR/prompt.md"
OUT="$TMPDIR/out.jsonl"
ERR="$TMPDIR/err.txt"
REPO_ROOT="$(tribunal_repo_root)"
WALK_ROOT="$(tribunal_walk_root "$TMPDIR/walk")" \
  || { tribunal_error muse "cannot prepare a checkout without the repository's untracked .env files"; exit 0; }
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error muse "cannot diff against $BASE_REF"; exit 0; }
DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
[ -s "$DIFF_FILE" ] || { tribunal_empty muse "${MUSE_MODEL:-default}" "$BASE_REF" "$DIFF_STAT"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
tribunal_review_prompt muse "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"
# Inline the diff: the workspace tools cannot read the runner's temp dir.
{
  printf '\n\n===== BEGIN UNIFIED DIFF (authoritative; review only these changed lines) =====\n'
  cat "$DIFF_FILE"
  printf '\n===== END UNIFIED DIFF =====\n'
} >> "$PROMPT_FILE"

SCHEMA_FILE="$(tribunal_review_schema)"
[ -f "$SCHEMA_FILE" ] || { tribunal_error muse "review schema missing at $SCHEMA_FILE (set TRIBUNAL_PLUGIN_ROOT or CLAUDE_PLUGIN_ROOT)"; exit 0; }

rc=0
(cd "$WALK_ROOT" && tribunal_leg_env 'MUSE_*' META_API_KEY 'XDG_*' -- timeout -k 10 "$TIMEOUT" \
  muse exec --json --yolo ${model_args[@]+"${model_args[@]}"} ${effort_args[@]+"${effort_args[@]}"} \
  --max-model-steps "$MAX_STEPS" --prompt-file "$PROMPT_FILE" --output-schema "$SCHEMA_FILE" \
  --workspace "$WALK_ROOT" --disable-write --disable-shell --disable-web-tools \
  --no-foreign-personal-context --disable-reminders) < /dev/null > "$OUT" 2> "$ERR" || rc=$?

terminal="$(jq -r 'select(.payload_type? == "run.terminal.completed") | .payload.text // empty' "$OUT" 2>/dev/null | tail -n 1)"
actual_model="$(jq -r 'select(.payload_type? == "run.model.configured") | .payload.model_id // empty' "$OUT" 2>/dev/null | tail -n 1)"
if [ "$rc" -ne 0 ] || [ -z "$terminal" ]; then
  tribunal_error_with_diagnostics muse "Muse execution failed or timed out" execution "$rc" "$OUT" "$ERR"
  exit 0
fi
if [ -n "$MUSE_MODEL" ] && [ -n "$actual_model" ] && [ "$actual_model" != "$MUSE_MODEL" ]; then
  tribunal_error_with_diagnostics muse "Muse configured model $actual_model, not the requested $MUSE_MODEL" \
    model_family "$rc" "$OUT" "$ERR"
  exit 0
fi
printf '%s\n' "$terminal" | tribunal_extract_json_object \
  | tribunal_emit_review muse "" "$OUT" "$ERR" "$rc" \
  | tribunal_stamp_executed_model muse "$actual_model" "$OUT" "$ERR" "$rc" \
  | tribunal_line_check "$REPO_ROOT" "$DIFF_STAT" \
  | tribunal_stamp_diff_stat "$DIFF_STAT"
