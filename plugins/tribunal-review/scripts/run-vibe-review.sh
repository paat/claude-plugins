#!/usr/bin/env bash
# Vibe tribunal leg: repo-walking read-only review through `vibe` (headless).
# --enabled-tools read_file leaves read_file as the only tool (no shell, no
# search, no writes); --max-price 0 stops the run before any call can spend
# paid credit. Flags verified against vibe 3.1.4.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

case "${TRIBUNAL_VIBE:-auto}" in
  off) tribunal_disabled vibe "Vibe leg disabled via TRIBUNAL_VIBE=off"; exit 0 ;;
  on|auto|'') ;;
  *) tribunal_error vibe "invalid TRIBUNAL_VIBE: ${TRIBUNAL_VIBE} (want on, off, or auto)"; exit 0 ;;
esac
MODE=review
case "${1:-}" in
  '') ;;
  --smoke) MODE=smoke ;;
  *) tribunal_error vibe 'Usage: run-vibe-review.sh [--smoke]'; exit 0 ;;
esac
command -v vibe >/dev/null 2>&1 || {
  if [ "${TRIBUNAL_VIBE:-auto}" = on ]; then
    tribunal_error vibe "Vibe CLI (vibe) not on PATH"
  else
    tribunal_disabled vibe "Vibe CLI (vibe) not on PATH"
  fi
  exit 0
}
if ! vibe_note="$(tribunal_vibe_available)"; then
  if [ "${TRIBUNAL_VIBE:-auto}" = on ]; then
    tribunal_error vibe "$vibe_note"
  else
    tribunal_disabled vibe "Vibe leg idle (default auto; $vibe_note)"
  fi
  exit 0
fi

# Panel rows pin mistral-large-4, which only answers default/low/medium/high
# thinking (other levels are an API 400). Standalone runs use the risk-tier
# effort, or no --thinking when TRIBUNAL_RISK is unset.
VIBE_MODEL="$(tribunal_vibe_model)"
case "$VIBE_MODEL" in
  ''|*[!A-Za-z0-9._/-]*) tribunal_error vibe "invalid TRIBUNAL_VIBE_MODEL: $VIBE_MODEL"; exit 0 ;;
esac
RISK_EFFORT="$(tribunal_risk_effort vibe 2>&1)" || { tribunal_error vibe "$RISK_EFFORT"; exit 0; }
VIBE_EFFORT="${TRIBUNAL_VIBE_EFFORT:-$RISK_EFFORT}"
case "$VIBE_EFFORT" in
  ''|low|medium|high) ;;
  *) tribunal_error vibe "invalid TRIBUNAL_VIBE_EFFORT: $VIBE_EFFORT (want low, medium, or high)"; exit 0 ;;
esac
TIMEOUT="${TRIBUNAL_VIBE_TIMEOUT_SECONDS:-600}"
MAX_TURNS="${TRIBUNAL_VIBE_MAX_TURNS:-50}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=600 ;; esac
case "$MAX_TURNS" in ''|*[!0-9]*) MAX_TURNS=50 ;; esac
[ "$TIMEOUT" -ge 30 ] || TIMEOUT=30
[ "$TIMEOUT" -le 1800 ] || TIMEOUT=1800
[ "$MAX_TURNS" -ge 1 ] || MAX_TURNS=1
[ "$MAX_TURNS" -le 200 ] || MAX_TURNS=200

BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
REPO_ROOT="$(tribunal_repo_root)"
PROMPT_FILE="$TMPDIR/prompt.md"
OUT="$TMPDIR/out.jsonl"
ERR="$TMPDIR/err.txt"
EXPORT_PARENT="$TMPDIR/export"

if [ "$MODE" = smoke ]; then
  RUN_TIMEOUT="${TRIBUNAL_SMOKE_TIMEOUT_SECONDS:-60}"
  # The model refuses to emit an uninspected APPROVE, so smoke is an honest
  # micro-review of one trivial file, not the canned no-inspection prompt.
  printf 'tribunal smoke probe\n' > "$TMPDIR/smoke.txt"
  cat > "$PROMPT_FILE" <<'PROMPT'
You are a senior code reviewer. Read the file smoke.txt in the working directory
with read_file (your only tool) and review its one line.

Report JSON only:
{
  "provider": "vibe",
  "model": "default",
  "files_examined": ["smoke.txt"],
  "findings": [],
  "summary": {
    "total_findings": 0,
    "critical": 0,
    "high": 0,
    "medium": 0,
    "low": 0,
    "quality_score": 10.0,
    "verdict": "APPROVE"
  }
}

