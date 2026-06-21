#!/usr/bin/env bash
# Test runner for agent-sync linter (lint.sh)
# Self-contained: bash 4+, jq, grep, awk, sort, sed.
# Usage: bash plugins/agent-sync/tests/run-lint-tests.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$PLUGIN_ROOT/scripts/lint.sh"
PASS=0
FAIL=0

# assert_exit NAME EXPECTED_CODE -- ARGS...   (runs lint.sh, checks exit code)
assert_exit() {
  local name="$1" want="$2"; shift 2; shift  # drop the literal --
  bash "$LINT" "$@" >/dev/null 2>&1; local ec=$?
  if [[ "$ec" -eq "$want" ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — exit $ec, expected $want"; FAIL=$((FAIL+1)); fi
}

# assert_stdout_contains NAME SUBSTRING -- ARGS...
assert_stdout_contains() {
  local name="$1" sub="$2"; shift 2; shift
  local out; out="$(bash "$LINT" "$@" 2>/dev/null)"
  if [[ "$out" == *"$sub"* ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — missing '$sub' in: $out"; FAIL=$((FAIL+1)); fi
}

# assert_stdout_empty NAME -- ARGS...
assert_stdout_empty() {
  local name="$1"; shift; shift
  local out; out="$(bash "$LINT" "$@" 2>/dev/null)"
  if [[ -z "$out" ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — expected empty stdout, got: $out"; FAIL=$((FAIL+1)); fi
}

# assert_stdout_absent NAME SUBSTRING -- ARGS...
assert_stdout_absent() {
  local name="$1" sub="$2"; shift 2; shift
  local out; out="$(bash "$LINT" "$@" 2>/dev/null)"
  if [[ "$out" != *"$sub"* ]]; then echo "PASS: $name"; PASS=$((PASS+1));
  else echo "FAIL: $name — unexpected '$sub' in: $out"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- Fixture: no lint block -> silent exit 0 ---
NOLINT="$TMP/nolint"; mkdir -p "$NOLINT/.agent-sync"
echo "# claude" > "$NOLINT/CLAUDE.md"
cat > "$NOLINT/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}]}
JSON
assert_stdout_empty "no lint block -> silent" -- --config "$NOLINT/.agent-sync/sources.json" --root "$NOLINT"
assert_exit "no lint block -> exit 0" 0 -- --config "$NOLINT/.agent-sync/sources.json" --root "$NOLINT"

# --- Fixture: empty lint block -> prints summary 0/0, exit 0 ---
EMPTY="$TMP/empty"; mkdir -p "$EMPTY/.agent-sync"
echo "# claude" > "$EMPTY/CLAUDE.md"
cat > "$EMPTY/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":{}}
JSON
assert_stdout_contains "empty lint -> summary 0/0" "summary: 0 errors, 0 warnings" -- --config "$EMPTY/.agent-sync/sources.json" --root "$EMPTY"
assert_exit "empty lint -> exit 0" 0 -- --config "$EMPTY/.agent-sync/sources.json" --root "$EMPTY"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
