#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_panel_selection() {
  local work fake out bad
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
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
    export PATH="$fake:/usr/bin:/bin" DEEPSEEK_API_KEY=fixture XAI_API_KEY=fixture GEMINI_API_KEY=fixture
    for bad in "$@"; do export "$bad"; done
    . "$PLUGIN_ROOT/scripts/lib.sh"
    tribunal_select_panel || exit
    jq -nc --argjson panel "$TRIBUNAL_SELECTED_PANEL_JSON" --arg backups "$TRIBUNAL_SELECTED_BACKUPS" '
      {panel:$panel,backups:($backups|split("\n")|map(select(length>0))),
       toggles:{codex:env.TRIBUNAL_CODEX,claude:env.TRIBUNAL_CLAUDE,
         grok:env.TRIBUNAL_GROK,muse:env.TRIBUNAL_MUSE,deepseek:env.TRIBUNAL_DEEPSEEK,
         gemini:env.TRIBUNAL_GEMINI,qwen:env.TRIBUNAL_QWEN}}'
  )
  out="$(select_panel)"
  tr_check "default selection runs the T2 Codex Claude Gemini panel and disables every other provider" jqe '
    .panel == [{provider:"codex",model:"gpt-6.2-sol",effort:"medium"},
      {provider:"claude",model:"claude-sonnet-5-5",effort:"medium"},
      {provider:"gemini",model:"gemini-4-hydrogen-medium",effort:null}]
    and .toggles == {codex:"on",claude:"on",gemini:"on",grok:"off",muse:"off",deepseek:"off",qwen:"off"}' <<< "$out"
  tr_check "default backup order uses the remaining available T2 rows" jqe \
    '.backups == ["grok","muse","deepseek","qwen"]' <<< "$out"
  out="$(select_panel TRIBUNAL_RISK=T3)"
  tr_check "T3 selection uses tiered Codex Claude and Gemini models and efforts" jqe '
    .panel == [{provider:"codex",model:"gpt-6.2-astra",effort:"high"},
      {provider:"claude",model:"claude-opus-5-5",effort:"high"},
      {provider:"gemini",model:"gemini-4-neon-high",effort:null}]' <<< "$out"
  out="$(select_panel TRIBUNAL_CLAUDE=off TRIBUNAL_CODEX=off)"
  tr_check "explicitly disabled legs are replaced by Gemini Grok and Muse" jqe \
    '[.panel[].provider] == ["gemini","grok","muse"]' <<< "$out"
  rm "$fake/claude"
  out="$(select_panel)"
  tr_check "a missing CLI is skipped and the next available row fills its seat" jqe \
    '[.panel[].provider] == ["codex","gemini","grok"]' <<< "$out"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
printf '%s\n' '{"loggedIn":false}'
exit 1
EOF
  chmod +x "$fake/claude"
  out="$(select_panel)"
  tr_check "an installed logged-out Claude is skipped and Gemini fills its seat" jqe \
    '[.panel[].provider] == ["codex","gemini","grok"]' <<< "$out"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
