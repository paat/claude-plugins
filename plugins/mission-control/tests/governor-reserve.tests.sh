#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() {
  TD="$(mktemp -d)"
  jq -n --arg td "$TD" '{
    engines:{c1:{pool:"claude",cmd:"echo {prompt}",pass_timeout_minutes:45},
             c2:{pool:"codex", cmd:"echo {prompt}"}},
    pools:{claude:{daily_pass_quota:2}, codex:{}},
    slots:{A:{}},
    projects:[{name:"p1",container:"local",repo_path:$td,stage:"live",engine:"c1",command:"x",hold:false,pass_timeout_minutes:7}],
    admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/portfolio.json"
}
# run <epoch> <fn|cmd> [args...] — fresh lib load at a fixed clock, argv forwarded verbatim
run() { local e="$1"; shift; MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$e" \
  bash -c 'source "$1"; shift; "$@"' _ "$MC" "$@"; }
NOW=1700000000

quota_three() {
  run "$NOW" governor_reserve c1 && run "$NOW" governor_reserve c1 || return 1
  ! run "$NOW" governor_reserve c1
}
counter_two() { [ "$(jq -r '.pools.claude.passes_today' "$TD/state/state.json")" = 2 ]; }
date_roll() { run "$((NOW + 86400))" governor_reserve c1; }
unlimited() { local i; for i in 1 2 3 4 5; do run "$NOW" governor_reserve c2 || return 1; done; }
unknown_engine() { ! run "$NOW" governor_reserve nope; }
backoff() {
  run "$NOW" state_set '.pools.claude.backoff_until = ($NOW + 600)' --argjson NOW "$NOW" || return 1
  ! run "$NOW" governor_reserve c1 || return 1
  run "$((NOW + 601))" governor_reserve c1
}
envelope() {
  [ "$(run "$NOW" governor_envelope c1 p1)" = 7 ] || return 1
  [ "$(run "$NOW" governor_envelope c1 missing-project)" = 45 ] || return 1
  [ "$(run "$NOW" governor_envelope c2 missing-project)" = 90 ]
}

mkenv
t "quota 2: two reserves ok, third refused" quota_three
t "counter persisted" counter_two
t "date roll resets quota" date_roll
t "unlimited pool never refuses" unlimited
t "unknown engine refused" unknown_engine

mkenv
t "backoff refuses, expiry allows" backoff

mkenv
t "envelope: project > engine > default" envelope

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
