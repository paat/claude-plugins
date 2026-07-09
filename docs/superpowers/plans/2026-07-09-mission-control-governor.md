# Mission Control Governor (#199) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stub bodies in `plugins/mission-control/scripts/governor.sh` with the real budget governor per `docs/superpowers/specs/2026-07-09-mission-control-governor-design.md` (read it first) — quotas, rate-limit backoff, envelopes, daily digest with spend summary.

**Architecture:** `governor.sh` is sourced by `mission-control.sh` AFTER its helpers; every function may use `cfg`, `pj`, `state_get`, `state_set`, `now`, `today`, `hour_now`, `run_in`, `slot_free`, `alert`, `log`, `SCRIPT_DIR`, and exported `MC_CONFIG`/`MC_STATE_DIR`. **No changes to `mission-control.sh`** — the four-function interface (`governor_reserve`, `governor_envelope`, `governor_report`, `governor_daily`) is the contract. Prerequisite: the #198 plan is fully merged.

**Tech Stack:** bash 4+, jq, flock, GNU date, awk; tests via the existing `tests/run-tests.sh` auto-discovery and the `MC_LIB_ONLY=1 source` seam.

## Global Constraints

- Never degrade pass quality to stretch quota: over-budget = not dispatched or killed by `timeout`, never a modified prompt.
- Ambiguous failure classification prefers `rate-limit` (backoff is always safe).
- All `state.json` mutations under `state.lock`. **Deadlock trap:** inside `governor_reserve`'s critical section you already hold `state.lock` — use direct `jq … > tmp && mv` there, never nested `state_set` calls.
- Plugin stays generic (no real project names outside examples/docs).
- Version bump `0.1.0` → `0.2.0` in BOTH `plugins/mission-control/.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json`, in the final task only.
- Commit after each task; `Closes #199` only in the final commit.

---

### Task 1: governor_reserve + governor_envelope

**Files:**
- Modify: `plugins/mission-control/scripts/governor.sh` (replace the stub `governor_reserve` and `governor_envelope` bodies; keep stub `governor_report`/`governor_daily` untouched)
- Create: `plugins/mission-control/tests/governor-reserve.tests.sh`

