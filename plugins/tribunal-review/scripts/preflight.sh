#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "PREFLIGHT FAIL: jq is required." >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "PREFLIGHT FAIL: timeout is required." >&2; exit 1; }

BASE_REF="$(tribunal_base_ref)"
DEFAULT_BRANCH="$(tribunal_default_branch)"
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"

if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  echo "PREFLIGHT FAIL: on default branch '$DEFAULT_BRANCH'. Check out a review branch first." >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
  git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || {
    echo "PREFLIGHT FAIL: cannot resolve base ref $BASE_REF. Set TRIBUNAL_BASE_REF or fetch origin/$DEFAULT_BRANCH." >&2
    exit 1
  }
fi

if ! DIFF_STAT="$(git diff --stat "$BASE_REF"...HEAD 2>/dev/null)"; then
  echo "PREFLIGHT FAIL: cannot diff against $BASE_REF." >&2
  exit 1
fi
if [ -z "$DIFF_STAT" ]; then
  echo "PREFLIGHT FAIL: no changes to review against $BASE_REF." >&2
  exit 1
fi

min_ok_legs="$(tribunal_min_ok_legs)" || exit 2
risk_tier="$(tribunal_risk_tier)" || exit 2
tribunal_select_panel || exit 2
backup_legs="${TRIBUNAL_SELECTED_BACKUPS:-}"

providers_json="[]"
warnings_json="[]"
add_provider() {
  providers_json="$(printf '%s' "$providers_json" | jq --arg n "$1" --arg s "$2" --arg note "$3" '. + [{name:$n,status:$s,note:$note}]')"
}
add_warning() {
  warnings_json="$(printf '%s' "$warnings_json" | jq --arg n "$1" --arg note "$2" '. + [{name:$n,note:$note}]')"
}
ignored_paths_json="$(tribunal_ignored_additions "$BASE_REF")" || {
  echo "PREFLIGHT FAIL: cannot inspect ignored path additions." >&2; exit 1;
}
if [ "$(printf '%s' "$ignored_paths_json" | jq 'length')" -gt 0 ]; then
  add_warning ignored-path-additions "added paths ignored by Git: $(printf '%s' "$ignored_paths_json" \
    | jq -r 'map("\(.path) (pattern \(.pattern), \(.source):\(.line))") | join("; ")')"
fi
deleted_paths_json="$(tribunal_deleted_policy_paths "$BASE_REF")" || {
  echo "PREFLIGHT FAIL: cannot inspect deleted policy paths." >&2; exit 1;
}
if [ "$(printf '%s' "$deleted_paths_json" | jq 'length')" -gt 0 ]; then
  add_warning deleted-policy-paths "deleted policy/rules paths: $(printf '%s' "$deleted_paths_json" \
    | jq -r 'map("\(.path) (glob \(.glob))") | join("; ")')"
fi
provider_usable() {
  printf '%s' "$providers_json" | jq -e --arg n "$1" 'any(.[]; .name==$n and .status=="usable")' >/dev/null
}
set_provider_result() {
  providers_json="$(printf '%s' "$providers_json" | jq --arg n "$1" --arg s "$2" --arg note "$3" \
    'map(if .name==$n then .status=$s | .note=$note else . end)')"
}
smoke_review_ok() {
  local provider="$1"
  jq -s -e --arg p "$provider" '
    [.[] | select(.provider==$p and (has("error")|not) and (.findings|type)=="array" and (.summary|type)=="object")]
    | length==1
  ' >/dev/null 2>&1
}
smoke_failure_note() {
  local provider="$1" output="$2" detail=""
  detail="$(printf '%s\n' "$output" | jq -sr --arg p "$provider" \
    '[.[] | select(.provider==$p and (.error|type)=="string") | .error][0] // empty' \
    2>/dev/null || true)"
  if [ -n "$detail" ]; then
    printf 'non-interactive smoke failed: %s\n' "$detail"
  else
    printf '%s\n' "non-interactive smoke failed"
  fi
}

disabled_note() {
  case "${TRIBUNAL_EXPLICIT_OFF:- }" in
    *" $1 "*) printf 'TRIBUNAL_%s=off\n' "${1^^}" ;;
    *) printf 'not in selected panel\n' ;;
  esac
}

