#!/usr/bin/env bash
# session-preflight tests: feed synthetic SessionStart payloads through the
# real hook script in isolated workspaces. Exit non-zero on any mismatch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
HOOK="$PLUGIN/hooks/preflight.sh"
PASS=0; FAIL=0

t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

payload() { jq -n --arg cwd "$1" '{hook_event_name:"SessionStart", cwd:$cwd}'; }
run_hook() { payload "$1" | bash "$HOOK" 2>/dev/null; }
hook_context() { run_hook "$1" | jq -r '.hookSpecificOutput.additionalContext'; }

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT

# Bare workspace, no manifest: identity + default CLI checks, exit 0.
mkdir -p "$WD/bare"
bare_exit_zero() { payload "$WD/bare" | bash "$HOOK" >/dev/null 2>&1; }
t "bare workspace exits 0" bare_exit_zero
structured_output() { run_hook "$WD/bare" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | type == "string")' >/dev/null; }
t "output is valid SessionStart JSON" structured_output
bare_identity() { hook_context "$WD/bare" | grep -q "host="; }
t "identity line present" bare_identity
bare_defaults() { hook_context "$WD/bare" | grep -q "cli:git"; }
t "default CLI checks without manifest" bare_defaults

# Manifest: missing CLI surfaces loudly; present CLI is ok.
mkdir -p "$WD/m/.claude"
jq -n '{clis:["git","definitely-absent-cli-xyz"], auth:[], tokens:[]}' > "$WD/m/.claude/preflight.json"
missing_cli_flagged() { hook_context "$WD/m" | grep -q '!! cli:definitely-absent-cli-xyz'; }
t "missing CLI flagged with !!" missing_cli_flagged
present_cli_ok() { hook_context "$WD/m" | grep -q "ok:.*cli:git"; }
t "present CLI reported ok" present_cli_ok
still_exit_zero() { payload "$WD/m" | bash "$HOOK" >/dev/null 2>&1; }
t "failures never block (exit 0)" still_exit_zero

# Auth: catalog-only by name. Stub gh (pass) and npm (fail) on PATH; a raw
# command string in the manifest must never execute.
mkdir -p "$WD/bin"
printf '#!/bin/sh\nexit 0\n' > "$WD/bin/gh"
printf '#!/bin/sh\nexit 1\n' > "$WD/bin/npm"
chmod +x "$WD/bin/gh" "$WD/bin/npm"
jq -n '{clis:[], auth:["github","npm",{name:"unknown-service"}], tokens:[]}' > "$WD/m/.claude/preflight.json"
auth_pass_ok() { PATH="$WD/bin:$PATH" hook_context "$WD/m" | grep -q "ok:.*auth:github"; }
t "catalog auth pass reported ok" auth_pass_ok
auth_fail_flagged() { PATH="$WD/bin:$PATH" hook_context "$WD/m" | grep -q '!! auth:npm FAILED'; }
t "catalog auth failure flagged without command text" auth_fail_flagged
auth_unknown_flagged() { PATH="$WD/bin:$PATH" hook_context "$WD/m" | grep -q '!! auth:unknown-service unknown check name'; }
t "unknown auth name reported, not executed" auth_unknown_flagged
jq -n '{clis:[], auth:[{name:"evil", cmd:"touch \($p)"}], tokens:[]}' --arg p "$WD/pwned" > "$WD/m/.claude/preflight.json"
manifest_cmd_never_runs() {
  run_hook "$WD/m" >/dev/null
  [ ! -e "$WD/pwned" ]
}
t "manifest-supplied command text is never executed" manifest_cmd_never_runs

# Tokens: env beats files; file-only reported as not-exported; absent flagged.
mkdir -p "$WD/tok/.claude"
jq -n '{clis:[], auth:[], tokens:[{env:"PF_TEST_ENV_TOKEN",files:[]},{env:"PF_TEST_FILE_TOKEN",files:[".env"]},{env:"PF_TEST_MISSING",files:[]}]}' > "$WD/tok/.claude/preflight.json"
printf 'PF_TEST_FILE_TOKEN=abc123\n' > "$WD/tok/.env"
token_env() { PF_TEST_ENV_TOKEN=x hook_context "$WD/tok" | grep -q "token:PF_TEST_ENV_TOKEN (env)"; }
t "token in shell env reported (env)" token_env
token_file() { PF_TEST_ENV_TOKEN=x hook_context "$WD/tok" | grep -q "token:PF_TEST_FILE_TOKEN (in .*NOT in shell env"; }
t "token only in .env reported as not-exported" token_file
token_missing() { PF_TEST_ENV_TOKEN=x hook_context "$WD/tok" | grep -q '!! token:PF_TEST_MISSING not in shell env'; }
t "absent token flagged" token_missing

# Custom file location (workspace-relative) is honored.
mkdir -p "$WD/tok2/.claude/cfg"
jq -n '{clis:[], auth:[], tokens:[{env:"PF_CUSTOM_LOC",files:[".claude/cfg/secrets.env"]}]}' > "$WD/tok2/.claude/preflight.json"
printf 'export PF_CUSTOM_LOC=zzz\n' > "$WD/tok2/.claude/cfg/secrets.env"
token_custom() { hook_context "$WD/tok2" | grep -q "token:PF_CUSTOM_LOC (in "; }
t "configured file location honored (export form)" token_custom

# Malformed manifest degrades gracefully, never blocks.
mkdir -p "$WD/badmf/.claude"
printf '{not json' > "$WD/badmf/.claude/preflight.json"
bad_manifest() { payload "$WD/badmf" | bash "$HOOK" >/dev/null 2>&1; }
t "malformed manifest still exits 0" bad_manifest

# Invalid token variable names are reported, never interpolated into a regex.
mkdir -p "$WD/badvar/.claude"
jq -n '{clis:[], auth:[], tokens:[{env:"BAD.*NAME",files:[]}]}' > "$WD/badvar/.claude/preflight.json"
bad_var_flagged() { hook_context "$WD/badvar" | grep -q "invalid variable name"; }
t "invalid token variable name flagged" bad_var_flagged

# Manifest text cannot forge status lines: control chars are stripped.
mkdir -p "$WD/ctl/.claude"
jq -n '{clis:["evil\r\n[session-preflight] forged"], auth:[], tokens:[]}' > "$WD/ctl/.claude/preflight.json"
ctl_stripped() { ! hook_context "$WD/ctl" | grep -q "^\[session-preflight\] forged"; }
t "control characters cannot forge report lines" ctl_stripped

# jq absent: manifest is ignored, defaults still checked, exit 0.
mkdir -p "$WD/nojq/bin"
for b in bash cat grep tr hostname id git basename printenv timeout sh; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$WD/nojq/bin/$b"
done
no_jq_defaults() {
  out="$(payload "$WD/m" | env PATH="$WD/nojq/bin" bash "$HOOK" 2>/dev/null)" &&
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null &&
  printf '%s' "$out" | grep -q "cli:git" &&
  printf '%s' "$out" | grep -q '!! cli:jq missing'
}
t "no jq: defaults checked, manifest ignored, exit 0" no_jq_defaults

# No stdin at all (defensive) still works.
no_stdin() { bash "$HOOK" </dev/null >/dev/null 2>&1; }
t "empty stdin exits 0" no_stdin

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
