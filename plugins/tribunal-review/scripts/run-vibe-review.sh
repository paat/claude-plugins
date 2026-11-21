#!/usr/bin/env bash
# Vibe tribunal leg: repo-walking read-only review through `vibe` (headless).
# --enabled-tools read_file leaves read_file as the only tool (no shell, no
# search, no writes). A pre-launch zero-price gate refuses paid or unverified
# routes before either mode runs; --max-price 0 stays only as a backstop
# because vibe 3.1.4 enforces that limit after the first priced call.
# Flags verified against vibe 3.1.4.
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
# Zero-spend gate before either mode launches: --max-price 0 admits the first
# priced call, so only a verified zero-price route may run. Refusals are
# disabled markers, never errors, so an unverified route cannot cost quorum noise.
if ! price_note="$(tribunal_vibe_free_route "$VIBE_MODEL")"; then
  tribunal_disabled vibe "$price_note"
  exit 0
fi
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
  # Transport probe: a short structured response with no file-review claim.
  # File access is proven by read_file events in real reviews, not here.
  cat > "$PROMPT_FILE" <<'PROMPT'
You are a tribunal smoke probe. Reply with exactly this JSON object and nothing else:
{
  "provider": "vibe",
  "model": "default",
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
# Session evidence carries the resolved alias (active_model) and the executed
# provider model (model_name); prefer the provider name, fall back to the alias.
served_model="$(jq -r '.config.model_name // empty' "$EXPORT_PARENT/export.json" 2>/dev/null)"
[ -n "$served_model" ] || served_model="$(jq -r '.config.active_model // empty' "$EXPORT_PARENT/export.json" 2>/dev/null)"
if [ "$rc" -ne 0 ] || [ -z "$terminal" ]; then
  if [ "$outcome" = price_limit ] || grep -q 'Missing MISTRAL_API_KEY' "$ERR" 2>/dev/null; then
    tribunal_error_with_diagnostics vibe "plan limit: Vibe execution stopped before completing (outcome: ${outcome:-missing})" \
      execution "$rc" "$OUT" "$ERR"
  else
    tribunal_error_with_diagnostics vibe "Vibe execution failed or timed out" execution "$rc" "$OUT" "$ERR"
  fi
  exit 0
fi
# The served model must be the requested id or its documented versioned form
# (mistral-large-4 → mistral-large-4-0 or mistral-large-4-0-3). Anything else —
# including preview builds — fails the leg, and the served name (not the
# requested alias) is stamped as the reviewer identity.
if [ -n "$served_model" ]; then
  want_lower="$(printf '%s' "$VIBE_MODEL" | tr '[:upper:]' '[:lower:]')"
  got_lower="$(printf '%s' "$served_model" | tr '[:upper:]' '[:lower:]')"
  version_ok=0
  if [ "$got_lower" = "$want_lower" ]; then
    version_ok=1
  else
    case "$got_lower" in
      "$want_lower"-*)
        tail="${got_lower#"$want_lower"-}"
        case "$tail" in
          [0-9]*)
            case "$tail" in *[!0-9.-]*) ;; *) version_ok=1 ;; esac
            ;;
        esac
        ;;
    esac
  fi
  if [ "$version_ok" -ne 1 ]; then
    tribunal_error_with_diagnostics vibe "Vibe served model $served_model, not the requested $VIBE_MODEL" \
      model_family "$rc" "$OUT" "$ERR"
    exit 0
  fi
fi
if [ "$MODE" = smoke ]; then
  printf '%s\n' "$terminal" | tribunal_extract_json_object \
    | tribunal_emit_review vibe "" "$OUT" "$ERR" "$rc" \
    | tribunal_stamp_executed_model vibe "$served_model" "$OUT" "$ERR" "$rc"
else
  printf '%s\n' "$terminal" | tribunal_extract_json_object \
    | tribunal_emit_review vibe "" "$OUT" "$ERR" "$rc" \
    | tribunal_stamp_executed_model vibe "$served_model" "$OUT" "$ERR" "$rc" \
    | tribunal_line_check "$REPO_ROOT" "$DIFF_STAT" \
    | tribunal_stamp_diff_stat "$DIFF_STAT"
fi