if [ "${TRIBUNAL_CODEX:-off}" != "on" ]; then add_provider codex disabled "$(disabled_note codex)"; elif command -v codex >/dev/null 2>&1; then add_provider codex usable "CLI present; non-interactive invocation not probed"; else add_provider codex skipped "CLI not on PATH"; fi
if [ "${TRIBUNAL_GEMINI:-off}" != "on" ]; then add_provider gemini disabled "$(disabled_note gemini)"; elif command -v agy >/dev/null 2>&1; then add_provider gemini usable "agy present; non-interactive invocation not probed"; else add_provider gemini skipped "agy not on PATH"; fi
if [ "${TRIBUNAL_QWEN:-off}" != "on" ]; then add_provider qwen disabled "$(disabled_note qwen)"; elif command -v qwen >/dev/null 2>&1; then add_provider qwen usable "CLI present; non-interactive invocation not probed"; else add_provider qwen skipped "CLI not on PATH"; fi
if [ "${TRIBUNAL_GROK:-off}" != "on" ]; then
  add_provider grok disabled "$(disabled_note grok)"
elif ! command -v grok >/dev/null 2>&1; then
  add_provider grok skipped "CLI not on PATH"
elif tribunal_grok_authenticated; then
  add_provider grok usable "CLI signed in; non-interactive invocation not probed"
else
  # Match Claude: a present CLI with a dead OIDC session is skipped, not usable (issue #374).
  add_provider grok skipped "CLI not signed in (no usable auth.json / XAI_API_KEY)"
fi
if [ "${TRIBUNAL_MUSE:-off}" != "on" ]; then add_provider muse disabled "$(disabled_note muse)"; elif command -v muse >/dev/null 2>&1; then add_provider muse usable "CLI present; non-interactive invocation not probed"; else add_provider muse skipped "CLI not on PATH"; fi
if [ "${TRIBUNAL_OPENCODE:-off}" != "on" ]; then
  add_provider opencode disabled "$(disabled_note opencode)"
elif opencode_note="$(tribunal_opencode_available)"; then
  add_provider opencode usable "OpenCode v2 CLI present; non-interactive invocation not probed"
else
  add_provider opencode skipped "$opencode_note"
fi
if [ "${TRIBUNAL_CLAUDE:-off}" != "on" ]; then
  add_provider claude disabled "$(disabled_note claude)"
elif ! command -v claude >/dev/null 2>&1; then
  add_provider claude skipped "CLI not on PATH"
elif tribunal_claude_authenticated; then
  add_provider claude usable "CLI authenticated; non-interactive invocation not probed"
else
  add_provider claude skipped "CLI not authenticated"
fi

if [ "${TRIBUNAL_GLM:-off}" = "on" ]; then
  add_warning retired-glm "GLM leg is retired; remove TRIBUNAL_GLM from the environment"
fi
if [ "${TRIBUNAL_DEEPSEEK:-off}" != "on" ]; then
  add_provider deepseek disabled "$(disabled_note deepseek)"
elif deepseek_note="$(tribunal_deepseek_available)"; then
  add_provider deepseek usable "dsh and credential present; non-interactive invocation not probed"
else
  add_provider deepseek skipped "$deepseek_note"
fi

