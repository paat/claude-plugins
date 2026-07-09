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
    engines:{e:{pool:"claude",cmd:"echo {prompt}"},
             x:{pool:"codex",cmd:"echo {prompt}",rate_limit_patterns:["FUNKY_LIMIT"]}},
    pools:{claude:{daily_pass_quota:5}, codex:{}}, slots:{A:{}},
    projects:[{name:"p1",container:"local",repo_path:$td,stage:"live",engine:"e",command:"x",hold:false}],
    admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/portfolio.json"
}
run() { local e="$1"; shift; MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$e" \
  bash -c 'source "$1"; shift; "$@"' _ "$MC" "$@"; }
NOW=1700000000

mkenv; echo "Error: 429 Too Many Requests" > "$TD/rl.log"; : > "$TD/ok.log"; echo "boom" > "$TD/err.log"
rl_beats_ok() { [ "$(run "$NOW" governor_report e p1 0 "$TD/rl.log")" = rate-limit ]; }
t "rate-limit beats exit 0" rl_beats_ok
first_backoff() {
  [ "$(run "$NOW" state_get .pools.claude.backoff_until)" = "$((NOW + 1800))" ] &&
  [ "$(run "$NOW" state_get .pools.claude.backoff_level)" = 1 ]
}
t "exponential fallback: first backoff 30m, level 1" first_backoff
second_backoff() {
  run "$NOW" governor_report e p1 1 "$TD/rl.log" >/dev/null
  [ "$(run "$NOW" state_get .pools.claude.backoff_until)" = "$((NOW + 3600))" ]
}
t "second consecutive: 60m, level 2" second_backoff
ok_clears() {
  [ "$(run "$NOW" governor_report e p1 0 "$TD/ok.log")" = ok ] &&
  [ "$(run "$NOW" state_get .pools.claude.backoff_level)" = 0 ]
}
t "ok clears backoff_level and error streak" ok_clears

mkenv
FUTURE_ISO="$(date -u -d "@$((NOW + 7200))" +%Y-%m-%dT%H:%M:%SZ)"
echo "usage limit reached, resets at $FUTURE_ISO" > "$TD/iso.log"
iso_wins() {
  [ "$(run "$NOW" governor_report e p1 1 "$TD/iso.log")" = rate-limit ] &&
  [ "$(run "$NOW" state_get .pools.claude.backoff_until)" = "$((NOW + 7200))" ]
}
t "parsed ISO reset time wins over exponential" iso_wins

mkenv; echo "FUNKY_LIMIT hit" > "$TD/custom.log"
custom_pat() { [ "$(run "$NOW" governor_report x p1 1 "$TD/custom.log")" = rate-limit ]; }
t "configured extra pattern classifies rate-limit" custom_pat

mkenv; echo boom > "$TD/err.log"
timeout_no_backoff() {
  [ "$(run "$NOW" governor_report e p1 124 "$TD/err.log")" = timeout ] &&
  [ "$(run "$NOW" state_get ".pools.claude.backoff_until // 0")" = 0 ]
}
t "timeout is 124, no backoff" timeout_no_backoff
three_strikes() {
  run "$NOW" governor_report e p1 1 "$TD/err.log" >/dev/null
  run "$NOW" governor_report e p1 1 "$TD/err.log" >/dev/null
  [ "$(run "$NOW" state_get ".projects.p1.cooldown_until // 0")" = "$((NOW + 86400))" ]
}
t "three strikes set 24h cooldown" three_strikes

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
