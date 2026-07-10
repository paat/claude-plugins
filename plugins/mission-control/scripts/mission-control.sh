#!/bin/bash
# mission-control.sh — portfolio scheduler. Deterministic bash: the tick
# spends zero LLM tokens; only dispatched passes think.
# Usage: mission-control.sh {tick|arm|status} --config <path> [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: mission-control.sh {tick|arm|status} --config <path> [--dry-run]" >&2; exit 2; }

# ---------- argument parsing (skipped when sourced as a library) ----------
CMD=""; MC_CONFIG="${MC_CONFIG:-}"; DRY_RUN=0
declare -A WRAP=()
if [ "${MC_LIB_ONLY:-0}" != 1 ]; then
  CMD="${1:-}"; shift || usage
  while [ $# -gt 0 ]; do
    case "$1" in
      --config)    MC_CONFIG="${2:?--config needs a value}"; shift 2 ;;
      --dry-run)   DRY_RUN=1; shift ;;
      --slot|--project|--engine|--container|--repo-path|--envelope|--base|--cmd)
                   WRAP[${1#--}]="${2:?$1 needs a value}"; shift 2 ;;
      *) usage ;;
    esac
  done
fi

[ -n "$MC_CONFIG" ] && [ -f "$MC_CONFIG" ] || { echo "mission-control: config not found: '$MC_CONFIG'" >&2; exit 2; }

# ---------- config / state helpers ----------
cfg() { jq -r "$1" "$MC_CONFIG"; }

MC_STATE_DIR="$(cfg '.state_dir // empty')"
[ -n "$MC_STATE_DIR" ] || MC_STATE_DIR="$(cd "$(dirname "$MC_CONFIG")" && pwd)/state"
export MC_CONFIG MC_STATE_DIR
mkdir -p "$MC_STATE_DIR/dispatches" "$MC_STATE_DIR/digests"
[ -f "$MC_STATE_DIR/state.json" ] || echo '{}' > "$MC_STATE_DIR/state.json"

DOCKER_CMD="$(cfg '.docker_cmd // "docker"')"
# Optional: run `docker exec` as this user instead of the image default.
# Needed when the container's agent toolchain (gh auth, git identity, engine
# config) lives under a non-root user reached via SSH login — `docker exec`
# skips that login and would otherwise land on the image default (often root).
DOCKER_EXEC_USER="$(cfg '.docker_exec_user // empty')"
DOCKER_USER_OPT=""
[ -n "$DOCKER_EXEC_USER" ] && DOCKER_USER_OPT="-u $DOCKER_EXEC_USER"
TZCFG="$(cfg '.timezone // empty')"

now() { echo "${MC_NOW_EPOCH:-$(date +%s)}"; }
today() {
  if [ -n "$TZCFG" ]; then TZ="$TZCFG" date -d "@$(now)" +%F; else date -d "@$(now)" +%F; fi
}
hour_now() {
  local h
  if [ -n "$TZCFG" ]; then h="$(TZ="$TZCFG" date -d "@$(now)" +%H)"; else h="$(date -d "@$(now)" +%H)"; fi
  echo "${h#0}"
}

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$MC_STATE_DIR/mission-control.log"
  # stderr, not stdout: pick_slot_* are consumed via $() and must stay clean
  if [ "$DRY_RUN" = 1 ]; then echo "$*" >&2; fi
}

state_get() { jq -r "$1" "$MC_STATE_DIR/state.json"; }
state_set() { # <jq-program> [jq options...]  — atomic under state.lock
  [ "${DRY_RUN:-0}" = 1 ] && return 0   # dry-run mutates nothing, anywhere
  local prog="$1"; shift
  (
    flock -w 10 9 || { echo "mission-control: state.lock timeout" >&2; exit 1; }
    jq "$@" "$prog" "$MC_STATE_DIR/state.json" > "$MC_STATE_DIR/.state.tmp"
    mv "$MC_STATE_DIR/.state.tmp" "$MC_STATE_DIR/state.json"
  ) 9>>"$MC_STATE_DIR/state.lock"
}

alert() { # <key> <message> — log always; push at most once per 24h per key
  local key="$1" msg="$2" last t
  t="$(now)"
  log "ALERT[$key] $msg"
  [ "$DRY_RUN" = 1 ] && return 0
  last="$(state_get ".alerts[\"$key\"] // 0")"
  [ $((t - last)) -ge 86400 ] || return 0
  state_set '.alerts[$k] = ($n|tonumber)' --arg k "$key" --arg n "$t"
  local var; var="$(cfg '.notify_env // empty')"
  [ -z "$var" ] || printf '%s\n' "$msg" | bash "$SCRIPT_DIR/notify.sh" "$var" "mission-control: $key"
}