printf '%s\n' '{"loggedIn":true}'
EOF
  chmod +x "$fake/claude"
  out="$(select_panel TRIBUNAL_CODEX_MODEL=operator-model)"
  tr_check "an operator model override wins over the panel table" jqe \
    '.panel[0].model == "operator-model" and .panel[0].effort == "medium"' <<< "$out"
  out="$(select_panel TRIBUNAL_PANEL_SIZE=2)"
  tr_check "TRIBUNAL_PANEL_SIZE=2 selects exactly two legs" jqe \
    '[.panel[].provider] == ["codex","claude"]' <<< "$out"
  invalid_panel_sizes() {
    for bad in 1 8 9 invalid; do
      if select_panel TRIBUNAL_PANEL_SIZE="$bad" > /dev/null 2> "$work/invalid.err"; then return 1; fi
      grep -q 'TRIBUNAL_PANEL_SIZE' "$work/invalid.err" || return 1
    done
  }
  tr_check "invalid panel sizes are rejected" invalid_panel_sizes
  out="$(select_panel TRIBUNAL_BACKUP_LEGS=)"
  tr_check "an explicitly empty TRIBUNAL_BACKUP_LEGS selects no backups" jqe '.backups == []' <<< "$out"
  invalid_toggle() {
    if select_panel TRIBUNAL_GROK=yes > /dev/null 2> "$work/invalid.err"; then return 1; fi
    grep -Fq 'invalid TRIBUNAL_GROK value: yes (want on, off, or auto)' "$work/invalid.err"
  }
  tr_check "invalid provider toggle values still fail loudly" invalid_toggle
  reject_non_gemini_auto() {
    if select_panel TRIBUNAL_QWEN=auto > /dev/null 2> "$work/invalid.err"; then return 1; fi
    grep -Fq 'invalid TRIBUNAL_QWEN value: auto' "$work/invalid.err"
  }
  tr_check "auto is rejected for non-Gemini provider toggles" reject_non_gemini_auto
  printf '# fixture\nT2\tcodex\tgpt-6.1-sol # trailing comment\tmedium\n' > "$work/bad-panel.tsv"
  reject_bad_model() {
    if select_panel TRIBUNAL_REVIEW_PANEL="$work/bad-panel.tsv" > /dev/null 2> "$work/invalid.err"; then return 1; fi
    grep -Fq "invalid review panel row at $work/bad-panel.tsv:2 (bad model:" "$work/invalid.err"
  }
  tr_check "panel model trailing comments are rejected with file and line" reject_bad_model
  printf '# fixture\nT2\tcodex\tgpt-6.1-sol\tmedium # trailing comment\n' > "$work/bad-panel.tsv"
  reject_bad_effort() {
    if select_panel TRIBUNAL_REVIEW_PANEL="$work/bad-panel.tsv" > /dev/null 2> "$work/invalid.err"; then return 1; fi
    grep -Fq "invalid review panel row at $work/bad-panel.tsv:2 (bad effort:" "$work/invalid.err"
  }
  tr_check "panel effort trailing comments are rejected with file and line" reject_bad_effort
  rm -rf "$work"
}

test_risk_tier_and_backup_config() {
  local out
  tr_check "risk T1..T4 map to low/medium/high and Codex xhigh at T4" bash -c '
    . "$1/scripts/lib.sh"
    [ "$(TRIBUNAL_RISK=T1 tribunal_risk_effort grok)" = low ] &&
    [ "$(TRIBUNAL_RISK=T2 tribunal_risk_effort claude)" = medium ] &&
    [ "$(TRIBUNAL_RISK=T3 tribunal_risk_effort codex)" = high ] &&
    [ "$(TRIBUNAL_RISK=T4 tribunal_risk_effort codex)" = xhigh ] &&
    [ "$(TRIBUNAL_RISK=T4 tribunal_risk_effort grok)" = high ] &&
    [ -z "$(env -u TRIBUNAL_RISK bash -c ". \"$1/scripts/lib.sh\"; tribunal_risk_effort codex")" ] &&
    ! TRIBUNAL_RISK=T9 tribunal_risk_effort codex 2>/dev/null' _ "$PLUGIN_ROOT"
  tr_check "backup legs default to deepseek, accept any of the 7 providers and off, reject unknown" bash -c '
    . "$1/scripts/lib.sh"
    [ "$(env -u TRIBUNAL_BACKUP_LEGS bash -c ". \"$1/scripts/lib.sh\"; tribunal_backup_legs")" = deepseek ] &&
    [ "$(TRIBUNAL_BACKUP_LEGS=deepseek,qwen,codex,gemini tribunal_backup_legs | tr "\n" " ")" = "deepseek qwen codex gemini " ] &&
    [ -z "$(TRIBUNAL_BACKUP_LEGS=off tribunal_backup_legs)" ] &&
    [ -z "$(TRIBUNAL_BACKUP_LEGS= tribunal_backup_legs)" ] &&
    ! TRIBUNAL_BACKUP_LEGS=deepseek,unknown tribunal_backup_legs >/dev/null 2>&1 &&
    ! TRIBUNAL_BACKUP_LEGS=deepseek,deepseek,gemini tribunal_backup_legs >/dev/null 2>&1 &&
    ! TRIBUNAL_BACKUP_LEGS="$(printf "deepseek\ncodex")" tribunal_backup_legs >/dev/null 2>&1 &&
    ! TRIBUNAL_BACKUP_LEGS="deepseek, qwen" tribunal_backup_legs >/dev/null 2>&1' _ "$PLUGIN_ROOT"
  local glob_dir; glob_dir="$(mktemp -d)"; touch "$glob_dir/deepseek" "$glob_dir/qwen"
  tr_check "a glob in TRIBUNAL_BACKUP_LEGS is rejected, not expanded against the cwd" bash -c '
    cd "$2" && . "$1/scripts/lib.sh" && ! TRIBUNAL_BACKUP_LEGS="*" tribunal_backup_legs >/dev/null 2>&1' _ "$PLUGIN_ROOT" "$glob_dir"
  rm -rf "$glob_dir"

  local work; work="$(mktemp -d)"
  printf 'API error (status 402 Payment Required): Grok Build usage balance exhausted\n' > "$work/limit.err"
  printf '429 Too Many Requests: rate limit\n' > "$work/rate.err"
  : > "$work/empty.out"
  out="$(bash -c '. "$1/scripts/lib.sh"; tribunal_error_with_diagnostics grok "Grok execution failed or timed out" execution 1 "$2/empty.out" "$2/limit.err"' _ "$PLUGIN_ROOT" "$work")"
  tr_check "a plan-limit execution failure is tagged 'plan limit:'" jqe '.error | startswith("plan limit: Grok execution failed")' <<< "$out"
  out="$(bash -c '. "$1/scripts/lib.sh"; tribunal_error_with_diagnostics grok "Grok execution failed or timed out" execution 124 "$2/empty.out" "$2/limit.err"' _ "$PLUGIN_ROOT" "$work")"
  tr_check "a timeout is never a plan limit" jqe '.error | startswith("plan limit") | not' <<< "$out"
  out="$(bash -c '. "$1/scripts/lib.sh"; tribunal_error_with_diagnostics grok "unparseable output" parse 0 "$2/empty.out" "$2/limit.err"' _ "$PLUGIN_ROOT" "$work")"
  tr_check "a parse failure is never a plan limit" jqe '.error | startswith("plan limit") | not' <<< "$out"
  out="$(bash -c '. "$1/scripts/lib.sh"; tribunal_error_with_diagnostics codex "Codex execution failed or timed out" execution 1 "$2/empty.out" "$2/rate.err"' _ "$PLUGIN_ROOT" "$work")"
  tr_check "a transient rate limit is not a plan limit" jqe '.error | startswith("plan limit") | not' <<< "$out"
  rm -rf "$work"
}

