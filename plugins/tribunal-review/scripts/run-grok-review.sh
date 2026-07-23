#!/usr/bin/env bash
# Grok tribunal leg: deterministic read-only review with inspect → finalize resume.
# Never reports success on progress-only output; recovers timeout/incomplete via
# a tools-off resume of the same session (issue #331).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_GROK:-on}" = "off" ]; then tribunal_disabled grok "Grok leg disabled via TRIBUNAL_GROK=off"; exit 0; fi
command -v grok >/dev/null 2>&1 || { tribunal_error grok "Grok CLI not on PATH"; exit 0; }
# Dead OIDC sessions fail at execution with "Not signed in"; catch early like Claude (issue #374).
tribunal_grok_authenticated || {
  tribunal_error grok "Grok CLI is not signed in (no usable auth.json / XAI_API_KEY). For Max/OAuth: grok login --device-code"
  exit 0
}

GROK_MODEL="${TRIBUNAL_GROK_MODEL:-grok-4.5}"
INSPECT_TIMEOUT="${TRIBUNAL_GROK_TIMEOUT_SECONDS:-600}"
FINALIZE_TIMEOUT="${TRIBUNAL_GROK_FINALIZE_TIMEOUT_SECONDS:-120}"
INSPECT_MAX_TURNS="${TRIBUNAL_GROK_MAX_TURNS:-30}"
FINALIZE_MAX_TURNS="${TRIBUNAL_GROK_FINALIZE_MAX_TURNS:-6}"
# Clamp knobs so a mis-set env cannot hang the panel indefinitely (lower + upper).
case "$INSPECT_TIMEOUT" in ''|*[!0-9]*) INSPECT_TIMEOUT=600 ;; esac
case "$FINALIZE_TIMEOUT" in ''|*[!0-9]*) FINALIZE_TIMEOUT=120 ;; esac
case "$INSPECT_MAX_TURNS" in ''|*[!0-9]*) INSPECT_MAX_TURNS=30 ;; esac
case "$FINALIZE_MAX_TURNS" in ''|*[!0-9]*) FINALIZE_MAX_TURNS=6 ;; esac
[ "$INSPECT_TIMEOUT" -ge 30 ] || INSPECT_TIMEOUT=30
[ "$INSPECT_TIMEOUT" -le 1800 ] || INSPECT_TIMEOUT=1800
[ "$FINALIZE_TIMEOUT" -ge 15 ] || FINALIZE_TIMEOUT=15
[ "$FINALIZE_TIMEOUT" -le 600 ] || FINALIZE_TIMEOUT=600
[ "$INSPECT_MAX_TURNS" -ge 1 ] || INSPECT_MAX_TURNS=1
[ "$INSPECT_MAX_TURNS" -le 80 ] || INSPECT_MAX_TURNS=80
[ "$FINALIZE_MAX_TURNS" -ge 1 ] || FINALIZE_MAX_TURNS=1
[ "$FINALIZE_MAX_TURNS" -le 20 ] || FINALIZE_MAX_TURNS=20

