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

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT

# Bare workspace, no manifest: identity + default CLI checks, exit 0.
mkdir -p "$WD/bare"
bare_exit_zero() { payload "$WD/bare" | bash "$HOOK" >/dev/null 2>&1; }
t "bare workspace exits 0" bare_exit_zero
bare_identity() { run_hook "$WD/bare" | grep -q "host="; }
t "identity line present" bare_identity
bare_defaults() { run_hook "$WD/bare" | grep -q "cli:git"; }
t "default CLI checks without manifest" bare_defaults

# Manifest: missing CLI surfaces loudly; present CLI is ok.
mkdir -p "$WD/m/.claude"
jq -n '{clis:["git","definitely-absent-cli-xyz"], auth:[], tokens:[]}' > "$WD/m/.claude/preflight.json"
missing_cli_flagged() { run_hook "$WD/m" | grep -q '!! cli:definitely-absent-cli-xyz'; }
t "missing CLI flagged with !!" missing_cli_flagged
present_cli_ok() { run_hook "$WD/m" | grep -q "ok:.*cli:git"; }
t "present CLI reported ok" present_cli_ok
still_exit_zero() { payload "$WD/m" | bash "$HOOK" >/dev/null 2>&1; }
t "failures never block (exit 0)" still_exit_zero

# Auth: failing command flagged, passing command ok, timeout bounded.
jq -n '{clis:[], auth:[{name:"good",cmd:"true"},{name:"bad",cmd:"false"}], tokens:[]}' > "$WD/m/.claude/preflight.json"
auth_bad_flagged() { run_hook "$WD/m" | grep -q '!! auth:bad FAILED'; }
t "failing auth flagged" auth_bad_flagged
auth_good_ok() { run_hook "$WD/m" | grep -q "auth:good"; }
t "passing auth ok" auth_good_ok

# Tokens: env beats files; file-only reported as not-exported; absent flagged.
mkdir -p "$WD/tok/.claude"
jq -n '{clis:[], auth:[], tokens:[{env:"PF_TEST_ENV_TOKEN",files:[]},{env:"PF_TEST_FILE_TOKEN",files:[".env"]},{env:"PF_TEST_MISSING",files:[]}]}' > "$WD/tok/.claude/preflight.json"
printf 'PF_TEST_FILE_TOKEN=abc123\n' > "$WD/tok/.env"
token_env() { PF_TEST_ENV_TOKEN=x run_hook "$WD/tok" | grep -q "token:PF_TEST_ENV_TOKEN (env)"; }
t "token in shell env reported (env)" token_env
token_file() { PF_TEST_ENV_TOKEN=x run_hook "$WD/tok" | grep -q "token:PF_TEST_FILE_TOKEN (in .*NOT in shell env"; }
t "token only in .env reported as not-exported" token_file
token_missing() { PF_TEST_ENV_TOKEN=x run_hook "$WD/tok" | grep -q '!! token:PF_TEST_MISSING not in shell env'; }
t "absent token flagged" token_missing

# Custom file location (workspace-relative) is honored.
mkdir -p "$WD/tok2/.claude/cfg"
jq -n '{clis:[], auth:[], tokens:[{env:"PF_CUSTOM_LOC",files:[".claude/cfg/secrets.env"]}]}' > "$WD/tok2/.claude/preflight.json"
printf 'export PF_CUSTOM_LOC=zzz\n' > "$WD/tok2/.claude/cfg/secrets.env"
token_custom() { run_hook "$WD/tok2" | grep -q "token:PF_CUSTOM_LOC (in "; }
t "configured file location honored (export form)" token_custom

# Malformed manifest degrades gracefully, never blocks.
mkdir -p "$WD/badmf/.claude"
printf '{not json' > "$WD/badmf/.claude/preflight.json"
bad_manifest() { payload "$WD/badmf" | bash "$HOOK" >/dev/null 2>&1; }
t "malformed manifest still exits 0" bad_manifest

# No stdin at all (defensive) still works.
no_stdin() { bash "$HOOK" </dev/null >/dev/null 2>&1; }
t "empty stdin exits 0" no_stdin

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
