#!/usr/bin/env bash
# Standalone regressions, also invoked by run-tests.sh.
test_opencode_model() (
  set -euo pipefail
  local plugin_root="$1" work scenario provider expected runner_rc preflight_rc
  local passed=0 failed=0
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/bin" "$work/data"
  git -C "$work" init -q -b main
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name 'Test User'
  printf 'one\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -qm base
  git -C "$work" checkout -qb review
  printf 'two\n' > "$work/file.txt"
  git -C "$work" commit -qam change
  cat > "$work/bin/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models) printf '%s\n' "$FIXTURE_MODEL" ;;
  run)
    shift
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -m ]; then printf '%s\n' "$2" >> "$FIXTURE_MODEL_LOG"; break; fi
      shift
    done
    jq -nc --arg p "$FIXTURE_PROVIDER" --arg m "$FIXTURE_MODEL" \
      '{provider:$p,model:$m,files_examined:["file.txt"],findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"}}'
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$work/bin/opencode"
  export PATH="$work/bin:$PATH" XDG_DATA_HOME="$work/data"
  export TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=main
  export TRIBUNAL_CODEX=off TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off
  export TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_SMOKE_PROBE=off
  export FIXTURE_MODEL_LOG="$work/model-log"
  cd "$work"
  for scenario in deepseek-default deepseek-override glm-default; do
    unset TRIBUNAL_DEEPSEEK_MODEL TRIBUNAL_GLM_MODEL
    export TRIBUNAL_DEEPSEEK=off TRIBUNAL_GLM=off
    provider=deepseek
    case "$scenario" in
      deepseek-default) expected=deepseek/deepseek-v4-pro ;;
      deepseek-override)
        expected=custom/deepseek-review
        export TRIBUNAL_DEEPSEEK_MODEL="$expected"
        ;;
      glm-default) provider=glm; expected=opencode-go/glm-5.1 ;;
    esac
    if [ "$provider" = deepseek ]; then export TRIBUNAL_DEEPSEEK=on; else export TRIBUNAL_GLM=on; fi
    export FIXTURE_PROVIDER="$provider" FIXTURE_MODEL="$expected"
    : > "$FIXTURE_MODEL_LOG"
    runner_rc=0 preflight_rc=0
    bash "$plugin_root/scripts/run-opencode-review.sh" > "$work/review" || runner_rc=$?
    bash "$plugin_root/scripts/preflight.sh" > "$work/preflight" 2> "$work/preflight-error" || preflight_rc=$?
    if [ "$runner_rc" -eq 0 ] && [ "$preflight_rc" -eq 0 ] \
      && [ "$(cat "$FIXTURE_MODEL_LOG")" = "$expected" ] \
      && jq -se --arg p "$provider" '[.[] | select(.provider==$p)] | length==1 and (.[0] | (has("error")|not) and .findings==[])' "$work/review" >/dev/null \
      && jq -e --arg p "$provider" '[.providers[] | select(.status=="usable")] | length==1 and .[0].name==$p' "$work/preflight" >/dev/null; then
      printf 'PASS %s runner and preflight select %s\n' "$scenario" "$expected"; passed=$((passed+1))
    else
      printf 'FAIL %s runner and preflight select %s\n' "$scenario" "$expected"
      cat "$FIXTURE_MODEL_LOG" "$work/review" "$work/preflight" "$work/preflight-error"
      failed=$((failed+1))
    fi
  done
  printf 'OpenCode model selection: PASS=%s FAIL=%s\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  test_opencode_model "$(cd "$(dirname "$0")/.." && pwd)"
fi
