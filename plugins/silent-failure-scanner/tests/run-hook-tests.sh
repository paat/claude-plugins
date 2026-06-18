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
trap 'rm -rf "$bad_repo" "$good_repo" "$clean_cwd"' EXIT

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

echo "== hooks.json manifest smoke test =="
HJ="$PLUGIN_ROOT/hooks/hooks.json"
if jq -e '.hooks.PreToolUse[0].matcher=="Bash"' "$HJ" >/dev/null 2>&1 \
   && jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HJ" | grep -q 'pre-commit-gate.sh' \
   && [[ -x "$HOOK" ]]; then
  echo "PASS: hooks.json wires PreToolUse:Bash -> pre-commit-gate.sh"; PASS=$((PASS+1))
else
  echo "FAIL: hooks.json manifest invalid or script not executable"; FAIL=$((FAIL+1))
fi

echo
echo "Hook results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