test_risk_effort_reaches_claude_and_grok() {
  local work fake host_grok
  work="$(mktemp -d)"; fake="$work/bin"; host_grok="$work/host-grok"; mkdir -p "$fake"
  install_grok_auth_fixture "$host_grok"
  for cli in claude grok; do
    cat > "$fake/$cli" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'; exit 0
fi
printf '%s\n' "\$@" > "$work/$cli.args"
cat >/dev/null
exit 1
EOF
  done
  chmod +x "$fake/claude" "$fake/grok"
  (
    cd "$work" && git init -q && git config user.email t@t && git config user.name t
    printf 'one\n' > file.txt && git add file.txt && git commit -q -m base
    printf 'two\n' > file.txt && git commit -q -am change
  )
  run_leg() {  # run_leg claude|grok ENV...
    local cli="$1"; shift
    rm -f "$work/$cli.args"
    (cd "$work" && env -u XAI_API_KEY -u TRIBUNAL_RISK -u TRIBUNAL_CLAUDE_EFFORT -u TRIBUNAL_GROK_EFFORT \
      -u TRIBUNAL_CLAUDE_MODEL PATH="$fake:$PATH" GROK_HOME="$host_grok" TRIBUNAL_BASE_REF=HEAD~1 \
      "$@" bash "$PLUGIN_ROOT/scripts/run-$cli-review.sh" </dev/null >/dev/null 2>&1) || true
  }
  pair() { awk -v f="$2" -v v="$3" 'p == f && $0 == v { ok = 1 } { p = $0 } END { exit !ok }' "$work/$1.args"; }
  run_leg claude TRIBUNAL_RISK=T3
  tr_check "TRIBUNAL_RISK=T3 passes --effort high to the Claude leg" pair claude --effort high
  run_leg claude TRIBUNAL_RISK=T3 TRIBUNAL_CLAUDE_MODEL=haiku
  tr_check "Claude Haiku never gets --effort" bash -c '! grep -qx -- --effort "$1"' _ "$work/claude.args"
  run_leg claude
  tr_check "unset TRIBUNAL_RISK keeps the Claude CLI default effort" bash -c '! grep -qx -- --effort "$1"' _ "$work/claude.args"
  run_leg grok TRIBUNAL_RISK=T4
  tr_check "TRIBUNAL_RISK=T4 passes --reasoning-effort high to the Grok leg" pair grok --reasoning-effort high
  tr_check "Grok T4 keeps the 30-turn inspect budget" pair grok --max-turns 30
  run_leg grok TRIBUNAL_RISK=T3
  tr_check "TRIBUNAL_RISK=T3 passes --reasoning-effort medium to the Grok leg" pair grok --reasoning-effort medium
  tr_check "Grok T3 default inspect budget is at least 60 turns" pair grok --max-turns 60
  run_leg grok TRIBUNAL_RISK=T3 TRIBUNAL_GROK_MAX_TURNS=4
  tr_check "explicit Grok turn budget overrides the T3 cap" pair grok --max-turns 4
  run_leg grok TRIBUNAL_RISK=T3 TRIBUNAL_GROK_MAX_TURNS=invalid
  tr_check "invalid Grok T3 turn budget falls back to sixty" pair grok --max-turns 60
  run_leg grok TRIBUNAL_RISK=T3 TRIBUNAL_GROK_EFFORT=high
  tr_check "explicit Grok high effort overrides the T3 medium default" pair grok --reasoning-effort high
  run_leg grok TRIBUNAL_RISK=T4 TRIBUNAL_GROK_EFFORT=xhigh
  tr_check "TRIBUNAL_GROK_EFFORT overrides the risk tier" pair grok --reasoning-effort xhigh
  run_leg grok
  tr_check "unset TRIBUNAL_RISK keeps the Grok CLI default effort" bash -c '! grep -qx -- --reasoning-effort "$1"' _ "$work/grok.args"
  tr_check "unset Grok risk keeps the 30-turn inspect budget" pair grok --max-turns 30
  run_leg grok TRIBUNAL_RISK=T9
  tr_check "an invalid TRIBUNAL_RISK fails the leg before the CLI runs" test ! -e "$work/grok.args"
  rm -rf "$work"
}

