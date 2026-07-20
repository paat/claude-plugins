#!/bin/bash
# Test runner for tribunal-review plugin.
# Usage: bash plugins/tribunal-review/tests/run-tests.sh
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; FAILURES=()
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

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

test_qwen_envelope_parser() {
  local label="qwen result envelope parsed" work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/qwen" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"type":"assistant","message":{"model":"qwen-envelope-test","content":null}},
  {"type":"result","model":"qwen-envelope-test","result":"{\"provider\":\"qwen\",\"model\":\"placeholder\",\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10.0,\"verdict\":\"APPROVE\"}}"}
]
JSON
EOF
  chmod +x "$fake/qwen"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_QWEN=on TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-qwen-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="qwen" and .model=="qwen-envelope-test" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

test_claude_auth_guard() {
  local label="expired Claude auth is skipped before provider execution" work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ] && [ "${3:-}" = "--json" ]; then
  printf '%s\n' '{"loggedIn":false,"authMethod":"none"}'
  exit 1
fi
: > "${CLAUDE_RUN_MARKER:?}"
exit 99
EOF
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fake/claude" "$fake/codex"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    export PATH="$fake:$PATH" CLAUDE_RUN_MARKER="$work/provider-ran"
    TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_CODEX=on TRIBUNAL_CLAUDE=on \
      TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=off \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/preflight.json"
    bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$work/review.json"
  ) && jq -e 'any(.providers[]; .name=="claude" and .status=="skipped" and .note=="CLI not authenticated")' "$work/preflight.json" >/dev/null \
    && jq -e '.provider=="claude" and .error=="Claude CLI is not authenticated"' "$work/review.json" >/dev/null \
    && [ ! -e "$work/provider-ran" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_preflight_smoke_probe() {
  local label="opt-in preflight smoke verifies every default transport" work fake ec=0
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
[ "${SMOKE_CODEX_EMPTY:-off}" = on ] && exit 0
printf '%s\n' '{"provider":"codex","model":"smoke","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
printf '%s\n' '{"structured_output":{"provider":"claude","model":"smoke","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}}'
EOF
  cat > "$fake/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  printf '%s\n' opencode-go/deepseek-v4-pro opencode-go/glm-5.1
  exit 0
fi
printf '%s\n' '{"provider":"deepseek","model":"smoke","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  chmod +x "$fake/codex" "$fake/claude" "$fake/opencode"

  (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    git checkout -qb feature
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
      TRIBUNAL_SMOKE_PROBE=on bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/preflight.json"
  )
  if jq -e '
      [.providers[] | select(.name=="codex" or .name=="claude" or .name=="deepseek")]
      | length==3 and all(.[]; .status=="usable" and .note=="non-interactive smoke passed")
    ' "$work/preflight.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi

  (
    cd "$work"
    PATH="$fake:$PATH" SMOKE_CODEX_EMPTY=on TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
      TRIBUNAL_SMOKE_PROBE=on TRIBUNAL_CLAUDE=off TRIBUNAL_DEEPSEEK=off \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > /dev/null 2> "$work/preflight-failed.err"
  ) || ec=$?
  label="failed smoke removes the provider from usable quorum"
  if [ "$ec" -eq 1 ] \
    && grep -q 'zero active reviewer legs are usable' "$work/preflight-failed.err" \
    && grep -q 'non-interactive smoke failed:' "$work/preflight-failed.err" \
    && grep -q 'phase=parse; exit=0; stdout_bytes=0' "$work/preflight-failed.err" \
    && grep -q 'stderr_bytes=0' "$work/preflight-failed.err"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_claude_tmpdir_cleanup() {
  local label="Claude auth and review residue stays in the cleaned runner tempdir"
  local work fake parent_tmp used_tmpdir
  work="$(mktemp -d)"
  fake="$work/bin"
  parent_tmp="$work/parent-tmp"
  mkdir -p "$fake" "$parent_tmp"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-review}" "${TMPDIR:-}" >> "${CLAUDE_TMPDIR_MARKER:?}"
: > "${TMPDIR:?}/claude-native-residue.so"
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
cat <<'JSON'
{"result":"{\"provider\":\"claude\",\"model\":\"fixture\",\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10.0,\"verdict\":\"APPROVE\"}}"}
JSON
EOF
  chmod +x "$fake/claude"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    TMPDIR="$parent_tmp" PATH="$fake:$PATH" CLAUDE_TMPDIR_MARKER="$work/tmpdirs" \
      TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" \
      > "$work/out.json"
  ) && jq -e '.provider=="claude" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null \
    && [ "$(wc -l < "$work/tmpdirs")" -eq 2 ] \
    && [ "$(cut -f2 "$work/tmpdirs" | sort -u | wc -l)" -eq 1 ] \
    && used_tmpdir="$(cut -f2 "$work/tmpdirs" | head -1)" \
    && [ "$used_tmpdir" != "$parent_tmp" ] \
    && [ ! -e "$used_tmpdir" ] \
    && [ -z "$(find "$parent_tmp" -mindepth 1 -print -quit)" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_codex_pins() {
  local expected_model="$1" expected_effort="$2" overrides="$3" label="$4"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/codex.args"
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"fake","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10.0,"verdict":"APPROVE"}}
JSON
EOF
  chmod +x "$fake/codex"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    export PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1
    unset TRIBUNAL_CODEX_MODEL TRIBUNAL_CODEX_EFFORT
    if [ "$overrides" = "yes" ]; then
      export TRIBUNAL_CODEX_MODEL="$expected_model" TRIBUNAL_CODEX_EFFORT="$expected_effort"
    fi
    bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="codex" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null &&
    awk -v model="$expected_model" -v effort="model_reasoning_effort=\"$expected_effort\"" '
      previous == "-m" && $0 == model { model_seen = 1 }
      previous == "-c" && $0 == effort { effort_seen = 1 }
      $0 == "--dangerously-bypass-approvals-and-sandbox" { bypass_count++ }
      $0 == "-s" { sandbox_selector_seen = 1 }
      $0 == "--ignore-user-config" { isolated_seen = 1 }
      $0 == "mcp_servers={}" { mcp_disabled = 1 }
      previous == "--output-schema" && $0 ~ /schemas\/review-output.json$/ { schema_seen = 1 }
      $0 == "--output-last-message" { last_message_seen = 1 }
      $0 == "--ephemeral" { ephemeral_seen = 1 }
      { previous = $0 }
      END { exit !(model_seen && effort_seen && bypass_count == 1 && !sandbox_selector_seen &&
        isolated_seen && mcp_disabled && schema_seen && last_message_seen && ephemeral_seen) }
    ' "$work/codex.args"
  then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_codex_parse_diagnostics() {
  local label="exit-zero malformed Codex output retains bounded diagnostics" work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex-prefix-'
head -c 4096 /dev/zero | tr '\0' x
printf '%s\n' '-codex-tail-marker'
printf '%s\n' 'codex-stderr-marker' >&2
EOF
  chmod +x "$fake/codex"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_DIAGNOSTIC_TAILS=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '
      .provider == "codex"
      and (.error | contains("unparseable codex output"))
      and (.error | contains("phase=parse; exit=0"))
      and (.error | contains("stdout_truncated=true"))
      and (.error | contains("codex-tail-marker"))
      and (.error | contains("codex-stderr-marker"))
      and ((.error | length) < 5000)
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_codex_empty_output() {
  local label="exit-zero empty Codex output is a diagnosed parse failure" work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
  chmod +x "$fake/codex"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '
      .provider=="codex"
      and (.error | contains("no review JSON object found"))
      and (.error | contains("phase=parse; exit=0; stdout_bytes=0"))
      and (.error | contains("stderr_bytes=0"))
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_claude_execution_diagnostics() {
  local label="immediate Claude failure retains safe diagnostics by default" work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
printf '%s\n' 'claude-partial-output API_KEY=fixture-secret-value'
printf '%s\n' 'claude-immediate-failure bearer fixture-secret-token' >&2
exit 7
EOF
  chmod +x "$fake/claude"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$work/out.json"
  ) && jq -e '
      .provider == "claude"
      and (.error | contains("Claude execution failed or timed out"))
      and (.error | contains("phase=execution; exit=7"))
      and (.error | contains("stdout_bytes="))
      and (.error | contains("stderr_bytes="))
      and (.error | contains("stdout_truncated=false"))
      and (.error | contains("stderr_truncated=false"))
      and (.error | contains("[omitted; set TRIBUNAL_DIAGNOSTIC_TAILS=on]"))
      and (.error | contains("fixture-secret-value") | not)
      and (.error | contains("fixture-secret-token") | not)
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

# Grok leg (#331): progress-only / timeout must not report success; tools-off
# resume of the same session must produce a schema verdict or a blocked error.
test_grok_deterministic_completion() {
  local work fake state
  work="$(mktemp -d)"
  fake="$work/bin"
  state="$work/state"
  mkdir -p "$fake" "$state"

  # Scenario A: inspect progress-only → finalize resume yields structured review
  cat > "$fake/grok" <<EOF
#!/usr/bin/env bash
# Record phase + tools value for later assertions (NUL-separated fields).
phase=inspect
tools_val=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--tools" ]; then tools_val="\$a"; fi
  if [ "\$a" = "--resume" ]; then phase=finalize; fi
  prev="\$a"
done
printf '%s\t%s\n' "\$phase" "\$tools_val" >> "$state/phases.log"
printf '%s\n' "\$@" >> "$state/args.log"
if [ "\$phase" = finalize ]; then
  cat <<'JSON'
{"text":"done","stopReason":"EndTurn","sessionId":"11111111-1111-1111-1111-111111111111","structuredOutput":{"provider":"grok","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":9,"verdict":"APPROVE"}},"modelUsage":{"fixture-model":{"inputTokens":1,"outputTokens":1}}}
JSON
  exit 0
fi
# Inspect phase: progress-only (no structured review)
cat <<'JSON'
{"text":"I'll review this PR as a read-only senior reviewer...","stopReason":"EndTurn","sessionId":"11111111-1111-1111-1111-111111111111","num_turns":1}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-a.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="APPROVE"
      and .model=="fixture-model"
      and ((.findings|length)==0)
      and (has("error")|not)
    ' "$work/out-a.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok progress-only inspect resumes tools-off for verdict"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok progress-only inspect resumes tools-off for verdict"; FAIL=$((FAIL+1))
    FAILURES+=("grok progress-only inspect resumes tools-off for verdict")
    echo "    out: $(cat "$work/out-a.json" 2>/dev/null || true)" >&2
  fi

  # Resume must use --resume; inspect allowlist vs finalize tools-off; pin session/max-turns
  if [ -f "$state/args.log" ] \
    && grep -q -- '--session-id' "$state/args.log" \
    && grep -q -- '--max-turns' "$state/args.log" \
    && grep -q -- '--resume' "$state/args.log" \
    && grep -q -- '--permission-mode' "$state/args.log" \
    && grep -qx $'inspect\tread_file,list_dir,grep' "$state/phases.log" \
    && grep -qx $'finalize\t' "$state/phases.log"; then
    echo -e "  ${GREEN}PASS${NC} grok inspect/finalize use session, max-turns, tools split"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok inspect/finalize use session, max-turns, tools split"; FAIL=$((FAIL+1))
    FAILURES+=("grok inspect/finalize use session, max-turns, tools split")
    echo "    phases: $(cat "$state/phases.log" 2>/dev/null | tr '\n' '|')" >&2
  fi

  # Scenario B: both phases incomplete → progress_only / incomplete error with session_id
  rm -f "$state/args.log" "$state/phases.log"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q -- '--resume'; then
  cat <<'JSON'
{"text":"Still gathering context...","stopReason":"EndTurn","sessionId":"22222222-2222-2222-2222-222222222222"}
JSON
  exit 0
fi
cat <<'JSON'
{"text":"I'll start by reading the diff...","stopReason":"EndTurn","sessionId":"22222222-2222-2222-2222-222222222222"}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-b.json"
  ) && jq -e '
      .provider=="grok"
      and (.error | test("incomplete|progress_only"))
      and (.error | test("session_id="))
      and (.error | test("phase=incomplete"))
    ' "$work/out-b.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok double progress-only reports incomplete not success"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok double progress-only reports incomplete not success"; FAIL=$((FAIL+1))
    FAILURES+=("grok double progress-only reports incomplete not success")
    echo "    out: $(cat "$work/out-b.json" 2>/dev/null || true)" >&2
  fi

  # Scenario C: first-pass structuredOutput (camelCase) completes without resume
  rm -f "$state/args.log" "$state/calls"
  cat > "$fake/grok" <<EOF
#!/usr/bin/env bash
count_file="$state/calls"
n=0
[ -f "\$count_file" ] && n="\$(cat "\$count_file")"
n=\$((n+1))
printf '%s\\n' "\$n" > "\$count_file"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","findings":[{"severity":"medium","category":"logic","file":"file.txt","line":1,"title":"t","description":"d","suggestion":"s","confidence":0.9}],"summary":{"total_findings":1,"critical":0,"high":0,"medium":1,"low":0,"quality_score":7,"verdict":"NEEDS_WORK"}},"sessionId":"33333333-3333-3333-3333-333333333333","modelUsage":{"fixture-model":{"inputTokens":1}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"
  : > "$state/calls"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-c.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="NEEDS_WORK"
      and (.findings|length)==1
      and .model=="fixture-model"
    ' "$work/out-c.json" >/dev/null \
    && [ "$(cat "$state/calls")" = "1" ]; then
    echo -e "  ${GREEN}PASS${NC} grok camelCase structuredOutput completes in one pass"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok camelCase structuredOutput completes in one pass"; FAIL=$((FAIL+1))
    FAILURES+=("grok camelCase structuredOutput completes in one pass")
    echo "    out: $(cat "$work/out-c.json" 2>/dev/null || true) calls=$(cat "$state/calls" 2>/dev/null)" >&2
  fi

  # Scenario D: inspect times out (124) → finalize recovers verdict
  rm -f "$state/args.log" "$state/calls"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q -- '--resume'; then
  cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":8,"verdict":"APPROVE"}},"sessionId":"44444444-4444-4444-4444-444444444444","modelUsage":{"fixture-model":{}}}
JSON
  exit 0
fi
# Partial envelope before timeout so session_id is known
cat <<'JSON'
{"text":"still reading files...","sessionId":"44444444-4444-4444-4444-444444444444"}
JSON
exit 124
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-d.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="APPROVE"
      and (has("error")|not)
    ' "$work/out-d.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok inspect timeout recovers via tools-off resume"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok inspect timeout recovers via tools-off resume"; FAIL=$((FAIL+1))
    FAILURES+=("grok inspect timeout recovers via tools-off resume")
    echo "    out: $(cat "$work/out-d.json" 2>/dev/null || true)" >&2
  fi

  # Lib helper: camelCase + snake_case extract, payload complete check
  complete_ok='{"provider":"grok","model":"m","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
  if printf '%s' "{\"structuredOutput\":$complete_ok}" \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_extract_grok_result" \
      | jq -e '.summary.verdict=="APPROVE"' >/dev/null \
    && printf '%s' '{"structured_output":{"findings":[],"summary":{"verdict":"BLOCK"}}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_extract_grok_result" \
      | jq -e '.summary.verdict=="BLOCK"' >/dev/null \
    && printf '%s' "$complete_ok" \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' 'I will review this next.' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' '{"findings":[],"summary":{"verdict":"pending"}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' '{"findings":[],"summary":{"verdict":"APPROVE"}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete"; then
    echo -e "  ${GREEN}PASS${NC} grok envelope helpers accept camel/snake and reject weak payloads"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok envelope helpers accept camel/snake and reject weak payloads"; FAIL=$((FAIL+1))
    FAILURES+=("grok envelope helpers accept camel/snake and reject weak payloads")
  fi

  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

test_claude_non_json_output() {
  local label="exit-zero non-JSON Claude result is a diagnosed parse failure" work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
printf '%s\n' '{"result":"The change looks good, but this is prose rather than review JSON."}'
EOF
  chmod +x "$fake/claude"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$work/out.json"
  ) && jq -e '
      .provider=="claude"
      and (.error | contains("no review JSON object found"))
      and (.error | contains("phase=parse; exit=0"))
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

# Vacuous verdict = zero findings + a blocking verdict. Both the reported BLOCK
# shape (quality 0.0) and the broader NEEDS_WORK / nonzero-quality shape must be
# downgraded to a leg error, never passed through as a real review (issue #171).
test_codex_vacuous_guard() {
  local verdict="$1" quality="$2" label="$3"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/codex.args"
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"default","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":$quality,"verdict":"$verdict"}}
JSON
EOF
  chmod +x "$fake/codex"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="codex" and (.error | test("vacuous"))' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  if [ "$verdict" = "BLOCK" ] && [ "$quality" = "0.0" ]; then
    local label2="codex reviewer always uses the exact unrestricted launch flag"
    if awk '
      $0 == "--dangerously-bypass-approvals-and-sandbox" { bypass_count++ }
      $0 == "-s" { sandbox_selector_seen = 1 }
      END { exit !(bypass_count == 1 && !sandbox_selector_seen) }
    ' "$work/codex.args" 2>/dev/null; then
      echo -e "  ${GREEN}PASS${NC} $label2"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $label2"; FAIL=$((FAIL+1)); FAILURES+=("$label2")
    fi
  fi
  rm -rf "$work"
}

