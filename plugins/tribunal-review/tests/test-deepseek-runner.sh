#!/usr/bin/env bash
test_deepseek_runner() (
  set -uo pipefail
  local plugin_root="$1" work passed=0 failed=0 scenario rc expected run_number=0 preflight_number=0
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/bin" "$work/home" "$work/output"
  git -C "$work" init -q -b main
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name 'Test User'
  printf 'one\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -qm base
  git -C "$work" checkout -qb review
  printf 'two\n' > "$work/file.txt"
  git -C "$work" commit -qam change
  cat > "$work/bin/dsh" <<'DSH'
#!/usr/bin/env bash
[ "$1" = --profile ] && [ "$2" = headless ] && [ "$3" = --patch ] && [ "$5" = --json ] && [ "$6" = - ] || exit 3
cp "$4" "$FIXTURE_PATCH"
pwd > "$FIXTURE_CWD"
cat > "$FIXTURE_PROMPT"
cat "$FIXTURE_STDOUT"
cat "$FIXTURE_STDERR" >&2
exit "${FIXTURE_RC:-0}"
DSH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/codex"
  chmod +x "$work/bin/dsh" "$work/bin/codex"
  export PATH="$work/bin:$PATH" HOME="$work/home" DSH_HOME="$work/home/dsh"
  export TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=main TRIBUNAL_LEG_ENV='FIXTURE_*'
  export TRIBUNAL_DEEPSEEK=on TRIBUNAL_CODEX=on TRIBUNAL_CLAUDE=off TRIBUNAL_GROK=off TRIBUNAL_MUSE=off
  export TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_SMOKE_PROBE=off TRIBUNAL_DIAGNOSTIC_TAILS=on
  export DEEPSEEK_API_KEY=sentinel-deepseek-secret-651
  export FIXTURE_STDOUT="$work/events" FIXTURE_STDERR="$work/errors" FIXTURE_RC=0
  export FIXTURE_PATCH="$work/output/patch" FIXTURE_CWD="$work/output/cwd" FIXTURE_PROMPT="$work/output/prompt"
  unset TRIBUNAL_DEEPSEEK_MODEL TRIBUNAL_RISK TRIBUNAL_GLM
  cd "$work" || exit 1
  check() {
    if "$@" >/dev/null 2>&1; then printf 'PASS %s\n' "$scenario"; passed=$((passed+1)); else printf 'FAIL %s\n' "$scenario"; failed=$((failed+1)); fi
  }
  events() {
    jq -nc '{type:"final",text:"not the last final"}, {type:"status",phase:"turn_end",reason:{kind:"completed"}}, {type:"final",text:({provider:"deepseek",model:"fixture",files_examined:["file.txt"],findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"}}|tojson)}' > "$FIXTURE_STDOUT"
    : > "$FIXTURE_STDERR"
    FIXTURE_RC=0
  }
  run_leg() {
    run_number=$((run_number+1))
    bash "$plugin_root/scripts/run-deepseek-review.sh" "$@" > "$work/output/result" 2> "$work/output/runner-error"
    cp "$work/output/result" "$work/output/result-$run_number"
    cp "$work/output/runner-error" "$work/output/runner-error-$run_number"
  }
  events
  scenario='extract last final and stamp reviewed diff'; run_leg
  check jq -e '.provider=="deepseek" and .findings==[] and (.diff_stat|length)>0 and (has("error")|not)' "$work/output/result"
  scenario='read-only patch and stdin contract'; check bash -c 'grep -q "mode: read-only" "$1" && grep -q "policy: never" "$1" && grep -q "DISABLED" "$1" && grep -q "session-log-deepseek" "$1" && grep -q "files_examined" "$2"' _ "$FIXTURE_PATCH" "$FIXTURE_PROMPT"
  scenario='overlay disables permission, session upload, telemetry, and web'
  check bash -c 'grep -A1 "id: permission" "$1" | grep -q "disabled: true" && grep -A1 "id: tool-web" "$1" | grep -q "disabled: true" && grep -A1 "id: session-log-deepseek" "$1" | grep -q "enabled: false" && grep -A1 "id: session-telemetry-otel" "$1" | grep -q "mode: DISABLED"' _ "$FIXTURE_PATCH"
  scenario='default model and effort'; check grep -q '"model":"deepseek-v4-pro","reasoningEffort":"high"' "$FIXTURE_PATCH"
  for expected in 'T1 low' 'T2 high' 'T3 high' 'T4 high'; do
    read -r TRIBUNAL_RISK effort <<< "$expected"; export TRIBUNAL_RISK
    export TRIBUNAL_DEEPSEEK_MODEL=custom-model
    run_leg
    scenario="model override and $TRIBUNAL_RISK effort"
    check grep -q "\"model\":\"custom-model\",\"reasoningEffort\":\"$effort\"" "$FIXTURE_PATCH"
  done
  unset TRIBUNAL_RISK TRIBUNAL_DEEPSEEK_MODEL
  scenario='non-completed turn fails'; sed 's/"completed"/"cancelled"/' "$FIXTURE_STDOUT" > "$work/events-next"; mv "$work/events-next" "$FIXTURE_STDOUT"; run_leg
  check jq -e '.error|contains("non-completed turn")' "$work/output/result"
  events; jq -c 'select(.type!="status")' "$FIXTURE_STDOUT" > "$work/events-next"; mv "$work/events-next" "$FIXTURE_STDOUT"
  scenario='missing turn_end fails'; run_leg
  check jq -e '.error|contains("non-completed turn")' "$work/output/result"
  events; jq -c 'if .type=="final" then .text="{\"status\":\"ok\"}" else . end' "$FIXTURE_STDOUT" > "$work/events-next"; mv "$work/events-next" "$FIXTURE_STDOUT"
  scenario='invalid review envelope fails'; run_leg
  check jq -e 'has("error")' "$work/output/result"
  for expected in MISSING_CREDENTIAL INVALID_REQUEST RATE_LIMIT QUOTA; do
    events; FIXTURE_RC=1
    printf 'dsh: %s: %s\n' "$expected" "$DEEPSEEK_API_KEY" > "$FIXTURE_STDERR"
    scenario="$expected named failure with secret-safe diagnostics"; run_leg
    check jq -e --arg cause "$expected" '.error|contains($cause) and (if $cause=="RATE_LIMIT" or $cause=="QUOTA" then startswith("plan limit:") and (contains("plan limit: plan limit:")|not) else true end)' "$work/output/result"
  done
  for expected in RATE_LIMIT QUOTA MISSING_CREDENTIAL INVALID_REQUEST; do
    events; FIXTURE_RC=1
    jq -nc --arg cause "$expected" '{type:"tool_result",text:$cause}' >> "$FIXTURE_STDOUT"
    printf 'dsh: SERVER: upstream 500\n' > "$FIXTURE_STDERR"
    scenario="reviewed $expected text does not classify server failure"; run_leg
    check jq -e '(.error|startswith("dsh execution failed (exit=1);")) and (.error|contains("plan limit:")|not)' "$work/output/result"
  done
  events; FIXTURE_RC=124; scenario='timeout named failure'; run_leg
  check jq -e '.error|contains("timed out")' "$work/output/result"
  events; scenario='smoke uses dsh JSON runner'; run_leg --smoke
  check jq -e '.provider=="deepseek" and (has("error")|not)' "$work/output/result"
  preflight() {
    preflight_number=$((preflight_number+1))
    bash "$plugin_root/scripts/preflight.sh" > "$work/output/preflight" 2> "$work/output/preflight-error"
    cp "$work/output/preflight" "$work/output/preflight-$preflight_number"
    cp "$work/output/preflight-error" "$work/output/preflight-error-$preflight_number"
  }
  scenario='preflight env key usable'; preflight
  check jq -e 'any(.providers[]; .name=="deepseek" and .status=="usable") and all(.providers[]; .name!="glm")' "$work/output/preflight"
  export DEEPSEEK_API_KEY=
  scenario='preflight empty env key skipped'; preflight
  check jq -e 'any(.providers[]; .name=="deepseek" and .status=="skipped" and (.note|contains("MISSING_CREDENTIAL")))' "$work/output/preflight"
  unset DEEPSEEK_API_KEY
  scenario='preflight absent key skipped'; preflight
  check jq -e 'any(.providers[]; .name=="deepseek" and .status=="skipped" and (.note|contains("MISSING_CREDENTIAL")))' "$work/output/preflight"
  mkdir -p "$DSH_HOME"
  printf 'version: 1\nrefs:\n  DEEPSEEK_API_KEY: sentinel-deepseek-secret-651\n' > "$DSH_HOME/.credentials.yaml"
  scenario='preflight stored credentials key usable'; preflight
  check jq -e 'any(.providers[]; .name=="deepseek" and .status=="usable")' "$work/output/preflight"
  rm "$DSH_HOME/.credentials.yaml"
  mkdir -p "$DSH_HOME"; printf 'DEEPSEEK_API_KEY=sentinel-deepseek-secret-651\n' > "$DSH_HOME/.env"
  scenario='preflight dsh home key usable'; preflight
  check jq -e 'any(.providers[]; .name=="deepseek" and .status=="usable")' "$work/output/preflight"
  unset DSH_HOME
  mkdir -p "$HOME/.dsh"; printf 'DEEPSEEK_API_KEY=sentinel-deepseek-secret-651\n' > "$HOME/.dsh/.env"
  scenario='preflight default home key usable'; preflight
  check jq -e 'any(.providers[]; .name=="deepseek" and .status=="usable")' "$work/output/preflight"
  mkdir "$work/missing-bin"; cp "$work/bin/codex" "$work/missing-bin/codex"
  scenario='preflight missing dsh skipped'; PATH="$work/missing-bin:/usr/bin:/bin" preflight
  check jq -e 'any(.providers[];.name=="deepseek" and .status=="skipped" and (.note|contains("dsh CLI not on PATH")))' "$work/output/preflight"
  scenario='runner missing dsh named error'; PATH="$work/missing-bin:/usr/bin:/bin" run_leg
  check jq -e '.error=="dsh CLI not on PATH"' "$work/output/result"
  export TRIBUNAL_GLM=on
  scenario='retired GLM warns once without provider'; preflight
  check jq -e '([.warnings[]|select(.note|contains("retired"))]|length)==1 and all(.providers[];.name!="glm")' "$work/output/preflight"
  unset TRIBUNAL_GLM
  export TRIBUNAL_SMOKE_PROBE=on
  scenario='preflight smoke usable'; preflight
  check jq -e 'any(.providers[];.name=="deepseek" and .status=="usable" and .note=="non-interactive smoke passed")' "$work/output/preflight"
  scenario='sentinel absent from all generated output'
  check bash -c '! grep -r -q -F sentinel-deepseek-secret-651 "$1"' _ "$work/output"
  printf 'DeepSeek runner: PASS=%s FAIL=%s\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  test_deepseek_runner "$(cd "$(dirname "$0")/.." && pwd)"
fi
