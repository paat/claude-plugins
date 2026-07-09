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

[ "${MC_LIB_ONLY:-0}" = 1 ] && return 0

# ---------- subcommand bodies ----------
# LADDER-FUNCTIONS-PLACEHOLDER (Task 4)
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

case "$CMD" in
  tick)    cmd_tick ;;
  arm)     cmd_arm ;;
  status)  cmd_status ;;
  wrapper) cmd_wrapper ;;
  *) usage ;;
esac