test_grok_finalize_effort() {
  local work fake host_grok tier override expected expected_turns
  work="$(mktemp -d)"; fake="$work/bin"; host_grok="$work/host-grok"; mkdir -p "$fake"
  install_grok_auth_fixture "$host_grok"
  (
    cd "$work" && git init -q && git config user.email t@t && git config user.name t
    printf 'one\n' > file.txt && git add file.txt && git commit -q -m base
    printf 'two\n' > file.txt && git commit -q -am change
  )
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
phase=inspect effort=default tools_val=missing sid= prompt= prev= max_turns=
for arg in "$@"; do
  case "$prev" in
    --reasoning-effort) effort="$arg" ;;
    --tools) tools_val="$arg" ;;
    --resume) phase=finalize; sid="$arg" ;;
    --prompt-file) prompt="$arg" ;;
    --max-turns) max_turns="$arg" ;;
  esac
  prev="$arg"
done
printf '%s %s %s\n' "$phase" "$effort" "$max_turns" >> "$FIXTURE_STATE/phases"
# Model timeouts are simulated without spending the real 600/120-second budgets.
if [ "$phase" = inspect ] || [ "$effort" != low ] || [ "${FIXTURE_PROGRESS_ONLY:-}" = yes ]; then
  printf '%s\n' '{"text":"still reviewing...","sessionId":"44444444-4444-4444-4444-444444444444"}'
  # A reached turn cap can exit successfully without a schema verdict.
  [ "$phase" != inspect ] || [ "$max_turns" != 60 ] || exit 0
  exit 124
fi
[ "$tools_val" = "read_file,list_dir,grep" ] && [ "$sid" = 44444444-4444-4444-4444-444444444444 ] \
  && grep -q 'diff --git a/file.txt b/file.txt' "$prompt" || exit 1
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[{"severity":"medium","category":"logic","file":"file.txt","line":1,"title":"Changed value breaks the consumer","description":"The consumer requires the original value.","suggestion":"Preserve the required value.","confidence":0.9}],"summary":{"total_findings":1,"critical":0,"high":0,"medium":1,"low":0,"quality_score":7,"verdict":"NEEDS_WORK"}},"modelUsage":{"grok-fixture-model":{}}}
JSON
EOF
  chmod +x "$fake/grok"
  run_finalize_fixture() {
    : > "$work/phases"
    (cd "$work" && env -u XAI_API_KEY TRIBUNAL_RISK="$tier" TRIBUNAL_GROK_EFFORT="$override" \
      PATH="$fake:$PATH" GROK_HOME="$host_grok" TRIBUNAL_BASE_REF=HEAD~1 FIXTURE_STATE="$work" FIXTURE_PROGRESS_ONLY=no \
      "$@" bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out.json")
  }
  recovered() {
    jq -e '.provider=="grok" and .model=="grok-fixture-model" and .summary.verdict=="NEEDS_WORK"
      and (.findings|length)==1 and (has("error")|not)' "$work/out.json" >/dev/null \
      && [ "$(cat "$work/phases")" = "$(printf 'inspect %s %s\nfinalize low 6' "$expected" "$expected_turns")" ]
  }
  for tier in T3 T4; do
    override= expected=high expected_turns=30
    if [ "$tier" = T3 ]; then expected=medium; expected_turns=60; fi
    run_finalize_fixture
    tr_check "grok $tier inspect budget recovers a schema verdict at low finalize effort" recovered
  done
  override=xhigh expected=xhigh
  run_finalize_fixture
  tr_check "grok explicit inspect effort preserves bounded low-effort finalize" recovered
  tier= override= expected=default
  run_finalize_fixture
  tr_check "grok CLI default inspect effort preserves bounded low-effort finalize" recovered
  tier=T4
  run_finalize_fixture FIXTURE_PROGRESS_ONLY=yes
  tr_check "grok low-effort finalize timeout remains a named progress-only failure" \
    jq -e '.provider=="grok" and (.error|contains("inspect_rc=124 finalize_rc=124"))
      and (.error|contains("completion_state=progress_only")) and (has("summary")|not)' "$work/out.json"
  rm -rf "$work"
}

