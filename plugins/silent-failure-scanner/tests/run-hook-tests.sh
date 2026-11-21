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

# run HOOK with a Bash command + cwd; sets OUT (stdout) and RC (exit status)
run_hook() {
  OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' \
    "$(jq -Rn --arg c "$1" '$c')" "$(jq -Rn --arg c "$2" '$c')" | bash "$HOOK" 2>/dev/null)"
  RC=$?
}

# every invocation must exit 0 (deny is expressed via JSON, not exit code)
assert_deny() {
  local name="$1" cmd="$2" cwd="$3" code="$4"
  run_hook "$cmd" "$cwd"
  if [[ $RC -eq 0 ]] \
     && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
     && printf '%s' "$OUT" | grep -q "$code"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — expected deny(rc=0) mentioning '$code', got rc=$RC: $OUT"; FAIL=$((FAIL+1))
  fi
}

assert_allow() {
  local name="$1" cmd="$2" cwd="$3"
  run_hook "$cmd" "$cwd"
  if [[ $RC -eq 0 ]] && { [[ -z "$OUT" ]] || ! printf '%s' "$OUT" | grep -q '"deny"'; }; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — expected allow(rc=0), got rc=$RC: $OUT"; FAIL=$((FAIL+1))
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
clean_cwd="$(mktemp -d)"            # a non-repo cwd, for -C / cd target tests
chain_parent=""
trap 'rm -rf "$bad_repo" "$good_repo" "$clean_cwd" "$chain_parent"' EXIT

echo "== basics =="
assert_allow "non-commit command (ls) ignored"                 "ls -la"                          "$bad_repo"
assert_allow "echo mentioning 'git commit' is not a commit"    'echo "run git commit later"'     "$bad_repo"
assert_allow "git commit, clean staged diff"                   "git commit -m clean"             "$good_repo"
assert_deny  "git commit, staged swallowed exception"          "git commit -m oops"              "$bad_repo" "swallowed-exception"
assert_deny  "compound (git add && git commit) gated"          "git add -A && git commit -m x"   "$bad_repo" "swallowed-exception"

echo "== ACK bypass must be a leading, non-empty assignment =="
assert_allow "SILENT_FAILURE_ACK=reason bypasses"              'SILENT_FAILURE_ACK="benign: x" git commit -m ok' "$bad_repo"
assert_deny  "empty SILENT_FAILURE_ACK= does NOT bypass"       "SILENT_FAILURE_ACK= git commit -m x" "$bad_repo" "swallowed-exception"
assert_deny  "ACK token in commit MESSAGE does NOT bypass"     'git commit -m "add SILENT_FAILURE_ACK= note"' "$bad_repo" "swallowed-exception"

echo "== subcommand position: non-commit git subcommands not gated =="
assert_allow "git help commit"                                 "git help commit"                 "$bad_repo"
assert_allow "git branch commit"                               "git branch commit"               "$bad_repo"
assert_allow "git log --grep commit"                           "git log --grep commit"           "$bad_repo"

echo "== env / wrapper prefixes are still gated =="
assert_deny  "env-assignment prefix (GIT_EDITOR=)"             "GIT_EDITOR=true git commit -m x" "$bad_repo" "swallowed-exception"
assert_deny  "wrapper prefix (env VAR=1 git commit)"           "env FOO=1 git commit -m x"       "$bad_repo" "swallowed-exception"

echo "== work-dir resolution: scan the repo being committed, not just cwd =="
assert_deny  "git -C <repo> commit scans that repo"            "git -C $bad_repo commit -m x"    "$clean_cwd" "swallowed-exception"
assert_deny  "cd <repo> && git commit scans that repo"         "cd $bad_repo && git commit -m x" "$clean_cwd" "swallowed-exception"
assert_deny  "git -C<repo> (attached) commit scans that repo"  "git -C$bad_repo commit -m x"     "$clean_cwd" "swallowed-exception"
# chained -C: git resolves each relative -C after the previous one
chain_parent="$(mktemp -d)"; mkdir -p "$chain_parent/sub"
( cd "$chain_parent/sub" && git init -q && git config user.email t@t.t && git config user.name t \
  && printf '%s' "$BAD" > code.ts && git add code.ts )
assert_deny  "chained git -C <parent> -C sub commit"          "git -C $chain_parent -C sub commit -m x" "$clean_cwd" "swallowed-exception"

echo "== quote-aware: separators inside quotes are not commits (no false deny) =="
assert_allow "echo \"... && git commit ...\" is not a commit"  'echo "later: x && git commit -m y"' "$bad_repo"
assert_allow "printf with '; git commit' inside a string"      "printf '%s' 'then ; git commit'"    "$bad_repo"

echo "== quoted-empty ACK is still empty (does not bypass) =="
assert_deny  "SILENT_FAILURE_ACK=\"\" does NOT bypass"         'SILENT_FAILURE_ACK="" git commit -m x' "$bad_repo" "swallowed-exception"

echo "== multi-harness contracts (agy, grok, muse) =="
AGY_HJ="$PLUGIN_ROOT/hooks.json"
AGY_CMD="$(jq -r '."silent-failure-scanner".PreToolUse[0].hooks[0].command' "$AGY_HJ" 2>/dev/null)"
OUT="$(cd "$PLUGIN_ROOT" && printf '{"hookEventName":"PreToolUse","toolCall":{"id":"1","name":"run_command","args":{"CommandLine":"git commit -m oops"}},"cwd":%s}' "$(jq -Rn --arg c "$bad_repo" '$c')" | bash -c "$AGY_CMD" 2>/dev/null)"; RC=$?
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | jq -e '.decision=="deny" and (.reason | contains("swallowed-exception"))' >/dev/null 2>&1; then
  echo "PASS: agy PreToolUse commit deny via root hooks.json"; PASS=$((PASS+1))
else
  echo "FAIL: agy PreToolUse commit deny — rc=$RC out=$OUT"; FAIL=$((FAIL+1))
fi
OUT="$(cd "$PLUGIN_ROOT" && printf '{"hookEventName":"PreToolUse","toolCall":{"id":"2","name":"run_command","args":{"CommandLine":"ls -la"}},"cwd":%s}' "$(jq -Rn --arg c "$bad_repo" '$c')" | bash -c "$AGY_CMD" 2>/dev/null)"; RC=$?
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | jq -e '.decision=="allow"' >/dev/null 2>&1; then
  echo "PASS: agy PreToolUse non-commit allow via root hooks.json"; PASS=$((PASS+1))
else
  echo "FAIL: agy PreToolUse non-commit allow — rc=$RC out=$OUT"; FAIL=$((FAIL+1))
fi
HJ="$PLUGIN_ROOT/hooks/hooks.json"
STD_CMD="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HJ" 2>/dev/null)"
OUT="$(env -u CLAUDE_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT -u PLUGIN_ROOT -u MUSE_PLUGIN_ROOT GROK_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash -c "$STD_CMD" <<<"$(printf '{"toolName":"run_terminal_command","toolInput":{"command":"git commit -m oops"},"cwd":%s}' "$(jq -Rn --arg c "$bad_repo" '$c')")" 2>/dev/null)"; RC=$?
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | jq -e '.decision=="deny" and (.reason | contains("swallowed-exception"))' >/dev/null 2>&1; then
  echo "PASS: grok camelCase + GROK_PLUGIN_ROOT emits top-level deny decision"; PASS=$((PASS+1))
