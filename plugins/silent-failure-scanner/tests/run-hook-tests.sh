#!/usr/bin/env bash
# Tests for the PreToolUse commit-gate hook (hooks/pre-commit-gate.sh).
# Self-contained: bash 4+, awk, git, jq. Usage: bash tests/run-hook-tests.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/pre-commit-gate.sh"
PASS=0
FAIL=0

# build a throwaway git repo with one staged change; echoes its path
make_repo() {
  local body="$1" d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf '%s' "$body" > "$d/code.ts"
  git -C "$d" add code.ts
  printf '%s' "$d"
}

# run HOOK with a Bash command + cwd, return stdout
run_hook() { printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' \
  "$(jq -Rn --arg c "$1" '$c')" "$(jq -Rn --arg c "$2" '$c')" | bash "$HOOK" 2>/dev/null; }

assert_deny() {
  local name="$1" out="$2" code="$3"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
     && printf '%s' "$out" | grep -q "$code"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — expected deny mentioning '$code', got: $out"; FAIL=$((FAIL+1))
  fi
}

assert_allow() {
  local name="$1" out="$2"
  if [[ -z "$out" ]] || ! printf '%s' "$out" | grep -q '"deny"'; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — expected allow, got: $out"; FAIL=$((FAIL+1))
  fi
}

BAD='export function h(o){
  try { save(o); } catch (e) {}
}
'
GOOD='export function h(o){
  try { save(o); } catch (e) { logger.error(e); throw e; }
}
'

bad_repo="$(make_repo "$BAD")"
good_repo="$(make_repo "$GOOD")"
trap 'rm -rf "$bad_repo" "$good_repo"' EXIT

assert_allow "non-commit command (ls) is ignored" \
  "$(run_hook "ls -la" "$bad_repo")"
assert_allow "echo mentioning 'git commit' is not a commit" \
  "$(run_hook "echo \"run git commit later\"" "$bad_repo")"
assert_allow "git commit with clean staged diff" \
  "$(run_hook "git commit -m clean" "$good_repo")"
assert_deny  "git commit with staged swallowed exception" \
  "$(run_hook "git commit -m oops" "$bad_repo")" "swallowed-exception"
assert_deny  "compound (git add && git commit) is gated" \
  "$(run_hook "git add -A && git commit -m oops" "$bad_repo")" "swallowed-exception"
assert_allow "SILENT_FAILURE_ACK bypasses with a reason" \
  "$(run_hook "SILENT_FAILURE_ACK=\"benign: demo\" git commit -m ok" "$bad_repo")"

echo
echo "Hook results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