# A provider can return structurally valid JSON whose line numbers are
# diff-global/prompt positions that cannot exist in the named file (issue #259).
# The runner must mark such findings (and findings on files outside the diff)
# instead of silently accepting them, while leaving valid positions untouched.
test_codex_line_bounds_guard() {
  local label="codex out-of-bounds finding positions are marked, valid ones untouched"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"default","findings":[
  {"severity":"high","category":"logic","file":"file.txt","line":1,"title":"valid position","description":"d","suggestion":"s","confidence":0.9},
  {"severity":"high","category":"logic","file":"file.txt","line":9333,"title":"diff-global position","description":"d","suggestion":"s","confidence":0.9},
  {"severity":"medium","category":"logic","file":"other.py","line":12,"title":"file outside diff","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"file.txt","line":"9333","title":"string-typed line","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","line":7,"title":"missing file field","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"gone.txt","line":4,"title":"positioned finding in deleted file","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"empty.txt","line":3,"title":"line in emptied file","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"nowhere.py","title":"line-less finding outside diff","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"dots..txt","line":9999,"title":"double-dot filename still bounded","description":"d","suggestion":"s","confidence":0.8}
],"summary":{"total_findings":9,"critical":0,"high":2,"medium":7,"low":0,"quality_score":5.0,"verdict":"NEEDS_WORK"}}
JSON
EOF
  chmod +x "$fake/codex"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    printf 'x = 1\n' > other.py
    printf 'bye\n' > gone.txt
    printf 'x\n' > empty.txt
    git add file.txt other.py gone.txt empty.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git rm -q gone.txt
    : > empty.txt
    printf 'dotted\n' > dots..txt
    git add empty.txt dots..txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '
      (.findings[0] | has("line_check") | not)
      and (.findings[1].line_check | test("out of bounds"))
      and (.findings[2].line_check == "file not in reviewed diff")
      and (.findings[3].line_check == "invalid line number")
      and (.findings[4].line_check == "malformed finding coordinates")
      and (.findings[5].line_check == "file missing at HEAD")
      and (.findings[6].line_check == "line out of bounds: file has 0 lines")
      and (.findings[7].line_check == "file not in reviewed diff")
      and (.findings[8].line_check == "line out of bounds: file has 1 lines")
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_wrapper_owned_provider_envelope() {
  local out
  out="$(printf '%s\n' '{"provider":"claude","status":"disabled","error":"spoof","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
    | bash -c '. "$1"; tribunal_emit_review codex' _ "$PLUGIN_ROOT/scripts/lib.sh")"
  if printf '%s' "$out" | jq -e '.provider=="codex" and (has("status")|not) and (has("error")|not)' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} wrapper owns provider identity and review status"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} wrapper owns provider identity and review status"; FAIL=$((FAIL+1)); FAILURES+=("wrapper-owned provider envelope")
  fi
}

