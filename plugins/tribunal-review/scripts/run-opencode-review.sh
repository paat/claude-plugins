#!/usr/bin/env bash
# OpenCode Go tribunal leg: repo-walking read-only review via OpenCode v2 `opencode run`.
# `--agent plan` denies file edits; collector mutation detection still guards the worktree.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_OPENCODE:-off}" != "on" ]; then
  tribunal_disabled opencode "OpenCode leg disabled (default off); set TRIBUNAL_OPENCODE=on to enable"
  exit 0
fi
MODE=review
case "${1:-}" in
  '') ;;
  --smoke) MODE=smoke ;;
  *) tribunal_error opencode "Usage: run-opencode-review.sh [--smoke]"; exit 0 ;;
esac
opencode_note="$(tribunal_opencode_available)" || { tribunal_error opencode "$opencode_note"; exit 0; }

OPENCODE_MODEL="${TRIBUNAL_OPENCODE_MODEL:-kimi-k3.1-pro}"
OPENCODE_MODEL="${OPENCODE_MODEL#opencode-go/}"
MODEL_BASE="opencode-go/$OPENCODE_MODEL"
RISK_EFFORT="$(tribunal_risk_effort opencode 2>&1)" || { tribunal_error opencode "$RISK_EFFORT"; exit 0; }
if [ -n "${TRIBUNAL_OPENCODE_EFFORT+x}" ]; then
  OPENCODE_EFFORT="$TRIBUNAL_OPENCODE_EFFORT"
elif [ "${TRIBUNAL_PANEL_SELECTED:-0}" = 1 ]; then
  OPENCODE_EFFORT=""
else
  OPENCODE_EFFORT="${RISK_EFFORT:-high}"
fi
[ "$OPENCODE_EFFORT" != "-" ] || OPENCODE_EFFORT=""
if [ -n "$OPENCODE_EFFORT" ]; then
  MODEL_SPEC="${MODEL_BASE}#${OPENCODE_EFFORT}"
else
  MODEL_SPEC="$MODEL_BASE"
fi

TIMEOUT="${TRIBUNAL_OPENCODE_TIMEOUT_SECONDS:-900}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=900 ;; esac
[ "$TIMEOUT" -ge 30 ] || TIMEOUT=30
[ "$TIMEOUT" -le 1800 ] || TIMEOUT=1800
[ "$MODE" != smoke ] || TIMEOUT="${TRIBUNAL_SMOKE_TIMEOUT_SECONDS:-60}"

TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
PROMPT_FILE="$TMPDIR/prompt.md"
OUT="$TMPDIR/out.jsonl"
ERR="$TMPDIR/err.txt"
REPO_ROOT="$(tribunal_repo_root)"
WALK_ROOT="$(tribunal_walk_root "$TMPDIR/walk")" \
  || { tribunal_error opencode "cannot prepare a checkout without the repository's untracked .env files"; exit 0; }

SCHEMA_FILE="$(tribunal_review_schema)"
[ -f "$SCHEMA_FILE" ] || { tribunal_error opencode "review schema missing at $SCHEMA_FILE (set TRIBUNAL_PLUGIN_ROOT or CLAUDE_PLUGIN_ROOT)"; exit 0; }

if [ "$MODE" = smoke ]; then
  tribunal_smoke_prompt opencode > "$PROMPT_FILE"
else
  BASE_REF="$(tribunal_base_ref)"
  tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error opencode "cannot diff against $BASE_REF"; exit 0; }
  DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
  [ -s "$DIFF_FILE" ] || { tribunal_empty opencode "$MODEL_BASE" "$BASE_REF" "$DIFF_STAT"; exit 0; }
  tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
  tribunal_review_prompt opencode "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"
  {
    printf '\nJSON Schema (strictly conform; return one JSON object only, no prose):\n'
    jq -c . "$SCHEMA_FILE"
    printf '\n\n===== BEGIN UNIFIED DIFF (authoritative; review only these changed lines) =====\n'
    cat "$DIFF_FILE"
    printf '\n===== END UNIFIED DIFF =====\n'
  } >> "$PROMPT_FILE"
fi

rc=0
(cd "$WALK_ROOT" && tribunal_leg_env 'OPENCODE_*' 'XDG_*' -- timeout -k 10 "$TIMEOUT" \
  opencode run --standalone --format json --agent plan -m "$MODEL_SPEC" \
  < "$PROMPT_FILE" > "$OUT" 2> "$ERR") || rc=$?

err_event="$(jq -Rrc 'fromjson? | select(type == "object" and .type == "error")' < "$OUT" 2>/dev/null | tail -n 1)"
if [ -n "$err_event" ] || [ "$rc" -ne 0 ]; then
  err_type="$(printf '%s\n' "$err_event" | jq -r '.error.type? // empty' 2>/dev/null || true)"
  err_msg="$(printf '%s\n' "$err_event" | jq -r '.error.message? // .message? // empty' 2>/dev/null \
    | LC_ALL=C tr -cd '\40-\176' | head -c 240)"
  msg="OpenCode execution failed or timed out"
  if [ -n "$err_type" ] && [ -n "$err_msg" ]; then
    msg="OpenCode execution failed ($err_type): $err_msg"
  elif [ -n "$err_type" ]; then
    msg="OpenCode execution failed ($err_type)"
  elif [ -n "$err_msg" ]; then
    msg="OpenCode execution failed: $err_msg"
  fi
  case "$rc" in
    124|137) ;;
    *)
      case "$err_type" in
        provider.go-limit|provider.free-limit|provider.budget-limit|provider.model-budget-limit)
          msg="plan limit: $msg"
          ;;
        '')
          if tribunal_plan_limited "$rc" "$OUT" "$ERR"; then
            msg="plan limit: $msg"
          fi
          ;;
      esac
      ;;
  esac
  tribunal_error_with_diagnostics opencode "$msg" execution "$rc" "$OUT" "$ERR"
  exit 0
fi

terminal="$(jq -Rrn '
  [inputs | fromjson? | select(type == "object")] as $ev |
  ([ $ev[] | select(.type == "step_start" or .type == "text" or .type == "step_finish")
      | (.part.messageID? // .messageID? // empty)
      | select(type == "string" and length > 0) ] | last) as $last_mid |
  if $last_mid != null then
    [ $ev[] | select(.type == "text" and ((.part.messageID? // .messageID?) == $last_mid))
        | (.part.text? // .text? // empty) ] | join("")
  else
    [ $ev[] | select(.type == "text") | (.part.text? // .text? // empty) ] | join("")
  end
' < "$OUT" 2>/dev/null || true)"

if [ -z "$terminal" ]; then
  tribunal_error_with_diagnostics opencode "OpenCode returned empty final text" parse "$rc" "$OUT" "$ERR"
  exit 0
fi

if [ "$MODE" = smoke ]; then
  printf '%s\n' "$terminal" | tribunal_extract_json_object \
    | tribunal_emit_review opencode "" "$OUT" "$ERR" "$rc" \
    | tribunal_stamp_executed_model opencode "$MODEL_BASE" "$OUT" "$ERR" "$rc"
else
  printf '%s\n' "$terminal" | tribunal_extract_json_object \
    | tribunal_emit_review opencode "" "$OUT" "$ERR" "$rc" \
    | tribunal_stamp_executed_model opencode "$MODEL_BASE" "$OUT" "$ERR" "$rc" \
    | tribunal_line_check "$REPO_ROOT" "$DIFF_STAT" \
    | tribunal_stamp_diff_stat "$DIFF_STAT"
fi