Rules: report only actionable findings with confidence >= 0.7 in the schema
above; when the file holds no defect, return it unchanged with an empty
findings list. List smoke.txt under files_examined.
PROMPT
  WALK_ROOT="$TMPDIR"
else
  RUN_TIMEOUT="$TIMEOUT"
  tribunal_prepare_review_input "$TMPDIR" || exit 1
  DIFF_FILE="$TRIBUNAL_REVIEW_INPUT_DIR/review.diff"
  CONTEXT_FILE="$TRIBUNAL_REVIEW_INPUT_DIR/context.md"
  WALK_ROOT="$(tribunal_walk_root "$TMPDIR/walk")" \
    || { tribunal_error vibe "cannot prepare a checkout without the repository's untracked .env files"; exit 0; }
  tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error vibe "cannot diff against $BASE_REF"; exit 0; }
  DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
  [ -s "$DIFF_FILE" ] || { tribunal_empty vibe "$VIBE_MODEL" "$BASE_REF" "$DIFF_STAT"; exit 0; }
  tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
  tribunal_review_prompt vibe "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"
  # Inline the diff: read_file cannot reach the runner's temp dir.
  {
    printf '\n\n===== BEGIN UNIFIED DIFF (authoritative; review only these changed lines) =====\n'
    cat "$DIFF_FILE"
    printf '\n===== END UNIFIED DIFF =====\n'
  } >> "$PROMPT_FILE"
fi

vibe_args=(--prompt-file "$PROMPT_FILE" --output streaming --max-turns "$MAX_TURNS"
  --max-price 0 --output-dir "$EXPORT_PARENT"
  --enabled-tools read_file
  --model "$VIBE_MODEL")
[ -z "$VIBE_EFFORT" ] || vibe_args+=(--thinking "$VIBE_EFFORT")

rc=0
(cd "$WALK_ROOT" && tribunal_leg_env 'VIBE_*' MISTRAL_API_KEY -- timeout -k 10 "$RUN_TIMEOUT" \
  vibe "${vibe_args[@]}") < /dev/null > "$OUT" 2> "$ERR" || rc=$?

# The stream holds every assistant message of the run; the last committed one is the answer.
terminal="$(jq -rs '[.[] | select(.type == "message" and .role == "assistant" and .outcome.type == "committed")] | last
  | [.content[]? | select(.type == "text") | .text] | join("")' "$OUT" 2>/dev/null)"
outcome="$(jq -r '.outcome // empty' "$EXPORT_PARENT/export.json" 2>/dev/null)"
actual_model="$(jq -r '.config.active_model // empty' "$EXPORT_PARENT/export.json" 2>/dev/null)"
if [ "$rc" -ne 0 ] || [ -z "$terminal" ]; then
  if [ "$outcome" = price_limit ] || grep -q 'Missing MISTRAL_API_KEY' "$ERR" 2>/dev/null; then
    tribunal_error_with_diagnostics vibe "plan limit: Vibe execution stopped before completing (outcome: ${outcome:-missing})" \
      execution "$rc" "$OUT" "$ERR"
  else
    tribunal_error_with_diagnostics vibe "Vibe execution failed or timed out" execution "$rc" "$OUT" "$ERR"
  fi
  exit 0
fi
# The CLI catalog may resolve an alias to a versioned id
# (mistral-large-4 → mistral-large-4-0); accept that suffix, nothing else.
if [ -n "$actual_model" ]; then
  case "${actual_model,,}" in
    "${VIBE_MODEL,,}"|"${VIBE_MODEL,,}"-[0-9]*|"${VIBE_MODEL,,}".[0-9]*) ;;
    *)
      tribunal_error_with_diagnostics vibe "Vibe configured model $actual_model, not the requested $VIBE_MODEL" \
        model_family "$rc" "$OUT" "$ERR"
      exit 0
      ;;
  esac
fi
if [ "$MODE" = smoke ]; then
  printf '%s\n' "$terminal" | tribunal_extract_json_object \
    | tribunal_emit_review vibe "" "$OUT" "$ERR" "$rc" \
    | tribunal_stamp_executed_model vibe "$actual_model" "$OUT" "$ERR" "$rc"
else
  printf '%s\n' "$terminal" | tribunal_extract_json_object \
    | tribunal_emit_review vibe "" "$OUT" "$ERR" "$rc" \
    | tribunal_stamp_executed_model vibe "$actual_model" "$OUT" "$ERR" "$rc" \
    | tribunal_line_check "$REPO_ROOT" "$DIFF_STAT" \
    | tribunal_stamp_diff_stat "$DIFF_STAT"
fi
