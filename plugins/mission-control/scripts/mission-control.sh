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
  if [ "$DRY_RUN" = 1 ]; then echo "$*"; fi
}

state_get() { jq -r "$1" "$MC_STATE_DIR/state.json"; }
state_set() { # <jq-program> [jq options...]  — atomic under state.lock
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
    timeout "$t" $DOCKER_CMD exec "$c" bash -c "cd $(printf %q "$rp") && $snip"
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
    [ "$DRY_RUN" = 1 ] || state_set '.projects[$n].probe_failures = ((.projects[$n].probe_failures // 0) + 1)' --arg n "$name"
    log "probe failed project=$name rc=$rc"
    return 1              # fail toward idle: treated as no work
  fi
  [ "$DRY_RUN" = 1 ] || state_set '.projects[$n].probe_failures = 0' --arg n "$name"
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

# ADMISSION-ELIGIBLE-PLACEHOLDER (Task 5)
admission_eligible() { return 1; }

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
# ADMISSION-FUNCTIONS-PLACEHOLDER (Task 5)
# DISPATCH-FUNCTIONS-PLACEHOLDER (Task 6)

cmd_tick() {
  echo "mission-control: tick not implemented yet" >&2; exit 3
}

cmd_arm() {
  # Validate config, then PRINT the arming instructions. Never installs.
  jq -e . "$MC_CONFIG" >/dev/null
  local bad
  bad="$(jq -r '. as $c | .projects[] | select(($c.engines[.engine] // null) == null) | .name' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: unknown engine on project(s): $bad" >&2; exit 2; fi
  bad="$(jq -r '.projects[].name | select(test("^[A-Za-z0-9_-]+$") | not)' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: project names must match ^[A-Za-z0-9_-]+$: $bad" >&2; exit 2; fi
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

*/30 * * * * bash $script tick --config $MC_CONFIG >> $MC_STATE_DIR/cron.log 2>&1

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
  ls -1t "$MC_STATE_DIR/dispatches/" 2>/dev/null | grep '\.json$' | head -10 | while read -r f; do
    jq -r '"  \(.started_at | todate) \(.slot) \(.project) (\(.engine)) -> \(.outcome)"' "$MC_STATE_DIR/dispatches/$f"
  done
}

cmd_wrapper() {
  echo "mission-control: wrapper not implemented yet" >&2; exit 3
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