test_trusted_evidence_collection() {
  local label="trusted evidence collection binds PR, providers, arbitration, and proof"
  local work repo fake plugin collection manifest_sha proof_sha base head
  work="$(mktemp -d)"; repo="$work/repo"; fake="$work/bin"; plugin="$work/plugin"
  mkdir -p "$repo" "$fake" "$work/tmp" "$plugin/scripts" "$plugin/schemas" "$plugin/.claude-plugin" "$plugin/integrity"
  cp "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/check-runner-bundle.sh" "$PLUGIN_ROOT/scripts/generate-runner-bundle.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/schemas/review-output.json" "$plugin/schemas/"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$plugin/.claude-plugin/plugin.json"

  cat > "$plugin/scripts/run-codex-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"codex","error":"fixture Codex transport failure"}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = malformed ]; then
  printf '%s\n' '{"provider":"claude","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"},"caller_owned":true}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = diagnostic ]; then
  printf '%s\n' '{"provider":"claude","error":"unparseable codex output: no review JSON object found; phase=parse; exit=0; stdout_bytes=12; stdout_truncated=false; stdout_tail=omitted; stderr_bytes=0; stderr_truncated=false; stderr_tail=omitted"}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = finding ]; then
  printf '%s\n' '{"provider":"claude","model":"fixture","findings":[{"severity":"medium","category":"logic","file":"app.txt","line":1,"title":"Fixture finding","description":"A concrete fixture defect.","suggestion":"Apply the fixture fix.","confidence":0.9}],"summary":{"total_findings":1,"critical":0,"high":0,"medium":1,"low":0,"quality_score":7,"verdict":"NEEDS_WORK"}}'
else
  printf '%s\n' '{"provider":"claude","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
fi
EOF
  for provider in gemini qwen grok; do
    cat > "$plugin/scripts/run-$provider-review.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '{"provider":"$provider","status":"disabled","note":"fixture disabled"}'
EOF
  done
  cat > "$plugin/scripts/run-claude-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"claude","error":"fixture Claude transport failure"}'
else
  printf '%s\n' '{"provider":"claude","status":"disabled","note":"fixture disabled"}'
fi
EOF
  cat > "$plugin/scripts/run-qwen-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_MUTATE_WORKTREE:-off}" = on ]; then printf 'provider mutation\n' >> app.txt; fi
