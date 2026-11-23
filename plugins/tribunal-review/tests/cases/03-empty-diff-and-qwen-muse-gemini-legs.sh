#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_empty_staged_diff_with_real_changes_fails_closed() {
  local label="empty staged diff with real changes is a leg error" work base_oid head_oid
  work="$(mktemp -d)"
  git -C "$work" init -q
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf 'base\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m base
  base_oid="$(git -C "$work" rev-parse HEAD)"
  printf 'changed\n' > "$work/file.txt"
  git -C "$work" commit -q -am change
  head_oid="$(git -C "$work" rev-parse HEAD)"

  (
    cd "$work"
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    tribunal_empty fixture fixture-model HEAD~1 "$(tribunal_take_diff_stat "$work/d.diff")"
  ) > "$work/out.json"

  if jq -e --arg base "$base_oid" --arg head "$head_oid" '
      .provider == "fixture"
      and has("error")
      and (.error | contains("resolved base ref HEAD~1"))
      and (.error | contains($base))
      and (.error | contains($head))
      and (.error | contains("a non-empty diff exists"))
    ' "$work/out.json" >/dev/null \
    && ! grep -q '"verdict":"APPROVE"' "$work/out.json"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_genuine_empty_diff_is_reverified_and_unchanged() {
  local label="genuine empty diff is reverified over the pinned range" work
  work="$(mktemp -d)"
  git -C "$work" init -q
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf 'base\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m base

  (
    cd "$work"
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD tribunal_prepare_diff "$work/d.diff"
    GIT_TRACE="$work/git.trace" tribunal_empty fixture fixture-model HEAD \
      "$(tribunal_take_diff_stat "$work/d.diff")"
  ) > "$work/out.json"

  if jq -e --arg oid "$(git -C "$work" rev-parse HEAD)" '
      .provider == "fixture"
      and .model == "fixture-model"
      and .findings == []
      and .files_examined == []
      and .summary.total_findings == 0
      and .summary.critical == 0
      and .summary.high == 0
      and .summary.medium == 0
      and .summary.low == 0
      and (.summary.quality_score | type == "number" and . == 10)
      and .summary.verdict == "APPROVE"
      and .summary.note == "No changes detected vs HEAD"
      and .diff_stat.files_changed == 0
      and .diff_stat.base_oid == $oid
      and .diff_stat.head_oid == $oid
    ' "$work/out.json" >/dev/null \
    && ! grep -Fq 'rev-parse' "$work/git.trace" \
    && grep -Fq 'diff --quiet' "$work/git.trace"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_unresolvable_base_during_empty_verification_fails_closed() {
  local label="unresolvable base during empty verification is a leg error" work
  work="$(mktemp -d)"
  git -C "$work" init -q
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf 'base\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m base

  (
    cd "$work"
    . "$PLUGIN_ROOT/scripts/lib.sh"
    if TRIBUNAL_BASE_REF=refs/heads/missing tribunal_prepare_diff "$work/d.diff"; then
      printf '%s\n' '{"provider":"fixture","error":"capture unexpectedly succeeded"}'
    else
      tribunal_empty fixture fixture-model refs/heads/missing \
        "$(tribunal_take_diff_stat "$work/d.diff")"
    fi
  ) > "$work/out.json"

  if jq -e '
      .provider == "fixture"
      and has("error")
      and (.error | contains("the reviewed range was not captured"))
      and (.error | contains("refs/heads/missing"))
    ' "$work/out.json" >/dev/null \
    && ! grep -q '"verdict":"APPROVE"' "$work/out.json"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_qwen_envelope_parser() {
  local label="qwen result envelope parsed; model fallback warns" work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/qwen" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"type":"assistant","message":{"model":"qwen-envelope-test","content":null}},
  {"type":"result","model":"qwen-envelope-test","result":"{\"provider\":\"qwen\",\"model\":\"placeholder\",\"files_examined\":[\"file.txt\"],\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10.0,\"verdict\":\"APPROVE\"}}"}
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
    PATH="$fake:$PATH" TRIBUNAL_QWEN=on TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-qwen-review.sh" > "$work/out.json" 2> "$work/err"
    PATH="$fake:$PATH" TRIBUNAL_QWEN=on TRIBUNAL_QWEN_MODEL=qwen-envelope-test TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-qwen-review.sh" > /dev/null 2> "$work/err-match"
  ) && jq -e '.provider=="qwen" and .model=="qwen-envelope-test" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null \
    && grep -qF 'qwen: requested qwen3.8-max but qwen-code ran qwen-envelope-test' "$work/err" \
    && ! grep -qF 'qwen: requested' "$work/err-match"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

