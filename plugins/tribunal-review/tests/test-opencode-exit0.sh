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
      for scenario in unavailable findings chatter silent; do
        label="$provider $mode exit=0 $scenario"
        [ "$scenario" = silent ] || label="$label with stderr"
        # More than 2 KiB, including JSON-sensitive characters and a control byte.
        { printf 'discarded-prefix'; printf '%03000d' 0; printf '\nError: provider unavailable "quoted" \\path\tmarker\001\n'; } > "$work/stderr"
        : > "$work/stdout"
        [ "$scenario" != chatter ] || printf 'Provider startup banner\n' > "$work/stdout"
        [ "$scenario" != silent ] || : > "$work/stderr"
        if [ "$scenario" = findings ]; then
          jq -nc --arg p "$provider" '{provider:$p,model:"fixture",findings:[{severity:"medium",category:"logic",file:"file.txt",line:1,title:"Preserve this finding",description:"fixture",suggestion:"fix",confidence:0.9}],summary:{total_findings:1,critical:0,high:0,medium:1,low:0,quality_score:8,verdict:"APPROVE"}}' > "$work/stdout"
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
              else
                keys == ["error", "provider"]
                and (.error | contains("phase=execution; exit=0") and contains("leg unavailable")
                  and contains("stderr_truncated=true") and (contains("unparseable") | not)
                  and (contains("discarded-prefix") | not)
                  and (split("; stderr_tail=")[1] | fromjson |
                    length <= 2048 and contains("Error: provider unavailable \"quoted\" \\path\tmarker")))
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
