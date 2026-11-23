#!/usr/bin/env bash
# Shared harness, fixtures, and assertion helpers for tribunal-review tests.
# Sourced by tests/run-tests.sh.

if [ -n "${TRIBUNAL_TEST_HELPERS_LOADED:-}" ]; then
  return 0
fi
TRIBUNAL_TEST_HELPERS_LOADED=1

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PASS=0; FAIL=0; SKIP=0; FAILURES=()
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

# Pin product defaults so host shell exports cannot flip panel membership mid-suite.
# Per-test prefixes still override (e.g. TRIBUNAL_GROK=off for disabled-marker cases).
unset TRIBUNAL_CODEX TRIBUNAL_CLAUDE TRIBUNAL_GROK TRIBUNAL_RISK TRIBUNAL_PANEL_SIZE \
  TRIBUNAL_MIN_OK_LEGS TRIBUNAL_BACKUP_LEGS TRIBUNAL_REVIEW_PANEL
export TRIBUNAL_GROK_RECOVERY=permit
# Opt-out host-installed repo-walking CLIs by default so real CLIs on PATH never answer legacy fixtures.
export TRIBUNAL_MUSE=off
export TRIBUNAL_GEMINI=off
export TRIBUNAL_QWEN=off
export TRIBUNAL_DEEPSEEK=off
# Smoke is opt-in; never inherit a host-on probe into default preflight checks.
export TRIBUNAL_SMOKE_PROBE=off
# Qwen/DeepSeek legs run under a scrubbed environment; the fakes read FIXTURE_* through it.
export TRIBUNAL_LEG_ENV='FIXTURE_*'

assert_grep() {
  local label="$1" file="$2" pat="$3"
  if grep -q -- "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_no_grep() {
  local label="$1" file="$2" pat="$3"
  if grep -q -- "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  else
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  fi
}

assert_file() {
  local label="$1" file="$2"
  if [ -f "$PLUGIN_ROOT/$file" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_executable() {
  local label="$1" file="$2"
  if [ -x "$PLUGIN_ROOT/$file" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_bash_n() {
  local label="$1" file="$2"
  if bash -n "$PLUGIN_ROOT/$file"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_json_field() {
  local label="$1" command="$2"
  if eval "$command" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}
native_review_repo() {
  git init -q
  git config user.email test@example.com
  git config user.name "Test User"
  printf 'one\n' > file.txt
  git add file.txt
  git commit -q -m base
  printf 'two\n' > file.txt
  git commit -q -am change
}

install_grok_auth_fixture() {
  local dest="$1" refresh="${2:-refresh-fixture}" expires="${3:-2099-01-01T00:00:00Z}"
  mkdir -p "$dest"
  jq -nc --arg r "$refresh" --arg e "$expires" \
    '{"https://auth.x.ai::fixture":{key:"access-fixture",refresh_token:$r,expires_at:$e,auth_mode:"oidc"}}' \
    > "$dest/auth.json"
  chmod 600 "$dest/auth.json"
}

# Grok leg (#331, #721): progress-only / timeout must not report success;
# finalize resumes the same session under the read-only allowlist (instructed not to use tools).
jqe() { jq -e "$@" >/dev/null; }
tr_check() {  # tr_check LABEL COMMAND...
  local label="$1"; shift
  if "$@"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