test_muse_leg() {
  local label="muse leg: read-only flags, spark default, stamped model, failures" work fake ok=1
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/muse" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FIXTURE_MUSE_ARGS"
jq -cn --arg m "${FIXTURE_MUSE_SERVED:-muse-spark-1.3}" '{payload_type:"run.model.configured",payload:{model_id:$m}}'
if [ -n "${FIXTURE_MUSE_FAIL:-}" ]; then
  jq -cn --arg r "$FIXTURE_MUSE_FAIL" '{payload_type:"run.terminal.failed",payload:{terminal:"failed",reason:$r}}'
  printf 'run ended with Failed: %s\n' "$FIXTURE_MUSE_FAIL" >&2
  exit 1
fi
[ "${FIXTURE_MUSE_NO_TERMINAL:-off}" = off ] || exit 0
# Pretty-printed answer: the leg must not keep only the last line of a multi-line text.
review="$(jq -n '{provider:"muse",model:"Muse Spark",files_examined:["file.txt"],findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"}}')"
jq -cn --arg t "$review" '{payload_type:"run.terminal.completed",payload:{terminal:"completed",text:$t}}'
EOF
  chmod +x "$fake/muse"
  (
    set -e
    cd "$work"
    git init -q; git config user.email test@example.com; git config user.name "Test User"
    printf 'one\n' > file.txt; git add file.txt; git commit -q -m base
    printf 'two\n' > file.txt; git commit -q -am change
  ) || ok=0
  run_muse() { (cd "$work" && PATH="$fake:$PATH" TRIBUNAL_MUSE=on TRIBUNAL_BASE_REF=HEAD~1 \
    FIXTURE_MUSE_ARGS="$work/args" "$@" bash "$PLUGIN_ROOT/scripts/run-muse-review.sh"); }
  run_muse env > "$work/ok.json" 2>/dev/null || ok=0
  jq -e '.provider=="muse" and .model=="muse-spark-1.3" and .summary.verdict=="APPROVE" and (.diff_stat|type=="object")' \
    "$work/ok.json" >/dev/null || ok=0
  for flag in exec --json --yolo --disable-write --disable-shell --disable-web-tools --no-foreign-personal-context --output-schema --model; do
    grep -qxF -- "$flag" "$work/args" || ok=0
  done
  grep -qxF -- muse-spark-1.3 "$work/args" || ok=0
  run_muse env FIXTURE_MUSE_SERVED=muse-spark-1.3-contributor > "$work/mismatch.json" 2>/dev/null || ok=0
  jq -e '.provider=="muse" and (.error|contains("not the requested muse-spark-1.3"))' "$work/mismatch.json" >/dev/null || ok=0
  run_muse env TRIBUNAL_MUSE_MODEL=muse-spark-1.3 FIXTURE_MUSE_SERVED=muse-spark-1.3 > "$work/pin-ok.json" 2>/dev/null || ok=0
  jq -e '.model=="muse-spark-1.3" and .summary.verdict=="APPROVE"' "$work/pin-ok.json" >/dev/null || ok=0
  run_muse env TRIBUNAL_MUSE_MODEL=default FIXTURE_MUSE_SERVED=muse-spark-1.3-contributor > "$work/cli-default.json" 2>/dev/null || ok=0
  jq -e '.provider=="muse" and .model=="muse-spark-1.3-contributor" and .summary.verdict=="APPROVE"' \
    "$work/cli-default.json" >/dev/null || ok=0
  ! grep -qxF -- --model "$work/args" || ok=0
  run_muse env TRIBUNAL_MUSE_MODEL=default FIXTURE_MUSE_SERVED=claude-haiku-4-5 > "$work/family.json" 2>/dev/null || ok=0
  jq -e '.provider=="muse" and (.error|contains("executed model family mismatch"))' "$work/family.json" >/dev/null || ok=0
  run_muse env FIXTURE_MUSE_NO_TERMINAL=on > "$work/noterm.json" 2>/dev/null || ok=0
  jq -e '.provider=="muse" and (.error|contains("Muse execution failed"))' "$work/noterm.json" >/dev/null || ok=0
  run_muse env FIXTURE_MUSE_FAIL='402 Payment Required: usage balance exhausted' > "$work/limit.json" 2>/dev/null || ok=0
  jq -e '.provider=="muse" and (.error|startswith("plan limit:"))' "$work/limit.json" >/dev/null || ok=0
  run_muse env TRIBUNAL_MUSE=off > "$work/off.json" 2>/dev/null || ok=0
  jq -e '.provider=="muse" and .status=="disabled"' "$work/off.json" >/dev/null || ok=0
  (cd "$work" && PATH="/usr/bin:/bin" TRIBUNAL_MUSE=on bash "$PLUGIN_ROOT/scripts/run-muse-review.sh") > "$work/missing.json" 2>/dev/null || ok=0
  jq -e '.provider=="muse" and .error=="Muse CLI not on PATH"' "$work/missing.json" >/dev/null || ok=0
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/codex"; chmod +x "$fake/codex"
  (cd "$work" && git branch -q -m main && git checkout -q -b feature && PATH="$fake:$PATH" TRIBUNAL_MUSE=on \
    TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_CODEX=on TRIBUNAL_CLAUDE=off TRIBUNAL_GROK=off \
    bash "$PLUGIN_ROOT/scripts/preflight.sh") > "$work/preflight.json" 2>/dev/null || ok=0
  jq -e '.providers[]|select(.name=="muse")|.status=="usable"' "$work/preflight.json" >/dev/null || ok=0
  if [ "$ok" -eq 1 ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_gemini_tier_panel() {
  local work fake home out
  work="$(mktemp -d)"; fake="$work/bin"; home="$work/home"
  mkdir -p "$fake" "$home/.gemini/antigravity-cli"
  for cli in codex grok muse agy qwen dsh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/$cli"
  done
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
printf '%s\n' '{"loggedIn":true}'
EOF
  chmod +x "$fake/"*
  select_panel() (
    local p upper
    for p in codex claude grok muse deepseek gemini qwen; do
      upper="${p^^}"
      unset "TRIBUNAL_$upper" "TRIBUNAL_${upper}_MODEL" "TRIBUNAL_${upper}_EFFORT"
    done
    unset TRIBUNAL_RISK TRIBUNAL_PANEL_SIZE TRIBUNAL_BACKUP_LEGS TRIBUNAL_PANEL_SELECTED
    export PATH="$fake:/usr/bin:/bin" DEEPSEEK_API_KEY=fixture XAI_API_KEY=fixture HOME="$home"
    unset GEMINI_API_KEY
    for bad in "$@"; do export "$bad"; done
    . "$PLUGIN_ROOT/scripts/lib.sh"
    tribunal_select_panel || exit
    jq -nc --argjson panel "$TRIBUNAL_SELECTED_PANEL_JSON" --arg backups "$TRIBUNAL_SELECTED_BACKUPS" '
      {panel:$panel,backups:($backups|split("\n")|map(select(length>0))),
       toggles:{codex:env.TRIBUNAL_CODEX,claude:env.TRIBUNAL_CLAUDE,
         grok:env.TRIBUNAL_GROK,muse:env.TRIBUNAL_MUSE,deepseek:env.TRIBUNAL_DEEPSEEK,
         gemini:env.TRIBUNAL_GEMINI,qwen:env.TRIBUNAL_QWEN}}'
  )
  printf 'token\n' > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  out="$(select_panel)"
  tr_check "signed-in default selection runs the T2 Codex Claude Gemini panel" jqe '
    .panel == [{provider:"codex",model:"gpt-6.2-sol",effort:"medium"},
      {provider:"claude",model:"claude-sonnet-5-5",effort:"medium"},
      {provider:"gemini",model:"gemini-4-hydrogen-medium",effort:null}]
    and .toggles == {codex:"on",claude:"on",gemini:"on",grok:"off",muse:"off",deepseek:"off",qwen:"off"}' <<< "$out"
  tr_check "default backup order uses the remaining available T2 rows" jqe \
    '.backups == ["grok","muse","deepseek","qwen"]' <<< "$out"
  out="$(select_panel TRIBUNAL_RISK=T3 TRIBUNAL_PANEL_SIZE=5)"
  tr_check "T3 selection tiers Codex Claude Gemini and pins Muse Wonder Full" jqe '
    [.panel[].provider] == ["codex","claude","gemini","grok","muse"]
    and .panel[2] == {provider:"gemini",model:"gemini-4-neon-high",effort:null}
    and .panel[4] == {provider:"muse",model:"muse-wonder-full-1.0",effort:"high"}' <<< "$out"
  rm -f "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  out="$(select_panel)"
  tr_check "unsigned Gemini auto-selects off and Grok fills the third seat" jqe '
    [.panel[].provider] == ["codex","claude","grok"]
    and .toggles.gemini == "off"' <<< "$out"
  out="$(select_panel GEMINI_API_KEY=fixture)"
  tr_check "GEMINI_API_KEY alone re-enables the Gemini leg" jqe \
    '[.panel[].provider] == ["codex","claude","gemini"]' <<< "$out"
  : > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  out="$(select_panel)"
  tr_check "an empty OAuth token is not a sign-in and Grok fills the third seat" jqe '
    [.panel[].provider] == ["codex","claude","grok"]
    and .toggles.gemini == "off"' <<< "$out"
  out="$(select_panel GEMINI_API_KEY=fixture)"
  tr_check "an empty OAuth token yields to a configured API key" jqe \
    '[.panel[].provider] == ["codex","claude","gemini"]' <<< "$out"
  rm -f "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  mkdir -p "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  out="$(select_panel)"
  tr_check "a directory at the OAuth token path is not a sign-in and Grok fills the third seat" jqe '
    [.panel[].provider] == ["codex","claude","grok"]
    and .toggles.gemini == "off"' <<< "$out"
  out="$(select_panel GEMINI_API_KEY=fixture)"
  tr_check "a directory at the OAuth token path yields to a configured API key" jqe \
    '[.panel[].provider] == ["codex","claude","gemini"]' <<< "$out"
  rm -rf "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  printf 'token\n' > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  out="$(select_panel TRIBUNAL_GEMINI=off)"
  tr_check "TRIBUNAL_GEMINI=off opts out even when signed in" jqe '
    [.panel[].provider] == ["codex","claude","grok"]
    and .toggles.gemini == "off"' <<< "$out"
  rm -rf "$work"
}

test_gemini_auto_runner() {
  local work fake home
  work="$(mktemp -d)"; fake="$work/bin"; home="$work/home"
  mkdir -p "$fake" "$home/.gemini/antigravity-cli"
  cat > "$fake/agy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/agy.args"
jq -nc '{event:"result",result:{status:"SUCCESS",response:({provider:"gemini",model:"default",files_examined:["file.txt"],findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:9,verdict:"APPROVE"}}|tojson)}}'
EOF
  chmod +x "$fake/agy"
  (
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
  )
  printf 'token\n' > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  (cd "$work" && env -u TRIBUNAL_GEMINI -u GEMINI_API_KEY PATH="$fake:/usr/bin:/bin" HOME="$home" \
    TRIBUNAL_GEMINI_MODEL=gemini-4-hydrogen-medium TRIBUNAL_BASE_REF=HEAD~1 \
    bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh") > "$work/auto-on.json" 2>/dev/null
  tr_check "unset TRIBUNAL_GEMINI runs the signed-in leg by default" jq -e \
    '.provider=="gemini" and .summary.verdict=="APPROVE" and (has("error")|not)' \
    "$work/auto-on.json"
  tr_check "the selected tier model reaches the agy CLI" bash -c '
    grep -qxF -- --model "$1" && grep -qxF -- gemini-4-hydrogen-medium "$1"' _ "$work/agy.args"
  rm -f "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  (cd "$work" && env -u TRIBUNAL_GEMINI -u GEMINI_API_KEY PATH="$fake:/usr/bin:/bin" HOME="$home" \
    TRIBUNAL_BASE_REF=HEAD~1 \
    bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh") > "$work/auto-off.json" 2>/dev/null
  tr_check "unset TRIBUNAL_GEMINI disables the unsigned leg without error" jq -e \
    '.provider=="gemini" and .status=="disabled"' \
    "$work/auto-off.json"
  printf 'token\n' > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  (cd "$work" && env -u GEMINI_API_KEY PATH="$fake:/usr/bin:/bin" HOME="$home" \
    TRIBUNAL_GEMINI=off TRIBUNAL_BASE_REF=HEAD~1 \
    bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh") > "$work/opt-out.json" 2>/dev/null
  tr_check "TRIBUNAL_GEMINI=off opts out even when signed in" jq -e \
    '.provider=="gemini" and .status=="disabled"' \
    "$work/opt-out.json"
  (cd "$work" && env -u TRIBUNAL_GEMINI -u GEMINI_API_KEY PATH="/usr/bin:/bin" HOME="$home" \
    TRIBUNAL_BASE_REF=HEAD~1 \
    bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh") > "$work/auto-missing.json" 2>/dev/null
  tr_check "auto emits disabled (not an error) when agy is missing" jq -e \
    '.provider=="gemini" and .status=="disabled"' \
    "$work/auto-missing.json"
  : > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  (cd "$work" && env -u TRIBUNAL_GEMINI -u GEMINI_API_KEY PATH="$fake:/usr/bin:/bin" HOME="$home" \
    TRIBUNAL_BASE_REF=HEAD~1 \
    bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh") > "$work/auto-empty.json" 2>/dev/null
  tr_check "auto disables the leg for an empty token without an error" jq -e \
    '.provider=="gemini" and .status=="disabled"' \
    "$work/auto-empty.json"
  (cd "$work" && env -u TRIBUNAL_GEMINI PATH="$fake:/usr/bin:/bin" HOME="$home" \
    GEMINI_API_KEY=key TRIBUNAL_BASE_REF=HEAD~1 \
    bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh") > "$work/auto-empty-key.json" 2>/dev/null
  tr_check "an empty token yields to a configured API key in auto mode" jq -e \
    '.provider=="gemini" and .summary.verdict=="APPROVE" and (has("error")|not)' \
    "$work/auto-empty-key.json"
  rm -f "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  mkdir -p "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  (cd "$work" && env -u TRIBUNAL_GEMINI -u GEMINI_API_KEY PATH="$fake:/usr/bin:/bin" HOME="$home" \
    TRIBUNAL_BASE_REF=HEAD~1 \
    bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh") > "$work/auto-dir.json" 2>/dev/null
  tr_check "auto disables the leg for a directory at the token path without an error" jq -e \
    '.provider=="gemini" and .status=="disabled"' \
    "$work/auto-dir.json"
  (cd "$work" && env -u TRIBUNAL_GEMINI PATH="$fake:/usr/bin:/bin" HOME="$home" \
    GEMINI_API_KEY=key TRIBUNAL_BASE_REF=HEAD~1 \
    bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh") > "$work/auto-dir-key.json" 2>/dev/null
  tr_check "a directory at the token path yields to a configured API key in auto mode" jq -e \
    '.provider=="gemini" and .summary.verdict=="APPROVE" and (has("error")|not)' \
    "$work/auto-dir-key.json"
  rm -rf "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  rm -rf "$work"
}

# The panel table selects per-tier models and efforts; the runners must pass
# those exact values to the provider CLIs (not their standalone defaults).
test_panel_selected_cli_argv() {
  local work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FIXTURE_CODEX_ARGS"
cat >/dev/null
printf '%s\n' '{"provider":"codex","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
printf '%s\n' "$@" > "$FIXTURE_CLAUDE_ARGS"
cat >/dev/null
printf '%s\n' '{"structured_output":{"provider":"claude","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}}'
EOF
  chmod +x "$fake/codex" "$fake/claude"
  (
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
  )
  run_selected_tier() {
    (
      set -e
      cd "$work"
      local p upper
      for p in codex claude grok muse deepseek gemini qwen; do
        upper="${p^^}"
        unset "TRIBUNAL_$upper" "TRIBUNAL_${upper}_MODEL" "TRIBUNAL_${upper}_EFFORT"
      done
      unset TRIBUNAL_PANEL_SIZE TRIBUNAL_BACKUP_LEGS TRIBUNAL_PANEL_SELECTED TRIBUNAL_REVIEW_PANEL
      if [ -n "${1:-}" ]; then export TRIBUNAL_RISK="$1"; else unset TRIBUNAL_RISK; fi
      export PATH="$fake:/usr/bin:/bin" TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_NATIVE_REVIEW=off HOME="$work/home"
      unset GEMINI_API_KEY DEEPSEEK_API_KEY XAI_API_KEY
      mkdir -p "$work/home"
      export FIXTURE_CODEX_ARGS="$work/codex.args" FIXTURE_CLAUDE_ARGS="$work/claude.args"
      . "$PLUGIN_ROOT/scripts/lib.sh"
      tribunal_select_panel
      bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/codex.selected.json"
      bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$work/claude.selected.json"
    )
  }
  run_selected_tier "" || true
  tr_check "default T2 selection runs the Codex leg successfully" jq -e \
    '.provider=="codex" and .summary.verdict=="APPROVE"' "$work/codex.selected.json"
  tr_check "default T2 selection runs the Claude leg successfully" jq -e \
    '.provider=="claude" and .summary.verdict=="APPROVE"' "$work/claude.selected.json"
  tr_check "default T2 selection sends Codex Sol medium to the CLI" bash -c '
    grep -qxF -- gpt-6.2-sol "$1" && grep -qxF -- "model_reasoning_effort=\"medium\"" "$1"' _ "$work/codex.args"
  tr_check "default T2 selection sends Claude Sonnet medium to the CLI" bash -c '
    grep -qxF -- claude-sonnet-5-5 "$1" && grep -qxF -- --effort "$1" && grep -qxF -- medium "$1"' _ "$work/claude.args"
  rm -f "$work/codex.args" "$work/claude.args"
  run_selected_tier T3 || true
  tr_check "T3 selection runs the Codex leg successfully" jq -e \
    '.provider=="codex" and .summary.verdict=="APPROVE"' "$work/codex.selected.json"
  tr_check "T3 selection runs the Claude leg successfully" jq -e \
    '.provider=="claude" and .summary.verdict=="APPROVE"' "$work/claude.selected.json"
  tr_check "T3 selection sends Codex Astra high to the CLI" bash -c '
    grep -qxF -- gpt-6.2-astra "$1" && grep -qxF -- "model_reasoning_effort=\"high\"" "$1"' _ "$work/codex.args"
  tr_check "T3 selection sends Claude Opus high to the CLI" bash -c '
    grep -qxF -- claude-opus-5-5 "$1" && grep -qxF -- --effort "$1" && grep -qxF -- high "$1"' _ "$work/claude.args"
  rm -rf "$work"
}

test_panel_contract_seven_legs() {
  local tsv tier count first3 tier_providers gemini_models muse_models
  tsv="$PLUGIN_ROOT/scripts/review-panel.tsv"
  tr_check "review schema provider enum is exactly the seven legs" jq -e \
    '.properties.provider.enum == ["codex","gemini","deepseek","qwen","grok","muse","claude"]' \
    "$PLUGIN_ROOT/schemas/review-output.json"
  for tier in T1 T2 T3 T4; do
    count="$(awk -F$'\t' -v t="$tier" '$1==t {print $2}' "$tsv" | sort -u | wc -l | tr -d ' ')"
    first3="$(awk -F$'\t' -v t="$tier" '$1==t {print $2}' "$tsv" | head -3 | sort -u | wc -l | tr -d ' ')"
    tier_providers="$(awk -F$'\t' -v t="$tier" '$1==t {print $2}' "$tsv" | sort -u | tr '\n' ' ')"
    tr_check "$tier fields exactly the seven legs and nothing retired" bash -c '[ "$1" = "claude codex deepseek gemini grok muse qwen " ]' _ "$tier_providers"
    tr_check "$tier leads with three distinct legs ahead of the fallbacks" bash -c '[ "$1" -eq 3 ]' _ "$first3"
  done
  gemini_models="$(awk -F$'\t' '$2=="gemini" {print $1 "=" $3}' "$tsv" | sort | tr '\n' ' ')"
  tr_check "gemini rows use Hydrogen at T1/T2 and Neon at T3/T4" bash -c '[ "$1" = "T1=gemini-4-hydrogen-low T2=gemini-4-hydrogen-medium T3=gemini-4-neon-high T4=gemini-4-neon-high " ]' _ "$gemini_models"
  muse_models="$(awk -F$'\t' '$2=="muse" && ($1=="T3" || $1=="T4") {print $1 "=" $3}' "$tsv" | sort | tr '\n' ' ')"
  tr_check "muse rows use Wonder Full at T3/T4" bash -c '[ "$1" = "T3=muse-wonder-full-1.0 T4=muse-wonder-full-1.0 " ]' _ "$muse_models"
}

test_executed_model_family_guard() {
  local label="executed model family guard" work review off_family on_family qwen_namespaced qwen_claude qwen_coder muse_ok muse_bad unresolved
  work="$(mktemp -d)"
  review='{"provider":"model-authored","model":"claude-haiku-4-5","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
  : > "$work/stdout"
  : > "$work/stderr"

  off_family="$(printf '%s' "$review" | bash -c '. "$1"; tribunal_stamp_executed_model grok claude-haiku-4-5 "$2" "$3" 0' _ "$PLUGIN_ROOT/scripts/lib.sh" "$work/stdout" "$work/stderr" 2>/dev/null || true)"
  on_family="$(printf '%s' "$review" | bash -c '. "$1"; tribunal_stamp_executed_model grok grok-4.6 "$2" "$3" 0' _ "$PLUGIN_ROOT/scripts/lib.sh" "$work/stdout" "$work/stderr" 2>/dev/null || true)"
  qwen_namespaced="$(printf '%s' "$review" | bash -c '. "$1"; tribunal_stamp_executed_model qwen qwen/qwen3-coder "$2" "$3" 0' _ "$PLUGIN_ROOT/scripts/lib.sh" "$work/stdout" "$work/stderr" 2>/dev/null || true)"
  qwen_claude="$(printf '%s' "$review" | bash -c '. "$1"; tribunal_stamp_executed_model qwen claude-haiku-4-5 "$2" "$3" 0' _ "$PLUGIN_ROOT/scripts/lib.sh" "$work/stdout" "$work/stderr" 2>/dev/null || true)"
  qwen_coder="$(printf '%s' "$review" | bash -c '. "$1"; tribunal_stamp_executed_model qwen coder-qwen "$2" "$3" 0' _ "$PLUGIN_ROOT/scripts/lib.sh" "$work/stdout" "$work/stderr" 2>/dev/null || true)"
  muse_ok="$(printf '%s' "$review" | bash -c '. "$1"; tribunal_stamp_executed_model muse muse-wonder-full-1.0 "$2" "$3" 0' _ "$PLUGIN_ROOT/scripts/lib.sh" "$work/stdout" "$work/stderr" 2>/dev/null || true)"
  muse_bad="$(printf '%s' "$review" | bash -c '. "$1"; tribunal_stamp_executed_model muse claude-haiku-4-5 "$2" "$3" 0' _ "$PLUGIN_ROOT/scripts/lib.sh" "$work/stdout" "$work/stderr" 2>/dev/null || true)"
  unresolved="$(printf '%s' "$review" | bash -c '. "$1"; tribunal_stamp_executed_model qwen "" "$2" "$3" 0' _ "$PLUGIN_ROOT/scripts/lib.sh" "$work/stdout" "$work/stderr" 2>/dev/null || true)"

  if printf '%s' "$off_family" | jq -e '
      .provider == "grok"
      and (.error | contains("requested provider grok"))
      and (.error | contains("claude-haiku-4-5"))
      and (.error | contains("phase=model_family"))
      and (has("findings") | not)
      and (.summary == null)
    ' >/dev/null \
    && printf '%s' "$on_family" | jq -e '
      .provider == "model-authored" and .model == "grok-4.6" and .summary.verdict == "APPROVE"
    ' >/dev/null \
    && printf '%s' "$qwen_namespaced" | jq -e '
      .provider == "model-authored" and .model == "qwen/qwen3-coder" and .summary.verdict == "APPROVE"
    ' >/dev/null \
    && printf '%s' "$qwen_claude" | jq -e '
      .provider == "qwen" and (.error | contains("requested provider qwen")) and (.error | contains("claude-haiku-4-5")) and (.error | contains("phase=model_family"))
    ' >/dev/null \
    && printf '%s' "$qwen_coder" | jq -e '
      .provider == "qwen" and (.error | contains("requested provider qwen")) and (.error | contains("coder-qwen")) and (.error | contains("phase=model_family"))
    ' >/dev/null \
    && printf '%s' "$muse_ok" | jq -e '
      .provider == "model-authored" and .model == "muse-wonder-full-1.0" and .summary.verdict == "APPROVE"
    ' >/dev/null \
    && printf '%s' "$muse_bad" | jq -e '
      .provider == "muse" and (.error | contains("requested provider muse")) and (.error | contains("claude-haiku-4-5")) and (.error | contains("phase=model_family"))
    ' >/dev/null \
    && printf '%s' "$unresolved" | jq -e '
      .provider == "model-authored" and .model == "unverified" and .summary.verdict == "APPROVE"
    ' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_gemini_agy_leg() {
  local work fake state home
  work="$(mktemp -d)"
  fake="$work/bin"
  state="$work/state"
  home="$work/home"
  mkdir -p "$fake" "$state" "$home/.gemini/antigravity-cli"
  (
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
  )
  cat > "$fake/agy" <<EOF
#!/usr/bin/env bash
: > "$state/ran"
dir="\$HOME/.gemini/antigravity-cli"
cp "\$dir/settings.json" "$state/settings.json"
[ ! -f "\$dir/antigravity-oauth-token" ] || stat -c %a "\$dir/antigravity-oauth-token" > "$state/token-mode"
printf '%s\n' "\$HOME" > "$state/home"
pwd -P > "$state/cwd"
jq -r 'select(.event=="user") | .message.content' | grep -q '^+two' && : > "$state/diff-inline"
case "\$*" in *"--input-format stream-json"*"-p="*) : > "$state/stream-args" ;; esac
printf '%s\n' '{"event":"init"}'
jq -nc '{event:"result",result:{status:"SUCCESS",response:({provider:"gemini",model:"default",files_examined:["file.txt"],findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:9,verdict:"APPROVE"}}|tojson)}}'
EOF
  chmod +x "$fake/agy"
  gemini_leg_run() {
    (cd "$work" && env "$@" HOME="$home" TRIBUNAL_GEMINI=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-gemini-review.sh")
  }
  gemini_leg_check() {
    if [ "$1" -eq 0 ]; then
      echo -e "  ${GREEN}PASS${NC} $2"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $2"; FAIL=$((FAIL+1)); FAILURES+=("$2")
    fi
  }
  local rc

  # Scenario A: signed-in agy runs read-only in an isolated home; API key is ignored.
  printf 'token\n' > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  gemini_leg_run PATH="$fake:$PATH" GEMINI_API_KEY=unused > "$work/out-a.json"
  rc=0
  jq -e '.provider=="gemini" and .summary.verdict=="APPROVE" and (has("error")|not)' "$work/out-a.json" >/dev/null \
    && jq -e '.permissions.deny==["read_file(*)","write_file(*)","command(*)","execute_url(*)","mcp(*)"] and (.permissions.allow==null) and (has("modelProvider")|not)' \
      "$state/settings.json" >/dev/null \
    && [ "$(cat "$state/token-mode")" = 600 ] \
    && [ "$(cat "$state/home")" != "$home" ] \
    && [ "$(cat "$state/cwd")" != "$(cd "$work" && pwd -P)" ] \
    && [ -e "$state/diff-inline" ] && [ -e "$state/stream-args" ] || rc=1
  gemini_leg_check "$rc" "gemini leg runs agy read-only with isolated sign-in"

  # Scenario B: API-key mode when agy is not signed in.
  rm -f "$home/.gemini/antigravity-cli/antigravity-oauth-token" "$state/token-mode"
  gemini_leg_run PATH="$fake:$PATH" GEMINI_API_KEY=key > "$work/out-b.json"
  rc=0
  jq -e '.provider=="gemini" and (has("error")|not)' "$work/out-b.json" >/dev/null \
    && jq -e '.modelProvider=="gemini"' "$state/settings.json" >/dev/null \
    && [ ! -e "$state/token-mode" ] || rc=1
  gemini_leg_check "$rc" "gemini leg falls back to agy API-key mode"

  # Scenario C: neither sign-in nor key fails before agy runs.
  rm -f "$state/ran"
  gemini_leg_run -u GEMINI_API_KEY PATH="$fake:$PATH" > "$work/out-c.json"
  rc=0
  jq -e '.provider=="gemini" and (.error|test("not signed in"))' "$work/out-c.json" >/dev/null \
    && [ ! -e "$state/ran" ] || rc=1
  gemini_leg_check "$rc" "gemini leg without agy sign-in fails before provider run"

  # Scenario E: a zero-byte token yields to API-key mode instead of the OAuth seat.
  : > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
  rm -f "$state/ran" "$state/token-mode"
  gemini_leg_run PATH="$fake:$PATH" GEMINI_API_KEY=key > "$work/out-e.json"
  rc=0
  jq -e '.provider=="gemini" and .summary.verdict=="APPROVE" and (has("error")|not)' "$work/out-e.json" >/dev/null \
    && jq -e '.modelProvider=="gemini"' "$state/settings.json" >/dev/null \
    && [ ! -e "$state/token-mode" ] && [ -e "$state/ran" ] || rc=1
  gemini_leg_check "$rc" "gemini leg with an empty token falls back to agy API-key mode"

  # Scenario F: a zero-byte token with no key fails before agy runs.
  rm -f "$state/ran"
  gemini_leg_run -u GEMINI_API_KEY PATH="$fake:$PATH" > "$work/out-f.json"
  rc=0
  jq -e '.provider=="gemini" and (.error|test("not signed in"))' "$work/out-f.json" >/dev/null \
    && [ ! -e "$state/ran" ] || rc=1
  gemini_leg_check "$rc" "gemini leg with an empty token and no key fails before provider run"

  # Scenario D: agy missing from PATH.
  gemini_leg_run PATH="/usr/bin:/bin" > "$work/out-d.json"
  rc=0
  jq -e '.provider=="gemini" and (.error|test("agy"))' "$work/out-d.json" >/dev/null || rc=1
  gemini_leg_check "$rc" "gemini leg reports missing agy"

  rm -rf "$work"
}


test_empty_staged_diff_with_real_changes_fails_closed
test_genuine_empty_diff_is_reverified_and_unchanged
test_unresolvable_base_during_empty_verification_fails_closed
test_qwen_envelope_parser
test_muse_leg
test_gemini_tier_panel
test_gemini_auto_runner
test_gemini_agy_leg
test_panel_selected_cli_argv
test_panel_contract_seven_legs
test_executed_model_family_guard