printf '%s\n' '{"provider":"qwen","status":"disabled","note":"fixture disabled"}'
EOF
  cat > "$plugin/scripts/run-grok-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"provider":"grok","status":"disabled","note":"fixture disabled"}'
EOF
  cat > "$plugin/scripts/run-opencode-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"provider":"glm","status":"disabled","note":"fixture disabled"}'
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"deepseek","error":"fixture DeepSeek transport failure"}'
else
  printf '%s\n' '{"provider":"deepseek","status":"disabled","note":"fixture disabled"}'
fi
EOF
  chmod +x "$plugin/scripts/"*.sh
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null

  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > app.txt
    git add app.txt
    git commit -q -m base
    printf 'two\n' > app.txt
    git commit -q -am change
    git remote add origin https://github.com/example/fixture.git
  )
  base="$(git -C "$repo" rev-parse HEAD~1)"; head="$(git -C "$repo" rev-parse HEAD)"
  printf 'Bound PR body' > "$work/pr-body"
  cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = repo ] && [ "$2" = view ]; then
  jq -nc '{nameWithOwner:"example/fixture",url:"https://github.com/example/fixture"}'
elif [ "$1" = pr ] && [ "$2" = view ]; then
  jq -nc --argjson number "$3" --arg base "$FIXTURE_BASE" --arg head "$FIXTURE_HEAD" \
    --rawfile body "$FIXTURE_BODY_FILE" \
    '{number:$number,url:("https://github.com/example/fixture/pull/"+($number|tostring)),state:"OPEN",
      baseRefName:"main",baseRefOid:$base,headRefName:"feature",headRefOid:$head,body:$body}'