test_grok_recovery_provenance() {
  local work fake host_grok
  work="$(mktemp -d)"; fake="$work/bin"; host_grok="$work/host-grok"; mkdir -p "$fake"
  install_grok_auth_fixture "$host_grok"
  (
    cd "$work" && git init -q && git config user.email t@t && git config user.name t
    printf 'one\n' > file.txt && git add file.txt && git commit -q -m base
    printf 'two\n' > file.txt && git commit -q -am change
  )
  cat > "$fake/grok" <<'CLI'
#!/usr/bin/env bash
phase=inspect
for arg in "$@"; do [ "$arg" != --resume ] || phase=finalize; done
printf '%s\n' "$phase" >> "$FIXTURE_STATE/phases"
if [ "$phase" = inspect ] && [ "$FIXTURE_SCENARIO" != direct ]; then
  printf '%s\n' '{"text":"still reviewing","sessionId":"44444444-4444-4444-4444-444444444444"}'
  if [ "$FIXTURE_SCENARIO" = quota ]; then
    printf 'usage limit exceeded\n' >&2
    exit 1
  fi
  exit 124
fi
case "$FIXTURE_SCENARIO" in
  progress) printf '%s\n' '{"text":"still reviewing"}'; exit 0 ;;
  failure) printf 'fixture recovery failed\n' >&2; exit 1 ;;
