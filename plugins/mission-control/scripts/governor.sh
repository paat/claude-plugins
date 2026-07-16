#!/bin/bash
# governor.sh — budget policy library sourced by mission-control.sh AFTER its
# helpers are defined; may use cfg/pj/state_get/state_set/now/today/hour_now/
# run_in/slot_free/alert/log and the exported MC_CONFIG / MC_STATE_DIR.
# The four governor_* functions are the scheduler's contract (#198 spec).

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
  if [ "$(cfg ".pools | has(\"$pool\")")" != "true" ]; then
    alert "config-pool-$pool" "engine '$engine' references undefined pool '$pool' — refusing dispatch"
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

# Built-in rate-limit signatures (case-insensitive grep -E). Config may add
# per-engine extras via engines.<name>.rate_limit_patterns.
RL_BUILTIN='429|rate.?limit|usage limit|quota exceeded|limit (will )?reset|overloaded'

_gov_backoff() { # <pool> <log_path> — set backoff_until (parsed reset or exponential)
  local pool="$1" logf="$2" ts="" until_e="" lvl mins
  ts="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:?[0-9]{2})?' "$logf" 2>/dev/null | head -1 || true)"
  if [ -z "$ts" ]; then
    ts="$(grep -oiE 'reset[s]?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)' "$logf" 2>/dev/null \
          | head -1 | sed -E 's/^[Rr]eset[s]?( at)? //' || true)"
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

governor_report() { # <engine> <project> <exit_code> <log_path> [delivery_hold]
  local engine="$1" name="$2" rc="$3" logf="$4" delivery_hold="${5:-}" pool patterns extra outcome errs blk
  [ -n "$delivery_hold" ] || delivery_hold="$(pj "$name" '.delivery_hold // false')"
  pool="$(cfg ".engines[\"$engine\"].pool // \"unknown\"")"
  patterns="$RL_BUILTIN"
  extra="$(cfg "(.engines[\"$engine\"].rate_limit_patterns // []) | join(\"|\")")"
  [ -z "$extra" ] || patterns="$patterns|$extra"
  # Line-anchored: prose merely mentioning the sentinel must not classify.
  blk="$(grep -oE '^MC-BLOCKED([[:space:]].*)?$' "$logf" 2>/dev/null | tail -1 || true)"
  if [ "$delivery_hold" = true ] && [ "$rc" -eq 75 ]; then outcome="deferred"
  elif [ "$delivery_hold" = true ] && [ "$rc" -eq 78 ]; then outcome="config-error"
  elif grep -qiE "$patterns" "$logf" 2>/dev/null; then
    outcome="rate-limit"                       # wins even over exit 0
    _gov_backoff "$pool" "$logf"
  elif [ -n "$blk" ]; then outcome="blocked"   # declared terminal state, any rc
  elif [ "$rc" -eq 124 ]; then outcome="timeout"
  elif [ "$rc" -eq 0 ]; then outcome="ok"
  else outcome="error"
  fi
  case "$outcome" in
    ok)
      state_set '.pools[$p].backoff_level = 0 | .projects[$n].consecutive_errors = 0
                 | del(.projects[$n].blocked_until) | del(.projects[$n].blocked_reason)' \
        --arg p "$pool" --arg n "$name" ;;
    blocked)
      # Not a failure: no strike, no pool backoff. The pass declared the block
      # and its recheck window; the ladder pivots to other work until it expires.
      local mins reason
      mins="$(printf '%s' "$blk" | grep -oE 'recheck_after=[0-9]+' | head -1 | cut -d= -f2 || true)"
      [ -n "$mins" ] || mins="$(cfg '.blocked_default_recheck_minutes // 360')"
      case "$mins" in ''|*[!0-9]*) mins=360 ;; esac
      [ "$mins" -ge 5 ] || mins=5
      [ "$mins" -le 10080 ] || mins=10080
      reason="$(printf '%s' "$blk" | sed -E 's/^MC-BLOCKED *//; s/recheck_after=[0-9]+ *//; s/^reason= *//')"
      [ -n "$reason" ] || reason="unspecified"
      state_set '.projects[$n].consecutive_errors = 0
                 | .projects[$n].blocked_until = ($u|tonumber)
                 | .projects[$n].blocked_reason = $r' \
        --arg n "$name" --arg u "$(( $(now) + mins * 60 ))" --arg r "$reason"
      log "blocked project=$name recheck_in=${mins}m reason=$reason" ;;
    deferred)
      log "deferred project=$name delivery hold busy" ;;
    config-error|timeout|error)
      if [ "$outcome" = config-error ]; then
        alert "delivery-config-$name" "$name: delivery hold launcher rejected the container configuration (exit 78)"
      fi
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
    jq -n --arg b "$(basename "$base")" '{outcome:"orphaned", dispatch:$b}' > "$base.json.tmp"
    mv "$base.json.tmp" "$base.json"
    echo "- orphaned dispatch: $(basename "$base")"
  done
}

