#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT

mkenv() {  # $1 = optional extra jq mutation, e.g. '.paused = true'
  rm -rf "$TD/state" "$TD/proj"; mkdir -p "$TD/proj"
  jq -n --arg rp "$TD/proj" '{
    timezone: "UTC",
    state_dir: null,
    engines: { e: { pool: "p", cmd: "bash -c '\''{prompt}'\''" } },
    pools: { p: { daily_pass_quota: 4 } },
    slots: { A: { pinned: "proj" }, B: {} },
    projects: [ { name: "proj", container: "local", repo_path: $rp,
                  stage: "live", engine: "e", command: "touch MARKER",
                  hold: false, work_probe: "echo yes" } ]
  } | del(.state_dir) | '"${1:-.}" > "$TD/portfolio.json"
}
tick() { bash "$MC" tick --config "$TD/portfolio.json"; }
waitfor() { local f="$1" i=0; while [ "$i" -lt 30 ]; do [ -f "$f" ] && return 0; sleep 0.5; i=$((i+1)); done; return 1; }

# Control: without paused, the pinned project dispatches and creates MARKER.
mkenv
t "control: tick dispatches"   bash -c "$(declare -f tick waitfor); TD='$TD'; MC='$MC'; tick && waitfor '$TD/proj/MARKER'"

# paused=true: tick exits 0, nothing dispatches.
mkenv '.paused = true'
t "paused tick exits 0"        tick
sleep 2
t "paused: no dispatch"        bash -c "[ ! -f '$TD/proj/MARKER' ]"
t "paused: no dispatch records" bash -c "[ ! -d '$TD/state/dispatches' ] || [ -z \"\$(ls -A '$TD/state/dispatches')\" ]"

# Malformed paused fails CLOSED at tick time (no dispatch).
mkenv '.paused = "yes"'
t "malformed paused: no dispatch" bash -c "bash '$MC' tick --config '$TD/portfolio.json' && sleep 2 && [ ! -f '$TD/proj/MARKER' ]"

# arm rejects a non-boolean paused.
mkenv '.paused = "yes"'
arm_rc=0
bash "$MC" arm --config "$TD/portfolio.json" >"$TD/arm.out" 2>&1 || arm_rc=$?
t "arm rejects string paused with exit 2" test "$arm_rc" -eq 2
t "arm rejection names paused field" grep -Fq '.paused must be true or false' "$TD/arm.out"
mkenv '.paused = false'
t "arm accepts boolean paused" bash "$MC" arm --config "$TD/portfolio.json"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
