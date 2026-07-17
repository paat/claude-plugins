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

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
