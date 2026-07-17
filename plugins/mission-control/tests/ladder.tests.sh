#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # fresh TD + config with file-based probes; args: extra jq mutation
  TD="$(mktemp -d)"
  mkdir -p "$TD/alpha" "$TD/beta" "$TD/gamma" "$TD/meta"
  jq -n --arg td "$TD" '{
    engines:{e:{pool:"p",cmd:"echo {prompt}"}}, pools:{p:{}},
    slots:{A:{pinned:"alpha"}},
    projects:[
      {name:"alpha", container:"local", repo_path:($td+"/alpha"), stage:"live",       engine:"e", command:"pass-a", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"beta",  container:"local", repo_path:($td+"/beta"),  stage:"live",       engine:"e", command:"pass-b", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"gamma", container:"local", repo_path:($td+"/gamma"), stage:"live",       engine:"e", command:"pass-c", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"meta1", container:"local", repo_path:($td+"/meta"),  stage:"meta",       engine:"e", command:"pass-m", hold:false, work_probe:"cat WORK 2>/dev/null"}
    ],
    admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' \
  | jq "${1:-.}" > "$TD/portfolio.json"
}
lib() { MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" source "$MC"; }

mkenv
t "no work anywhere: no candidates" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ -z "$(pick_pinned A)" ] && [ -z "$(pick_ladder)" ]'

mkenv; echo yes > "$TD/alpha/WORK"
t "slot A picks pinned when it has work" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_pinned A)" = alpha ]'

mkenv; echo yes > "$TD/beta/WORK"; echo yes > "$TD/meta/WORK"
t "rung 1 (live incident) beats rung 4 (meta)" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_ladder)" = "1 beta" ]'

mkenv; echo yes > "$TD/meta/WORK"
t "meta reached when higher rungs empty" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_ladder)" = "4 meta1" ]'

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "pinned excluded from slot B rung 1" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_ladder)" = "1 beta" ]'

mkenv; echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "round-robin cursor rotates within rung" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  state_set ".cursor[\"1\"]=\"beta\""
  [ "$(pick_ladder)" = "1 gamma" ]'

mkenv '.projects[1].hold=true'; echo yes > "$TD/beta/WORK"; echo yes > "$TD/meta/WORK"
t "held project skipped, ladder continues" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_ladder)" = "4 meta1" ]'

mkenv '.projects[1].work_probe="exit 1"'; echo yes > "$TD/meta/WORK"
t "probe failure = empty + streak recorded" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_ladder)" = "4 meta1" ] && [ "$(state_get ".projects[\"beta\"].probe_failures")" = 1 ]'

mkenv
t "cooldown blocks candidate" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  echo yes > "'"$TD"'/alpha/WORK"
  state_set ".projects[\"alpha\"].cooldown_until = (\$n|tonumber)" --arg n "$(( $(now) + 3600 ))"
  [ -z "$(pick_pinned A)" ]'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
