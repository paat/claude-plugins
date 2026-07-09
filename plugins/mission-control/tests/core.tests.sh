#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
jq -n '{engines:{e:{pool:"p",cmd:"echo {prompt}"}}, pools:{p:{}}, slots:{A:{pinned:"alpha"}},
        projects:[{name:"alpha",container:"local",repo_path:"'"$TD"'",stage:"live",engine:"e",command:"true",hold:false}],
        admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/portfolio.json"

# lib seam loads helpers without running a subcommand
t "lib seam"        bash -c 'MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" && type cfg state_set governor_reserve >/dev/null' "$MC" "$TD"
t "state dir created" bash -c 'MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" && [ -d "$1/state/dispatches" ] && jq -e . "$1/state/state.json"' "$MC" "$TD"
t "state_set atomic + persisted" bash -c 'MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" && state_set ".x=\$v" --arg v hi && [ "$(state_get .x)" = hi ]' "$MC" "$TD"
t "MC_NOW_EPOCH overrides now" env MC_NOW_EPOCH=1000 bash -c 'MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" && [ "$(now)" = 1000 ]' "$MC" "$TD"
t "slot_free true then false" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" || exit 1
  slot_free A || exit 1
  ( flock 9; sleep 2 ) 9>>"$MC_STATE_DIR/slot-A.lock" &
  sleep 0.3
  ! slot_free A' "$MC" "$TD"

# arm: validates and prints, writes nothing outside state
t "arm prints cron line" bash -c 'bash "$0" arm --config "$1/portfolio.json" | grep -q "mission-control.sh tick --config"' "$MC" "$TD"
t "arm mentions crontab file + lessons removal" bash -c 'out="$(bash "$0" arm --config "$1/portfolio.json")"; grep -q "crontab" <<<"$out" && grep -qi "lessons-deliver" <<<"$out"' "$MC" "$TD"
t "arm rejects unknown engine" bash -c '
  jq ".projects[0].engine=\"nope\"" "$1/portfolio.json" > "$1/bad.json"
  ! bash "$0" arm --config "$1/bad.json"' "$MC" "$TD"

# status runs read-only
t "status prints slots" bash -c 'bash "$0" status --config "$1/portfolio.json" | grep -q "slot A"' "$MC" "$TD"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