else
  printf 'unexpected gh invocation: %s\n' "$*" >&2
  exit 2
fi
EOF
  chmod +x "$fake/gh"

  cat > "$fake/mv" <<'EOF'
#!/usr/bin/env bash
target=${!#}
if [ -n "${FIXTURE_KILL_PUBLISH:-}" ] && [ "$target" = "$FIXTURE_KILL_PUBLISH" ]; then
  kill -KILL "$PPID"
  exit 137
fi
/usr/bin/mv "$@"
if [ -n "${FIXTURE_KILL_FINALIZE:-}" ] && [ "$target" = "$FIXTURE_KILL_FINALIZE" ]; then
  kill -KILL "$PPID"
fi
EOF
  chmod +x "$fake/mv"

  if FIXTURE_MUTATE_WORKTREE=on PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/mutated" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} trusted evidence runner rejects provider worktree mutation"; FAIL=$((FAIL+1)); FAILURES+=("provider worktree mutation")
    rm -rf "$work"; return
  else
    echo -e "  ${GREEN}PASS${NC} trusted evidence runner rejects provider worktree mutation"; PASS=$((PASS+1))
  fi

  local killed_collection="$work/killed-collection" interrupted_ec=0
  TMPDIR="$work/tmp" FIXTURE_KILL_PUBLISH="$killed_collection" \
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$killed_collection" >/dev/null 2>&1 || interrupted_ec=$?
  if [ "$interrupted_ec" -ne 0 ] && [ ! -e "$killed_collection" ]; then
    echo -e "  ${GREEN}PASS${NC} killed publication leaves no partial collection"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} killed publication leaves no partial collection"; FAIL=$((FAIL+1)); FAILURES+=("atomic collection publication")
    rm -rf "$work"; return
  fi

  collection="$work/collection"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$collection" > "$work/collect.json"; then
    echo -e "  ${RED}FAIL${NC} $label (collection failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  manifest_sha="$(jq -r .manifest_sha256 "$work/collect.json")"

  # The codex fixture claims to be Claude; the aggregate runner owns and
  # rewrites identity before sealing the artifact.
  if ! jq -e '.provider=="codex" and (has("caller_owned")|not)' "$collection/providers/codex.json" >/dev/null; then
    echo -e "  ${RED}FAIL${NC} $label (provider identity/schema not owned by runner)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi

  chmod u+w "$collection/providers/codex.json"
  cp "$collection/providers/codex.json" "$work/codex.saved"
  printf '\n' >> "$collection/providers/codex.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (artifact tamper accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  cp "$work/codex.saved" "$collection/providers/codex.json"; chmod 0444 "$collection/providers/codex.json"

  cp "$plugin/scripts/lib.sh" "$work/lib.saved"
  printf '\n# drift\n' >> "$plugin/scripts/lib.sh"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (runner provenance drift accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  cp "$work/lib.saved" "$plugin/scripts/lib.sh"

  printf 'Changed PR body' > "$work/pr-body"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (PR body drift accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  printf 'Bound PR body' > "$work/pr-body"

  cat > "$work/arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"One valid reviewer found no defects."},
  "findings":[],"scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "glm":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"}
  },
  "conflicts_resolved":[],"summary":"No blocking findings."
}
EOF
  jq '.provider_assessment.codex.status="failed"' "$work/arbitration.json" > "$work/bad-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/bad-arbitration.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (caller-authored provider status accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi

  interrupted_ec=0
  TMPDIR="$work/tmp" FIXTURE_KILL_FINALIZE="$collection/arbitration.json" \
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
      >/dev/null 2>&1 || interrupted_ec=$?
  if [ "$interrupted_ec" -ne 0 ] && [ -f "$collection/arbitration.json" ] \
    && [ ! -e "$collection/proof.json" ] && [ -f "$collection/.finalize.lock" ]; then
    echo -e "  ${GREEN}PASS${NC} killed finalization releases its process lock"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} killed finalization releases its process lock"; FAIL=$((FAIL+1)); FAILURES+=("crash-releasing finalization lock")
    rm -rf "$work"; return
  fi

  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" > "$work/finalize.json"; then
    echo -e "  ${RED}FAIL${NC} $label (finalization failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  proof_sha="$(jq -r .proof_sha256 "$work/finalize.json")"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-proof --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --expected-proof-sha256 "$proof_sha" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label (proof verification failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" > "$work/finalize-repeat.json" \
    && cmp -s "$work/finalize.json" "$work/finalize-repeat.json"; then
    echo -e "  ${GREEN}PASS${NC} identical finalize retry returns the retained proof"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} identical finalize retry returns the retained proof"; FAIL=$((FAIL+1)); FAILURES+=("idempotent finalize retry")
  fi
  jq '.tribunal_verdict.rationale="Conflicting repeat."' "$work/arbitration.json" > "$work/conflicting-repeat.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/conflicting-repeat.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} conflicting finalize retry is rejected"; FAIL=$((FAIL+1)); FAILURES+=("conflicting finalize retry")
  else
    echo -e "  ${GREEN}PASS${NC} conflicting finalize retry is rejected"; PASS=$((PASS+1))
  fi

  FIXTURE_CODEX_MODE=malformed PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/malformed" > "$work/malformed.json"
  if jq -e '.provider=="codex" and has("error")' "$work/malformed/providers/codex.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} strict provider schema rejects caller/model extras"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} strict provider schema rejects caller/model extras"; FAIL=$((FAIL+1)); FAILURES+=("strict provider schema")
  fi
  jq '.provider_assessment.codex.status="failed"' "$work/arbitration.json" > "$work/no-quorum-approve.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/malformed" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/malformed.json")" \
      --arbitration "$work/no-quorum-approve.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} no successful provider cannot approve"; FAIL=$((FAIL+1)); FAILURES+=("no-quorum approval")
  else
    echo -e "  ${GREEN}PASS${NC} no successful provider cannot approve"; PASS=$((PASS+1))
  fi

  FIXTURE_ZERO_SUCCESS=on PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/zero-success" > "$work/zero-success.json"
  if jq -e '
      [.providers[] | select(.provider=="codex" or .provider=="deepseek" or .provider=="claude")]
      | length==3 and all(.[]; .status=="failed")
    ' "$work/zero-success/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} aggregate collection retains zero-success default panel"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} aggregate collection retains zero-success default panel"; FAIL=$((FAIL+1)); FAILURES+=("zero-success default panel")
  fi
  jq '
    .tribunal_verdict={"decision":"NEEDS_WORK","confidence":0,"rationale":"No default reviewer completed successfully."}
    | .summary="No usable reviewer evidence; merge remains blocked."
    | .provider_assessment.codex.status="failed"
    | .provider_assessment.deepseek.status="failed"
    | .provider_assessment.claude.status="failed"
  ' "$work/arbitration.json" > "$work/zero-success-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/zero-success" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/zero-success.json")" \
      --arbitration "$work/zero-success-arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} zero-success default panel fails closed at confidence zero"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} zero-success default panel fails closed at confidence zero"; FAIL=$((FAIL+1)); FAILURES+=("zero-success fail closed")
  fi

  FIXTURE_CODEX_MODE=diagnostic PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/diagnostic" > "$work/diagnostic.json"
  if jq -e '.provider=="codex" and (.error | contains("phase=parse; exit=0"))' \
      "$work/diagnostic/providers/codex.json" >/dev/null \
    && PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$work/diagnostic" \
        --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/diagnostic.json")" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} aggregate evidence retains provider diagnostics"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} aggregate evidence retains provider diagnostics"; FAIL=$((FAIL+1)); FAILURES+=("aggregate diagnostics")
  fi

  FIXTURE_CODEX_MODE=finding PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/finding" > "$work/finding.json"
  cat > "$work/finding-arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.9,"rationale":"The medium finding is non-blocking."},
  "findings":[{"id":"T-001","consensus":"SINGLE_PROVIDER","providers":["codex"],"severity":"medium",
    "category":"logic","file":"app.txt","line":1,"title":"Fixture finding","description":"A concrete fixture defect.",
    "suggestion":"Apply the fixture fix.","confidence":0.9,"arbiter_notes":"Verified and non-blocking."}],
  "scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":1,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "glm":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"}
  },
  "conflicts_resolved":[],"summary":"One medium finding remains non-blocking."
}
EOF
  jq '.findings[0].severity="high"' "$work/finding-arbitration.json" > "$work/missing-blocking-proof.json"
  local finding_manifest
  finding_manifest="$(jq -r .manifest_sha256 "$work/finding.json")"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/finding" \
      --expected-manifest-sha256 "$finding_manifest" --arbitration "$work/missing-blocking-proof.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} strict arbitration requires blocking proof"; FAIL=$((FAIL+1)); FAILURES+=("strict arbitration blocking proof")
  else
    jq -S . "$work/finding-arbitration.json" > "$work/finding/arbitration.json"
    chmod 0444 "$work/finding/arbitration.json"
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/finding" \
      --expected-manifest-sha256 "$finding_manifest" --arbitration "$work/finding-arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} interrupted finalize resumes from identical retained arbitration"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} interrupted finalize resumes from identical retained arbitration"; FAIL=$((FAIL+1)); FAILURES+=("interrupted finalize recovery")
  fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

