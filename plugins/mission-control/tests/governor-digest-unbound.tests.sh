#!/bin/bash
# Regression for #200/#201: governor_daily's non-meta fallback echoed markdown
# italics `_digest unavailable for $n_` — bash parses `$n_` as the unset var
# `n_`, and under set -u (mission-control.sh: set -euo pipefail) that aborts
# the whole digest build, truncating the output after the failing project's
# header. Exercise 2 projects where the SECOND one takes the run_in failure
# path, and assert the digest still completes past it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/alpha/plugins/saas-startup-team/scripts" "$TD/alpha/.startup/loop/runs"
cp "$HERE/../../saas-startup-team/scripts/digest.sh" "$TD/alpha/plugins/saas-startup-team/scripts/"
echo "shipped PR #1" > "$TD/alpha/.startup/loop/runs/run-1.md"
# "broken" project targets a nonexistent docker container: docker_check's
# `docker info` may still succeed, but `docker exec <no-such-container>`
# fails -> run_in returns nonzero -> the `||` fallback on governor.sh line
# ~200 fires reliably regardless of whether docker itself is installed.

jq -n --arg alpha "$TD/alpha" '{
  digest_hour: 0, retention_days: 14,
  engines:{e:{pool:"claude",cmd:"echo {prompt}"}}, pools:{claude:{daily_pass_quota:6}},
  slots:{A:{}},
  projects:[
    {name:"alpha", container:"local", repo_path:$alpha, stage:"live", engine:"e", command:"x", hold:false},
    {name:"broken",container:"mc-test-no-such-container-xyz", repo_path:"/", stage:"live", engine:"e", command:"x", hold:false}
  ]}' > "$TD/portfolio.json"

NOW=1700000000
run() { local e="$1"; shift; MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$e" \
  bash -c 'source "$1"; shift; "$@"' _ "$MC" "$@"; }
D="$(date -d "@$NOW" +%F)"

digest_completes_past_failing_project() {
  run "$NOW" governor_daily || return 1
  local f="$TD/state/digests/$D.md"
  [ -f "$f" ] || return 1
  grep -q "^## Project: alpha" "$f" &&
  grep -q "shipped PR #1" "$f" &&
  grep -q "^## Project: broken" "$f" &&
  grep -qF "_digest unavailable for broken_" "$f" &&
  grep -q "^## Mission control warnings" "$f" &&
  grep -q "^## Spend & pass summary" "$f"
}
t "digest completes with both project sections after run_in failure" digest_completes_past_failing_project

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
