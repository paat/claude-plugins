#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"
# fake product repo with the REAL digest.sh in place (monorepo layout)
mkdir -p "$TD/prod/plugins/saas-startup-team/scripts" "$TD/prod/.startup/loop/runs" "$TD/export" "$TD/bin"
cp "$REPO_ROOT/plugins/saas-startup-team/scripts/digest.sh" "$TD/prod/plugins/saas-startup-team/scripts/"
echo "shipped PR #42" > "$TD/prod/.startup/loop/runs/run-1.md"
# meta repo with a lessons-deliver run digest
mkdir -p "$TD/meta/.startup/lessons-deliver/runs"
echo "lesson shipped" > "$TD/meta/.startup/lessons-deliver/runs/r1.md"
cat > "$TD/bin/curl" <<'SH'
#!/bin/bash
echo "curl $*" >> "$CURL_CALLS"; cat >> "$CURL_CALLS"; exit 0
SH
chmod +x "$TD/bin/curl"
export CURL_CALLS="$TD/curl.calls" MC_TEST_NTFY="https://ntfy.example/x"; : > "$CURL_CALLS"

jq -n --arg td "$TD" '{
  digest_hour: 0, retention_days: 14, notify_env: "MC_TEST_NTFY",
  digest_export_path: ($td+"/export"),
  engines:{e:{pool:"claude",cmd:"echo {prompt}"}}, pools:{claude:{daily_pass_quota:6}},
  slots:{A:{}},
  projects:[
    {name:"prod", container:"local", repo_path:($td+"/prod"), stage:"live", engine:"e", command:"x", hold:false},
    {name:"meta1",container:"local", repo_path:($td+"/meta"), stage:"meta", engine:"e", command:"x", hold:false}
  ],
  admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/portfolio.json"

NOW=1700000000
run() { local e="$1"; shift; PATH="$TD/bin:$PATH" MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$e" \
  bash -c 'source "$1"; shift; "$@"' _ "$MC" "$@"; }
D="$(date -d "@$NOW" +%F)"

# seed: one dispatch outcome + one stale orphan log + one ancient record
seed() {
  SD="$TD/state"; mkdir -p "$SD/dispatches"
  jq -n --arg s "$NOW" '{slot:"A",project:"prod",engine:"e",started_at:($s|tonumber),ended_at:($s|tonumber),exit_code:0,outcome:"ok"}' \
    > "$SD/dispatches/20261109T000000Z-A-prod.json"
  echo log > "$SD/dispatches/20261109T000000Z-A-prod.log"
  echo orphan > "$SD/dispatches/20261108T000000Z-B-meta1.log"     # no .json
  touch -d "3 hours ago" "$SD/dispatches/20261108T000000Z-B-meta1.log"
  echo old > "$SD/dispatches/ancient-A-x.log"
  touch -d "30 days ago" "$SD/dispatches/ancient-A-x.log"
}
seed
run "$NOW" state_set '.projects.prod.probe_failures = 4'

writes_digest() {
  run "$NOW" governor_daily || return 1
  local f="$TD/state/digests/$D.md"
  grep -q "^# Mission control digest" "$f" &&
  grep -q "^## Project: prod" "$f" && grep -q "shipped PR #42" "$f" &&
  grep -q "^## Project: meta1" "$f" && grep -q "lesson shipped" "$f" &&
  grep -q "^## Mission control warnings" "$f" && grep -q "probe failing x4: prod" "$f" &&
  grep -q "^## Spend & pass summary" "$f" && grep -q "pool claude: 1 passes (quota 6/day)" "$f"
}
t "daily writes digest with all sections" writes_digest

push_sent() { grep -q "Spend & pass summary" "$CURL_CALLS" && grep -q "probe failing" "$CURL_CALLS"; }
t "push sent with spend + warnings" push_sent

t "export copy exists" test -f "$TD/export/$D.md"

orphan_marked() { jq -e '.outcome == "orphaned"' "$TD/state/dispatches/20261108T000000Z-B-meta1.json"; }
t "orphan marked" orphan_marked

t "retention deleted ancient record" test ! -f "$TD/state/dispatches/ancient-A-x.log"

idempotent() { : > "$CURL_CALLS"; run "$NOW" governor_daily && [ ! -s "$CURL_CALLS" ]; }
t "idempotent per day" idempotent

spend_from_records() {
  run "$NOW" state_set '.pools.claude.passes_today = 0'
  grep -q "pool claude: 1 passes" "$TD/state/digests/$D.md"
}
t "spend survives counter reset (window from records)" spend_from_records

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