SK=skills/tribunal-loop/SKILL.md
CL=skills/closing-tribunal-loop/SKILL.md
LIB=scripts/lib.sh
PF=scripts/preflight.sh

echo "Extracted script surface:"
for script in \
  scripts/lib.sh \
  scripts/preflight.sh \
  scripts/run-codex-review.sh \
  scripts/run-gemini-review.sh \
  scripts/run-opencode-review.sh \
  scripts/run-qwen-review.sh \
  scripts/run-grok-review.sh \
  scripts/run-claude-review.sh \
  scripts/collect-review-evidence.sh \
  scripts/check-runner-bundle.sh \
  scripts/generate-runner-bundle.sh
do
  assert_file "$script exists" "$script"
  assert_executable "$script executable" "$script"
  assert_bash_n "$script parses" "$script"
done
assert_file "structured review schema exists" "schemas/review-output.json"
assert_json_field "structured review schema is valid JSON" "jq -e '.type==\"object\" and .additionalProperties==false' '$PLUGIN_ROOT/schemas/review-output.json'"
assert_file "static runner bundle manifest exists" "integrity/runner-bundle.json"
assert_json_field "static runner bundle validates" "bash '$PLUGIN_ROOT/scripts/check-runner-bundle.sh' | jq -e '.status==\"valid\" and .version==\"0.20.5\"'"
assert_json_field "static runner bundle is current" "bash '$PLUGIN_ROOT/scripts/generate-runner-bundle.sh' --check"

echo "Skill is orchestration-focused:"
line_count="$(wc -l < "$PLUGIN_ROOT/$SK" | tr -d ' ')"
if [ "$line_count" -le 260 ]; then
  echo -e "  ${GREEN}PASS${NC} compact tribunal skill ($line_count<=260)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} compact tribunal skill ($line_count>260)"; FAIL=$((FAIL+1)); FAILURES+=("compact tribunal skill")