# ---------- exec plumbing ----------
DOCKER_OK=""
docker_check() { # lazy: only called right before the tick's first docker use
  [ -z "$DOCKER_OK" ] || return 0
  if $DOCKER_CMD info >/dev/null 2>&1; then DOCKER_OK=1; return 0; fi
  alert docker-preflight "docker unreachable via '$DOCKER_CMD'"
  return 1
}

run_in() { # <container> <repo_path> <snippet> <timeout_s> — non-login bash -c
  local c="$1" rp="$2" snip="$3" t="${4:-30}"
  if [ "$c" = "local" ]; then
    timeout "$t" bash -c "cd $(printf %q "$rp") && $snip"
  else
    docker_check || return 1
    timeout "$t" $DOCKER_CMD exec $DOCKER_USER_OPT "$c" bash -c "cd $(printf %q "$rp") && $snip"
  fi
}

slot_free() { # <A|B> — test-acquire without holding
  ( flock -n 9 ) 9>>"$MC_STATE_DIR/slot-$1.lock"
}

# project helpers: pj <name> <jq-filter over the project object>
pj() { jq -r --arg n "$1" ".projects[] | select(.name == \$n) | $2" "$MC_CONFIG"; }

# ---------- governor ----------
# shellcheck source=governor.sh
source "${MC_GOVERNOR:-$SCRIPT_DIR/governor.sh}"

# ---------- subcommand bodies ----------
# ---------- probes & ladder ----------
EXCLUDE_LABELS='"needs-human","maintain:blocked","lessons:blocked","lessons:needs-human","epic"'

probe_run() { # <name> <snippet> — run probe, maintain probe_failures streak
  local name="$1" snip="$2" c rp out rc
  c="$(pj "$name" '.container')"; rp="$(pj "$name" '.repo_path')"
  set +e; out="$(run_in "$c" "$rp" "$snip" 30)"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    state_set '.projects[$n].probe_failures = ((.projects[$n].probe_failures // 0) + 1)' --arg n "$name"
    log "probe failed project=$name rc=$rc"
    return 1              # fail toward idle: treated as no work
  fi
  state_set '.projects[$n].probe_failures = 0' --arg n "$name"
  [ -n "$out" ]
}

default_work_probe() { # <stage>
  if [ "$1" = "meta" ]; then
    printf '%s' "gh issue list --state open --label lesson-approved --limit 50 --json number,labels --jq 'first(.[] | select(([.labels[].name] | map(IN($EXCLUDE_LABELS)) | any | not)) | .number) // empty'"
  else
    printf '%s' "gh issue list --state open --limit 50 --json number,labels --jq 'first(.[] | select(([.labels[].name] | map(IN($EXCLUDE_LABELS)) | any | not)) | .number) // empty'"
  fi
}

probe_work() { # <name>
  local name="$1" snip stage
  stage="$(pj "$name" '.stage')"
  snip="$(pj "$name" '.work_probe // empty')"
  [ -n "$snip" ] || snip="$(default_work_probe "$stage")"
  probe_run "$name" "$snip"
}

probe_incident() { # <name> — any open issue with an incident label
  local name="$1" snip l
  snip="$(pj "$name" '.work_probe // empty')"
  if [ -n "$snip" ]; then probe_run "$name" "$snip"; return; fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if probe_run "$name" "gh issue list --state open --label $(printf %q "$l") --limit 1 --json number --jq '.[].number'"; then
      return 0
    fi
  done < <(pj "$name" '(.incident_labels // ["incident","production","critical"])[]')
  return 1
}

project_blocked() { # <name> — hold or active cooldown
  [ "$(pj "$1" '.hold')" = "true" ] && return 0
  local cd; cd="$(state_get ".projects[\"$1\"].cooldown_until // 0")"
  [ "$(now)" -lt "$cd" ]
}

# Engines refused by governor_reserve earlier THIS tick (set by cmd_tick's
# retry loop, Task 6). Lets the ladder continue past an exhausted pool.
declare -ga DENIED_ENGINES=()
engine_denied() { # <name> — is this project's engine denied this tick?
  local e d; e="$(pj "$1" '.engine')"
  for d in "${DENIED_ENGINES[@]:-}"; do [ "$d" = "$e" ] && return 0; done
  return 1
}

