#!/usr/bin/env bash
# Integration test: feed synthetic PreToolUse payloads through the real wrapper
# and assert the mapped outcome. Exit non-zero on any mismatch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$HERE")"
HOOK="$PLUGIN_ROOT/hooks/guard.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

if ! HOOK_COMMAND="$(HOOKS_JSON="$HOOKS_JSON" python3 - <<'PY'
import json
import os

with open(os.environ["HOOKS_JSON"]) as f:
    hooks = json.load(f)

print(hooks["hooks"]["PreToolUse"][0]["hooks"][0]["command"])
PY
)"; then
  echo "failed to read hook command from $HOOKS_JSON"
  exit 1
fi

pass=0; fail=0

record_check() {
  local name="$1" actual="$2" expected="$3" detail="${4:-}"
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "MISMATCH [want=$expected got=$actual]: $name${detail:+ ($detail)}"
  fi
}

payload_for() {
  CMD="$1" python3 -c 'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]},"cwd":os.getcwd()}))'
}

assert_hook_command_fails_open_without_plugin_root() {
  local tmpdir code actual
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/irreversible-guard.XXXXXX")" || {
    record_check "hook registration without plugin root" "MKTEMP_FAILED" "PASS"
    return
  }

  (
    unset CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT
    cd "$tmpdir" || exit 1
    bash -c "$HOOK_COMMAND" </dev/null >"$tmpdir/out" 2>"$tmpdir/err"
  )
  code=$?

  if [[ $code -eq 0 ]] && grep -q "hook target not found" "$tmpdir/err"; then
    actual=PASS
  else
    actual="EXIT_$code"
  fi

  record_check "hook registration without plugin root" "$actual" "PASS"
  rm -rf "$tmpdir"
}

assert_guard_wrapper_runs_without_plugin_root() {
  local tmpdir payload code actual
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/irreversible-guard.XXXXXX")" || {
    record_check "guard wrapper without plugin root" "MKTEMP_FAILED" "PASS"
    return
  }
  payload="$(payload_for "echo hi")"

  (
    unset CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT
    printf '%s' "$payload" | bash "$HOOK" >"$tmpdir/out" 2>"$tmpdir/err"
  )
  code=$?

  if [[ $code -eq 0 ]]; then
    actual=PASS
  else
    actual="EXIT_$code"
  fi

  record_check "guard wrapper without plugin root" "$actual" "PASS"
  rm -rf "$tmpdir"
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
assert_hook_command_fails_open_without_plugin_root
assert_guard_wrapper_runs_without_plugin_root
while IFS=$'\t' read -r cmd expected; do
  [[ -z "${cmd:-}" || "$cmd" == \#* ]] && continue
  payload="$(payload_for "$cmd")"
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"; code=$?
  if [[ $code -eq 2 ]]; then actual=BLOCK
  elif printf '%s' "$out" | grep -q '"additionalContext"'; then actual=WARN
  else actual=PASS; fi
  record_check "$cmd" "$actual" "$expected"
done < "$HERE/cases.tsv"

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