esac
# A model-authored provenance claim must be discarded before runner stamping.
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"},"grok_execution":{"verdict_phase":"inspect","inspect_exit_code":77,"requested_effort":"forged","verdict_effort":"forged"}},"modelUsage":{"grok-fixture-model":{}}}
JSON
CLI
  chmod +x "$fake/grok"
  run_provenance_fixture() {
    : > "$work/phases"
    (cd "$work" && env -u XAI_API_KEY -u TRIBUNAL_GROK_RECOVERY -u TRIBUNAL_RISK -u TRIBUNAL_GROK_EFFORT \
      PATH="$fake:$PATH" GROK_HOME="$host_grok" TRIBUNAL_BASE_REF=HEAD~1 FIXTURE_STATE="$work" \
      FIXTURE_SCENARIO=timeout "$@" bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out.json")
  }
  run_provenance_fixture FIXTURE_SCENARIO=direct TRIBUNAL_GROK_EFFORT=high
  tr_check "Grok direct inspection stamps runner-owned phase, exit and efforts" jq -e \
    '.summary.verdict=="APPROVE" and .grok_execution=={verdict_phase:"inspect",inspect_exit_code:0,requested_effort:"high",verdict_effort:"high"}' "$work/out.json"
  run_provenance_fixture FIXTURE_SCENARIO=direct TRIBUNAL_RISK=T3
  tr_check "Grok T3 direct inspection stamps medium effort without recovery" jq -e \
    '.summary.verdict=="APPROVE" and .grok_execution=={verdict_phase:"inspect",inspect_exit_code:0,requested_effort:"medium",verdict_effort:"medium"}' "$work/out.json"
  run_provenance_fixture FIXTURE_SCENARIO=direct
  tr_check "Grok CLI-default inspection effort stays explicitly unknown" jq -e \
    '.grok_execution=={verdict_phase:"inspect",inspect_exit_code:0,requested_effort:null,verdict_effort:null}' "$work/out.json"
  run_provenance_fixture TRIBUNAL_GROK_EFFORT=high
  tr_check "Grok timeout APPROVE recovery is distinguishable and permitted by default" jq -e \
    '.summary.verdict=="APPROVE" and (has("error")|not) and .grok_execution=={verdict_phase:"finalize",inspect_exit_code:124,requested_effort:"high",verdict_effort:"low"}' "$work/out.json"
  run_provenance_fixture TRIBUNAL_GROK_RECOVERY=permit
  tr_check "Grok explicit permit retains recovery with unknown requested effort" jq -e \
    '.summary.verdict=="APPROVE" and .grok_execution=={verdict_phase:"finalize",inspect_exit_code:124,requested_effort:null,verdict_effort:"low"}' "$work/out.json"
  run_provenance_fixture TRIBUNAL_GROK_RECOVERY=reject
  tr_check "Grok strict recovery is a named failed leg, never an ok APPROVE" jq -e \
    '.provider=="grok" and (.error|contains("grok_recovery_rejected")) and (has("summary")|not) and (has("status")|not)' "$work/out.json"
  tr_check "Grok strict timeout records required phase and inspect exit in the standard error shape" jq -e \
    'keys==["error","provider"] and (.error|contains("(inspect_rc=124, phase=finalize required)"))' "$work/out.json"
  tr_check "Grok strict timeout never invokes finalize" test "$(cat "$work/phases")" = inspect
  for name in validate_provider write_failed_provider grok_recovery_allowed normalize_single provider_status; do
    sed -n "/^$name() {/,/^}/p" "$PLUGIN_ROOT/scripts/collector-validate.sh" "$PLUGIN_ROOT/scripts/collector-containment.sh" >> "$work/helpers.sh"
  done
  bash -c '. "$1/helpers.sh"; normalize_single grok "$1/out.json" 0 "$1/grok.json" "" "" reject
    provider_status "$1/grok.json" > "$1/status"' _ "$work"
  tr_check "collector preserves the wrapper timeout rejection and diagnostics" jq -e \
    '.provider=="grok" and (.error|startswith("grok_recovery_rejected")) and (.error|contains("(inspect_rc=124, phase=finalize required)"))' "$work/grok.json"
  tr_check "collector classifies the wrapper timeout rejection as failed" test "$(cat "$work/status")" = failed
  tr_check "collector rejection never invokes Grok finalize" test "$(cat "$work/phases")" = inspect
  run_provenance_fixture FIXTURE_SCENARIO=quota TRIBUNAL_GROK_RECOVERY=reject
  bash -c '. "$1/helpers.sh"; normalize_single grok "$1/out.json" 0 "$1/grok.json" "" "" reject' _ "$work"
  tr_check "collector preserves plan-limit diagnostics for strict partial-output inspect failure" jq -e \
    '.provider=="grok" and (.error|startswith("plan limit:"))' "$work/grok.json"
  tr_check "Grok strict quota failure never invokes finalize" test "$(cat "$work/phases")" = inspect
  run_provenance_fixture FIXTURE_SCENARIO=direct TRIBUNAL_GROK_RECOVERY=reject
  tr_check "Grok strict policy still accepts a completed direct inspection" jq -e \
    '.summary.verdict=="APPROVE" and .grok_execution.verdict_phase=="inspect" and (has("error")|not)' "$work/out.json"
  run_provenance_fixture FIXTURE_SCENARIO=progress
  tr_check "Grok progress-only recovery remains a failed leg" jq -e \
    '.provider=="grok" and (.error|contains("progress_only")) and (has("summary")|not)' "$work/out.json"
  run_provenance_fixture FIXTURE_SCENARIO=failure
  tr_check "Grok failed recovery remains a failed leg" jq -e \
    '.provider=="grok" and (.error|contains("finalize_rc=1")) and (has("summary")|not)' "$work/out.json"
  run_provenance_fixture TRIBUNAL_BASE_REF=HEAD TRIBUNAL_GROK_RECOVERY=reject
  tr_check "Grok empty diff records no invented inspection or effort" jq -e \
    '.diff_stat.files_changed==0 and .grok_execution=={verdict_phase:null,inspect_exit_code:null,requested_effort:null,verdict_effort:null}' "$work/out.json"
  tr_check "provider normalization strips model-authored Grok provenance" bash -c '
    . "$1/scripts/lib.sh"
    jq -n '\''{provider:"claude",findings:[],summary:{verdict:"APPROVE"},grok_execution:{verdict_phase:"inspect"}}'\'' | tribunal_emit_review claude | jq -e '\''has("grok_execution")|not'\''
  ' _ "$PLUGIN_ROOT"
  tr_check "provider output schema forbids model-authored Grok provenance" jq -e \
    '.additionalProperties==false and (.properties|has("grok_execution")|not)' "$PLUGIN_ROOT/schemas/review-output.json"
  run_provenance_fixture TRIBUNAL_GROK_RECOVERY=typo
  invalid_recovery_policy() {
    [ ! -s "$work/phases" ] && jq -e '.provider=="grok" and has("error") and (has("summary")|not)' "$work/out.json" >/dev/null
  }
  tr_check "Grok invalid recovery policy fails before invoking the CLI" invalid_recovery_policy
  rm -rf "$work"
}