fi
assert_grep "skill references preflight script" "$SK" "scripts/preflight.sh"
assert_grep "skill references codex runner" "$SK" "scripts/run-codex-review.sh"
assert_grep "skill references opencode runner" "$SK" "scripts/run-opencode-review.sh"
assert_grep "skill references grok runner" "$SK" "scripts/run-grok-review.sh"
assert_grep "skill references claude runner" "$SK" "scripts/run-claude-review.sh"
assert_grep "merge gate uses trusted aggregate runner" "$SK" "scripts/collect-review-evidence.sh"
assert_grep "caller provider JSON is not merge evidence" "$SK" "caller-created provider JSON as merge evidence"
assert_no_grep "skill no inline provider command bloat" "$SK" "timeout -k 10 600 codex exec"

echo "Preflight/base-ref behavior:"
assert_grep "resolves GitHub default branch" "$LIB" "defaultBranchRef"
assert_grep "supports base-ref override" "$LIB" "TRIBUNAL_BASE_REF"
assert_grep "checks diff vs BASE_REF" "$LIB" 'git diff "$base_ref"...HEAD'
assert_grep "tracks active reviewer legs" "$PF" "zero active reviewer legs"
assert_grep "warms OpenCode model registry" "$PF" "opencode models"
assert_grep "Claude auth probe is bounded" "$LIB" "timeout -k 1 10 claude auth status --json"
assert_grep "preflight checks Claude auth" "$PF" "tribunal_claude_authenticated"
assert_grep "preflight discloses invocation limitation" "$PF" "non-interactive invocation not probed"
assert_grep "preflight offers bounded non-interactive smoke" "$PF" "TRIBUNAL_SMOKE_PROBE"
assert_no_grep "skill has no hardcoded origin/main" "$SK" "origin/main"
assert_no_grep "lib has no hardcoded origin/main" "$LIB" "origin/main"

echo "Context and large-diff guards:"
assert_grep "AGENTS.md capped" "$LIB" "head -c 4096"
assert_grep "reachability.md capped" "$LIB" "head -c 8192"
assert_no_grep "reviewer prompt has no DRY instruction" "$LIB" "DRY: flag meaningful duplication"
assert_grep "diff limit env" "$LIB" "TRIBUNAL_DIFF_LIMIT_BYTES"
assert_grep "large diff uses head -c" "$LIB" 'head -c "$max"'
assert_grep "OpenCode uses file attachment" "scripts/run-opencode-review.sh" '-f "$diff_attach"'
assert_grep "OpenCode prompt positional precedes -f (array flag swallows positionals, issue #170)" "scripts/run-opencode-review.sh" '"$(cat "$prompt")" -f "$diff_attach"'
assert_no_grep "OpenCode -f does not precede prompt positional" "scripts/run-opencode-review.sh" '-f "$diff_attach" "$(cat'
assert_grep "OpenCode stages diff in cwd" "scripts/run-opencode-review.sh" ".tribunal-review-"
assert_grep "OpenCode isolates external plugins" "scripts/run-opencode-review.sh" "--pure"
assert_grep "OpenCode non-interactive run bypasses permission prompts" "scripts/run-opencode-review.sh" "--dangerously-skip-permissions"
assert_grep "Codex writes its final response independently of stdout" "scripts/run-codex-review.sh" "--output-last-message"
assert_grep "Codex requests the shared output schema" "scripts/run-codex-review.sh" "--output-schema"
assert_grep "Claude requests the shared output schema" "scripts/run-claude-review.sh" "--json-schema"
assert_grep "Claude disables the complete tool surface" "scripts/run-claude-review.sh" '--tools ""'
assert_grep "Grok requests the shared output schema" "scripts/run-grok-review.sh" "--json-schema"
assert_grep "Grok tools allowlist is read-only" "scripts/run-grok-review.sh" "read_file,list_dir,grep"
assert_grep "Grok uses kernel read-only sandbox" "scripts/run-grok-review.sh" "--sandbox read-only"
assert_grep "Grok unsets host GROK_SANDBOX" "scripts/run-grok-review.sh" "env -u GROK_SANDBOX"
assert_grep "Grok isolates host HOME" "scripts/run-grok-review.sh" 'HOME="$ISOLATED_HOME"'
assert_grep "Grok isolates host GROK_HOME" "scripts/run-grok-review.sh" 'GROK_HOME="$ISOLATED_HOME/.grok"'
assert_grep "Grok links auth into isolation" "scripts/run-grok-review.sh" 'ln -s "$AUTH_SRC"'
assert_grep "Grok disables web search" "scripts/run-grok-review.sh" "--disable-web-search"
assert_grep "Grok pins a session id for resume" "scripts/run-grok-review.sh" "--session-id"
assert_grep "Grok finalize resumes the same session" "scripts/run-grok-review.sh" "--resume"
assert_grep "Grok bounds inspect turns" "scripts/run-grok-review.sh" "--max-turns"
assert_grep "Grok uses dontAsk for headless read-only" "scripts/run-grok-review.sh" "--permission-mode dontAsk"
assert_grep "Grok rejects progress-only as incomplete" "scripts/run-grok-review.sh" "completion_state=progress_only"
assert_grep "Grok finalize re-inlines the authoritative diff" "scripts/run-grok-review.sh" "Base the verdict on the unified diff"
assert_grep "Grok clamps inspect timeout upper bound" "scripts/run-grok-review.sh" "INSPECT_TIMEOUT=1800"
assert_grep "Grok extracts camelCase structuredOutput" "scripts/lib.sh" "structuredOutput"
assert_grep "Grok payload completeness helper" "scripts/lib.sh" "tribunal_review_payload_complete"
assert_grep "Grok payload requires enum verdict" "scripts/lib.sh" 'APPROVE" or $v == "NEEDS_WORK" or $v == "BLOCK"'

