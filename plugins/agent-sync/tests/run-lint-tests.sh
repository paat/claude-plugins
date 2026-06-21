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

# --- Config validation (exit 2) ---
mk_cfg() {  # $1 dir, $2 lint-json  -> writes sources.json, echoes its path
  local d="$1" lint="$2"; mkdir -p "$d/.agent-sync"; echo "# c" > "$d/CLAUDE.md"
  cat > "$d/.agent-sync/sources.json" <<JSON
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":$lint}
JSON
  echo "$d/.agent-sync/sources.json"
}

C1="$(mk_cfg "$TMP/badsev" '{"lineBudget":{"severity":"loud","max":200}}')"
assert_exit "invalid severity -> exit 2" 2 -- --config "$C1" --root "$TMP/badsev"

C2="$(mk_cfg "$TMP/badmax" '{"lineBudget":{"max":0}}')"
assert_exit "max=0 -> exit 2" 2 -- --config "$C2" --root "$TMP/badmax"

C2b="$(mk_cfg "$TMP/badmax2" '{"lineBudget":{"max":"two"}}')"
assert_exit "max non-numeric -> exit 2" 2 -- --config "$C2b" --root "$TMP/badmax2"

C3="$(mk_cfg "$TMP/badfiles" '{"lineBudget":{"files":"CLAUDE.md"}}')"
assert_exit "files not array -> exit 2" 2 -- --config "$C3" --root "$TMP/badfiles"

C4="$(mk_cfg "$TMP/badgroups" '{"contradictions":{"exclusiveGroups":["Supabase","Postgres"]}}')"
assert_exit "exclusiveGroups not array-of-arrays -> exit 2" 2 -- --config "$C4" --root "$TMP/badgroups"

# malformed JSON -> exit 2
MJ="$TMP/malformed"; mkdir -p "$MJ/.agent-sync"; echo "# c" > "$MJ/CLAUDE.md"
printf '{ this is not json' > "$MJ/.agent-sync/sources.json"
assert_exit "malformed JSON -> exit 2" 2 -- --config "$MJ/.agent-sync/sources.json" --root "$MJ"

C5="$(mk_cfg "$TMP/badsevfalse" '{"lineBudget":{"severity":false,"max":10}}')"
assert_exit "severity false -> exit 2" 2 -- --config "$C5" --root "$TMP/badsevfalse"

C6="$(mk_cfg "$TMP/badcheck" '{"typoCheck":false}')"
assert_exit "non-object lint child -> exit 2" 2 -- --config "$C6" --root "$TMP/badcheck"

# --- Line budget ---
mk_repo_lb() {  # $1 dir, $2 line-count for big.md, $3 lint-json
  local d="$1" n="$2" lint="$3"; mkdir -p "$d/.agent-sync" "$d/.claude/rules"
  echo "# c" > "$d/CLAUDE.md"
  awk -v n="$n" 'BEGIN{for(i=1;i<=n;i++) print "line " i}' > "$d/.claude/rules/big.md"
  cat > "$d/.agent-sync/sources.json" <<JSON
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":$lint}
JSON
  echo "$d/.agent-sync/sources.json"
}

