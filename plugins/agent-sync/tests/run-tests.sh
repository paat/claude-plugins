#!/usr/bin/env bash
# Test runner for agent-sync hook (check-source-edit.sh)
# Self-contained: bash 4+ and jq only.
# Usage: bash plugins/agent-sync/tests/run-tests.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/check-source-edit.sh"
GEN="$PLUGIN_ROOT/scripts/generate.sh"
PASS=0
FAIL=0

# The bundled tests below exercise the no-generator "nudge fallback" path; keep the inherited
# environment from steering the hook into live regeneration. Regeneration tests set these per-run.
unset CLAUDE_PLUGIN_ROOT AGENT_SYNC_AUTO_STAGE 2>/dev/null || true

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

# Fallback-path tests run with no generator present, so the hook only nudges and never writes.
assert_file_absent() {
  local name="$1" f="$2"
  if [[ -e "$f" ]]; then echo "FAIL: $name — file unexpectedly exists: $f"; FAIL=$((FAIL+1));
  else echo "PASS: $name"; PASS=$((PASS+1)); fi
}
assert_file_present() {
  local name="$1" f="$2"
  if [[ -e "$f" ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — expected file to exist: $f"; FAIL=$((FAIL+1)); fi
}
run "no generator -> nudge does not write AGENTS.md" \
  "{\"tool_input\":{\"file_path\":\"$TMP/with/CLAUDE.md\"},\"cwd\":\"$TMP/with\"}" "/agent-sync:generate"
assert_file_absent "no generator -> AGENTS.md not created" "$TMP/with/AGENTS.md"

# --- Regeneration path (issue #93): a vendored generator is present, so a tracked-source edit
#     regenerates AGENTS.md in place instead of merely nudging. ---------------------------------
REGEN="$TMP/regen"
mkdir -p "$REGEN/tools/agent-sync" "$REGEN/.claude/rules"
cp "$GEN" "$REGEN/tools/agent-sync/generate.sh"
cat > "$REGEN/CLAUDE.md" <<'EOF'
# Project

## Overview
Body text.
EOF
cat > "$REGEN/tools/agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"main":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"o","title":"Overview","source":"main","type":"full-body"}]}]}
JSON

regen_out="$(printf '%s' "{\"tool_input\":{\"file_path\":\"$REGEN/CLAUDE.md\"},\"cwd\":\"$REGEN\"}" | bash "$HOOK" 2>/dev/null)"
if [[ "$regen_out" == *"regenerated AGENTS.md"* ]]; then echo "PASS: regen: vendored generator regenerates"; PASS=$((PASS+1));
else echo "FAIL: regen: vendored generator regenerates — got: $regen_out"; FAIL=$((FAIL+1)); fi
assert_file_present "regen: AGENTS.md created in working tree" "$REGEN/AGENTS.md"

# Second run with no source change reports already-in-sync (and does not claim a regen).
resync_out="$(printf '%s' "{\"tool_input\":{\"file_path\":\"$REGEN/CLAUDE.md\"},\"cwd\":\"$REGEN\"}" | bash "$HOOK" 2>/dev/null)"
if [[ "$resync_out" == *"already in sync"* ]]; then echo "PASS: regen: no-op run reports already in sync"; PASS=$((PASS+1));
else echo "FAIL: regen: no-op run reports already in sync — got: $resync_out"; FAIL=$((FAIL+1)); fi

# Editing the OUTPUT (AGENTS.md) must not trigger regeneration (loop guard).
out_edit="$(printf '%s' "{\"tool_input\":{\"file_path\":\"$REGEN/AGENTS.md\"},\"cwd\":\"$REGEN\"}" | bash "$HOOK" 2>/dev/null)"
if [[ -z "$out_edit" ]]; then echo "PASS: regen: editing AGENTS.md output is silent"; PASS=$((PASS+1));
else echo "FAIL: regen: editing AGENTS.md output is silent — got: $out_edit"; FAIL=$((FAIL+1)); fi

# --- Auto-stage in a git repo: ON by default, opt out with AGENT_SYNC_AUTO_STAGE=0. ------------
GITREPO="$TMP/gitregen"
mkdir -p "$GITREPO/tools/agent-sync"
cp "$GEN" "$GITREPO/tools/agent-sync/generate.sh"
cat > "$GITREPO/CLAUDE.md" <<'EOF'
# Project

## Overview
Initial body.
EOF
cat > "$GITREPO/tools/agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"main":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"o","title":"Overview","source":"main","type":"full-body"}]}]}
JSON
git -C "$GITREPO" init -q
git -C "$GITREPO" config user.email t@t.t
git -C "$GITREPO" config user.name t

# Default (no env): regenerate AND stage.
printf 'changed' >> "$GITREPO/CLAUDE.md"
stage_out="$(printf '%s' "{\"tool_input\":{\"file_path\":\"$GITREPO/CLAUDE.md\"},\"cwd\":\"$GITREPO\"}" | bash "$HOOK" 2>/dev/null)"
if git -C "$GITREPO" diff --cached --name-only | grep -q '^AGENTS.md$'; then
  echo "PASS: auto-stage: staged by default"; PASS=$((PASS+1))
else
  echo "FAIL: auto-stage: not staged by default — got: $stage_out"; FAIL=$((FAIL+1))
fi
if [[ "$stage_out" == *"staged"* ]]; then echo "PASS: auto-stage: message reports staging"; PASS=$((PASS+1));
else echo "FAIL: auto-stage: message reports staging — got: $stage_out"; FAIL=$((FAIL+1)); fi

# Opt out: AGENT_SYNC_AUTO_STAGE=0 regenerates but leaves staging to the user.
git -C "$GITREPO" reset -q
printf 'more' >> "$GITREPO/CLAUDE.md"
optout_out="$(printf '%s' "{\"tool_input\":{\"file_path\":\"$GITREPO/CLAUDE.md\"},\"cwd\":\"$GITREPO\"}" | AGENT_SYNC_AUTO_STAGE=0 bash "$HOOK" 2>/dev/null)"
if git -C "$GITREPO" diff --cached --name-only | grep -q '^AGENTS.md$'; then
  echo "FAIL: auto-stage: staged despite AGENT_SYNC_AUTO_STAGE=0 — got: $optout_out"; FAIL=$((FAIL+1))
else
  echo "PASS: auto-stage: opt-out (=0) does not stage"; PASS=$((PASS+1))
fi
if [[ "$optout_out" == *"regenerated AGENTS.md"* && "$optout_out" != *"staged"* ]]; then
  echo "PASS: auto-stage: opt-out message omits staging"; PASS=$((PASS+1))
else
  echo "FAIL: auto-stage: opt-out message omits staging — got: $optout_out"; FAIL=$((FAIL+1))
fi

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
