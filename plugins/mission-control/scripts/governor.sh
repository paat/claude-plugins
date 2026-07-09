#!/bin/bash
# governor.sh — budget policy library sourced by mission-control.sh AFTER its
# helpers are defined; may use cfg/state_get/state_set/now/today/alert and
# the exported MC_CONFIG / MC_STATE_DIR. This is the #198 STUB: permissive,
# stateless. #199 replaces the bodies; the signatures are the contract.

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

# Daily digest/housekeeping; owns its own once-per-day guard. Stub: no-op.
governor_daily() {
  return 0
}