LB1="$(mk_repo_lb "$TMP/lb_over" 250 '{"lineBudget":{"max":200,"files":[".claude/rules/*.md"]}}')"
assert_stdout_contains "250-line file flagged" "big.md is 250 lines (budget 200)" -- --config "$LB1" --root "$TMP/lb_over"
assert_exit "line-budget warn -> exit 0" 0 -- --config "$LB1" --root "$TMP/lb_over"

LB2="$(mk_repo_lb "$TMP/lb_under" 50 '{"lineBudget":{"max":200,"files":[".claude/rules/*.md"]}}')"
assert_stdout_absent "in-budget file not flagged" "big.md" -- --config "$LB2" --root "$TMP/lb_under"

LB3="$(mk_repo_lb "$TMP/lb_off" 250 '{"lineBudget":{"severity":"off","max":200,"files":[".claude/rules/*.md"]}}')"
assert_stdout_absent "severity off -> no finding" "big.md" -- --config "$LB3" --root "$TMP/lb_off"

LB4="$(mk_repo_lb "$TMP/lb_err" 250 '{"lineBudget":{"severity":"error","max":200,"files":[".claude/rules/*.md"]}}')"
assert_exit "line-budget error -> exit 1" 1 -- --config "$LB4" --root "$TMP/lb_err"

# Missing glob / missing literal file -> no crash, no finding
LB5="$(mk_repo_lb "$TMP/lb_missing" 50 '{"lineBudget":{"max":200,"files":["does-not-exist.md","nope/*.md"]}}')"
assert_exit "missing files skipped -> exit 0" 0 -- --config "$LB5" --root "$TMP/lb_missing"
assert_stdout_contains "missing files -> summary 0/0" "0 errors, 0 warnings" -- --config "$LB5" --root "$TMP/lb_missing"

# Dedup: overlapping glob + literal resolve to one file -> single finding line
LB6="$(mk_repo_lb "$TMP/lb_dedup" 250 '{"lineBudget":{"max":200,"files":[".claude/rules/*.md",".claude/rules/big.md"]}}')"
DEDUP_OUT="$(bash "$LINT" --config "$LB6" --root "$TMP/lb_dedup" 2>/dev/null | grep -c 'big.md is 250')"
if [[ "$DEDUP_OUT" -eq 1 ]]; then echo "PASS: dedup overlapping globs"; PASS=$((PASS+1));
else echo "FAIL: dedup overlapping globs — got $DEDUP_OUT finding lines"; FAIL=$((FAIL+1)); fi

# --- Soft preferences ---
mk_repo_sp() {  # $1 dir, $2 body-file-content (heredoc text), $3 lint-json
  local d="$1" lint="$3"; mkdir -p "$d/.agent-sync" "$d/.claude/rules"
  printf '%s' "$2" > "$d/.claude/rules/style.md"
  echo "# c" > "$d/CLAUDE.md"
  cat > "$d/.agent-sync/sources.json" <<JSON
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":$lint}
JSON
  echo "$d/.agent-sync/sources.json"
}

SP_BODY=$'# Style\n\nPrefer composition over inheritance.\n- prefer using hooks\n1. Prefer X\nUsers prefer dark mode here.\nWe preferred the old API.\n'
SP1="$(mk_repo_sp "$TMP/sp" "$SP_BODY" '{"softPreferences":{"files":[".claude/rules/*.md"]}}')"
# NOTE: the file lives at .claude/rules/style.md, so the reported path is the full relative path.
assert_stdout_contains "leading Prefer flagged" "soft-preference: .claude/rules/style.md:3" -- --config "$SP1" --root "$TMP/sp"
assert_stdout_contains "bullet prefer flagged" ".claude/rules/style.md:4" -- --config "$SP1" --root "$TMP/sp"
assert_stdout_contains "numbered Prefer flagged" ".claude/rules/style.md:5" -- --config "$SP1" --root "$TMP/sp"
assert_stdout_absent "mid-sentence prefer NOT flagged" ".claude/rules/style.md:6:" -- --config "$SP1" --root "$TMP/sp"
assert_stdout_absent "mid-sentence preferred NOT flagged" ".claude/rules/style.md:7:" -- --config "$SP1" --root "$TMP/sp"

# --- Contradictions ---
mk_repo_ct() {  # $1 dir, $2 README content, $3 CLAUDE content, $4 lint-json
  local d="$1" lint="$4"; mkdir -p "$d/.agent-sync"
  printf '%s' "$2" > "$d/README.md"
  printf '%s' "$3" > "$d/CLAUDE.md"
  cat > "$d/.agent-sync/sources.json" <<JSON
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":$lint}
JSON
  echo "$d/.agent-sync/sources.json"
}

# Contradiction across README + CLAUDE.md
CT1="$(mk_repo_ct "$TMP/ct" $'We use Supabase.\n' $'We use Postgres.\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"]]}}')"
assert_stdout_contains "contradiction flagged" "contradiction: group {Supabase, Postgres}" -- --config "$CT1" --root "$TMP/ct"
assert_exit "contradiction warn default -> exit 0" 0 -- --config "$CT1" --root "$TMP/ct"

CT1e="$(mk_repo_ct "$TMP/ct_err" $'Supabase\n' $'Postgres\n' '{"contradictions":{"severity":"error","files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"]]}}')"
assert_exit "contradiction error -> exit 1" 1 -- --config "$CT1e" --root "$TMP/ct_err"

# Single term present -> no finding
CT2="$(mk_repo_ct "$TMP/ct_single" $'Postgres only\n' $'Postgres again\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"]]}}')"
assert_stdout_absent "single term -> no contradiction" "contradiction:" -- --config "$CT2" --root "$TMP/ct_single"

# Boundary guard: Postgres term must NOT match inside PostgreSQL
CT3="$(mk_repo_ct "$TMP/ct_bound" $'We use Supabase.\n' $'We use PostgreSQL 16.\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"]]}}')"
assert_stdout_absent "Postgres not matched in PostgreSQL" "contradiction:" -- --config "$CT3" --root "$TMP/ct_bound"

# Punctuation + multiword terms match literally
CT4="$(mk_repo_ct "$TMP/ct_punct" $'Built with .NET and Node.js.\n' $'Also uses Claude Code.\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[[".NET","Claude Code"]]}}')"
assert_stdout_contains "punct/multiword terms match" "contradiction: group {.NET, Claude Code}" -- --config "$CT4" --root "$TMP/ct_punct"

# Group with <2 terms -> skipped, no error
CT5="$(mk_repo_ct "$TMP/ct_short" $'Supabase\n' $'Supabase\n' '{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase"]]}}')"
assert_exit "group <2 terms skipped -> exit 0" 0 -- --config "$CT5" --root "$TMP/ct_short"

# --- FIX 1: resolve_files must not scan files outside REPO_ROOT ---
# Structure: real repo at $TMP/escape/repo; outside file at $TMP/escape_outside.md
# The outside file has 5 lines; max=3 so it WOULD trigger a finding if scanned.
# Since it is outside root it must be silently skipped (no finding, exit 0).
ESCAPE_OUTSIDE="$TMP/escape_outside.md"
printf 'line1\nline2\nline3\nline4\nline5\n' > "$ESCAPE_OUTSIDE"
mkdir -p "$TMP/escape/repo/.agent-sync"
echo "# c" > "$TMP/escape/repo/CLAUDE.md"
cat > "$TMP/escape/repo/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":{"lineBudget":{"max":3,"files":["../escape_outside.md"]}}}
JSON
assert_stdout_absent "escape-root: outside file name absent from output" "escape_outside.md" \
  -- --config "$TMP/escape/repo/.agent-sync/sources.json" --root "$TMP/escape/repo"
assert_exit "escape-root: exit 0 (0/0 scan)" 0 \
  -- --config "$TMP/escape/repo/.agent-sync/sources.json" --root "$TMP/escape/repo"

# Positive control: a file inside the repo IS still scanned and flagged
awk 'BEGIN{for(i=1;i<=5;i++) print "line " i}' > "$TMP/escape/repo/inside.md"
cat > "$TMP/escape/repo/.agent-sync/sources-inside.json" <<'JSON'
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],"lint":{"lineBudget":{"max":3,"files":["inside.md"]}}}
JSON
assert_stdout_contains "escape-root positive control: inside file is scanned" "inside.md is 5 lines" \
  -- --config "$TMP/escape/repo/.agent-sync/sources-inside.json" --root "$TMP/escape/repo"

# --- FIX 2: exclusiveGroups must reject empty string terms ---
C_EMPTY_TERM="$(mk_cfg "$TMP/emptyterm" '{"contradictions":{"exclusiveGroups":[["","Postgres"]]}}')"
assert_exit "empty exclusiveGroups term -> exit 2" 2 -- --config "$C_EMPTY_TERM" --root "$TMP/emptyterm"

# --- Acceptance: clean synced fixture -> no findings, exit 0 ---
CLEAN="$TMP/clean"; mkdir -p "$CLEAN/.agent-sync" "$CLEAN/.claude/rules"
printf '# App\nWe use Postgres on Hetzner.\n' > "$CLEAN/README.md"
printf '# Claude\nWe use Postgres on Hetzner.\n' > "$CLEAN/CLAUDE.md"
printf '# Arch\nKeep modules small.\n' > "$CLEAN/.claude/rules/architecture.md"
cat > "$CLEAN/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"m":"CLAUDE.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"a","title":"R","source":"m","type":"full-body"}]}],
"lint":{"contradictions":{"files":["README.md","CLAUDE.md"],"exclusiveGroups":[["Supabase","Postgres"],["Vercel","Hetzner"]]},
"lineBudget":{"max":200,"files":["CLAUDE.md",".claude/rules/*.md"]},
"softPreferences":{"files":["CLAUDE.md",".claude/rules/*.md"]}}}
JSON
assert_stdout_contains "clean fixture -> 0/0 summary" "0 errors, 0 warnings" -- --config "$CLEAN/.agent-sync/sources.json" --root "$CLEAN"
assert_exit "clean fixture -> exit 0" 0 -- --config "$CLEAN/.agent-sync/sources.json" --root "$CLEAN"

# --- Determinism: two runs of CT1 produce byte-identical output ---
D1="$(bash "$LINT" --config "$CT1" --root "$TMP/ct" 2>/dev/null)"
D2="$(bash "$LINT" --config "$CT1" --root "$TMP/ct" 2>/dev/null)"
if [[ "$D1" == "$D2" ]]; then echo "PASS: deterministic output"; PASS=$((PASS+1));
else echo "FAIL: deterministic output differs"; FAIL=$((FAIL+1)); fi

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
