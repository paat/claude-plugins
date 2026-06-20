#!/usr/bin/env bash
# Integration test: feed synthetic PreToolUse payloads through the real wrapper
# and assert the mapped outcome. Exit non-zero on any mismatch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export CLAUDE_PLUGIN_ROOT="$(dirname "$HERE")"
HOOK="$CLAUDE_PLUGIN_ROOT/hooks/guard.sh"

pass=0; fail=0
while IFS=$'\t' read -r cmd expected; do
  [[ -z "${cmd:-}" || "$cmd" == \#* ]] && continue
  payload="$(CMD="$cmd" python3 -c 'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]},"cwd":os.getcwd()}))')"
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"; code=$?
  if [[ $code -eq 2 ]]; then actual=BLOCK
  elif printf '%s' "$out" | grep -q '"additionalContext"'; then actual=WARN
  else actual=PASS; fi
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "MISMATCH [want=$expected got=$actual]: $cmd"
  fi
done < "$HERE/cases.tsv"

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
