#!/usr/bin/env bash
# Standalone regressions, also invoked by run-tests.sh.
test_opencode_exit0() (
  set -euo pipefail
  local plugin_root="$1" work provider mode scenario rc label
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
  printf 'two\n' > "$work/file.txt"
  git -C "$work" commit -qam change
  cat > "$work/bin/opencode" <<'EOF'
#!/usr/bin/env bash
cat "$FIXTURE_STDOUT"
cat "$FIXTURE_STDERR" >&2
exit 0
EOF
  chmod +x "$work/bin/opencode"
  export PATH="$work/bin:$PATH" XDG_DATA_HOME="$work/data"
  export TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1
  export FIXTURE_STDOUT="$work/stdout" FIXTURE_STDERR="$work/stderr"
  unset TRIBUNAL_DIAGNOSTIC_TAILS
  cd "$work"
  for provider in deepseek glm; do
    export TRIBUNAL_DEEPSEEK=off TRIBUNAL_GLM=off
    if [ "$provider" = deepseek ]; then export TRIBUNAL_DEEPSEEK=on; else export TRIBUNAL_GLM=on; fi
    for mode in review smoke; do
      for scenario in unavailable unavailable_tails findings chatter silent gate gate_workspace whitespace status_blob; do
        label="$provider $mode exit=0 $scenario"
        [ "$scenario" = silent ] || label="$label with stderr"
        # More than 2 KiB, including JSON-sensitive characters and a control byte.
        { printf 'discarded-prefix'; printf '%03000d' 0; printf '\nError: provider unavailable "quoted" \\path\tmarker\001\n'; } > "$work/stderr"
        : > "$work/stdout"
        [ "$scenario" != chatter ] || printf 'Provider startup banner\n' > "$work/stdout"
        [ "$scenario" != silent ] || : > "$work/stderr"
        [ "$scenario" != whitespace ] || printf '\n' > "$work/stderr"
        if [ "$scenario" = unavailable_tails ]; then
          export TRIBUNAL_DIAGNOSTIC_TAILS=on
        else
          unset TRIBUNAL_DIAGNOSTIC_TAILS
        fi
        if [ "$scenario" = gate ] || [ "$scenario" = gate_workspace ]; then
          printf '%s\n' 'Error: The latest version of this model is only available hosted in China and requires explicit opt in: https://opencode.ai/workspace/<id>/go' > "$work/stderr"
          if [ "$scenario" = gate_workspace ]; then
            sed 's/<id>/wrk_ABC/' "$work/stderr" > "$work/gate.stderr"
            mv "$work/gate.stderr" "$work/stderr"
          fi
        fi
        if [ "$scenario" = findings ]; then
          jq -nc --arg p "$provider" '{provider:$p,model:"fixture",files_examined:["file.txt"],findings:[{severity:"medium",category:"logic",file:"file.txt",line:1,title:"Preserve this finding",description:"fixture",suggestion:"fix",confidence:0.9}],summary:{total_findings:1,critical:0,high:0,medium:1,low:0,quality_score:8,verdict:"APPROVE"}}' > "$work/stdout"
        fi
        # Non-review JSON object on stdout must still take the exit-0 execution path (#503).
        if [ "$scenario" = status_blob ]; then
          printf '%s\n' '{"status":"ok","progress":true}' > "$work/stdout"
          printf '%s\n' 'Error: fatal provider failure' > "$work/stderr"
        fi
        rc=0
        if [ "$mode" = smoke ]; then
          bash "$plugin_root/scripts/run-opencode-review.sh" --smoke > "$work/result" || rc=$?
        else
          bash "$plugin_root/scripts/run-opencode-review.sh" > "$work/result" || rc=$?
        fi
        if [ "$rc" -eq 0 ] && jq -se --arg p "$provider" --arg scenario "$scenario" --rawfile expected "$work/stdout" '
            length == 2 and ([.[] | select(.provider != $p)] | length == 1 and .[0].status == "disabled")
            and ([.[] | select(.provider == $p)] | length == 1 and (.[0] |
              if $scenario == "findings" then
                (has("error") | not) and .findings == ($expected | fromjson | .findings) and .summary == ($expected | fromjson | .summary)
              elif $scenario == "silent" then
                keys == ["error", "provider"] and (.error | contains("phase=parse; exit=0") and contains("stderr_bytes=0"))
              elif $scenario == "whitespace" then
                keys == ["error", "provider"] and (.error | contains("phase=parse; exit=0") and contains("stderr_bytes=1"))
              elif $scenario == "gate" or $scenario == "gate_workspace" then
                keys == ["error", "provider"]
                and (.error | contains("phase=execution; exit=0")
                  and (split(";")[0] == ($p + " leg unavailable: provider rejected model " + "\u0027"
                    + (if $p == "deepseek" then "deepseek/deepseek-v4-pro" else "opencode-go/glm-5.1" end)
                    + "\u0027 (requires explicit opt-in)"))
                  and (contains("opencode.ai/workspace/") | not) and (contains("wrk_ABC") | not)
                  and (split("; stderr_tail=")[1] | fromjson == "[omitted; set TRIBUNAL_DIAGNOSTIC_TAILS=on]"))
              elif $scenario == "status_blob" then
                keys == ["error", "provider"]
                and (.error | contains("phase=execution; exit=0")
                  and contains("leg unavailable")
                  and contains("no review findings/summary envelope")
                  and (contains("phase=schema") | not)
                  and (contains("omitted the review findings/summary envelope") | not)
                  and (split("; stderr_tail=")[1] | fromjson == "[omitted; set TRIBUNAL_DIAGNOSTIC_TAILS=on]"))
              else
                keys == ["error", "provider"]
                and (.error | contains("phase=execution; exit=0") and contains("leg unavailable")
                  and contains("TRIBUNAL_DIAGNOSTIC_TAILS=on")
                  and contains("stderr_truncated=true") and (contains("unparseable") | not)
                  and (contains("discarded-prefix") | not)
                  and (split("; stderr_tail=")[1] | fromjson |
                    if $scenario == "unavailable_tails" then
                      length <= 2048 and contains("Error: provider unavailable \"quoted\" \\path\tmarker")
                    else
                      . == "[omitted; set TRIBUNAL_DIAGNOSTIC_TAILS=on]"
                    end))
              end))' "$work/result" >/dev/null; then
          printf 'PASS %s\n' "$label"; passed=$((passed+1))
        else
          printf 'FAIL %s\n' "$label"; cat "$work/result"; failed=$((failed+1))
        fi
      done
    done
  done
  printf 'OpenCode exit-0: PASS=%s FAIL=%s\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  test_opencode_exit0 "$(cd "$(dirname "$0")/.." && pwd)"
fi
