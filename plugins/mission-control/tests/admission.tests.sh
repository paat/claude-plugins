#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # $1: jq mutation, default identity
  TD="$(mktemp -d)"
  mkdir -p "$TD/p1/.startup" "$TD/p2/.startup"
  jq -n --arg td "$TD" '{
    engines:{e:{pool:"p",cmd:"echo {prompt}"}}, pools:{p:{}}, slots:{A:{}},
    projects:[
      {name:"p1", container:"local", repo_path:($td+"/p1"), stage:"pre-launch", engine:"e", command:"c", hold:false},
      {name:"p2", container:"local", repo_path:($td+"/p2"), stage:"pre-launch", engine:"e", command:"c", hold:false}
    ],
    admission:{wip_cap:1, confidence_min:0.7, veto_hours:72}}' \
  | jq "${1:-.}" > "$TD/portfolio.json"
}
NOW=1700000000

mkenv
t "no provenance: fail closed, nothing stamped" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"\$0\"; ! admission_eligible p1 && [ \"\$(state_get \".admissions[\\\"p1\\\"].requested_at // 0\")\" = 0 ]" "'"$MC"'"'

mkenv
echo '{"validation":{"confidence":0.9}}' > "$TD/p1/.startup/provenance.json"
t "gate pass stamps requested_at, not yet eligible" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"\$0\"; ! admission_eligible p1 && [ \"\$(state_get \".admissions[\\\"p1\\\"].requested_at // 0\")\" = '"$NOW"' ]" "'"$MC"'"'
LATER=$((NOW + 72*3600 + 60))
t "after veto window: admitted and eligible" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$LATER"' bash -c "source \"\$0\"; admission_eligible p1 && [ \"\$(state_get \".admissions[\\\"p1\\\"].admitted_at // 0\")\" != 0 ]" "'"$MC"'"'
echo '{"validation":{"confidence":0.9}}' > "$TD/p2/.startup/provenance.json"
t "wip_cap blocks second admission" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$LATER"' bash -c "source \"\$0\"; ! admission_eligible p2 && [ \"\$(state_get \".admissions[\\\"p2\\\"].requested_at // 0\")\" = 0 ]" "'"$MC"'"'

mkenv '.admission.confidence_min = 0.95'
echo '{"validation":{"confidence":0.9}}' > "$TD/p1/.startup/provenance.json"
t "below confidence bar: refused" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"\$0\"; ! admission_eligible p1 && [ \"\$(state_get \".admissions[\\\"p1\\\"].requested_at // 0\")\" = 0 ]" "'"$MC"'"'

mkenv
echo '{"validation":{"confidence":0.9}}' > "$TD/p1/.startup/provenance.json"
t "hold clears requested_at via housekeeping" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"\$0\"; admission_eligible p1 || true" "'"$MC"'"
  jq ".projects[0].hold = true" "'"$TD"'/portfolio.json" > "'"$TD"'/x" && mv "'"$TD"'/x" "'"$TD"'/portfolio.json"
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"\$0\"; admission_housekeeping; [ \"\$(state_get \".admissions[\\\"p1\\\"].requested_at // 0\")\" = 0 ]" "'"$MC"'"'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
