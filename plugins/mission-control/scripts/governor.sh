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

# Post-pass accounting; print the outcome word (ok|rate-limit|timeout|error).
governor_report() { # <engine> <project> <exit_code> <log_path>
  if [ "$3" -eq 0 ]; then echo ok; else echo error; fi
}

# Daily digest/housekeeping; owns its own once-per-day guard. Stub: no-op.
governor_daily() {
  return 0
}
