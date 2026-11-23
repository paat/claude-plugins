#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

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
  cat > "$fake/muse" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fake/claude" "$fake/codex" "$fake/muse"

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
    TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_CODEX=on TRIBUNAL_CLAUDE=on TRIBUNAL_MUSE=on \
      TRIBUNAL_GROK=off TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_DEEPSEEK=off \
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

# Issue #518 / tribunal T-001: smoke prompt must emit files_examined so the
# shared review-output schema's required keys are satisfied (smoke reads no files).
test_smoke_prompt_files_examined() {
  local label="smoke prompt includes files_examined satisfying schema required keys"
  if (
    set -euo pipefail
    . "$PLUGIN_ROOT/scripts/lib.sh"
    prompt="$(tribunal_smoke_prompt codex)"
    printf '%s\n' "$prompt" | grep -q 'files_examined'
    obj="$(printf '%s\n' "$prompt" | sed -n 's/^Return only this JSON object with no fence or commentary: \(.*\)\. Do not inspect files or use tools\.$/\1/p')"
    [ -n "$obj" ]
    printf '%s' "$obj" | jq -e . >/dev/null
    required="$(jq -c '.required' "$PLUGIN_ROOT/schemas/review-output.json")"
    printf '%s' "$obj" | jq -e --argjson req "$required" \
      '(.files_examined == []) and (($req - keys) | length == 0)' >/dev/null
    # preflight smoke_review_ok accepts the smoke-shaped object
    printf '%s\n' "$obj" | jq -s -e --arg p codex '
      [.[] | select(.provider==$p and (has("error")|not) and (.findings|type)=="array" and (.summary|type)=="object")]
      | length==1
    ' >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

test_preflight_smoke_probe() {
  local label="opt-in preflight smoke verifies every enabled transport" work fake ec=0
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
[ "${SMOKE_CODEX_EMPTY:-off}" = on ] && exit 0
printf '%s\n' '{"provider":"codex","model":"smoke","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
printf '%s\n' '{"structured_output":{"provider":"claude","model":"smoke","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}}'
EOF
  cat > "$fake/dsh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
jq -nc --arg text '{"provider":"deepseek","model":"smoke","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' '{type:"final",text:$text}'
printf '%s\n' '{"type":"status","phase":"turn_end","reason":{"kind":"completed"}}'
EOF
  chmod +x "$fake/codex" "$fake/claude" "$fake/dsh"

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
      TRIBUNAL_GROK=off DEEPSEEK_API_KEY=fixture TRIBUNAL_DEEPSEEK=on TRIBUNAL_SMOKE_PROBE=on bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/preflight.json"
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
    # Only codex remains eligible; empty smoke must zero the usable quorum.
    PATH="$fake:$PATH" SMOKE_CODEX_EMPTY=on TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
      TRIBUNAL_SMOKE_PROBE=on TRIBUNAL_CLAUDE=off TRIBUNAL_DEEPSEEK=off \
      TRIBUNAL_GROK=off TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off \
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
{"result":"{\"provider\":\"claude\",\"model\":\"fixture\",\"files_examined\":[\"file.txt\"],\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10.0,\"verdict\":\"APPROVE\"}}"}
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
    && [ "$(wc -l < "$work/tmpdirs")" -eq 3 ] \
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

# Fixture repo with one changed file; prints nothing. Run inside a subshell.
test_codex_native_review() {
  local mode="$1" label="$2" work fake expected_note base_oid ok=0
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
if [ "\${2:-}" = review ]; then
  printf '%s\n' "\$@" > "$work/native.args"
  pwd > "$work/native.cwd"
  [ "\${NATIVE_FIXTURE:-ok}" = fail ] && exit 7
  while [ \$# -gt 0 ]; do
    [ "\$1" = --output-last-message ] && printf '%s\n' '- [P2] Fixture lead — file.txt:1-1' > "\$2"
    shift
  done
  exit 0
fi
printf 'call\n' >> "$work/verdict.calls"
printf '%s\n' "\$@" > "$work/verdict.args"
cat > "$work/verdict.prompt"
printf '%s\n' '{"provider":"codex","model":"fake","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10.0,"verdict":"APPROVE"}}'
EOF
  chmod +x "$fake/codex"
  (
    set -e
    cd "$work"
    native_review_repo
    export PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1
    unset TRIBUNAL_CODEX_MODEL TRIBUNAL_CODEX_EFFORT TRIBUNAL_RISK
    case "$mode" in
      ok) export TRIBUNAL_RISK=T4 ;;
      fail) export NATIVE_FIXTURE=fail ;;
      off) export TRIBUNAL_NATIVE_REVIEW=off ;;
    esac
    bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json" 2> "$work/err.txt"
  ) || ok=1
  base_oid="$(git -C "$work" rev-parse HEAD~1 2>/dev/null)"
  [ "$(wc -l < "$work/verdict.calls" 2>/dev/null)" = 1 ] || ok=1
  jq -e '.provider=="codex" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null 2>&1 || ok=1
  case "$mode" in
    ok)
      expected_note='native review (codex exec review) fed the verdict pass'
      grep -q 'Native review report (from codex exec review)' "$work/verdict.prompt" || ok=1
      grep -q 'Fixture lead — file.txt:1-1' "$work/verdict.prompt" || ok=1
      grep -q '^## End of native review report$' "$work/verdict.prompt" || ok=1
      [ -n "$(cat "$work/native.cwd")" ] && [ "$(cat "$work/native.cwd")" != "$work" ] || ok=1
      awk -v base="$base_oid" '
        previous == "--base" && $0 == base { base_seen = 1 }
        $0 == "--dangerously-bypass-approvals-and-sandbox" { bypass_seen = 1 }
        $0 == "--ignore-user-config" { isolated_seen = 1 }
        $0 == "--output-schema" { schema_seen = 1 }
        previous == "-c" && $0 == "model_reasoning_effort=\"high\"" { capped_seen = 1 }
        previous == "-c" && $0 == "review_model=\"gpt-6.2-astra\"" { review_model_seen = 1 }
        { previous = $0 }
        END { exit !(base_seen && bypass_seen && isolated_seen && !schema_seen && capped_seen && review_model_seen) }
      ' "$work/native.args" || ok=1
      grep -qx 'model_reasoning_effort="xhigh"' "$work/verdict.args" || ok=1
      ;;
    fail)
      expected_note='native review (codex exec review) unavailable (exit 7); verdict pass ran without it'
      ! grep -q 'Native review report' "$work/verdict.prompt" || ok=1
      grep -q 'tribunal: native review (codex exec review) unavailable: exit 7; stderr_bytes=0' "$work/err.txt" || ok=1
      ;;
    off)
      expected_note=''
      [ ! -e "$work/native.args" ] || ok=1
      ! grep -q 'Native review report' "$work/verdict.prompt" || ok=1
      ;;
  esac
  jq -e --arg note "$expected_note" '(.summary.note // "") == $note' "$work/out.json" >/dev/null 2>&1 || ok=1
  if [ "$ok" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_claude_native_review() {
  local mode="$1" label="$2" work fake expected_note ok=0
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/claude" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
case "\${2:-}" in
  /review*)
    printf '%s\n' "\$@" > "$work/native.args"
    if [ "\${NATIVE_FIXTURE:-ok}" = error ]; then
      printf '%s\n' '{"is_error":true,"result":"usage limit reached"}'
    else
      printf '%s\n' '{"result":"file.txt:1 — Fixture lead"}'
    fi
    exit 0 ;;
esac
printf '%s\n' "\$@" > "$work/verdict.args"
cat > "$work/verdict.prompt"
printf '%s\n' '{"result":"{\"provider\":\"claude\",\"model\":\"fixture\",\"files_examined\":[\"file.txt\"],\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10.0,\"verdict\":\"APPROVE\"}}"}'
EOF
  chmod +x "$fake/claude"
  (
    set -e
    cd "$work"
    native_review_repo
    unset TRIBUNAL_CLAUDE_MODEL TRIBUNAL_CLAUDE_EFFORT
    case "$mode" in
      error) export NATIVE_FIXTURE=error ;;
      off) export TRIBUNAL_NATIVE_REVIEW=off ;;
    esac
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_RISK=T4 \
      bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$work/out.json" 2> "$work/err.txt"
  ) || ok=1
  jq -e '.provider=="claude" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null 2>&1 || ok=1
  grep -q '^You are a senior code reviewer' "$work/verdict.prompt" 2>/dev/null || ok=1
  grep -qx -- '--disable-slash-commands' "$work/verdict.args" 2>/dev/null || ok=1
  case "$mode" in
    ok)
      expected_note='native review (/review) fed the verdict pass'
      grep -q 'Native review report (from /review)' "$work/verdict.prompt" 2>/dev/null || ok=1
      grep -q 'file.txt:1 — Fixture lead' "$work/verdict.prompt" 2>/dev/null || ok=1
      awk '
        NR == 2 && $0 ~ /^\/review high \/.*\/input\/review\.diff$/ { target_seen = 1 }
        previous == "--tools" && $0 == "Read,Glob,Grep" { tools_seen = 1 }
        $0 == "--safe-mode" { safe_seen = 1 }
        $0 == "--disable-slash-commands" || $0 == "--json-schema" { verdict_only_seen = 1 }
        { previous = $0 }
        END { exit !(target_seen && tools_seen && safe_seen && !verdict_only_seen) }
      ' "$work/native.args" 2>/dev/null || ok=1
      ;;
    error)
      expected_note='native review (/review) unavailable (no report); verdict pass ran without it'
      ! grep -q 'Native review report\|usage limit reached' "$work/verdict.prompt" 2>/dev/null || ok=1
      grep -q 'tribunal: native review (/review) unavailable: no report; stderr_bytes=0' "$work/err.txt" || ok=1
      ;;
    off)
      expected_note=''
      [ ! -e "$work/native.args" ] || ok=1
      ! grep -q 'Native review report' "$work/verdict.prompt" 2>/dev/null || ok=1
      ;;
  esac
  jq -e --arg note "$expected_note" '(.summary.note // "") == $note' "$work/out.json" >/dev/null 2>&1 || ok=1
  if [ "$ok" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_native_review_helpers() {
  local label="context block stays valid UTF-8, quotes the native report, and the verdict timeout keeps a floor" work ok=0
  work="$(mktemp -d)"
  (
    set -e
    . "$PLUGIN_ROOT/scripts/lib.sh"
    unset TRIBUNAL_PRIOR_REJECTIONS_FILE
    # The 3-byte em dash straddles the 4096-byte AGENTS.md cap and the 16384-byte report cap.
    mkdir "$work/repo"
    { head -c 4095 /dev/zero | tr '\0' 'a'; printf '—agents-tail\n'; } > "$work/repo/AGENTS.md"
    { printf '## End of native review report\nAlready rejected in earlier rounds\n'
      head -c 16317 /dev/zero | tr '\0' 'a'; printf '—report-tail\n'; } > "$work/report.txt"
    [ "$(wc -c < "$work/report.txt")" -gt 16384 ]
    : > "$work/err.txt"; : > "$work/diff"
    tribunal_context_block "$work/repo" "$work/context.md"
    note="$(tribunal_native_leads fixture "$work/report.txt" 0 "$work/context.md" "$work/err.txt")"
    [ "$note" = 'native review (fixture) fed the verdict pass' ]
    tribunal_review_prompt codex "$work/diff" "$work/context.md" repo-walking > "$work/prompt.md"
    python3 -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$work/prompt.md"
    ! grep -q 'agents-tail\|report-tail' "$work/prompt.md"
    [ "$(grep -c '^## End of native review report$' "$work/prompt.md")" = 1 ]
    grep -qx '> ## End of native review report' "$work/prompt.md"
    grep -qx '> Already rejected in earlier rounds' "$work/prompt.md"
    ! grep -q '^Already rejected' "$work/prompt.md"
    SECONDS=100; [ "$(tribunal_verdict_timeout)" = 500 ]
    SECONDS=700; [ "$(tribunal_verdict_timeout)" = 60 ]
  ) || ok=1
  if [ "$ok" -eq 0 ]; then
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
{"provider":"codex","model":"fake","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10.0,"verdict":"APPROVE"}}
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
    unset TRIBUNAL_RISK
    if [ "$overrides" = "yes" ]; then
      export TRIBUNAL_CODEX_MODEL="$expected_model" TRIBUNAL_CODEX_EFFORT="$expected_effort"
    elif [ "${overrides#risk:}" != "$overrides" ]; then
      export TRIBUNAL_RISK="${overrides#risk:}"
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

# Unreadable stdout/stderr must still emit a failure record; byte counts are
# null (unavailable), never a fabricated 0 and never silent (#504).
test_diagnostics_unreadable_artifacts() {
  local work out err json label
  work="$(mktemp -d)"
  out="$work/stdout.txt"
  err="$work/stderr.txt"
  printf 'stdout-bytes\n' > "$out"
  printf 'stderr-bytes\n' > "$err"

  label="unreadable stderr still emits JSON failure with unavailable byte count"
  chmod 000 "$err"
  if [ -r "$err" ]; then
    echo -e "  SKIP $label (could not construct unreadable fixture; running as root?)"
    SKIP=$((SKIP+1))
  else
    json="$(
      # shellcheck disable=SC1091
      . "$PLUGIN_ROOT/scripts/lib.sh"
      tribunal_error_with_diagnostics deepseek "fixture failure" execution 1 "$out" "$err"
    )"
    if printf '%s' "$json" | jq -e '
        .provider == "deepseek"
        and (.error | contains("phase=execution; exit=1"))
        and (.error | contains("stdout_bytes=13"))
        and (.error | contains("stderr_bytes=null"))
        and (.error | contains("stderr_bytes=0") | not)
      ' >/dev/null; then
      echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $label"; printf '%s\n' "$json"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    fi
  fi
  chmod 600 "$err" 2>/dev/null || true

  label="unreadable stdout still emits JSON failure with unavailable byte count"
  chmod 644 "$out" "$err"
  chmod 000 "$out"
  if [ -r "$out" ]; then
    echo -e "  SKIP $label (could not construct unreadable fixture; running as root?)"
    SKIP=$((SKIP+1))
  else
    json="$(
      # shellcheck disable=SC1091
      . "$PLUGIN_ROOT/scripts/lib.sh"
      tribunal_error_with_diagnostics deepseek "fixture failure" execution 1 "$out" "$err"
    )"
    if printf '%s' "$json" | jq -e '
        .provider == "deepseek"
        and (.error | contains("phase=execution; exit=1"))
        and (.error | contains("stdout_bytes=null"))
        and (.error | contains("stderr_bytes=13"))
        and (.error | contains("stdout_bytes=0") | not)
      ' >/dev/null; then
      echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $label"; printf '%s\n' "$json"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    fi
  fi
  chmod 600 "$out" 2>/dev/null || true
  rm -rf "$work"
}

# Fixture OIDC session for Grok runner/preflight tests (issue #374).
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
test_preflight_min_ok_legs() {
  local work fake ec=0 out err
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
exit 0
EOF
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  # Grok auth via XAI_API_KEY; no CLI probe required beyond presence.
  chmod +x "$fake/codex" "$fake/claude" "$fake/grok"
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
  )

  # One usable (codex only) with floor 2 → exit 1 naming both counts.
  ec=0
  (
    cd "$work"
    PATH="$fake:$PATH" XAI_API_KEY=fixture TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
      TRIBUNAL_CLAUDE=off TRIBUNAL_GROK=off TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off \
      TRIBUNAL_DEEPSEEK=off TRIBUNAL_MIN_OK_LEGS=2 \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > /dev/null 2> "$work/below.err"
  ) || ec=$?
  if [ "$ec" -eq 1 ] \
    && grep -Fq 'PREFLIGHT FAIL: usable legs (1) below TRIBUNAL_MIN_OK_LEGS (2).' "$work/below.err"; then
    echo -e "  ${GREEN}PASS${NC} preflight rejects usable below TRIBUNAL_MIN_OK_LEGS"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} preflight rejects usable below TRIBUNAL_MIN_OK_LEGS"; FAIL=$((FAIL+1))
    FAILURES+=("preflight usable below min_ok_legs")
  fi

  # Two usable with floor 2 → ok; status JSON carries min_ok_legs=2.
  ec=0
  (
    cd "$work"
    PATH="$fake:$PATH" XAI_API_KEY=fixture TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
      TRIBUNAL_CLAUDE=off TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off \
      TRIBUNAL_DEEPSEEK=off TRIBUNAL_MIN_OK_LEGS=2 \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/ok.json" 2> "$work/ok.err"
  ) || ec=$?
  if [ "$ec" -eq 0 ] \
    && jq -e '.status=="ok" and .min_ok_legs==2
        and ([.providers[]|select(.status=="usable")]|length) >= 2' "$work/ok.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} preflight accepts usable at TRIBUNAL_MIN_OK_LEGS"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} preflight accepts usable at TRIBUNAL_MIN_OK_LEGS"; FAIL=$((FAIL+1))
    FAILURES+=("preflight usable at min_ok_legs")
  fi

  # Invalid values → exit 2 naming the key (including 1: one-leg APPROVE rejected); unset → floor 2.
  local bad
  for bad in 0 1 8 abc 9; do
    ec=0
    (
      cd "$work"
      PATH="$fake:$PATH" XAI_API_KEY=fixture TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
        TRIBUNAL_CLAUDE=off TRIBUNAL_GROK=off TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off \
        TRIBUNAL_DEEPSEEK=off TRIBUNAL_MIN_OK_LEGS="$bad" \
        bash "$PLUGIN_ROOT/scripts/preflight.sh" > /dev/null 2> "$work/bad.err"
    ) || ec=$?
    if [ "$ec" -eq 2 ] && grep -q 'TRIBUNAL_MIN_OK_LEGS' "$work/bad.err" \
      && { [ "$bad" != 1 ] || grep -Fq 'one-leg APPROVE is not allowed' "$work/bad.err"; }; then
      echo -e "  ${GREEN}PASS${NC} preflight rejects invalid TRIBUNAL_MIN_OK_LEGS=$bad"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} preflight rejects invalid TRIBUNAL_MIN_OK_LEGS=$bad"; FAIL=$((FAIL+1))
      FAILURES+=("preflight invalid min_ok_legs=$bad")
    fi
  done
  ec=0
  (
    cd "$work"
    PATH="$fake:$PATH" XAI_API_KEY=fixture TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
      TRIBUNAL_CODEX=on TRIBUNAL_GROK=on TRIBUNAL_CLAUDE=off TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off \
      TRIBUNAL_DEEPSEEK=off \
      env -u TRIBUNAL_MIN_OK_LEGS bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/unset.json" 2> "$work/unset.err"
  ) || ec=$?
  if [ "$ec" -eq 0 ] && jq -e '.status=="ok" and .min_ok_legs==2' "$work/unset.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} preflight defaults TRIBUNAL_MIN_OK_LEGS to 2"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} preflight defaults TRIBUNAL_MIN_OK_LEGS to 2"; FAIL=$((FAIL+1))
    FAILURES+=("preflight default min_ok_legs")
  fi
  rm -rf "$work"
}