if [ "${TRIBUNAL_SMOKE_PROBE:-off}" = on ]; then
  smoke_timeout="${TRIBUNAL_SMOKE_TIMEOUT_SECONDS:-60}"
  case "$smoke_timeout" in ''|*[!0-9]*) echo "PREFLIGHT FAIL: TRIBUNAL_SMOKE_TIMEOUT_SECONDS must be 5..300." >&2; exit 1 ;; esac
  [ "$smoke_timeout" -ge 5 ] && [ "$smoke_timeout" -le 300 ] \
    || { echo "PREFLIGHT FAIL: TRIBUNAL_SMOKE_TIMEOUT_SECONDS must be 5..300." >&2; exit 1; }
  export TRIBUNAL_SMOKE_TIMEOUT_SECONDS="$smoke_timeout"

  if provider_usable codex; then
    smoke_output="$(TRIBUNAL_DIAGNOSTIC_TAILS=off bash "$SCRIPT_DIR/run-codex-review.sh" --smoke 2>/dev/null || true)"
    if printf '%s\n' "$smoke_output" | smoke_review_ok codex; then
      set_provider_result codex usable "non-interactive smoke passed"
    else
      set_provider_result codex failed "$(smoke_failure_note codex "$smoke_output")"
    fi
  fi
  if provider_usable claude; then
    smoke_output="$(TRIBUNAL_DIAGNOSTIC_TAILS=off bash "$SCRIPT_DIR/run-claude-review.sh" --smoke 2>/dev/null || true)"
    if printf '%s\n' "$smoke_output" | smoke_review_ok claude; then
      set_provider_result claude usable "non-interactive smoke passed"
    else
      set_provider_result claude failed "$(smoke_failure_note claude "$smoke_output")"
    fi
  fi
  if provider_usable opencode; then
    smoke_output="$(TRIBUNAL_DIAGNOSTIC_TAILS=off bash "$SCRIPT_DIR/run-opencode-review.sh" --smoke 2>/dev/null || true)"
    if printf '%s\n' "$smoke_output" | smoke_review_ok opencode; then
      set_provider_result opencode usable "non-interactive smoke passed"
    else
      set_provider_result opencode failed "$(smoke_failure_note opencode "$smoke_output")"
    fi
  fi
  if provider_usable deepseek; then
    smoke_output="$(bash "$SCRIPT_DIR/run-deepseek-review.sh" --smoke 2>/dev/null || true)"
    if printf '%s\n' "$smoke_output" | smoke_review_ok deepseek; then
      set_provider_result deepseek usable "non-interactive smoke passed"
    else
      set_provider_result deepseek failed "$(smoke_failure_note deepseek "$smoke_output")"
    fi
  fi
fi

avail_kb="$(df -Pk "${TMPDIR:-/tmp}" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${avail_kb:-}" ] && [ "$avail_kb" -lt 2097152 ]; then
  add_warning disk "only $((avail_kb / 1024)) MiB free on ${TMPDIR:-/tmp}; reviewers may stall on writes"
fi

usable="$(printf '%s' "$providers_json" | jq '[.[] | select(.status=="usable")] | length')"
if [ "$usable" -lt "$min_ok_legs" ]; then
  available_backup_count=0
  available_backup_names=""
  while IFS= read -r backup; do
    [ -n "$backup" ] || continue
    if tribunal_backup_installed "$backup"; then
      available_backup_count=$((available_backup_count + 1))
      available_backup_names="${available_backup_names}${available_backup_names:+, }$backup"
    fi
  done <<< "$backup_legs"
  if [ "$usable" -eq 0 ] && [ "$available_backup_count" -lt "$min_ok_legs" ]; then
    echo "PREFLIGHT FAIL: zero active reviewer legs are usable." >&2
    printf '%s\n' "$providers_json" >&2
    exit 1
  fi
  if [ $((usable + available_backup_count)) -lt "$min_ok_legs" ]; then
    echo "PREFLIGHT FAIL: usable legs ($usable) below TRIBUNAL_MIN_OK_LEGS ($min_ok_legs)." >&2
    exit 1
  fi
  add_warning backup-quorum "quorum relies on available backup legs: $available_backup_names"
fi

jq -nc --arg base "$BASE_REF" --arg default "$DEFAULT_BRANCH" --argjson providers "$providers_json" \
  --argjson warnings "$warnings_json" --argjson min_ok_legs "$min_ok_legs" \
  --argjson panel_size "$TRIBUNAL_SELECTED_PANEL_SIZE" --argjson panel "$TRIBUNAL_SELECTED_PANEL_JSON" \
  --arg risk_tier "$risk_tier" --arg backup_legs "$backup_legs" \
  '{status:"ok",base_ref:$base,default_branch:$default,providers:$providers,warnings:$warnings,min_ok_legs:$min_ok_legs,
    panel_size:$panel_size,panel:$panel,
    risk_tier:(if $risk_tier == "" then null else $risk_tier end),
    backup_legs:($backup_legs | split("\n") | map(select(length > 0)))}'