test_grok_collector_provenance() {
  local work
  work="$(mktemp -d)"
  for name in validate_provider write_failed_provider grok_recovery_allowed normalize_single; do
    sed -n "/^$name() {/,/^}/p" "$PLUGIN_ROOT/scripts/collector-validate.sh" "$PLUGIN_ROOT/scripts/collector-containment.sh" >> "$work/helpers.sh"
  done
  jq -n '{provider:"grok",model:"grok-fixture",files_examined:["file.txt"],findings:[],
    summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"},
    diff_stat:{files_changed:1,insertions:1,deletions:1,base:"HEAD~1",base_oid:("a"*40),head_oid:("b"*40),truncated:false},
    grok_execution:{verdict_phase:"finalize",inspect_exit_code:124,requested_effort:null,verdict_effort:"low"}}' > "$work/recovered.json"
  tr_check "collector accepts complete Grok runner provenance" bash -c '. "$1/helpers.sh"; validate_provider grok "$1/recovered.json"' _ "$work"
  jq 'del(.grok_execution)' "$work/recovered.json" > "$work/missing.json"
  tr_check "collector rejects successful Grok without runner provenance" bash -c '. "$1/helpers.sh"; ! validate_provider grok "$1/missing.json"' _ "$work"
  jq '.provider="claude"' "$work/recovered.json" > "$work/foreign.json"
  tr_check "collector forbids Grok provenance on another provider" bash -c '. "$1/helpers.sh"; ! validate_provider claude "$1/foreign.json"' _ "$work"
  jq 'del(.grok_execution.requested_effort)' "$work/recovered.json" > "$work/partial.json"
  tr_check "collector requires explicit null for unknown effort" bash -c '. "$1/helpers.sh"; ! validate_provider grok "$1/partial.json"' _ "$work"
  jq '.grok_execution.verdict_effort="high"' "$work/recovered.json" > "$work/wrong-effort.json"
  tr_check "collector rejects finalize provenance claiming a non-low effort" bash -c '. "$1/helpers.sh"; ! validate_provider grok "$1/wrong-effort.json"' _ "$work"
  bash -c '. "$1/helpers.sh"; normalize_single grok "$1/recovered.json" 0 "$1/permit.json" "" "" permit' _ "$work"
  tr_check "collector permit preserves recovered APPROVE and provenance" jq -e '.summary.verdict=="APPROVE" and .grok_execution.verdict_phase=="finalize"' "$work/permit.json"
  bash -c '. "$1/helpers.sh"; normalize_single grok "$1/recovered.json" 0 "$1/reject.json" "" "" reject' _ "$work"
  tr_check "collector strict normalization excludes recovery from quorum" jq -e '.provider=="grok" and (.error|contains("grok_recovery_rejected")) and (has("summary")|not)' "$work/reject.json"
  jq '.grok_execution.verdict_phase=null' "$work/recovered.json" > "$work/unknown.json"
  bash -c '. "$1/helpers.sh"; normalize_single grok "$1/unknown.json" 0 "$1/reject-unknown.json" "" "" reject' _ "$work"
  tr_check "collector strict normalization cannot accept unknown inspection phase" jq -e '.provider=="grok" and (.error|contains("grok_recovery_rejected")) and (has("summary")|not)' "$work/reject-unknown.json"
  rm -rf "$work"
}

