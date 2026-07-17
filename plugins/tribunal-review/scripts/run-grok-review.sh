#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ "${TRIBUNAL_GROK:-off}" != "on" ]; then tribunal_disabled grok "Grok leg disabled (default off); set TRIBUNAL_GROK=on to enable"; exit 0; fi
command -v grok >/dev/null 2>&1 || { tribunal_error grok "Grok CLI not on PATH"; exit 0; }

GROK_MODEL="${TRIBUNAL_GROK_MODEL:-grok-4.5}"
BASE_REF="$(tribunal_base_ref)"
TMPDIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPDIR"' EXIT
DIFF_FILE="$TMPDIR/review.diff"
CONTEXT_FILE="$TMPDIR/context.md"
PROMPT_FILE="$TMPDIR/prompt.md"
REPO_ROOT="$(tribunal_repo_root)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error grok "cannot diff against $BASE_REF"; exit 0; }
[ -s "$DIFF_FILE" ] || { tribunal_empty grok "$GROK_MODEL" "$BASE_REF"; exit 0; }
tribunal_context_block "$REPO_ROOT" "$CONTEXT_FILE"
tribunal_review_prompt grok "$DIFF_FILE" "$CONTEXT_FILE" "repo-walking" > "$PROMPT_FILE"
# grok reads the prompt from --prompt-file (no argv limit); inline the diff so the leg does not
# depend on grok reading a path outside --cwd. grok still repo-walks to verify cross-file effects.
{
  printf '\n\n===== BEGIN UNIFIED DIFF (authoritative; review only these changed lines) =====\n'
  cat "$DIFF_FILE"
  printf '\n===== END UNIFIED DIFF =====\n'
} >> "$PROMPT_FILE"

# Isolate host user config (Claude skills/hooks/CLAUDE.md, GROK_SANDBOX inheritance) while
# preserving auth. Auth is linked from the pre-isolation GROK_HOME/HOME; the child runs with a
# scratch HOME + GROK_HOME so host ~/.claude is not scanned.
AUTH_SRC="${GROK_HOME:-${HOME}/.grok}/auth.json"
ISOLATED_HOME="$TMPDIR/grok-home"
mkdir -p "$ISOLATED_HOME/.grok" "$ISOLATED_HOME/.claude"
# Preserve login credentials without importing the rest of the host Grok/Claude config.
if [ -e "$AUTH_SRC" ]; then
  ln -s "$AUTH_SRC" "$ISOLATED_HOME/.grok/auth.json"
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
rc=0
# Read-only is tool-enforced (--tools allowlist: no bash/write/edit) and kernel-enforced
# (--sandbox read-only: project tree is not writable). Unset GROK_SANDBOX so a host export
# cannot override the explicit profile. Drop bypassPermissions — remaining tools are read-only.
env -u GROK_SANDBOX \
  HOME="$ISOLATED_HOME" \
  GROK_HOME="$ISOLATED_HOME/.grok" \
  timeout -k 10 600 grok --model "$GROK_MODEL" --output-format json \
  --json-schema "$SCHEMA_JSON" \
  --tools "read_file,list_dir,grep" \
  --sandbox read-only \
  --disable-web-search \
  --no-subagents --no-plan --no-memory \
  --cwd "$REPO_ROOT" --prompt-file "$PROMPT_FILE" \
  > "$TMPDIR/out.txt" 2> "$TMPDIR/err.txt" || rc=$?
if [ "$rc" -eq 0 ]; then
  response="$(jq -r '
    if (.structured_output? | type) == "object" then (.structured_output | tojson)
    elif (.text? | type) == "string" and (.text | length) > 0 then .text
    else empty end
  ' "$TMPDIR/out.txt" 2>/dev/null || true)"
  if [ -n "$response" ]; then
    printf '%s\n' "$response" > "$TMPDIR/response.txt"
  else
    cp "$TMPDIR/out.txt" "$TMPDIR/response.txt"
  fi
  json="$(tribunal_extract_json_object < "$TMPDIR/response.txt")"
  if printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    actual_model="$(jq -r '(.modelUsage // {}) | to_entries | (.[0].key // empty)' "$TMPDIR/out.txt" 2>/dev/null || true)"
    [ -n "$actual_model" ] && json="$(printf '%s' "$json" | jq --arg m "$actual_model" '.model = $m')"
    printf '%s' "$json" \
      | tribunal_emit_review grok "" "$TMPDIR/out.txt" "$TMPDIR/err.txt" "$rc" \
      | tribunal_line_check "$REPO_ROOT" "$DIFF_FILE"
  else
    tribunal_error_with_diagnostics grok "unparseable Grok output" parse \
      "$rc" "$TMPDIR/out.txt" "$TMPDIR/err.txt"
  fi
else
  tribunal_error_with_diagnostics grok "Grok execution failed or timed out" execution \
    "$rc" "$TMPDIR/out.txt" "$TMPDIR/err.txt"
fi