_digest_extra_sections() {
  # Optional .digest_sections_dir: every *.md file (sorted) is appended
  # verbatim as digest sections; files are expected to start with "## ".
  local secdir sf
  secdir="$(cfg '.digest_sections_dir // ""')"
  [ -n "$secdir" ] && [ -d "$secdir" ] || return 0
  for sf in "$secdir"/*.md; do
    [ -f "$sf" ] || continue
    cat "$sf"
    echo
  done
}

_warnings_section() { # prints warning lines (or nothing)
  jq -r --arg now "$(now)" '
    ((.projects // {}) | to_entries[] | select((.value.probe_failures // 0) >= 3)
      | "- probe failing x\(.value.probe_failures): \(.key)"),
    ((.projects // {}) | to_entries[] | select((.value.cooldown_until // 0) > ($now|tonumber))
      | "- cooldown active: \(.key) until \(.value.cooldown_until | todate)"),
    ((.projects // {}) | to_entries[] | select((.value.blocked_until // 0) > ($now|tonumber))
      | "- blocked: \(.key) — \(.value.blocked_reason // "unspecified") (recheck \(.value.blocked_until | todate))"),
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
    jq -e --arg s "$since" '(.started_at // 0) > 0 and (.started_at // 0) >= ($s|tonumber)' "$f" >/dev/null || continue
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
        run_in "$c" "$rp" "$(_digest_snippet)" 120 || echo "_digest unavailable for ${n}_"
      fi
    done < <(jq -r '.projects[].name' "$MC_CONFIG")
    _digest_extra_sections
    echo; echo "## Mission control warnings"
    local w; w="$(_warnings_section)"
    if [ -n "$w" ]; then printf '%s\n' "$w"; else echo "_None._"; fi
    echo; echo "## Spend & pass summary"
    _spend_section "$last"
  } > "$out"

  local var; var="$(cfg '.notify_env // empty')"
  if [ -n "$var" ]; then
    { _digest_extra_sections
      awk '/^## Needs-human/{f=1;print;next} /^## /{f=0} f' "$out"
      awk '/^## Mission control warnings/,/^## Spend/' "$out" | grep -v '^## Spend'
      awk '/^## Spend & pass summary/,0' "$out"
    } | head -c 3500 | bash "$SCRIPT_DIR/notify.sh" "$var" "mission-control digest $d" || true
    # || true: head's truncation SIGPIPEs the upstream awk; under pipefail that
    # would abort the daily job before last_sent_date is marked -> resend loop
  fi

  local exp; exp="$(cfg '.digest_export_path // empty')"
  if [ -n "$exp" ]; then
    mkdir -p "$exp" && cp "$out" "$exp/" || alert digest-export "cannot copy digest to $exp"
  fi
  _housekeeping
  state_set '.digest.last_sent_date = $d' --arg d "$d"
  log "digest written: $out"
}