test_preflight_risk_and_backups() {
  local work fake out ec
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  for cli in codex grok muse dsh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/$cli"; chmod +x "$fake/$cli"
  done
  (
    cd "$work" && git init -q && git config user.email t@t && git config user.name t
    printf 'one\n' > file.txt && git add file.txt && git commit -q -m base
    git checkout -qb feature && printf 'two\n' > file.txt && git commit -q -am change
  )
  pre() { (cd "$work" && env -u TRIBUNAL_RISK -u TRIBUNAL_BACKUP_LEGS -u TRIBUNAL_MUSE -u TRIBUNAL_DEEPSEEK \
    PATH="$fake:/usr/bin:/bin" XAI_API_KEY=fixture DEEPSEEK_API_KEY=fixture TRIBUNAL_BASE_BRANCH=main \
    TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_CLAUDE=off "$@" \
    bash "$PLUGIN_ROOT/scripts/preflight.sh" 2>/dev/null); }
  out="$(pre TRIBUNAL_RISK=T3)" || true
  tr_check "preflight reports the risk tier, selected panel, and backup legs" \
    jqe '.risk_tier == "T3" and .panel_size == 3 and ([.panel[].provider] == ["codex","grok","muse"]) and .backup_legs == ["deepseek"]' <<< "$out"
  out="$(pre TRIBUNAL_BACKUP_LEGS=off)" || true
  tr_check "preflight reports no risk tier and no backups when unset/off" \
    jqe '.risk_tier == null and .backup_legs == []' <<< "$out"
  ec=0; pre TRIBUNAL_RISK=high >/dev/null || ec=$?
  tr_check "preflight rejects an invalid TRIBUNAL_RISK" test "$ec" -eq 2
  ec=0; pre TRIBUNAL_BACKUP_LEGS=unknown >/dev/null || ec=$?
  tr_check "preflight rejects an unknown backup leg" test "$ec" -eq 2
  rm -rf "$work"
}

test_preflight_backup_quorum() {
  local work fake panel out ec=0
  work="$(mktemp -d)"; fake="$work/bin"; panel="$work/panel.tsv"; mkdir -p "$fake"
  for cli in grok muse; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/$cli"; chmod +x "$fake/$cli"
  done
  (
    cd "$work" && git init -q && git config user.email t@t && git config user.name t
    printf 'one\n' > file.txt && git add file.txt && git commit -q -m base
    git checkout -qb feature && printf 'two\n' > file.txt && git commit -q -am change
  )
  pre() { (cd "$work" && env -u TRIBUNAL_GROK -u TRIBUNAL_MUSE -u TRIBUNAL_BACKUP_LEGS \
    -u TRIBUNAL_PANEL_SIZE -u TRIBUNAL_MIN_OK_LEGS -u TRIBUNAL_RISK \
    PATH="$fake:/usr/bin:/bin" XAI_API_KEY=fixture TRIBUNAL_BASE_BRANCH=main \
    TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_CODEX=on TRIBUNAL_REVIEW_PANEL="$panel" \
    TRIBUNAL_PANEL_SIZE=2 bash "$PLUGIN_ROOT/scripts/preflight.sh"); }
  printf 'T2\tcodex\tgpt-6.1-sol\tmedium\nT2\tgrok\tgrok-4.7\tmedium\nT2\tmuse\tmuse-spark-1.3\tmedium\n' > "$panel"
  out="$(pre 2> "$work/preflight.err")" || true
  tr_check "preflight lets an available backup fill the quorum and warns with its name" jqe '
    ([.providers[] | select(.status=="usable")] | length) == 1
    and .backup_legs == ["muse"]
    and any(.warnings[]; .name=="backup-quorum" and (.note|contains("muse")))' <<< "$out"
  printf 'T2\tcodex\tgpt-6.1-sol\tmedium\nT2\tgrok\tgrok-4.7\tmedium\n' > "$panel"
  pre > /dev/null 2> "$work/preflight.err" || ec=$?
  tr_check "preflight keeps the existing quorum failure when no backup is available" bash -c '
    [ "$1" -ne 0 ] && grep -Fxq "PREFLIGHT FAIL: usable legs (1) below TRIBUNAL_MIN_OK_LEGS (2)." "$2"' \
    _ "$ec" "$work/preflight.err"
  printf 'T2\tcodex\tgpt-6.1-sol\tmedium\nT2\tclaude\tclaude-sonnet-5-5\tmedium\nT2\tgrok\tgrok-4.7\tmedium\nT2\tmuse\tmuse-spark-1.3\tmedium\n' > "$panel"
  out="$(TRIBUNAL_CLAUDE=on pre 2> "$work/preflight.err")" || true
  tr_check "preflight lets backups fill the quorum when no selected leg is usable" jqe '
    ([.providers[] | select(.status=="usable")] | length) == 0
    and .backup_legs == ["grok","muse"]
    and any(.warnings[]; .name=="backup-quorum" and (.note|contains("grok")) and (.note|contains("muse")))' <<< "$out"
  rm -rf "$work"
}


echo "Risk tier, effort, and backup legs"
test_panel_selection
test_risk_tier_and_backup_config
test_risk_effort_reaches_claude_and_grok
test_grok_finalize_effort
test_grok_recovery_provenance
test_grok_collector_provenance
test_preflight_risk_and_backups
test_preflight_backup_quorum
