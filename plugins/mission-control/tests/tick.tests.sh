#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # $1: jq mutation
  TD="$(mktemp -d)"
  mkdir -p "$TD/alpha" "$TD/beta" "$TD/bin"
  cat > "$TD/bin/docker" <<'SH'
#!/bin/bash
echo "docker $*" >> "$DOCKER_CALLS"; exit 0
SH
  chmod +x "$TD/bin/docker"
  export DOCKER_CALLS="$TD/docker.calls"; : > "$DOCKER_CALLS"
  jq -n --arg td "$TD" '{
    engines:{e:{pool:"p", cmd:"echo ran-{prompt} > MARKER"}}, pools:{p:{}},
    slots:{A:{pinned:"alpha"}},
    projects:[
      {name:"alpha", container:"local", repo_path:($td+"/alpha"), stage:"live", engine:"e", command:"A", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"beta",  container:"local", repo_path:($td+"/beta"),  stage:"live", engine:"e", command:"B", hold:false, work_probe:"cat WORK 2>/dev/null"}
    ],
    admission:{wip_cap:1, confidence_min:0.7, veto_hours:72}}' \
  | jq "${1:-.}" > "$TD/portfolio.json"
  SD="$TD/state"
}
tick() { PATH="$TD/bin:$PATH" bash "$MC" tick --config "$TD/portfolio.json" "$@"; }
wait_outcomes() { # <count> — wait up to 5s for N outcome files
  local i=0
  while [ "$(ls "$SD/dispatches/"*.json 2>/dev/null | wc -l)" -lt "$1" ]; do
    i=$((i + 1)); [ "$i" -lt 50 ] || return 1; sleep 0.1
  done
}

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "tick dispatches both slots; outcomes ok" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 2 || exit 1
  [ -f "$TD/alpha/MARKER" ] && [ -f "$TD/beta/MARKER" ] || exit 1
  grep -q ran-A "$TD/alpha/MARKER" && grep -q ran-B "$TD/beta/MARKER" || exit 1
  for f in "$SD/dispatches/"*.json; do jq -e ".outcome == \"ok\" and .exit_code == 0" "$f" >/dev/null || exit 1; done'

mkenv '.projects[1].container="some-container"'; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "busy slots: zero dispatches, zero docker calls" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  mkdir -p "$SD"
  ( flock 9; sleep 3 ) 9>>"$SD/slot-A.lock" &
  ( flock 9; sleep 3 ) 9>>"$SD/slot-B.lock" &
  sleep 0.3
  tick || exit 1
  [ -z "$(ls "$SD/dispatches" 2>/dev/null)" ] && [ ! -s "$DOCKER_CALLS" ]'

mkenv
t "no work: no dispatches" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && [ -z "$(ls "$SD/dispatches" 2>/dev/null)" ]'

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "quota-1 governor: exactly one dispatch (reserve atomicity)" bash -c '
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
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 1 ]'

mkenv; echo yes > "$TD/alpha/WORK"
t "slot lock held when tick exits (no free window)" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  # pass sleeps: lock must be observed held right after tick returns
  jq ".engines.e.cmd = \"sleep 1 # {prompt}\"" "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
  tick || exit 1
  ! ( flock -n 9 ) 9>>"$SD/slot-A.lock"'

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "dry-run: prints decisions, mutates nothing" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  out="$(tick --dry-run 2>&1)" || exit 1
  grep -qi "would dispatch" <<<"$out" || exit 1
  [ -z "$(ls "$SD/dispatches" 2>/dev/null)" ] && [ ! -f "$TD/alpha/MARKER" ] &&
  [ "$(cat "$SD/state.json")" = "{}" ]'

mkenv; echo yes > "$TD/alpha/WORK"
t "second tick runs while a pass is live (tick lock not leaked)" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  jq ".engines.e.cmd = \"sleep 3 # {prompt}\"" "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
  tick || exit 1        # dispatches only slot A (beta has no work yet)
  sleep 0.3
  [ "$(ls "$SD/dispatches/"*.log | wc -l)" = 1 ] || exit 1
  echo yes > "$TD/beta/WORK"
  tick || exit 1        # must not be blocked by the running pass holding tick.lock
  sleep 0.3
  [ "$(ls "$SD/dispatches/"*.log | wc -l)" = 2 ]'

mkenv; echo yes > "$TD/alpha/WORK"
t "envelope timeout yields timeout outcome" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  cat > "$TD/gov.sh" <<'"'"'GOV'"'"'
governor_reserve() { return 0; }
governor_envelope() { echo 0.02; }   # ~1.2s via timeout(1) float support
governor_report() { if [ "$3" -eq 124 ]; then echo timeout; elif [ "$3" -eq 0 ]; then echo ok; else echo error; fi; }
governor_daily() { return 0; }
GOV
  jq ".engines.e.cmd = \"sleep 5 # {prompt}\"" "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
  MC_GOVERNOR="$TD/gov.sh" tick && wait_outcomes 1 || exit 1
  jq -e ".outcome == \"timeout\" and .exit_code == 124" "$SD"/dispatches/*.json'

mkenv; mkdir -p "$TD/gamma"
jq --arg td "$TD" '.engines.e2 = {pool:"p2", cmd:"echo ran2-{prompt} > MARKER"}
  | .projects += [{name:"gamma", container:"local", repo_path:($td+"/gamma"), stage:"meta",
                   engine:"e2", command:"M", hold:false, work_probe:"cat WORK 2>/dev/null"}]' \
  "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "reserve refusal re-walks ladder to another pool" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  cat > "$TD/gov.sh" <<'"'"'GOV'"'"'
governor_reserve() { [ "$(cfg ".engines[\"$1\"].pool")" != "p" ]; }
governor_envelope() { echo 1; }
governor_report() { if [ "$3" -eq 0 ]; then echo ok; else echo error; fi; }
governor_daily() { return 0; }
GOV
  MC_GOVERNOR="$TD/gov.sh" tick && wait_outcomes 1 || exit 1
  grep -q ran2-M "$TD/gamma/MARKER" && [ ! -f "$TD/beta/MARKER" ] &&
  jq -e ".project == \"gamma\"" "$SD"/dispatches/*.json'

mkenv; echo yes > "$TD/alpha/WORK"
t "self-resume: killed pass frees slot, next tick redispatches" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  jq ".engines.e.cmd = \"sleep 30 # RESUME-{prompt}\"" "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
  tick || exit 1
  sleep 0.5
  # simulate the pass dying mid-flight: kill everything holding the slot lock
  # (wrapper + its timeout/sleep descendants, which live in a separate group)
  h="$(fuser "$SD/slot-A.lock" 2>/dev/null)"; [ -n "$h" ] && kill -TERM $h 2>/dev/null
  i=0; until ( flock -n 9 ) 9>>"$SD/slot-A.lock"; do i=$((i+1)); [ "$i" -lt 50 ] || exit 1; sleep 0.1; done
  # redispatch must land in a new UTC second for a distinct dispatch filename
  now1=$(date +%s); while [ "$(date +%s)" -le "$now1" ]; do sleep 0.05; done
  tick || exit 1
  sleep 0.5
  [ "$(ls "$SD/dispatches/"*.log | wc -l)" = 2 ]'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
