#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # $1: jq mutation, default identity — 3 slots: A pinned, B ladder, C pinned
  TD="$(mktemp -d)"
  mkdir -p "$TD/alpha" "$TD/beta" "$TD/gamma"
  jq -n --arg td "$TD" '{
    engines:{e:{pool:"p",cmd:"echo ran-{prompt} > MARKER"}}, pools:{p:{}},
    slots:{A:{pinned:"alpha"}, B:{}, C:{pinned:"gamma"}},
    projects:[
      {name:"alpha", container:"local", repo_path:($td+"/alpha"), stage:"live", engine:"e", command:"PA", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"beta",  container:"local", repo_path:($td+"/beta"),  stage:"live", engine:"e", command:"PB", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"gamma", container:"local", repo_path:($td+"/gamma"), stage:"live", engine:"e", command:"PC", hold:false, work_probe:"cat WORK 2>/dev/null"}
    ],
    admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' \
  | jq "${1:-.}" > "$TD/portfolio.json"
  SD="$TD/state"
}
lib() { MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" source "$MC"; }

mkenv; echo yes > "$TD/gamma/WORK"
t "pick_pinned is slot-parameterized (C -> gamma)" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_pinned C)" = gamma ] && [ -z "$(pick_pinned A)" ]'

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "ladder rung 1 excludes ALL pinned projects" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_ladder)" = "1 beta" ]'

mkenv; echo yes > "$TD/gamma/WORK"
t "only pinned work: ladder returns nothing" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  declare -F pick_ladder >/dev/null && [ -z "$(pick_ladder)" ]'

tick() { bash "$MC" tick --config "$TD/portfolio.json" "$@"; }
wait_outcomes() { # <count> — wait up to 5s for N outcome files
  local i=0
  while [ "$(ls "$SD/dispatches/"*.json 2>/dev/null | wc -l)" -lt "$1" ]; do
    i=$((i + 1)); [ "$i" -lt 50 ] || return 1; sleep 0.1
  done
}

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "three slots each dispatch their project on one tick" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 3 || exit 1
  grep -q ran-PA "$TD/alpha/MARKER" && grep -q ran-PB "$TD/beta/MARKER" && grep -q ran-PC "$TD/gamma/MARKER" || exit 1
  for s in A B C; do ls "$SD/dispatches/"*"-$s-"*.json >/dev/null || exit 1; done'

mkenv '.slots = {B:{}, C:{pinned:"gamma"}}'
echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "pinned-first: with quota 1 the pinned slot beats the ladder" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  cat > "$TD/gov.sh" <<'"'"'GOV'"'"'
governor_reserve() {
  ( flock -w 5 8 || exit 1
    local n; n="$(cat "$MC_STATE_DIR/q" 2>/dev/null || echo 0)"
    [ "$n" -lt 1 ] || exit 1
    echo $((n + 1)) > "$MC_STATE_DIR/q"
  ) 8>>"$MC_STATE_DIR/q.lock"
}
governor_envelope() { echo 1; }
governor_report() { if [ "$3" -eq 0 ]; then echo ok; else echo error; fi; }
governor_daily() { return 0; }
GOV
  MC_GOVERNOR="$TD/gov.sh" tick && wait_outcomes 1 || exit 1
  sleep 0.5
  [ -f "$TD/gamma/MARKER" ] && [ ! -f "$TD/beta/MARKER" ] &&
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 1 ] &&
  jq -e '"'"'.slot == "C" and .project == "gamma"'"'"' "$SD"/dispatches/*.json'

mkenv '.slots = {B:{}, D:{}}'
echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "multi-ladder smoke: two ladder slots pick different candidates" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 2 || exit 1
  [ -f "$TD/beta/MARKER" ] && [ -f "$TD/gamma/MARKER" ] &&
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 2 ]'

mkenv '.slots = {C:{pinned:"gamma"}, B:{}, A:{pinned:"alpha"}}'
echo yes > "$TD/alpha/WORK"; echo yes > "$TD/gamma/WORK"
t "within-class sort: slot A beats slot C under quota 1 despite C-first declaration" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  cat > "$TD/gov.sh" <<'"'"'GOV'"'"'
governor_reserve() {
  ( flock -w 5 8 || exit 1
    local n; n="$(cat "$MC_STATE_DIR/q" 2>/dev/null || echo 0)"
    [ "$n" -lt 1 ] || exit 1
    echo $((n + 1)) > "$MC_STATE_DIR/q"
  ) 8>>"$MC_STATE_DIR/q.lock"
}
governor_envelope() { echo 1; }
governor_report() { if [ "$3" -eq 0 ]; then echo ok; else echo error; fi; }
governor_daily() { return 0; }
GOV
  MC_GOVERNOR="$TD/gov.sh" tick && wait_outcomes 1 || exit 1
  sleep 0.5
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 1 ] &&
  jq -e '"'"'.slot == "A" and .project == "alpha"'"'"' "$SD"/dispatches/*.json'

mkenv '.slots = {A:{pinned:"alpha"}, B:{}}'
echo yes > "$TD/alpha/WORK"
t "legacy two-slot config: decision log lines byte-identical" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 1 || exit 1
  cut -d" " -f2- "$SD/mission-control.log" | grep -E "^(dispatch slot=|slot [A-Za-z0-9_-]+ )" > "$TD/got"
  printf "dispatch slot=A project=alpha engine=e envelope=90m\nslot B idle\n" | diff - "$TD/got"'

mkenv ".engines.e.cmd = \"MC_T_V=ran-{prompt} bash -c 'echo \$MC_T_V > MARKER'\" | .slots = {A:{pinned:\"alpha\"}, B:{}}"
echo yes > "$TD/alpha/WORK"
t "env-assignment-prefixed engine cmd executes (dedicated-subscription shape)" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 1 || exit 1
  grep -qx ran-PA "$TD/alpha/MARKER" &&
  jq -e ".outcome == \"ok\" and .exit_code == 0" "$SD"/dispatches/*.json'

mkenv '.slots = {B:{}, D:{}}'
echo yes > "$TD/beta/WORK"
t "one candidate, two ladder slots: dispatched once (slot B), not twice" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 1 || exit 1
  sleep 0.5
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 1 ] &&
  jq -e '"'"'.slot == "B" and .project == "beta"'"'"' "$SD"/dispatches/*.json'

mkenv
t "arm accepts three-slot config" bash -c 'bash "$0" arm --config "$1/portfolio.json" | grep -q "mission-control.sh tick --config"' "$MC" "$TD"
t "arm rejects unknown pinned on any slot" bash -c '
  jq ".slots.C.pinned=\"nope\"" "$1/portfolio.json" > "$1/bad.json"
  ! bash "$0" arm --config "$1/bad.json"' "$MC" "$TD"
t "arm rejects bad slot name" bash -c '
  jq ".slots[\"C/x\"]={}" "$1/portfolio.json" > "$1/bad.json"
  ! bash "$0" arm --config "$1/bad.json"' "$MC" "$TD"
t "arm rejects one project pinned on two slots" bash -c '
  jq ".slots.C.pinned=\"alpha\"" "$1/portfolio.json" > "$1/bad.json"
  ! bash "$0" arm --config "$1/bad.json"' "$MC" "$TD"
t "status lists every configured slot" bash -c '
  out="$(bash "$0" status --config "$1/portfolio.json")"
  grep -q "slot A" <<<"$out" && grep -q "slot B" <<<"$out" && grep -q "slot C" <<<"$out"' "$MC" "$TD"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
