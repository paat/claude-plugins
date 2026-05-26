#!/usr/bin/env bash
# Test runner for agent-sync hook (check-source-edit.sh)
# Self-contained: bash 4+ and jq only.
# Usage: bash plugins/agent-sync/tests/run-tests.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/check-source-edit.sh"
PASS=0
FAIL=0

# run NAME PAYLOAD EXPECT
#   EXPECT="" means expect empty stdout; otherwise expect stdout to contain EXPECT.
run() {
  local name="$1" payload="$2" expect="$3" out ec
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"; ec=$?
  if [[ $ec -ne 0 ]]; then
    echo "FAIL: $name — hook exited $ec (expected 0)"; FAIL=$((FAIL+1)); return
  fi
  if [[ -z "$expect" ]]; then
    if [[ -z "$out" ]]; then echo "PASS: $name"; PASS=$((PASS+1));
    else echo "FAIL: $name — expected empty stdout, got: $out"; FAIL=$((FAIL+1)); fi
  else
    if [[ "$out" == *"$expect"* ]]; then echo "PASS: $name"; PASS=$((PASS+1));
    else echo "FAIL: $name — expected substring '$expect', got: $out"; FAIL=$((FAIL+1)); fi
  fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Configured repo fixture
mkdir -p "$TMP/with/tools/agent-sync" "$TMP/with/.claude/rules"
echo "# claude rules" > "$TMP/with/CLAUDE.md"
echo "# architecture" > "$TMP/with/.claude/rules/architecture.md"
echo "# readme" > "$TMP/with/README.md"
cat > "$TMP/with/tools/agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"main":"CLAUDE.md","arch":".claude/rules/architecture.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"Architecture","source":"arch","type":"full-body"}]}]}
JSON

# Unconfigured repo fixture
mkdir -p "$TMP/noconfig"
echo "# claude rules" > "$TMP/noconfig/CLAUDE.md"

# .agent-sync layout fixture
mkdir -p "$TMP/alt/.agent-sync"
echo "# claude rules" > "$TMP/alt/CLAUDE.md"
cat > "$TMP/alt/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"main":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"Rules","source":"main","type":"full-body"}]}]}
JSON

run "no config -> silent" \
  "{\"tool_input\":{\"file_path\":\"$TMP/noconfig/CLAUDE.md\"},\"cwd\":\"$TMP/noconfig\"}" ""
run "tracked file -> reminder" \
  "{\"tool_input\":{\"file_path\":\"$TMP/with/CLAUDE.md\"},\"cwd\":\"$TMP/with\"}" "/agent-sync:generate"
run "tracked nested file -> reminder" \
  "{\"tool_input\":{\"file_path\":\"$TMP/with/.claude/rules/architecture.md\"},\"cwd\":\"$TMP/with\"}" "/agent-sync:generate"
run "untracked file -> silent" \
  "{\"tool_input\":{\"file_path\":\"$TMP/with/README.md\"},\"cwd\":\"$TMP/with\"}" ""
run ".agent-sync layout tracked -> reminder" \
  "{\"tool_input\":{\"file_path\":\"$TMP/alt/CLAUDE.md\"},\"cwd\":\"$TMP/alt\"}" "/agent-sync:generate"
run "relative file_path -> reminder" \
  "{\"tool_input\":{\"file_path\":\"CLAUDE.md\"},\"cwd\":\"$TMP/with\"}" "/agent-sync:generate"
run "malformed stdin -> silent" "not json at all" ""
run "missing file_path -> silent" "{\"cwd\":\"$TMP/with\"}" ""
run "empty stdin -> silent" "" ""

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