rotate() { # <rung> <names...> — start after this rung's cursor
  local rung="$1"; shift
  [ $# -gt 0 ] || return 0
  local cur i n=$#
  cur="$(state_get ".cursor[\"$rung\"] // \"\"")"
  local -a a=("$@")
  local start=0
  for i in "${!a[@]}"; do
    if [ "${a[$i]}" = "$cur" ]; then start=$(( (i + 1) % n )); break; fi
  done
  for ((i = 0; i < n; i++)); do echo "${a[$(( (start + i) % n ))]}"; done
}

names_by_stage() { jq -r --arg s "$1" '.projects[] | select(.stage == $s) | .name' "$MC_CONFIG"; }

# ---------- admission gate (absorbed from #206) ----------
admitted_unheld_count() {
  local n c=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$(state_get ".admissions[\"$n\"].admitted_at // 0")" != 0 ] || continue
    [ "$(pj "$n" '.hold')" = "true" ] && continue
    c=$((c + 1))
  done < <(names_by_stage pre-launch)
  echo "$c"
}

admission_housekeeping() { # held + never-admitted => veto clock restarts later
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$(pj "$n" '.hold')" = "true" ] || continue
    [ "$(state_get ".admissions[\"$n\"].admitted_at // 0")" = 0 ] || continue
    [ "$(state_get ".admissions[\"$n\"].requested_at // 0")" != 0 ] || continue
    state_set 'del(.admissions[$n].requested_at)' --arg n "$n"
    log "admission clock cleared (held): $n"
  done < <(names_by_stage pre-launch)
}

admission_eligible() { # <name> — exit 0 iff admitted; advances the gate
  local name="$1" req veto
  [ "$(state_get ".admissions[\"$name\"].admitted_at // 0")" != 0 ] && return 0
  veto="$(cfg '.admission.veto_hours // 72')"
  req="$(state_get ".admissions[\"$name\"].requested_at // 0")"
  if [ "$req" != 0 ]; then
    if [ "$(now)" -ge $((req + veto * 3600)) ]; then
      state_set '.admissions[$n].admitted_at = ($t|tonumber)' --arg n "$name" --arg t "$(now)"
      log "admitted: $name"
      return 0
    fi
    return 1                                    # veto window still open
  fi
  # not yet requested: evaluate the gate (fail closed at every step)
  local cap; cap="$(cfg '.admission.wip_cap // 1')"
  [ "$(admitted_unheld_count)" -lt "$cap" ] || return 1
  local c rp conf min
  c="$(pj "$name" '.container')"; rp="$(pj "$name" '.repo_path')"
  local prc
  set +e
  conf="$(run_in "$c" "$rp" "jq -r '.validation.confidence // empty' .startup/provenance.json 2>/dev/null" 15)"
  prc=$?
  set -e
  [ "$prc" -eq 0 ] && [ -n "$conf" ] || return 1
  min="$(cfg '.admission.confidence_min // 0.7')"
  awk -v c="$conf" -v m="$min" 'BEGIN { exit !(c + 0 >= m + 0) }' || return 1
  state_set '.admissions[$n].requested_at = ($t|tonumber)' --arg n "$name" --arg t "$(now)"
  alert "admission-$name" "$name enters Slot B delivery in ${veto}h — set hold:true in portfolio.json to veto"
  return 1                                      # never dispatch on request tick
}

pick_slot_a() {
  local p; p="$(cfg '.slots.A.pinned // empty')"
  [ -n "$p" ] || return 0
  project_blocked "$p" && { log "slot A pinned $p blocked"; return 0; }
  engine_denied "$p" && return 0
  probe_work "$p" && echo "$p" || true
}

pick_slot_b() {
  local pinned n
  pinned="$(cfg '.slots.A.pinned // empty')"
  # rung 1: live incidents, excluding the pinned project
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" != "$pinned" ] || continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_incident "$n"; then state_set '.cursor["1"]=$n' --arg n "$n"; echo "1 $n"; return 0; fi
  done < <(rotate 1 $(names_by_stage live))
  # rung 2: admitted pre-launch with work
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    admission_eligible "$n" || continue
    if probe_work "$n"; then state_set '.cursor["2"]=$n' --arg n "$n"; echo "2 $n"; return 0; fi
  done < <(rotate 2 $(names_by_stage pre-launch))
  # rung 3: validation
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_work "$n"; then state_set '.cursor["3"]=$n' --arg n "$n"; echo "3 $n"; return 0; fi
  done < <(rotate 3 $(names_by_stage validation))
  # rung 4: meta
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_work "$n"; then state_set '.cursor["4"]=$n' --arg n "$n"; echo "4 $n"; return 0; fi
  done < <(rotate 4 $(names_by_stage meta))
  return 0
}
# ---------- dispatch ----------
dispatch() { # <slot> <name> — reserve, take slot lock on an FD, spawn wrapper
  local slot="$1" name="$2"
  local engine container rp command tmpl rendered env_min base lfd
  engine="$(pj "$name" '.engine')"
  container="$(pj "$name" '.container')"
  rp="$(pj "$name" '.repo_path')"
  command="$(pj "$name" '.command')"
  tmpl="$(cfg ".engines[\"$engine\"].cmd")"
  rendered="${tmpl//\{prompt\}/$command}"
  env_min="$(governor_envelope "$engine" "$name")"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY: would dispatch slot=$slot project=$name engine=$engine envelope=${env_min}m cmd: $rendered"
    return 0
  fi
  exec {lfd}>>"$MC_STATE_DIR/slot-$slot.lock"
  if ! flock -n "$lfd"; then exec {lfd}>&-; return 1; fi
  if ! governor_reserve "$engine"; then
    log "reserve refused slot=$slot project=$name engine=$engine"
    exec {lfd}>&-
    return 1
  fi
  base="$MC_STATE_DIR/dispatches/$(date -u +%Y%m%dT%H%M%SZ)-$slot-$name"
  : > "$base.log"
  log "dispatch slot=$slot project=$name engine=$engine envelope=${env_min}m"
  # Wrapper inherits the slot-lock FD: held continuously until the pass ends.
  # fd 8 (tick.lock) must NOT leak into it, or a long pass blocks every tick.
  setsid bash "$0" wrapper --config "$MC_CONFIG" --slot "$slot" --project "$name" \
    --engine "$engine" --container "$container" --repo-path "$rp" \
    --envelope "$env_min" --base "$base" --cmd "$rendered" \
    >>"$base.log" 2>&1 8>&- &
  exec {lfd}>&-   # parent's copy closed; child's inherited copy keeps the lock
  return 0
}

cmd_tick() {
  exec 8>>"$MC_STATE_DIR/tick.lock"
  flock -n 8 || exit 0                       # overlapping ticks impossible
  local d; d="$(today)"
  if [ "$DRY_RUN" != 1 ] && [ "$(state_get '.date // ""')" != "$d" ]; then
    state_set '.date = $d' --arg d "$d"      # scheduler-owned; pool counters roll in governor_reserve
  fi
  [ "$DRY_RUN" = 1 ] || admission_housekeeping
  local slot cand tries
  for slot in A B; do
    if ! slot_free "$slot"; then log "slot $slot busy"; continue; fi
    if [ "$slot" = A ]; then
      cand="$(pick_slot_a)"
      if [ -n "$cand" ]; then
        dispatch A "$cand" || { DENIED_ENGINES+=("$(pj "$cand" '.engine')"); log "slot A reserve refused: $cand"; }
      else
        log "slot A idle"
      fi
    else
      tries=0
      while :; do
        cand="$(pick_slot_b)"
        [ -n "$cand" ] || { log "slot B idle"; break; }
        dispatch B "${cand#* }" && break
        DENIED_ENGINES+=("$(pj "${cand#* }" '.engine')")
        log "slot B reserve refused: $cand — re-walking ladder without that engine"
        tries=$((tries + 1))
        [ "$tries" -lt 4 ] || break
      done
    fi
  done
  [ "$DRY_RUN" = 1 ] || governor_daily
}

cmd_arm() {
  # Validate config, then PRINT the arming instructions. Never installs.
  jq -e . "$MC_CONFIG" >/dev/null
  local bad
  bad="$(jq -r '. as $c | .projects[] | select(($c.engines[.engine] // null) == null) | .name' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: unknown engine on project(s): $bad" >&2; exit 2; fi
  bad="$(jq -r '.projects[].name | select(test("^[A-Za-z0-9_-]+$") | not)' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: project names must match ^[A-Za-z0-9_-]+$: $bad" >&2; exit 2; fi
  bad="$(jq -r '[ (.admission.wip_cap // 1), (.admission.veto_hours // 72),
                  (.admission.confidence_min // 0.7), (.digest_hour // 7), (.retention_days // 14),
                  (.pools[]?.daily_pass_quota // 0),
                  (.engines[]?.pass_timeout_minutes // 90), (.projects[]?.pass_timeout_minutes // 90) ]
                | map(select(type != "number")) | length' "$MC_CONFIG")"
  if [ "$bad" != 0 ]; then echo "mission-control: budget fields (quotas, envelopes, hours, caps) must be JSON numbers" >&2; exit 2; fi
  local pat rc
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    rc=0; printf '' | grep -qiE "$pat" || rc=$?
    if [ "$rc" -gt 1 ]; then echo "mission-control: invalid rate_limit_patterns regex: $pat" >&2; exit 2; fi
  done < <(jq -r '.engines[]?.rate_limit_patterns[]? // empty' "$MC_CONFIG")
  local pinned
  pinned="$(cfg '.slots.A.pinned // empty')"
  if [ -n "$pinned" ] && [ -z "$(pj "$pinned" '.name')" ]; then
    echo "mission-control: slots.A.pinned '$pinned' is not a project" >&2; exit 2
  fi
  local script; script="$(cd "$SCRIPT_DIR" && pwd)/mission-control.sh"
  cat <<EOF
mission-control is NOT armed by agents. A human installs ONE cron line, once.

1. Edit your persistent crontab file (on LinuxServer-style containers:
   /config/crontabs/<user> — edit the file, not 'crontab -e'). Add:

*/30 * * * * bash "$script" tick --config "$MC_CONFIG" >> "$MC_STATE_DIR/cron.log" 2>&1

2. In the same crontab file, DELETE any standalone lessons-deliver cron line —
   mission-control now dispatches lessons-deliver as Slot B's idle rung.
   Two schedulers would double-dip the same budget pools.

3. Export the push URL in the crontab environment block if you want
   notifications, e.g.:  $(cfg '.notify_env // "MC_NTFY_URL"')=https://ntfy.sh/<topic>

4. Verify before trusting it:  bash $script tick --config $MC_CONFIG --dry-run
EOF
}

cmd_status() {
  local s
  for s in A B; do
    if slot_free "$s"; then echo "slot $s: free"; else echo "slot $s: RUNNING"; fi
  done
  echo "state: $MC_STATE_DIR/state.json"
  jq '{date, pools, projects, admissions, digest}' "$MC_STATE_DIR/state.json"
  echo "recent dispatches:"
  { ls -1t "$MC_STATE_DIR/dispatches/" 2>/dev/null | grep '\.json$' | head -10 | while read -r f; do
    jq -r '"  \(.started_at | todate) \(.slot) \(.project) (\(.engine)) -> \(.outcome)"' "$MC_STATE_DIR/dispatches/$f"
  done; } || true
}

cmd_wrapper() {
  local slot="${WRAP[slot]}" name="${WRAP[project]}" engine="${WRAP[engine]}"
  local container="${WRAP[container]}" rp="${WRAP[repo-path]}"
  local envelope="${WRAP[envelope]}" base="${WRAP[base]}" rendered="${WRAP[cmd]}"
  local started rc outcome
  started="$(now)"
  set +e
  if [ "$container" = "local" ]; then
    bash -c "cd $(printf %q "$rp") && timeout ${envelope}m $rendered"
  else
    $DOCKER_CMD exec $DOCKER_USER_OPT "$container" bash -c "cd $(printf %q "$rp") && timeout ${envelope}m $rendered"
  fi
  rc=$?
  set -e
  outcome="$(governor_report "$engine" "$name" "$rc" "$base.log")"
  jq -n --arg slot "$slot" --arg p "$name" --arg e "$engine" \
        --arg s "$started" --arg t "$(now)" --arg rc "$rc" --arg o "$outcome" \
        '{slot:$slot, project:$p, engine:$e, started_at:($s|tonumber),
          ended_at:($t|tonumber), exit_code:($rc|tonumber), outcome:$o}' \
        > "$base.json.tmp"
  mv "$base.json.tmp" "$base.json"
  log "pass done slot=$slot project=$name outcome=$outcome rc=$rc"
}

# Library seam: when sourced (tests, #199 governor), define all functions
# above but run no subcommand.
[ "${MC_LIB_ONLY:-0}" = 1 ] && return 0

case "$CMD" in
  tick)    cmd_tick ;;
  arm)     cmd_arm ;;
  status)  cmd_status ;;
  wrapper) cmd_wrapper ;;
  *) usage ;;
esac
