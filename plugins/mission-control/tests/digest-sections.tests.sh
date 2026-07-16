#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
E=1784216000  # fixed epoch; digest_hour 0 means the digest always fires
D="$(TZ=UTC date -d "@$E" +%F)"

mkenv() {  # $1 = optional extra jq mutation
  rm -rf "$TD/state"
  jq -n --arg sd "$TD/sections" '{
    timezone: "UTC", digest_hour: 0, retention_days: 14,
    digest_sections_dir: $sd,
    engines: { e: { pool: "p", cmd: "true # {prompt}" } },
    pools: { p: { daily_pass_quota: 1 } },
    slots: { A: {}, B: {} },
    projects: [],
    admission: { wip_cap: 1, confidence_min: 0.7, veto_hours: 72 }
  } | '"${1:-.}" > "$TD/portfolio.json"
}
daily() {
  MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$E" \
    bash -c 'source "$1"; shift; "$@"' _ "$MC" governor_daily
}

mkdir -p "$TD/sections"
printf '## Steering memo\n\nhello-from-steering\n' > "$TD/sections/10-steering-memo.md"
printf '## Open proposals\n\n- none\n' > "$TD/sections/20-open-proposals.md"

mkenv
t "governor_daily runs"          daily
t "memo section in digest"       grep -q 'hello-from-steering' "$TD/state/digests/$D.md"
t "memo heading in digest"       grep -q '^## Steering memo' "$TD/state/digests/$D.md"
t "proposals section in digest"  grep -q '^## Open proposals' "$TD/state/digests/$D.md"
t "sections in order"            bash -c "grep -n '^## ' '$TD/state/digests/$D.md' | grep -A1 'Steering memo' | tail -1 | grep -q 'Open proposals'"

# Regression: no digest_sections_dir configured -> digest still builds.
mkenv 'del(.digest_sections_dir)'
t "no sections dir: still runs"  daily
t "no sections dir: digest file" test -f "$TD/state/digests/$D.md"

# Empty dir -> no crash, no stray content.
mkenv
rm -f "$TD/sections"/*.md
t "empty dir: still runs"        daily

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