**Interfaces:**
- Consumes: `cfg`, `pj`, `today`, `now`, `alert` and `MC_STATE_DIR` (from mission-control.sh core).
- Produces: `governor_reserve <engine>` — exit 0 reserves one pass on the engine's pool (increments `pools.<pool>.passes_today`, lazily rolling `counter_date`), exit 1 refuses (backoff active, quota reached, or unknown engine/pool). `governor_envelope <engine> <project>` — prints minutes: project `pass_timeout_minutes` override, else engine override, else 90.

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/governor-reserve.tests.sh`:

```bash
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
    engines:{c1:{pool:"claude",cmd:"echo {prompt}",pass_timeout_minutes:45},
             c2:{pool:"codex", cmd:"echo {prompt}"}},
    pools:{claude:{daily_pass_quota:2}, codex:{}},
    slots:{A:{}},
    projects:[{name:"p1",container:"local",repo_path:$td,stage:"live",engine:"c1",command:"x",hold:false,pass_timeout_minutes:7}],
    admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/portfolio.json"
}
# run <epoch> <bash-body> — fresh lib load at a fixed clock
run() { local e="$1"; shift; MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$e" bash -c "source '$MC'; $1"; }
NOW=1700000000

mkenv
t "quota 2: two reserves ok, third refused" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  run '"$NOW"' "governor_reserve c1" && run '"$NOW"' "governor_reserve c1" || exit 1
  ! run '"$NOW"' "governor_reserve c1"'
t "counter persisted" bash -c 'TD="'"$TD"'"; [ "$(jq -r ".pools.claude.passes_today" "$TD/state/state.json")" = 2 ]'
t "date roll resets quota" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  run $(( '"$NOW"' + 86400 )) "governor_reserve c1"'
t "unlimited pool never refuses" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  for i in 1 2 3 4 5; do run '"$NOW"' "governor_reserve c2" || exit 1; done'
t "unknown engine refused" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  ! run '"$NOW"' "governor_reserve nope"'

mkenv
t "backoff refuses, expiry allows" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  run '"$NOW"' "state_set \".pools.claude.backoff_until = ($NOW + 600)\" --argjson NOW '"$NOW"'" || exit 1
  ! run '"$NOW"' "governor_reserve c1" || exit 1
  run $(( '"$NOW"' + 601 )) "governor_reserve c1"'

mkenv
t "envelope: project > engine > default" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  [ "$(run '"$NOW"' "governor_envelope c1 p1")" = 7 ] || exit 1
  [ "$(run '"$NOW"' "governor_envelope c1 missing-project")" = 45 ] || exit 1
  [ "$(run '"$NOW"' "governor_envelope c2 missing-project")" = 90 ]'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/mission-control/tests/governor-reserve.tests.sh`
Expected: FAIL — stub reserve always allows; stub envelope prints 90 for p1.

- [ ] **Step 3: Implement — replace the two stub bodies in governor.sh**

```bash
# Atomic check-and-reserve. One critical section: lazy date roll, backoff
# check, quota check, increment. DO NOT call state_set in here — it takes
# state.lock again and deadlocks; use direct jq > tmp && mv.
governor_reserve() { # <engine>
  local engine="$1" pool quota d
  pool="$(cfg ".engines[\"$engine\"].pool // empty")"
  if [ -z "$pool" ]; then
    alert "config-engine-$engine" "unknown engine '$engine' (no pool) — refusing dispatch"
    return 1
  fi
  quota="$(cfg ".pools[\"$pool\"].daily_pass_quota // empty")"
  d="$(today)"
  (
    flock -w 10 9 || exit 1
    st="$MC_STATE_DIR/state.json"
    cdate="$(jq -r ".pools[\"$pool\"].counter_date // \"\"" "$st")"
    if [ "$cdate" != "$d" ]; then
      jq --arg p "$pool" --arg d "$d" \
        '.pools[$p].passes_today = 0 | .pools[$p].counter_date = $d' \
        "$st" > "$MC_STATE_DIR/.state.tmp" && mv "$MC_STATE_DIR/.state.tmp" "$st"
    fi
    bu="$(jq -r ".pools[\"$pool\"].backoff_until // 0" "$st")"
    [ "$(now)" -ge "$bu" ] || exit 1
    cur="$(jq -r ".pools[\"$pool\"].passes_today // 0" "$st")"
    if [ -n "$quota" ] && [ "$cur" -ge "$quota" ]; then exit 1; fi
    jq --arg p "$pool" '.pools[$p].passes_today = ((.pools[$p].passes_today // 0) + 1)' \
      "$st" > "$MC_STATE_DIR/.state.tmp" && mv "$MC_STATE_DIR/.state.tmp" "$st"
  ) 9>>"$MC_STATE_DIR/state.lock"
}

# Pass wall-clock envelope in minutes: project override > engine override > 90.
governor_envelope() { # <engine> <project>
  local v
  v="$(pj "$2" '.pass_timeout_minutes // empty')"
  [ -n "$v" ] || v="$(cfg ".engines[\"$1\"].pass_timeout_minutes // empty")"
  [ -n "$v" ] || v=90
  echo "$v"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/governor-reserve.tests.sh`
Expected: `pass=7 fail=0`. Full suite (`tests/run-tests.sh`) stays green — the #198 tick tests use the real governor now; their unlimited default pools must still dispatch.

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts/governor.sh plugins/mission-control/tests/governor-reserve.tests.sh
git commit -m "mission-control: governor reserve (quota, lazy date roll, backoff refusal) and envelope"
```

---

### Task 2: governor_report — classification, backoff, cooldown breaker

**Files:**
- Modify: `plugins/mission-control/scripts/governor.sh` (replace stub `governor_report`; add `RL_BUILTIN` and `_gov_backoff` above it)
- Create: `plugins/mission-control/tests/governor-report.tests.sh`

**Interfaces:**
- Consumes: `cfg`, `state_get`, `state_set`, `now`, `alert`, `TZCFG`.
- Produces: `governor_report <engine> <project> <exit_code> <log_path>` printing exactly one of `ok|rate-limit|timeout|error`; state effects per spec (backoff on rate-limit, 3-strike 24h cooldown on error/timeout, ok clears both streaks).

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/governor-report.tests.sh`:

```bash
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
run() { local e="$1"; shift; MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$e" bash -c "source '$MC'; $1"; }
NOW=1700000000

mkenv; echo "Error: 429 Too Many Requests" > "$TD/rl.log"; : > "$TD/ok.log"; echo "boom" > "$TD/err.log"
t "rate-limit beats exit 0" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  [ "$(run '"$NOW"' "governor_report e p1 0 $TD/rl.log")" = rate-limit ]'
t "exponential fallback: first backoff 30m, level 1" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  [ "$(run '"$NOW"' "state_get .pools.claude.backoff_until")" = $(( '"$NOW"' + 1800 )) ] &&
  [ "$(run '"$NOW"' "state_get .pools.claude.backoff_level")" = 1 ]'
t "second consecutive: 60m, level 2" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  run '"$NOW"' "governor_report e p1 1 $TD/rl.log" >/dev/null
  [ "$(run '"$NOW"' "state_get .pools.claude.backoff_until")" = $(( '"$NOW"' + 3600 )) ]'
t "ok clears backoff_level and error streak" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  [ "$(run '"$NOW"' "governor_report e p1 0 $TD/ok.log")" = ok ] &&
  [ "$(run '"$NOW"' "state_get .pools.claude.backoff_level")" = 0 ]'

mkenv
FUTURE_ISO="$(date -u -d "@$((NOW + 7200))" +%Y-%m-%dT%H:%M:%SZ)"
echo "usage limit reached, resets at $FUTURE_ISO" > "$TD/iso.log"
t "parsed ISO reset time wins over exponential" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  [ "$(run '"$NOW"' "governor_report e p1 1 $TD/iso.log")" = rate-limit ] &&
  [ "$(run '"$NOW"' "state_get .pools.claude.backoff_until")" = '"$((NOW + 7200))"' ]'

mkenv; echo "FUNKY_LIMIT hit" > "$TD/custom.log"
t "configured extra pattern classifies rate-limit" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  [ "$(run '"$NOW"' "governor_report x p1 1 $TD/custom.log")" = rate-limit ]'

mkenv; echo boom > "$TD/err.log"
t "timeout is 124, no backoff" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  [ "$(run '"$NOW"' "governor_report e p1 124 $TD/err.log")" = timeout ] &&
  [ "$(run '"$NOW"' "state_get \".pools.claude.backoff_until // 0\"")" = 0 ]'
t "three strikes set 24h cooldown" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  run '"$NOW"' "governor_report e p1 1 $TD/err.log" >/dev/null
  run '"$NOW"' "governor_report e p1 1 $TD/err.log" >/dev/null
  [ "$(run '"$NOW"' "state_get \".projects.p1.cooldown_until // 0\"")" = $(( '"$NOW"' + 86400 )) ]'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

(The three-strikes test issues 2 reports after the timeout test's 1 → streak reaches 3.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/mission-control/tests/governor-report.tests.sh`
Expected: FAIL — stub prints `error`, sets no state.

- [ ] **Step 3: Implement — replace stub `governor_report` with:**

```bash
# Built-in rate-limit signatures (case-insensitive grep -E). Config may add
# per-engine extras via engines.<name>.rate_limit_patterns.
RL_BUILTIN='429|rate.?limit|usage limit|quota exceeded|limit (will )?reset|overloaded'

_gov_backoff() { # <pool> <log_path> — set backoff_until (parsed reset or exponential)
  local pool="$1" logf="$2" ts="" until_e="" lvl mins
  ts="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})?' "$logf" 2>/dev/null | head -1)"
  if [ -z "$ts" ]; then
    ts="$(grep -oiE 'reset[s]?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)' "$logf" 2>/dev/null \
          | head -1 | sed -E 's/^[Rr]eset[s]?( at)? //')"
  fi
  if [ -n "$ts" ]; then
    if [ -n "$TZCFG" ]; then until_e="$(TZ="$TZCFG" date -d "$ts" +%s 2>/dev/null || true)"
    else until_e="$(date -d "$ts" +%s 2>/dev/null || true)"; fi
  fi
  if [ -z "$until_e" ] || [ "$until_e" -le "$(now)" ]; then
    lvl="$(state_get ".pools[\"$pool\"].backoff_level // 0")"
    case "$lvl" in 0) mins=30 ;; 1) mins=60 ;; 2) mins=120 ;; *) mins=240 ;; esac
    until_e="$(( $(now) + mins * 60 ))"
  fi
  state_set '.pools[$p].backoff_until = ($u|tonumber)
             | .pools[$p].backoff_level = ((.pools[$p].backoff_level // 0) + 1)' \
    --arg p "$pool" --arg u "$until_e"
  alert "backoff-$pool" "pool $pool rate-limited; backing off until $(date -d "@$until_e" +%FT%T 2>/dev/null || echo "$until_e")"
}

governor_report() { # <engine> <project> <exit_code> <log_path>
  local engine="$1" name="$2" rc="$3" logf="$4" pool patterns extra outcome errs
  pool="$(cfg ".engines[\"$engine\"].pool // \"unknown\"")"
  patterns="$RL_BUILTIN"
  extra="$(cfg "(.engines[\"$engine\"].rate_limit_patterns // []) | join(\"|\")")"
  [ -z "$extra" ] || patterns="$patterns|$extra"
  if grep -qiE "$patterns" "$logf" 2>/dev/null; then
    outcome="rate-limit"                       # wins even over exit 0
    _gov_backoff "$pool" "$logf"
  elif [ "$rc" -eq 124 ]; then outcome="timeout"
  elif [ "$rc" -eq 0 ]; then outcome="ok"
  else outcome="error"
  fi
  case "$outcome" in
    ok)
      state_set '.pools[$p].backoff_level = 0 | .projects[$n].consecutive_errors = 0' \
        --arg p "$pool" --arg n "$name" ;;
    timeout|error)
      state_set '.projects[$n].consecutive_errors = ((.projects[$n].consecutive_errors // 0) + 1)' --arg n "$name"
      errs="$(state_get ".projects[\"$name\"].consecutive_errors // 0")"
      if [ "$errs" -ge 3 ]; then
        state_set '.projects[$n].cooldown_until = ($u|tonumber)' \
          --arg n "$name" --arg u "$(( $(now) + 86400 ))"
        alert "cooldown-$name" "$name: 3 consecutive failed passes — 24h cooldown"
      fi ;;
  esac
  echo "$outcome"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/governor-report.tests.sh`
Expected: `pass=8 fail=0`. Full suite green (the #198 tick test asserting `outcome == "ok"` still passes — empty logs match no pattern).

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts/governor.sh plugins/mission-control/tests/governor-report.tests.sh
git commit -m "mission-control: governor report — rate-limit backoff, cooldown breaker"
```

---

### Task 3: governor_daily — digest, push, export, housekeeping

**Files:**
- Modify: `plugins/mission-control/scripts/governor.sh` (replace stub `governor_daily`; add `_digest_snippet`, `_warnings_section`, `_spend_section`, `_orphans_mark`, `_housekeeping` helpers above it)
- Create: `plugins/mission-control/tests/governor-daily.tests.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–2 plus `run_in`, `slot_free`, `hour_now`, `SCRIPT_DIR` (notify.sh).
- Produces: `governor_daily` writing `MC_STATE_DIR/digests/<date>.md` once per day after `digest_hour`, pushing warnings+spend, copying to `digest_export_path` if set, deleting dispatch records older than `retention_days`, marking orphans.

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/governor-daily.tests.sh`:

```bash
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
run() { local e="$1"; shift; PATH="$TD/bin:$PATH" MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$e" bash -c "source '$MC'; $1"; }
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
run "$NOW" "state_set '.projects.prod.probe_failures = 4'"

t "daily writes digest with all sections" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  run '"$NOW"' governor_daily || exit 1
  f="$TD/state/digests/'"$D"'.md"
  grep -q "^# Mission control digest" "$f" &&
  grep -q "^## Project: prod" "$f" && grep -q "shipped PR #42" "$f" &&
  grep -q "^## Project: meta1" "$f" && grep -q "lesson shipped" "$f" &&
  grep -q "^## Mission control warnings" "$f" && grep -q "probe failing x4: prod" "$f" &&
  grep -q "^## Spend & pass summary" "$f" && grep -q "pool claude: 1 passes (quota 6/day)" "$f"'
t "push sent with spend + warnings" bash -c '
  grep -q "Spend & pass summary" "'"$CURL_CALLS"'" && grep -q "probe failing" "'"$CURL_CALLS"'"'
t "export copy exists" test -f "$TD/export/$D.md"
t "orphan marked" bash -c '
  jq -e ".outcome == \"orphaned\"" "'"$TD"'/state/dispatches/20261108T000000Z-B-meta1.json"'
t "retention deleted ancient record" bash -c '[ ! -f "'"$TD"'/state/dispatches/ancient-A-x.log" ]'
t "idempotent per day" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  : > "'"$CURL_CALLS"'"
  run '"$NOW"' governor_daily && [ ! -s "'"$CURL_CALLS"'" ]'
t "spend survives counter reset (window from records)" bash -c '
  '"$(declare -f run)"'; TD="'"$TD"'"; MC="'"$MC"'"
  run '"$NOW"' "state_set \".pools.claude.passes_today = 0\"" 
  grep -q "pool claude: 1 passes" "$TD/state/digests/'"$D"'.md"'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/mission-control/tests/governor-daily.tests.sh`
Expected: FAIL — stub daily is a no-op, no digest file.

- [ ] **Step 3: Implement — replace stub `governor_daily` with helpers + body**

```bash
_digest_snippet() { # runs INSIDE the project container/cwd; resolves digest.sh
  cat <<'SNIP'
DS="plugins/saas-startup-team/scripts/digest.sh"
if [ ! -f "$DS" ]; then
  CACHE_ROOT="${CLAUDE_HOME:-$HOME/.claude}/plugins/cache"
  DS="$(find "$CACHE_ROOT" -path '*/saas-startup-team/*/scripts/digest.sh' -type f 2>/dev/null |
    awk 'BEGIN{best=""}
      function vk(p, r,a,s,i,o){split(p,r,"/saas-startup-team/");split(r[2],a,"/");split(a[1],s,".");o="v";for(i=1;i<=4;i++)o=o sprintf("%09d",s[i]+0);return o}
      {k=vk($0); if(k>=best){best=k;sel=$0}} END{print sel}')"
fi
if [ -n "$DS" ] && [ -f "$DS" ]; then
  f="$(bash "$DS" assemble)" && cat "$f" && bash "$DS" mark-sent >/dev/null
else
  echo "_no digest.sh found in this project_"
fi
SNIP
}

_orphans_mark() { # stale dispatch log, no outcome json, slot free, >120min old
  local logf base slot
  for logf in "$MC_STATE_DIR/dispatches/"*.log; do
    [ -f "$logf" ] || continue
    base="${logf%.log}"
    [ -f "$base.json" ] && continue
    slot="$(basename "$base" | sed -E 's/^[^-]*-([AB])-.*$/\1/')"
    slot_free "$slot" || continue
    find "$logf" -mmin +120 2>/dev/null | grep -q . || continue
    jq -n --arg b "$(basename "$base")" '{outcome:"orphaned", dispatch:$b}' > "$base.json"
    echo "- orphaned dispatch: $(basename "$base")"
  done
}

_warnings_section() { # prints warning lines (or nothing)
  jq -r --arg now "$(now)" '
    ((.projects // {}) | to_entries[] | select((.value.probe_failures // 0) >= 3)
      | "- probe failing x\(.value.probe_failures): \(.key)"),
    ((.projects // {}) | to_entries[] | select((.value.cooldown_until // 0) > ($now|tonumber))
      | "- cooldown active: \(.key) until \(.value.cooldown_until | todate)"),
    ((.admissions // {}) | to_entries[] | select((.value.admitted_at // 0) == 0 and (.value.requested_at // 0) != 0)
      | "- admission pending: \(.key) (requested \(.value.requested_at | todate))")
  ' "$MC_STATE_DIR/state.json"
  _orphans_mark
}

_spend_section() { # <last_sent_date> — from outcome records, not live counters
  local since=0 f eng p
  [ -z "$1" ] || since="$(date -d "$1" +%s 2>/dev/null || echo 0)"
  declare -A pool_of=() pool_count=()
  while IFS=$'\t' read -r eng p; do pool_of[$eng]="$p"; done \
    < <(jq -r '.engines | to_entries[] | [.key, .value.pool] | @tsv' "$MC_CONFIG")
  local any=0
  for f in "$MC_STATE_DIR/dispatches/"*.json; do
    [ -f "$f" ] || continue
    jq -e --arg s "$since" '(.started_at // 0) >= ($s|tonumber)' "$f" >/dev/null || continue
    any=1
    jq -r '"- \(.started_at | todate) slot \(.slot): \(.project) (\(.engine)) -> \(.outcome)"' "$f"
    eng="$(jq -r '.engine // "unknown"' "$f")"
    p="${pool_of[$eng]:-unknown}"
    pool_count[$p]=$(( ${pool_count[$p]:-0} + 1 ))
  done
  [ "$any" -eq 1 ] || echo "_No passes in window._"
  echo
  local pool q bu
  while IFS= read -r pool; do
    q="$(cfg ".pools[\"$pool\"].daily_pass_quota // \"unlimited\"")"
    bu="$(state_get ".pools[\"$pool\"].backoff_until // 0")"
    if [ "$bu" -gt "$(now)" ]; then bu="backoff until $(date -d "@$bu" +%FT%T)"; else bu="no backoff"; fi
    echo "- pool $pool: ${pool_count[$pool]:-0} passes (quota $q/day), $bu"
  done < <(jq -r '.pools | keys[]' "$MC_CONFIG")
}

_housekeeping() {
  local rd; rd="$(cfg '.retention_days // 14')"
  find "$MC_STATE_DIR/dispatches" -type f -mtime +"$rd" -delete 2>/dev/null || true
}

governor_daily() {
  local d hour last
  d="$(today)"; hour="$(cfg '.digest_hour // 7')"
  last="$(state_get '.digest.last_sent_date // ""')"
  [ "$last" = "$d" ] && return 0                 # guard FIRST: no-op path = 1 jq read
  [ "$(hour_now)" -ge "$hour" ] || return 0

  local out="$MC_STATE_DIR/digests/$d.md" n stage c rp
  {
    echo "# Mission control digest — $d"
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      stage="$(pj "$n" '.stage')"; c="$(pj "$n" '.container')"; rp="$(pj "$n" '.repo_path')"
      echo; echo "## Project: $n"
      if [ "$stage" = "meta" ]; then
        run_in "$c" "$rp" "find .startup/lessons-deliver/runs -type f -name '*.md' 2>/dev/null | sort | tail -5 | while read -r f; do echo \"### \$f\"; cat \"\$f\"; done" 60 \
          || echo "_meta digest unavailable_"
      else
        run_in "$c" "$rp" "$(_digest_snippet)" 120 || echo "_digest unavailable for $n_"
      fi
    done < <(jq -r '.projects[].name' "$MC_CONFIG")
    echo; echo "## Mission control warnings"
    local w; w="$(_warnings_section)"
    if [ -n "$w" ]; then printf '%s\n' "$w"; else echo "_None._"; fi
    echo; echo "## Spend & pass summary"
    _spend_section "$last"
  } > "$out"

  local var; var="$(cfg '.notify_env // empty')"
  if [ -n "$var" ]; then
    { awk '/^## Needs-human/{f=1;print;next} /^## /{f=0} f' "$out"
      awk '/^## Mission control warnings/,/^## Spend/' "$out" | grep -v '^## Spend'
      awk '/^## Spend & pass summary/,0' "$out"
    } | head -c 3500 | bash "$SCRIPT_DIR/notify.sh" "$var" "mission-control digest $d"
  fi

  local exp; exp="$(cfg '.digest_export_path // empty')"
  if [ -n "$exp" ]; then
    mkdir -p "$exp" && cp "$out" "$exp/" || alert digest-export "cannot copy digest to $exp"
  fi
  _housekeeping
  state_set '.digest.last_sent_date = $d' --arg d "$d"
  log "digest written: $out"
}
```

Spec deviation to preserve, already accepted: orphan grace is a fixed 120 min (default envelope 90 + 30 grace) because the envelope of a crashed pass is not recorded in its artifacts; a longer-envelope pass could be falsely marked orphaned only if it also crashed its wrapper — cosmetic, warning-only.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/governor-daily.tests.sh`
Expected: `pass=7 fail=0`. Full suite green — note the #198 tick tests run `governor_daily` at the end of each tick now; their configs have no `digest_hour`, so default 7 applies and `hour_now` may be past 7 in a real run: those tick-test configs get digests written into their temp state dirs, which is harmless, but if any tick test asserts an empty state dir, scope the assertion to `dispatches/`. Verify and adjust only if a #198 test actually breaks.

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts/governor.sh plugins/mission-control/tests/governor-daily.tests.sh
git commit -m "mission-control: governor daily digest, push, export, housekeeping"
```

---

### Task 4: Version bump + docs

**Files:**
- Modify: `plugins/mission-control/.claude-plugin/plugin.json` (`0.1.0` → `0.2.0`)
- Modify: `.claude-plugin/marketplace.json` (mission-control entry `0.1.0` → `0.2.0`)
- Modify: `plugins/mission-control/README.md` (governor section)
- Modify: `plugins/mission-control/docs/runbook.md` (digest note)

- [ ] **Step 1: Bump both versions**

In `plugins/mission-control/.claude-plugin/plugin.json` and the mission-control entry of root `.claude-plugin/marketplace.json`: `"version": "0.2.0"`.

- [ ] **Step 2: README — append after the "Engine routing" section:**

```markdown
## Budget governor

Behavioral, not a ledger (remaining subscription quota is not reliably
readable): per-pool daily pass quotas (`pools.<name>.daily_pass_quota`,
absent = unlimited), per-pass wall-clock envelopes
(`pass_timeout_minutes` on engine or project, default 90), rate-limit
backoff (parsed reset time when the CLI prints one, else exponential
30m/1h/2h/4h) with clean resume on the next tick, and a 3-strike 24h
per-project cooldown. A daily digest lands in `state/digests/<date>.md`
(pushed via `notify_env`, copied to `digest_export_path` if set) with a
Spend & pass summary computed from dispatch outcome records. Passes are
never asked to economize — an over-budget pass is simply not dispatched.
```

- [ ] **Step 3: Runbook — append:**

```markdown
9. **Digest.** The daily digest (first tick after `digest_hour`, default 7)
   aggregates each project's own digest, then warnings and the spend
   summary. When mission-control owns a project's digest delivery, disable
   that project's own digest send wiring (monitor-nightly) — two senders
   race the mark-sent cursor and double-deliver.
```

- [ ] **Step 4: Full suite + syntax check**

Run: `bash plugins/mission-control/tests/run-tests.sh && bash -n plugins/mission-control/scripts/governor.sh`
Expected: all green.

Run: `jq -r '.version' plugins/mission-control/.claude-plugin/plugin.json; jq -r '.plugins[] | select(.name=="mission-control").version' .claude-plugin/marketplace.json`
Expected: `0.2.0` twice.

- [ ] **Step 5: Commit (closes the issue)**

```bash
git add plugins/mission-control .claude-plugin/marketplace.json
git commit -m "mission-control 0.2.0: budget governor — quotas, backoff, envelopes, daily digest

Closes #199"
```

---

## Post-plan notes for the supervising session (not the implementer)

- Codex surface + `.agents/plugins/marketplace.json` regeneration happen in
  the supervised session after merge (`python3 scripts/sync-codex-marketplace.py`),
  outside the loop firewall.
- After both plans merge: arm on the real host per the runbook (human pastes
  the cron line; delete the standalone lessons-deliver line).