BASE_REF="$(tribunal_base_ref)"
# Capture host auth path before HOME isolation. Copy (never symlink) so OIDC refresh
# token rotation under the scratch home can be written back to the host (issue #374).
AUTH_SRC="$(tribunal_grok_auth_file)"
TMPDIR="$(mktemp -d)" || exit 1
ISOLATED_HOME="$TMPDIR/grok-home"
AUTH_ISOLATED="$ISOLATED_HOME/.grok/auth.json"
tribunal_grok_cleanup() {
  # Write refreshed tokens home before deleting the scratch tree.
  tribunal_grok_auth_writeback "$AUTH_ISOLATED" "$AUTH_SRC" 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap 'tribunal_grok_cleanup' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
PROMPT_FILE="$TMPDIR/prompt.md"
FINALIZE_PROMPT="$TMPDIR/finalize.md"
REPO_ROOT="$(tribunal_repo_root)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error grok "cannot diff against $BASE_REF"; exit 0; }
[ -s "$DIFF_FILE" ] || { tribunal_empty grok "$GROK_MODEL" "$BASE_REF"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
tribunal_review_prompt grok "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"
# Inline the diff so the leg does not depend on grok reading a path outside --cwd.
# Grok may still repo-walk with read_file/list_dir/grep to verify cross-file effects.
{
  printf '\n\n===== BEGIN UNIFIED DIFF (authoritative; review only these changed lines) =====\n'
  cat "$DIFF_FILE"
  printf '\n===== END UNIFIED DIFF =====\n'
  printf '\nCompletion contract: after gathering evidence, emit the review JSON matching the schema and stop. Do not end on a plan or progress announcement without the JSON verdict.\n'
} >> "$PROMPT_FILE"

# Finalize re-inlines the authoritative diff so a tools-off resume can still
# produce a real review even if session recall of the inspect turn is thin.
# Never instruct the model to manufacture APPROVE merely because tools failed.
{
  cat <<'EOF'
Stop inspecting. Do not use tools. Emit the final review JSON matching the required schema now.

Rules for this finalize turn:
- Output the structured review only (provider, model, findings, summary with verdict).
- Base the verdict on the unified diff below (authoritative) plus any evidence already gathered in this session. Tool use was optional verification only; the diff alone is enough to review.
- Verdict must be APPROVE, NEEDS_WORK, or BLOCK from reviewing that diff — never invent APPROVE because inspection timed out or tools were unavailable.
- Never reply with a plan, progress announcement, or blocked-tool narrative alone.

===== BEGIN UNIFIED DIFF (authoritative; review only these changed lines) =====
EOF
  cat "$DIFF_FILE"
  printf '\n===== END UNIFIED DIFF =====\n'
} > "$FINALIZE_PROMPT"

# Isolate host user config (Claude skills/hooks/CLAUDE.md, GROK_SANDBOX inheritance) while
# preserving auth via a durable copy. The child runs with a scratch HOME + GROK_HOME so host
# ~/.claude is not scanned. Sessions live under this scratch home for the duration of the
# script so inspect → finalize resume stays deterministic. EXIT trap write-backs auth.json.
mkdir -p "$ISOLATED_HOME/.grok" "$ISOLATED_HOME/.claude"
if [ -f "$AUTH_SRC" ]; then
  # Regular file copy only — symlink + atomic replace severs host OIDC refresh (issue #374).
  cp -a "$AUTH_SRC" "$AUTH_ISOLATED"
fi
cat > "$ISOLATED_HOME/.grok/config.toml" <<'EOF'
# Tribunal Grok leg: no foreign-vendor project instructions, skills, hooks, or MCP.
[compat.claude]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[compat.cursor]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[compat.codex]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[features]
telemetry = false
feedback = false
codebase_indexing = false
EOF

SCHEMA_JSON="$(jq -c . "$(tribunal_review_schema)")"
SESSION_ID="$(tribunal_grok_new_session_id)"
INSPECT_OUT="$TMPDIR/inspect.out"
INSPECT_ERR="$TMPDIR/inspect.err"
FINALIZE_OUT="$TMPDIR/finalize.out"
FINALIZE_ERR="$TMPDIR/finalize.err"
LAST_OUT="$INSPECT_OUT"
LAST_ERR="$INSPECT_ERR"
LAST_RC=0

# Shared env: kernel read-only sandbox + tools allowlist (inspect) or tools off (finalize).
# Unset GROK_SANDBOX so a host export cannot override the explicit profile.
# Permission mode dontAsk is safe: only read-only tools are allowed on inspect, none on finalize.
run_grok() {
  local phase="$1" tools="$2" max_turns="$3" timeout_s="$4" out="$5" err="$6" prompt="$7"
  local -a session_args=()
  if [ "$phase" = inspect ]; then
    session_args=(--session-id "$SESSION_ID")
  else
    session_args=(--resume "$SESSION_ID")
  fi
  env -u GROK_SANDBOX \
    HOME="$ISOLATED_HOME" \
    GROK_HOME="$ISOLATED_HOME/.grok" \
    timeout -k 10 "$timeout_s" grok --model "$GROK_MODEL" --output-format json \
    --json-schema "$SCHEMA_JSON" \
    --tools "$tools" \
    --sandbox read-only \
    --permission-mode dontAsk \
    --disable-web-search \
    --no-subagents --no-plan --no-memory \
    --max-turns "$max_turns" \
    "${session_args[@]}" \
    --cwd "$REPO_ROOT" --prompt-file "$prompt" \
    > "$out" 2> "$err"
}

emit_from_envelope() {
  local out="$1" err="$2" rc="$3" response json actual_model sid
  response="$(tribunal_extract_grok_result < "$out" || true)"
  if ! printf '%s' "$response" | tribunal_review_payload_complete; then
    return 1
  fi
  json="$(printf '%s' "$response" | tribunal_extract_json_object)"
  actual_model="$(jq -r '(.modelUsage // {}) | to_entries | (.[0].key // empty)' "$out" 2>/dev/null || true)"
  [ -n "$actual_model" ] && json="$(printf '%s' "$json" | jq --arg m "$actual_model" '.model = $m')"
  printf '%s' "$json" \
    | tribunal_emit_review grok "" "$out" "$err" "$rc" \
    | tribunal_line_check "$REPO_ROOT" "$DIFF_FILE"
  return 0
}

capture_session_id() {
  local out="$1" sid
  sid="$(tribunal_grok_session_id < "$out" 2>/dev/null || true)"
  if [ -n "$sid" ]; then
    SESSION_ID="$sid"
  fi
}

incomplete_error() {
  local phase="$1" rc="$2" out="$3" err="$4" detail="$5"
  tribunal_error_with_diagnostics grok \
    "incomplete Grok review ($detail); session_id=$SESSION_ID; completion_state=progress_only" \
    "$phase" "$rc" "$out" "$err"
}

# --- Phase 1: inspect (read-only tools) ---
rc=0
run_grok inspect "read_file,list_dir,grep" "$INSPECT_MAX_TURNS" "$INSPECT_TIMEOUT" \
  "$INSPECT_OUT" "$INSPECT_ERR" "$PROMPT_FILE" || rc=$?
LAST_OUT="$INSPECT_OUT"
LAST_ERR="$INSPECT_ERR"
LAST_RC=$rc
capture_session_id "$INSPECT_OUT"

if [ "$rc" -eq 0 ] && emit_from_envelope "$INSPECT_OUT" "$INSPECT_ERR" "$rc"; then
  exit 0
fi

# Hard failure with no session artifact: do not pretend we can resume.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ ! -s "$INSPECT_OUT" ]; then
  tribunal_error_with_diagnostics grok "Grok execution failed or timed out" execution \
    "$rc" "$INSPECT_OUT" "$INSPECT_ERR"
  exit 0
fi

# --- Phase 2: finalize (tools off, same session) ---
# Covers: progress-only exit 0, max-turns stop, timeout (124), interrupted inspect with partial envelope.
frc=0
run_grok finalize "" "$FINALIZE_MAX_TURNS" "$FINALIZE_TIMEOUT" \
  "$FINALIZE_OUT" "$FINALIZE_ERR" "$FINALIZE_PROMPT" || frc=$?
LAST_OUT="$FINALIZE_OUT"
LAST_ERR="$FINALIZE_ERR"
LAST_RC=$frc
capture_session_id "$FINALIZE_OUT"

if [ "$frc" -eq 0 ] && emit_from_envelope "$FINALIZE_OUT" "$FINALIZE_ERR" "$frc"; then
  exit 0
fi

# Prefer finalize diagnostics; fall back to inspect if finalize produced nothing.
if [ ! -s "$FINALIZE_OUT" ] && [ -s "$INSPECT_OUT" ]; then
  LAST_OUT="$INSPECT_OUT"
  LAST_ERR="$INSPECT_ERR"
  LAST_RC=$rc
fi

if [ "$rc" -eq 124 ] || [ "$frc" -eq 124 ]; then
  incomplete_error timeout "$LAST_RC" "$LAST_OUT" "$LAST_ERR" \
    "inspect_rc=$rc finalize_rc=$frc; timed out before schema verdict"
elif [ "$frc" -ne 0 ] && [ "$rc" -ne 0 ]; then
  tribunal_error_with_diagnostics grok \
    "Grok execution failed or timed out; session_id=$SESSION_ID; completion_state=blocked" \
    execution "$LAST_RC" "$LAST_OUT" "$LAST_ERR"
else
  incomplete_error incomplete "$LAST_RC" "$LAST_OUT" "$LAST_ERR" \
    "inspect_rc=$rc finalize_rc=$frc; no structured verdict after tools-off resume"
fi
