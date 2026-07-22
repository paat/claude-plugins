#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$PLUGIN/../.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
MAINTAIN_LOOP="$REPO/plugins/saas-startup-team/references/workflows/maintain.md"
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

# Worktree ids embed digit runs that can contain "429" (e.g. 306203429). Those
# must not false-trigger pool backoff when terminal_status is missing.
mkenv
echo "maintain-leases: expired lease is reclaimable for maintain:worktree:306203429" > "$TD/wt.log"
worktree_id_not_rate_limit() {
  [ "$(run "$NOW" governor_report e p1 0 "$TD/wt.log" false missing)" = error ] &&
  [ "$(run "$NOW" state_get ".pools.claude.backoff_until // 0")" = 0 ]
}
t "worktree id containing 429 is not rate-limit" worktree_id_not_rate_limit

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

mkenv; : > "$TD/hold.log"
deferred_no_strike() {
  run "$NOW" state_set '.projects.p1.consecutive_errors = 2' >/dev/null
  [ "$(run "$NOW" governor_report e p1 75 "$TD/hold.log" true)" = deferred ] &&
  [ "$(run "$NOW" state_get ".projects.p1.consecutive_errors")" = 2 ] &&
  [ "$(run "$NOW" state_get ".projects.p1.cooldown_until // 0")" = 0 ]
}
t "delivery hold contention is deferred without a failure strike" deferred_no_strike

mkenv; : > "$TD/hold.log"
config_error_is_actionable() {
  [ "$(run "$NOW" governor_report e p1 78 "$TD/hold.log" true)" = config-error ] &&
  [ "$(run "$NOW" state_get ".projects.p1.consecutive_errors")" = 1 ] &&
  grep -q 'delivery hold launcher rejected the container configuration' "$TD/state/mission-control.log"
}
t "invalid delivery hold configuration is reported and alerted" config_error_is_actionable

mkenv; : > "$TD/hold.log"
hold_codes_without_opt_in_are_errors() {
  [ "$(run "$NOW" governor_report e p1 75 "$TD/hold.log")" = error ] &&
  [ "$(run "$NOW" state_get ".projects.p1.consecutive_errors")" = 1 ]
}
t "launcher exit codes retain normal meaning without the opt-in" hold_codes_without_opt_in_are_errors

# --- MC-BLOCKED terminal state (#243) ---
mkenv; echo "MC-BLOCKED recheck_after=90 reason=CI runner offline until soak ends" > "$TD/blk.log"
blocked_outcome() {
  [ "$(run "$NOW" governor_report e p1 0 "$TD/blk.log")" = blocked ] &&
  [ "$(run "$NOW" state_get ".projects.p1.blocked_until")" = "$((NOW + 90 * 60))" ] &&
  [ "$(run "$NOW" state_get ".projects.p1.blocked_reason")" = "CI runner offline until soak ends" ]
}
t "MC-BLOCKED records blocked outcome, recheck window, reason" blocked_outcome
blocked_is_not_a_strike() {
  run "$NOW" governor_report e p1 0 "$TD/blk.log" >/dev/null
  run "$NOW" governor_report e p1 0 "$TD/blk.log" >/dev/null
  [ "$(run "$NOW" state_get ".projects.p1.consecutive_errors // 0")" = 0 ] &&
  [ "$(run "$NOW" state_get ".projects.p1.cooldown_until // 0")" = 0 ] &&
  [ "$(run "$NOW" state_get ".pools.claude.backoff_until // 0")" = 0 ]
}
t "blocked is terminal, not a failure: no strike, no cooldown, no backoff" blocked_is_not_a_strike
blocked_nonzero_rc() { [ "$(run "$NOW" governor_report e p1 1 "$TD/blk.log")" = blocked ]; }
t "declared block wins over nonzero exit" blocked_nonzero_rc
mkenv; echo "MC-BLOCKED reason=waiting on human signoff" > "$TD/blk2.log"
blocked_default_recheck() {
  [ "$(run "$NOW" governor_report e p1 0 "$TD/blk2.log")" = blocked ] &&
  [ "$(run "$NOW" state_get ".projects.p1.blocked_until")" = "$((NOW + 360 * 60))" ]
}
t "missing recheck_after uses 360m default" blocked_default_recheck
mkenv; echo "MC-BLOCKED recheck_after=999999 reason=x" > "$TD/blk3.log"
blocked_clamped() {
  run "$NOW" governor_report e p1 0 "$TD/blk3.log" >/dev/null
  [ "$(run "$NOW" state_get ".projects.p1.blocked_until")" = "$((NOW + 10080 * 60))" ]
}
t "recheck window clamps at 7 days" blocked_clamped
mkenv; echo "Error: 429 Too Many Requests" > "$TD/rlblk.log"; echo "MC-BLOCKED reason=x" >> "$TD/rlblk.log"
rl_beats_blocked() { [ "$(run "$NOW" governor_report e p1 0 "$TD/rlblk.log")" = rate-limit ]; }
t "rate-limit precedence over declared block" rl_beats_blocked
mkenv; printf '%s\n' '{"rate_limits":{"limit_id":"codex","used_percent":21.0}}' 'MC-BLOCKED reason=probe_failed' > "$TD/telemetry.log"
api_telemetry_not_rate_limit() {
  [ "$(run "$NOW" governor_report e p1 0 "$TD/telemetry.log")" = blocked ] &&
  [ "$(run "$NOW" state_get ".pools.claude.backoff_until // 0")" = 0 ]
}
t "API rate_limits JSON telemetry does not classify rate-limit" api_telemetry_not_rate_limit
mkenv; printf '%s\n' '{"rate_limits":{"limit_id":"codex"}}' > "$TD/accounted_blocked.log"
accounted_blocked_beats_telemetry() {
  [ "$(run "$NOW" governor_report e p1 0 "$TD/accounted_blocked.log" false accounted blocked probe_failed)" = blocked ] &&
  [ "$(run "$NOW" state_get ".pools.claude.backoff_until // 0")" = 0 ]
}
t "accounted blocked terminal beats rate_limits telemetry" accounted_blocked_beats_telemetry
mkenv; echo "MC-BLOCKED recheck_after=90 reason=soak" > "$TD/blk.log"; : > "$TD/ok.log"
blocked_ladder_and_clear() {
  run "$NOW" governor_report e p1 0 "$TD/blk.log" >/dev/null
  run "$NOW" project_blocked p1 &&
  ! run "$((NOW + 90 * 60))" project_blocked p1 &&
  { run "$NOW" governor_report e p1 0 "$TD/ok.log" >/dev/null
    [ "$(run "$NOW" state_get ".projects.p1.blocked_until // 0")" = 0 ] &&
    [ "$(run "$NOW" state_get ".projects.p1.blocked_reason // \"\"")" = "" ]; }
}
t "ladder skips blocked project until expiry; ok clears the block" blocked_ladder_and_clear
blocked_in_warnings() {
  run "$NOW" governor_report e p1 0 "$TD/blk.log" >/dev/null
  run "$NOW" _warnings_section | grep -q "blocked: p1 — soak"
}
t "digest warnings surface blocked project with reason" blocked_in_warnings
mkenv; echo "the pass should print MC-BLOCKED recheck_after=10 when stuck" > "$TD/prose.log"
prose_not_blocked() { [ "$(run "$NOW" governor_report e p1 0 "$TD/prose.log")" = ok ]; }
t "prose mentioning the sentinel mid-line does not classify blocked" prose_not_blocked
mkenv; { cat "$MAINTAIN_LOOP"; echo "pass-complete"; } > "$TD/codex.log"
codex_template_not_blocked() { [ "$(run "$NOW" governor_report e p1 0 "$TD/codex.log")" = ok ]; }
t "Codex transcript containing producer template remains successful" codex_template_not_blocked

# --- dedicated_subscription: no soft-block window, no 24h cooldown ---
mkenv
jq '.pools.claude.dedicated_subscription = true' "$TD/portfolio.json" > "$TD/p.json" && mv "$TD/p.json" "$TD/portfolio.json"
echo "MC-BLOCKED reason=verification_failed" > "$TD/ded.log"
dedicated_pool_no_soft_block() {
  [ "$(run "$NOW" governor_report e p1 0 "$TD/ded.log")" = blocked ] &&
  [ "$(run "$NOW" state_get ".projects.p1.blocked_until // 0")" = 0 ] &&
  [ "$(run "$NOW" state_get ".projects.p1.blocked_reason // \"\"")" = "" ]
}
t "dedicated pool: MC-BLOCKED verification_failed sets no soft-block window" dedicated_pool_no_soft_block

mkenv
jq '(.projects[] | select(.name=="p1") | .dedicated_subscription) = true' \
  "$TD/portfolio.json" > "$TD/p.json" && mv "$TD/p.json" "$TD/portfolio.json"
echo "MC-BLOCKED recheck_after=90 reason=soak" > "$TD/ded2.log"
dedicated_project_ignores_recheck() {
  [ "$(run "$NOW" governor_report e p1 0 "$TD/ded2.log")" = blocked ] &&
  [ "$(run "$NOW" state_get ".projects.p1.blocked_until // 0")" = 0 ]
}
t "dedicated project: recheck_after is ignored (no park)" dedicated_project_ignores_recheck

mkenv
jq '.pools.claude.dedicated_subscription = true' "$TD/portfolio.json" > "$TD/p.json" && mv "$TD/p.json" "$TD/portfolio.json"
: > "$TD/err.log"
dedicated_no_cooldown() {
  run "$NOW" governor_report e p1 1 "$TD/err.log" >/dev/null
  run "$NOW" governor_report e p1 1 "$TD/err.log" >/dev/null
  run "$NOW" governor_report e p1 1 "$TD/err.log" >/dev/null
  [ "$(run "$NOW" state_get ".projects.p1.consecutive_errors")" = 3 ] &&
  [ "$(run "$NOW" state_get ".projects.p1.cooldown_until // 0")" = 0 ]
}
t "dedicated pool: 3 consecutive errors do not start 24h cooldown" dedicated_no_cooldown

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