echo "Disabled-provider markers:"
assert_json_field "codex disabled JSON" "TRIBUNAL_CODEX=off bash '$PLUGIN_ROOT/scripts/run-codex-review.sh' | jq -e '.provider==\"codex\" and .status==\"disabled\"'"
assert_json_field "gemini disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-gemini-review.sh' | jq -e '.provider==\"gemini\" and .status==\"disabled\"'"
assert_json_field "qwen disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-qwen-review.sh' | jq -e '.provider==\"qwen\" and .status==\"disabled\"'"
assert_json_field "grok disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-grok-review.sh' | jq -e '.provider==\"grok\" and .status==\"disabled\"'"
assert_json_field "claude disabled JSON" "TRIBUNAL_CLAUDE=off bash '$PLUGIN_ROOT/scripts/run-claude-review.sh' | jq -e '.provider==\"claude\" and .status==\"disabled\"'"
assert_json_field "opencode disabled JSONL" "TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=off bash '$PLUGIN_ROOT/scripts/run-opencode-review.sh' | jq -s -e 'length==2 and all(.[]; .status==\"disabled\")'"
assert_json_field "opencode usage error preserves disabled markers" "TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=on bash '$PLUGIN_ROOT/scripts/run-opencode-review.sh' --bad-flag | jq -s -e 'length==2 and .[0].provider==\"glm\" and .[0].status==\"disabled\" and (.[1] | .provider==\"deepseek\" and has(\"error\"))'"
test_qwen_envelope_parser
test_claude_auth_guard
test_preflight_smoke_probe
test_claude_tmpdir_cleanup
test_codex_pins gpt-5.6-sol medium no "codex defaults pin Sol and medium in argv"
test_codex_pins test-model high yes "codex model and effort environment overrides stay explicit"
test_codex_parse_diagnostics
test_codex_empty_output
test_claude_execution_diagnostics
test_claude_non_json_output
test_grok_deterministic_completion
test_codex_vacuous_guard BLOCK 0.0 "codex vacuous empty-BLOCK downgraded to leg error"
test_codex_vacuous_guard NEEDS_WORK 7.5 "codex vacuous empty-NEEDS_WORK (nonzero quality) downgraded to leg error"
test_codex_vacuous_guard " BLOCK " 0.0 "codex vacuous verdict tolerates surrounding whitespace"
test_codex_line_bounds_guard
test_wrapper_owned_provider_envelope
test_trusted_evidence_collection

echo "Finding position validation:"
assert_grep "lib defines line-bounds validator" "$LIB" "tribunal_line_check()"
assert_grep "prepare_diff records NUL-delimited changed paths" "$LIB" 'git diff --name-only -z "$base_ref"'
for runner in run-codex-review.sh run-claude-review.sh run-gemini-review.sh run-qwen-review.sh run-grok-review.sh run-opencode-review.sh; do
  assert_grep "$runner pipes through line check" "scripts/$runner" "tribunal_line_check"
done
assert_grep "arbiter told to distrust marked positions" "$SK" "line_check"

echo "Arbitration contract:"
assert_grep "3b-0 in SKILL" "$SK" "3b-0: Blocking-Finding Standard"
assert_grep "standard overrides highest-severity" "$SK" "never override 3b-0"
assert_grep "same-class merge" "$SK" "Same-Class Merge (Every Round)"
assert_grep "reachability read by arbiter" "$SK" "Also read .reachability.md"
assert_grep "blocking_proof schema" "$SK" '"blocking_proof"'
assert_grep "arbiter applies KISS/YAGNI filter" "$SK" "3c: KISS / YAGNI Filter (Arbiter)"
assert_grep "arbiter rewrites over-engineered suggestions" "$SK" "smallest sufficient fix"
assert_grep "KISS/YAGNI alone cannot block" "$SK" "Never promote to critical/high for a KISS/YAGNI violation alone"
assert_grep "scope lens switch" "$SK" "TRIBUNAL_SCOPE_LENS"
assert_grep "scope findings schema" "$SK" "scope_findings"
assert_grep "calling context arbitrates" "$SK" "calling context arbitrates"
assert_grep "caller provider metadata optional" "$SK" "TRIBUNAL_CALLER_PROVIDER"
assert_grep "caller model metadata optional" "$SK" "TRIBUNAL_CALLER_MODEL"
assert_grep "caller effort metadata optional" "$SK" "TRIBUNAL_CALLER_EFFORT"
assert_grep "sealed proof rechecks live PR drift" "$SK" "rechecks live PR drift"
assert_grep "standalone caller identity is optional" "$SK" "standalone runs may leave all three unset"
assert_no_grep "tribunal skill has no Opus authority claim" "$SK" "Opus"
assert_no_grep "closing skill has no Opus authority claim" "$CL" "Opus"
assert_no_grep "README has no Opus authority claim" "README.md" "Opus"
assert_no_grep "Claude reviewer has no Opus authority claim" "agents/claude-reviewer.md" "Opus"

echo "Closing loop governor:"
assert_grep "stop on no crit/high" "$CL" "zero .critical. and"
assert_grep "YAGNI triage" "$CL" "YAGNI triage"
assert_grep "closing loop freezes delivery scope" "$CL" "Frozen Delivery Contract"
assert_grep "scope comes from explicit task text" "$CL" "using only explicit user, issue, PR, or plan text"
assert_grep "missing scope is not invented" "$CL" "Never invent missing"
assert_grep "findings do not redefine task" "$CL" "do not redefine the task"
assert_grep "fixes remain causal and minimal" "$CL" "smallest causal fix"
assert_grep "adjacent concerns do not expand investigation" "$CL" "beyond evidence already present"
assert_grep "step-back preserves architecture" "$CL" "existing architecture"
assert_grep "step-back workflow" "$CL" "Step-back workflow (anti-spiral)"
assert_grep "no-net-increase guard" "$CL" "no-net-increase"
assert_grep "round 3 checkpoint" "$CL" "Round 3 — checkpoint"
assert_grep "round 5 ceiling" "$CL" "Round 5 — hard ceiling"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