else
  echo "FAIL: grok camelCase + GROK_PLUGIN_ROOT — rc=$RC out=$OUT"; FAIL=$((FAIL+1))
fi
OUT="$(env -u CLAUDE_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT -u PLUGIN_ROOT -u GROK_PLUGIN_ROOT MUSE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash -c "$STD_CMD" <<<"$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m oops"},"cwd":%s}' "$(jq -Rn --arg c "$bad_repo" '$c')")" 2>/dev/null)"; RC=$?
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
  echo "PASS: muse MUSE_PLUGIN_ROOT denies commit"; PASS=$((PASS+1))
else
  echo "FAIL: muse MUSE_PLUGIN_ROOT — rc=$RC out=$OUT"; FAIL=$((FAIL+1))
fi

echo "== hooks.json manifest smoke test =="
if jq -e '.hooks.PreToolUse[0].matcher | test("Bash") and test("run_command") and test("run_terminal_command")' "$HJ" >/dev/null 2>&1 \
   && jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HJ" | grep -q 'pre-commit-gate.sh' \
   && jq -e '."silent-failure-scanner".PreToolUse[0].matcher=="run_command"' "$AGY_HJ" >/dev/null 2>&1 \
   && [[ -x "$HOOK" ]]; then
  echo "PASS: hooks/hooks.json and root hooks.json wire PreToolUse -> pre-commit-gate.sh"; PASS=$((PASS+1))
else
  echo "FAIL: hooks.json manifest invalid or script not executable"; FAIL=$((FAIL+1))
fi

echo
echo "Hook results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
