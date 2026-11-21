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
    unset CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT PLUGIN_ROOT GROK_PLUGIN_ROOT MUSE_PLUGIN_ROOT
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
    unset CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT PLUGIN_ROOT GROK_PLUGIN_ROOT MUSE_PLUGIN_ROOT
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

# Multi-harness contract tests: agy (protojson + root hooks.json), Grok (camelCase + GROK_PLUGIN_ROOT), Muse (MUSE_PLUGIN_ROOT)
assert_agy_contracts() {
  local agy_hooks="$PLUGIN_ROOT/hooks.json" agy_cmd out code
  agy_cmd="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["irreversible-guard"]["PreToolUse"][0]["hooks"][0]["command"])' "$agy_hooks")"
  out="$(cd "$PLUGIN_ROOT" && printf '{"hookEventName":"PreToolUse","toolCall":{"id":"1","name":"run_command","args":{"CommandLine":"rm -rf /"}},"cwd":"%s"}' "$PWD" | bash -c "$agy_cmd" 2>/dev/null)"; code=$?
  if [[ $code -eq 0 ]] && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("decision")=="deny" and "BLOCKED" in d.get("reason","")'; then
    record_check "agy PreToolUse block via root hooks.json" "PASS" "PASS"
  else
    record_check "agy PreToolUse block via root hooks.json" "EXIT_${code}:${out}" "PASS"
  fi
  out="$(cd "$PLUGIN_ROOT" && printf '{"hookEventName":"PreToolUse","toolCall":{"id":"2","name":"run_command","args":{"CommandLine":"echo hi"}},"cwd":"%s"}' "$PWD" | bash -c "$agy_cmd" 2>/dev/null)"; code=$?
  if [[ $code -eq 0 ]] && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("decision")=="allow"'; then
    record_check "agy PreToolUse allow via root hooks.json" "PASS" "PASS"
  else
    record_check "agy PreToolUse allow via root hooks.json" "EXIT_${code}:${out}" "PASS"
  fi
  out="$(cd "$PLUGIN_ROOT" && printf '{"hookEventName":"PreToolUse","toolCall":{"id":"3","name":"run_command","args":{"CommandLine":"git reset --hard HEAD~1"}},"cwd":"%s"}' "$PWD" | bash -c "$agy_cmd" 2>/dev/null)"; code=$?
  if [[ $code -eq 0 ]] && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("decision")=="allow" and "CAUTION" in d.get("reason","")'; then
    record_check "agy PreToolUse warn via root hooks.json" "PASS" "PASS"
  else
    record_check "agy PreToolUse warn via root hooks.json" "EXIT_${code}:${out}" "PASS"
  fi
  # T-201: toolCall.args.Cwd overrides session cwd for project rules
  local ws_dir cmd_dir
  ws_dir="$(mktemp -d "${TMPDIR:-/tmp}/ig-ws.XXXXXX")"
  cmd_dir="$(mktemp -d "${TMPDIR:-/tmp}/ig-cmd.XXXXXX")"
  mkdir -p "$cmd_dir/.claude"
  printf '{"extra_block":["\\\\bcustom-danger\\\\b"]}\n' > "$cmd_dir/.claude/irreversible-guard.json"
  out="$(cd "$PLUGIN_ROOT" && printf '{"hookEventName":"PreToolUse","toolCall":{"id":"4","name":"run_command","args":{"CommandLine":"custom-danger","Cwd":"%s"}},"cwd":"%s"}' "$cmd_dir" "$ws_dir" | bash -c "$agy_cmd" 2>/dev/null)"; code=$?
  if [[ $code -eq 0 ]] && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("decision")=="deny"'; then
    record_check "agy PreToolUse honors toolCall.args.Cwd over cwd" "PASS" "PASS"
  else
    record_check "agy PreToolUse honors toolCall.args.Cwd over cwd" "EXIT_${code}:${out}" "PASS"
  fi
  rm -rf "$ws_dir" "$cmd_dir"
  # T-202: missing python3 under HOOK_RUNTIME=agy emits allow JSON (fail-open, not hard deny)
  local empty_bin
  empty_bin="$(mktemp -d "${TMPDIR:-/tmp}/ig-nobin.XXXXXX")"
  ln -sf "$(command -v bash)" "$empty_bin/bash"
  out="$(cd "$PLUGIN_ROOT" && PATH="$empty_bin" HOOK_RUNTIME=agy "$empty_bin/bash" ./hooks/guard.sh </dev/null 2>/dev/null)"; code=$?
  if [[ $code -eq 0 ]] && [[ "$out" == '{"decision":"allow"}' ]]; then
    record_check "agy guard.sh without python3 emits allow JSON" "PASS" "PASS"
  else
    record_check "agy guard.sh without python3 emits allow JSON" "EXIT_${code}:${out}" "PASS"
  fi
  rm -rf "$empty_bin"
}

assert_grok_and_muse_contracts() {
  local root="$PLUGIN_ROOT" code bogus
  bogus="$(mktemp -d "${TMPDIR:-/tmp}/ig-bogus.XXXXXX")"
  mkdir -p "$bogus/rules"
  printf '{"tier1_cmd":[],"tier1_regex":[],"tier2_cmd":[],"tier2_sql_regex":[],"tier2_regex":[],"warn_regex":[],"prod_markers":[],"allow":[],"extra_block":[],"warn_only":[]}\n' > "$bogus/rules/deny-set.json"
  (
    unset CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT PLUGIN_ROOT MUSE_PLUGIN_ROOT
    export CLAUDE_PLUGIN_ROOT="$bogus"
    export GROK_PLUGIN_ROOT="$root"
    printf '{"toolName":"run_terminal_command","toolInput":{"command":"kubectl delete namespace prod"},"cwd":"%s"}' "$PWD" | bash -c "$HOOK_COMMAND" >/dev/null 2>&1
  ); code=$?
  record_check "T-204 bogus CLAUDE_PLUGIN_ROOT ignored in favor of real GROK_PLUGIN_ROOT" "$code" "2"
  rm -rf "$bogus"
  (
    unset CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT PLUGIN_ROOT MUSE_PLUGIN_ROOT
    export GROK_PLUGIN_ROOT="$root"
    printf '{"toolName":"run_terminal_command","toolInput":{"command":"rm -rf /"},"cwd":"%s"}' "$PWD" | bash -c "$HOOK_COMMAND" >/dev/null 2>&1
  ); code=$?
  record_check "grok camelCase + GROK_PLUGIN_ROOT blocks" "$code" "2"

  (
    unset CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT PLUGIN_ROOT MUSE_PLUGIN_ROOT
    export GROK_PLUGIN_ROOT="$root"
    printf '{"toolName":"run_terminal_command","toolInput":{"command":"echo hi"},"toolInputTruncated":true,"cwd":"%s"}' "$PWD" | bash -c "$HOOK_COMMAND" >/dev/null 2>&1
  ); code=$?
  record_check "grok toolInputTruncated=true blocks" "$code" "2"

  (
    unset CLAUDE_PLUGIN_ROOT CODEX_PLUGIN_ROOT PLUGIN_ROOT GROK_PLUGIN_ROOT
    export MUSE_PLUGIN_ROOT="$root"
    printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"cwd":"%s"}' "$PWD" | bash -c "$HOOK_COMMAND" >/dev/null 2>&1
  ); code=$?
  record_check "muse MUSE_PLUGIN_ROOT blocks" "$code" "2"
}

assert_agy_contracts
assert_grok_and_muse_contracts

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