# Issue #518: empty-findings APPROVE without examined overlap against the
# reviewed range must become a provider error, never seal as ok.

test_claude_auth_guard
test_smoke_prompt_files_examined
test_preflight_smoke_probe
test_preflight_min_ok_legs
test_claude_tmpdir_cleanup
test_codex_pins gpt-6.2-astra medium no "codex defaults pin Astra and medium in argv"
test_codex_pins test-model high yes "codex model and effort environment overrides stay explicit"
test_codex_pins gpt-6.2-astra xhigh risk:T4 "TRIBUNAL_RISK=T4 lifts the Codex leg to xhigh"
test_codex_pins gpt-6.2-astra low risk:T1 "TRIBUNAL_RISK=T1 lowers the Codex leg to low"
test_codex_native_review ok "codex exec review runs against the pinned base and feeds the verdict pass"
test_codex_native_review fail "a failed codex exec review is recorded and the verdict pass still runs"
test_codex_native_review off "TRIBUNAL_NATIVE_REVIEW=off skips codex exec review"
test_claude_native_review ok "Claude /review reads the captured diff with read-only tools and feeds the verdict pass"
test_claude_native_review error "an is_error Claude /review result is recorded and the verdict pass still runs"
test_claude_native_review off "TRIBUNAL_NATIVE_REVIEW=off skips Claude /review"
test_native_review_helpers
test_codex_parse_diagnostics
test_codex_empty_output
test_claude_execution_diagnostics
test_diagnostics_unreadable_artifacts
test_claude_non_json_output
