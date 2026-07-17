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
      --slot|--project|--engine|--container|--repo-path|--envelope|--base|--cmd|--delivery-hold|--run-id)
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
if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$MC_STATE_DIR/dispatches" "$MC_STATE_DIR/digests"
  [ -f "$MC_STATE_DIR/state.json" ] || echo '{}' > "$MC_STATE_DIR/state.json"
fi

DOCKER_CMD="$(cfg '.docker_cmd // "docker"')"
# Optional: run `docker exec` as this user instead of the image default.
# Needed when the container's agent toolchain (gh auth, git identity, engine
# config) lives under a non-root user reached via SSH login — `docker exec`
# skips that login and would otherwise land on the image default (often root).
DOCKER_EXEC_USER="$(cfg '.docker_exec_user // empty')"
# charset guard: the option is expanded unquoted into argv (like docker_cmd),
# so a value with whitespace/globs would shift arguments — refuse it outright
case "$DOCKER_EXEC_USER" in *[!A-Za-z0-9_:.-]*)
  echo "mission-control: invalid docker_exec_user '$DOCKER_EXEC_USER' (allowed: [A-Za-z0-9_:.-])" >&2; exit 2 ;;
esac
DOCKER_USER_OPT=""
[ -n "$DOCKER_EXEC_USER" ] && DOCKER_USER_OPT="-u $DOCKER_EXEC_USER"
TZCFG="$(cfg '.timezone // empty')"

now() { echo "${MC_NOW_EPOCH:-$(date +%s)}"; }
now_ms() {
  if [ -n "${MC_NOW_EPOCH_MS:-}" ]; then echo "$MC_NOW_EPOCH_MS"
  elif [ -n "${MC_NOW_EPOCH:-}" ]; then echo "$((MC_NOW_EPOCH * 1000))"
  else date +%s%3N
  fi
}
today() {
  if [ -n "$TZCFG" ]; then TZ="$TZCFG" date -d "@$(now)" +%F; else date -d "@$(now)" +%F; fi
}
hour_now() {
  local h
  if [ -n "$TZCFG" ]; then h="$(TZ="$TZCFG" date -d "@$(now)" +%H)"; else h="$(date -d "@$(now)" +%H)"; fi
  echo "${h#0}"
}

log() {
  # stderr, not stdout: pick_pinned/pick_ladder are consumed via $() and must stay clean
  if [ "$DRY_RUN" = 1 ]; then echo "$*" >&2; return 0; fi
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$MC_STATE_DIR/mission-control.log"
}

state_get() {
  if [ -f "$MC_STATE_DIR/state.json" ]; then
    jq -r "$1" "$MC_STATE_DIR/state.json"
  elif [ "$DRY_RUN" = 1 ]; then
    jq -r "$1" <<< '{}'
  else
    return 1
  fi
}
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
  local c="$1" rp="$2" snip="$3" t="${4:-30}" context_var
  local -a scrub_env=() docker_scrub=()
  # Clear ambient workflow + shell-startup context before helper Bash starts so a
  # poisoned BASH_ENV/ENV or prior SAAS_* cannot rewrite preflight/accounting.
  while IFS= read -r context_var; do
    [ -n "$context_var" ] || continue
    scrub_env+=(-u "$context_var")
    docker_scrub+=(-e "$context_var=")
  done < <(workflow_context_vars)
  if [ "$c" = "local" ]; then
    env "${scrub_env[@]}" timeout "$t" bash -c "cd $(printf %q "$rp") && $snip"
  else
    docker_check || return 1
    timeout "$t" $DOCKER_CMD exec $DOCKER_USER_OPT "${docker_scrub[@]}" "$c" \
      bash -c "cd $(printf %q "$rp") && $snip"
  fi
}

slot_free() { # <slot> — test-acquire without holding
  local lock="$MC_STATE_DIR/slot-$1.lock"
  if [ "$DRY_RUN" = 1 ]; then
    [ ! -L "$lock" ] || return 1
    [ -e "$lock" ] || return 0
    [ -f "$lock" ] || return 1
    ( flock -n 9 ) 9<"$lock"
  else
    ( flock -n 9 ) 9>>"$lock"
  fi
}

new_run_id() {
  local hex
  hex="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$hex" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf 'run-%s\n' "$hex"
}

valid_run_id() { [[ "$1" =~ ^run-[0-9a-f]{32}$ ]]; }

# Transient workflow authority that must never cross a mission dispatch boundary.
# A configured command may set its own values after launch; ambient scheduler or
# container state is always cleared first.
workflow_context_vars() {
  printf '%s\n' \
    BASH_ENV ENV \
    SAAS_AGENT_EVENTS_FILE SAAS_RUN_ID SAAS_PARENT_RUN_ID SAAS_ATTEMPT \
    SAAS_COMMAND SAAS_PHASE SAAS_WRITER_ID SAAS_ROUTING_REASONS \
    SAAS_COST_MICROUNITS SAAS_TOKENS_AVAILABLE_BEFORE SAAS_TOKENS_AVAILABLE_AFTER \
    SAAS_CURRENT_CONTAINER_ID SAAS_SINGLE_FLIGHT_OWNER SAAS_EMBEDDED_CALLER \
    SAAS_EMBEDDED_WORKTREE SAAS_EMBEDDED_CLAIM SAAS_EMBEDDED_LEASE_STATE \
    SAAS_EMBEDDED_REMAINING_SECONDS SAAS_LEASE_GUARDIAN_TOKEN \
    SAAS_MAINTAIN_ESCALATION_GH_BIN SAAS_MAINTAIN_ESCALATION_HOLD_TOKEN \
    SAAS_MAINTAIN_LIVE_PROOF_ENV SAAS_MAINTAIN_QA_PROOF_ENV \
    SAAS_MAINTAIN_RESET_HOLD_TOKEN \
    MAINTAIN_BLOCKED_FILE MAINTAIN_CONTROLLER_MODE MAINTAIN_CONTROLLER_ROUTE \
    MAINTAIN_DEPLOY_RUN_ID MAINTAIN_HEAD_SHA MAINTAIN_ISSUE_NUMBER \
    MAINTAIN_LEASE_RUN_ID MAINTAIN_LEASE_STATE MAINTAIN_LIVE_TARGET_SOURCE \
    MAINTAIN_MERGE_SHA MAINTAIN_PENDING_FINGERPRINT MAINTAIN_PROOF_KIND \
    MAINTAIN_PR_NUMBER MAINTAIN_QUEUE_DEFAULT_BRANCH MAINTAIN_QUEUE_NOW
}

# Print the canonical workflow command when the configured command owns a
# schema-v2 pass terminal. This deliberately tokenizes whitespace only: it
# does not interpret shell wrappers, quoting, or substrings.
workflow_command() { # <configured command>
  local command="$1" first canonical="" word has_once=0
  local -a words=()
  read -r -a words <<< "$command"
  [ "${#words[@]}" -gt 0 ] || return 1
  first="${words[0]}"
  case "$first" in
    /maintain-loop) canonical=maintain-loop ;;
    /maintain) canonical=maintain ;;
    /goal-deliver) canonical=goal-deliver ;;
    /saas-startup-team:*|'$saas-startup-team:'*)
      canonical="${first#*:}"
      ;;
    *) return 1 ;;
  esac
  case "$canonical" in
    maintain-loop|maintain|goal-deliver) : ;;
    *) return 1 ;;
  esac
  for word in "${words[@]:1}"; do
    [ "$word" = --dry-run ] && return 1
    [ "$word" = --once ] && has_once=1
  done
  [ "$canonical" != maintain-loop ] || [ "$has_once" -eq 1 ] || return 1
  printf '%s\n' "$canonical"
}

engine_template_is_codex_exec() { # <engine command template>
  local template="$1" i=0 executable
  local -a words=()
  read -r -a words <<< "$template"
  while [ "$i" -lt "${#words[@]}" ] &&
        [[ "${words[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; do
    i=$((i + 1))
  done
  [ "$i" -lt "${#words[@]}" ] || return 1
  executable="${words[$i]##*/}"
  [ "$executable" = codex ] && [ "${words[$((i + 1))]:-}" = exec ]
}

codex_total_tokens() { # <log path> — strict last complete footer pair
  awk '
    function grouped(value, parts,count,i) {
      count=split(value, parts, ",")
      if (count < 2 || parts[1] !~ /^[0-9]+$/ || length(parts[1]) > 3) return 0
      for (i=2; i<=count; i++)
        if (parts[i] !~ /^[0-9]+$/ || length(parts[i]) != 3) return 0
      return 1
    }
    { sub(/\r$/, "", $0) }
    previous == "tokens used" &&
      ($0 ~ /^[0-9]+$/ || grouped($0)) {
        total=$0; gsub(/,/, "", total); found=1
      }
    { previous=$0 }
    END { if (found) print total }
  ' "$1" 2>/dev/null
}

_workflow_helper_binding_snippet() {
  cat <<'SNIP'
surface="$1"
case "$surface" in
  codex)
    command -v codex >/dev/null 2>&1 || exit 20
    inventory="$(codex plugin list --json 2>/dev/null)" || exit 20
    record="$(printf '%s\n' "$inventory" | jq -cer '
      [.installed[]? | select(.pluginId == "saas-startup-team@paat-plugins"
        and .installed == true and .enabled == true)]
      | if length == 1 then .[0] else error("expected one enabled install") end
    ')" || exit 20
    version="$(printf '%s\n' "$record" | jq -er '.version | select(type == "string")')" || exit 20
    root="${CODEX_HOME:-$HOME/.codex}/plugins/cache/paat-plugins/saas-startup-team/$version"
    ;;
  claude)
    command -v claude >/dev/null 2>&1 || exit 20
    inventory="$(claude plugin list --json 2>/dev/null)" || exit 20
    record="$(printf '%s\n' "$inventory" | jq -cer '
      [.[]? | select(.id == "saas-startup-team@paat-plugins"
        and .scope == "user" and .enabled == true)]
      | if length == 1 then .[0] else error("expected one enabled user install") end
    ')" || exit 20
    version="$(printf '%s\n' "$record" | jq -er '.version | select(type == "string")')" || exit 20
    root="$(printf '%s\n' "$record" | jq -er '.installPath | select(type == "string")')" || exit 20
    [ "$root" = "${CLAUDE_HOME:-$HOME/.claude}/plugins/cache/paat-plugins/saas-startup-team/$version" ] || exit 20
    ;;
  *) exit 20 ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$root" == /* ]] || exit 20
DIR="$root/scripts"; AE="$DIR/agent-events.sh"
[ -d "$DIR" ] && [ ! -L "$DIR" ] && [ "$(cd "$DIR" && pwd -P)" = "$DIR" ] || exit 20
[ -f "$AE" ] && [ ! -L "$AE" ] || exit 20
DIR="${AE%/*}"; PII="$DIR/pii-gate.sh"; ROUTE="$DIR/delivery-route.sh"
[ -f "$PII" ] && [ ! -L "$PII" ] && [ -f "$ROUTE" ] && [ ! -L "$ROUTE" ] || exit 20
command -v sha256sum >/dev/null 2>&1 || exit 20
ae_sha="$(sha256sum "$AE" | awk '{print $1}')" || exit 20
pii_sha="$(sha256sum "$PII" | awk '{print $1}')" || exit 20
route_sha="$(sha256sum "$ROUTE" | awk '{print $1}')" || exit 20
schema="$(bash "$AE" schema-version)" || exit 20
schema_version="$(printf '%s\n' "$schema" | jq -ser '
  if length == 1 and (.[0].schema_version | type == "number" and floor == .)
  then .[0].schema_version else empty end')" || exit 20
[ "$schema_version" -ge 1 ] || exit 20
printf '%s\t%s\t%s\t%s\t%s\n' "$AE" "$ae_sha" "$pii_sha" "$route_sha" "$schema_version"
SNIP
}

workflow_helper_binding() { # <container> <repo> <surface> — bind installed helper before dispatch
  local snip
  snip="set -- $(printf %q "$3"); $(_workflow_helper_binding_snippet)"
  run_in "$1" "$2" "$snip" 30
}

_workflow_account_snippet() {
  cat <<'SNIP'
AE="$1"; expected_ae="$2"; expected_pii="$3"; expected_route="$4"; expected_schema="$5"; shift 5
DIR="${AE%/*}"; PII="$DIR/pii-gate.sh"; ROUTE="$DIR/delivery-route.sh"
[ -f "$AE" ] && [ ! -L "$AE" ] && [ -f "$PII" ] && [ ! -L "$PII" ] \
  && [ -f "$ROUTE" ] && [ ! -L "$ROUTE" ] || exit 22
command -v sha256sum >/dev/null 2>&1 || exit 22
[ "$(sha256sum "$AE" | awk '{print $1}')" = "$expected_ae" ] \
  && [ "$(sha256sum "$PII" | awk '{print $1}')" = "$expected_pii" ] \
  && [ "$(sha256sum "$ROUTE" | awk '{print $1}')" = "$expected_route" ] || exit 22
[ "$expected_schema" -ge 2 ] || exit 20
run_id="$1"; duration_ms="$2"; total_tokens="${3:-}"
args=(account --run-id "$run_id" --duration-ms "$duration_ms")
[ -z "$total_tokens" ] || args+=(--total-tokens "$total_tokens")
bash "$AE" "${args[@]}"
SNIP
}

workflow_account() { # <container> <repo> <binding> <run-id> <duration-ms> [total-tokens]
  local c="$1" rp="$2" binding="$3" run_id="$4" duration_ms="$5" total_tokens="${6:-}" snip
  local ae ae_sha pii_sha route_sha schema_version extra=""
  IFS=$'\t' read -r ae ae_sha pii_sha route_sha schema_version extra <<< "$binding"
  [ -n "$ae" ] && [[ "$ae" == /* ]] && [ -z "$extra" ] \
    && [[ "$ae_sha" =~ ^[0-9a-f]{64}$ ]] && [[ "$pii_sha" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$route_sha" =~ ^[0-9a-f]{64}$ ]] && [[ "$schema_version" =~ ^[0-9]+$ ]] || return 20
  snip="set -- $(printf %q "$ae") $(printf %q "$ae_sha") $(printf %q "$pii_sha") $(printf %q "$route_sha") $(printf %q "$schema_version") $(printf %q "$run_id") $(printf %q "$duration_ms") $(printf %q "$total_tokens"); $(_workflow_account_snippet)"
  run_in "$c" "$rp" "$snip" 30
}

valid_account_json() { # <json> <run-id> <command> <duration-ms> [footer]
  local payload="$1" run_id="$2" command="$3" duration_ms="$4" footer="${5:-}"
  jq -se --arg run_id "$run_id" --arg command "$command" \
    --arg duration_ms "$duration_ms" --arg footer "$footer" '
      def uint: type == "number" and . >= 0 and floor == .;
      def registered_terminal_reason:
        . != null and IN(
          "invalid_workflow_state","context_binding_violation","false_success",
          "probe_failed","triage_failed","delivery_failed","verification_failed",
          "lease_conflict","receipt_conflict","budget_exhausted","timeout","rate_limited",
          "delivery_hold","cancelled","escalated","unknown_failure");
      length == 1 and (.[0] |
        type == "object" and
        .schema_version == 2 and .run_id == $run_id and .command == $command and
        .phase == "pass-outcome" and .parent_run_id == null and
        .event_type == "accounted" and .duration_ms == ($duration_ms|tonumber) and
        ((.outcome | IN("success","no-op","skipped")) and .terminal_reason == null or
         (.outcome | IN("blocked","failure","escalated","cancelled")) and
           (.terminal_reason | registered_terminal_reason)) and
        (.total_tokens == null or (.total_tokens | uint)) and
        ($footer == "" or .total_tokens == ($footer|tonumber)))
    ' <<< "$payload" >/dev/null 2>&1
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

project_blocked() { # <name> — hold, active cooldown, or declared MC-BLOCKED window
  [ "$(pj "$1" '.hold')" = "true" ] && return 0
  local cd bu t; t="$(now)"
  cd="$(state_get ".projects[\"$1\"].cooldown_until // 0")"
  [ "$t" -lt "$cd" ] && return 0
  bu="$(state_get ".projects[\"$1\"].blocked_until // 0")"
  [ "$t" -lt "$bu" ]
}

# Engines refused by governor_reserve earlier THIS tick (set by cmd_tick's
# retry loop, Task 6). Lets the ladder continue past an exhausted pool.
declare -ga DENIED_ENGINES=()
engine_denied() { # <name> — is this project's engine denied this tick?
  local e d; e="$(pj "$1" '.engine')"
  for d in "${DENIED_ENGINES[@]:-}"; do [ "$d" = "$e" ] && return 0; done
  return 1
}

# Projects dispatched earlier THIS tick (pinned slots walk first). Later
# ladder slots skip them: two slots must never run the same repo at once.
declare -ga DISPATCHED_PROJECTS=()
project_dispatched() { # <name>
  local d
  for d in "${DISPATCHED_PROJECTS[@]:-}"; do [ "$d" = "$1" ] && return 0; done
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

slot_names() { # <pinned|ladder> — slot keys of that class, sorted
  jq -r --arg w "$1" '.slots // {} | to_entries | sort_by(.key)[]
    | select((.value | has("pinned")) == ($w == "pinned")) | .key' "$MC_CONFIG"
}

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
  alert "admission-$name" "$name enters ladder delivery in ${veto}h — set hold:true in portfolio.json to veto"
  return 1                                      # never dispatch on request tick
}

pinned_anywhere() { # <name> — is this project pinned on any slot?
  jq -e --arg n "$1" '[.slots // {} | .[] | .pinned // empty] | index($n) != null' \
    "$MC_CONFIG" >/dev/null
}

pick_pinned() { # <slot>
  local slot="$1" p
  p="$(jq -r --arg s "$slot" '.slots[$s].pinned // empty' "$MC_CONFIG")"
  [ -n "$p" ] || return 0
  project_blocked "$p" && { log "slot $slot pinned $p blocked"; return 0; }
  engine_denied "$p" && return 0
  probe_work "$p" && echo "$p" || true
}

pick_ladder() {
  local n
  # rung 1: live incidents, excluding every pinned project
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pinned_anywhere "$n" && continue
    project_dispatched "$n" && continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_incident "$n"; then state_set '.cursor["1"]=$n' --arg n "$n"; echo "1 $n"; return 0; fi
  done < <(rotate 1 $(names_by_stage live))
  # rung 2: admitted pre-launch with work
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_dispatched "$n" && continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    admission_eligible "$n" || continue
    if probe_work "$n"; then state_set '.cursor["2"]=$n' --arg n "$n"; echo "2 $n"; return 0; fi
  done < <(rotate 2 $(names_by_stage pre-launch))
  # rung 3: validation
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_dispatched "$n" && continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_work "$n"; then state_set '.cursor["3"]=$n' --arg n "$n"; echo "3 $n"; return 0; fi
  done < <(rotate 3 $(names_by_stage validation))
  # rung 4: meta
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_dispatched "$n" && continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_work "$n"; then state_set '.cursor["4"]=$n' --arg n "$n"; echo "4 $n"; return 0; fi
  done < <(rotate 4 $(names_by_stage meta))
  return 0
}
# ---------- dispatch ----------
dispatch() { # <slot> <name> — reserve, take slot lock on an FD, spawn wrapper
  local slot="$1" name="$2"
  local engine container rp command tmpl rendered delivery_hold env_min base lfd run_id
  engine="$(pj "$name" '.engine')"
  container="$(pj "$name" '.container')"
  rp="$(pj "$name" '.repo_path')"
  command="$(pj "$name" '.command')"
  tmpl="$(cfg ".engines[\"$engine\"].cmd")"
  rendered="${tmpl//\{prompt\}/$command}"
  delivery_hold="$(pj "$name" '.delivery_hold // false')"
  env_min="$(governor_envelope "$engine" "$name")"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY: would dispatch slot=$slot project=$name engine=$engine delivery_hold=$delivery_hold envelope=${env_min}m cmd: $rendered"
    return 0
  fi
  exec {lfd}>>"$MC_STATE_DIR/slot-$slot.lock"
  if ! flock -n "$lfd"; then exec {lfd}>&-; return 1; fi
  if ! governor_reserve "$engine"; then
    log "reserve refused slot=$slot project=$name engine=$engine"
    exec {lfd}>&-
    return 1
  fi
  run_id="$(new_run_id)" || {
    log "run-id mint failed slot=$slot project=$name"
    exec {lfd}>&-
    return 1
  }
  base="$MC_STATE_DIR/dispatches/$(date -u +%Y%m%dT%H%M%SZ)-$slot-$name"
  : > "$base.log"
  log "dispatch slot=$slot project=$name engine=$engine envelope=${env_min}m"
  # Wrapper inherits the slot-lock FD: held continuously until the pass ends.
  # fd 8 (tick.lock) must NOT leak into it, or a long pass blocks every tick.
  # Wrapper Bash must not inherit ambient BASH_ENV/ENV or prior workflow context.
  local context_var
  local -a wrapper_env=()
  while IFS= read -r context_var; do
    [ -n "$context_var" ] || continue
    wrapper_env+=(-u "$context_var")
  done < <(workflow_context_vars)
  setsid env "${wrapper_env[@]}" bash "$0" wrapper --config "$MC_CONFIG" --slot "$slot" --project "$name" \
    --engine "$engine" --container "$container" --repo-path "$rp" \
    --envelope "$env_min" --base "$base" --cmd "$rendered" --delivery-hold "$delivery_hold" \
    --run-id "$run_id" \
    >>"$base.log" 2>&1 8>&- &
  exec {lfd}>&-   # parent's copy closed; child's inherited copy keeps the lock
  return 0
}

cmd_tick() {
  local state_file="$MC_STATE_DIR/state.json"
  if [ "$DRY_RUN" != 1 ]; then
    exec 8>>"$MC_STATE_DIR/tick.lock"
    flock -n 8 || exit 0                     # overlapping ticks impossible
  elif [ -e "$state_file" ] || [ -L "$state_file" ]; then
    if [ ! -f "$state_file" ] || ! jq -e 'type == "object"' "$state_file" >/dev/null 2>&1; then
      log "state error: state.json must be a readable JSON object — refusing dry-run"
      return 1
    fi
  fi
  case "$(cfg '.paused // false')" in
    false) ;;
    true)  log "paused: tick skipped"; exit 0 ;;
    *)     log "config error: .paused must be boolean — refusing to dispatch"; exit 0 ;;
  esac
  local d; d="$(today)"
  if [ "$DRY_RUN" != 1 ] && [ "$(state_get '.date // ""')" != "$d" ]; then
    state_set '.date = $d' --arg d "$d"      # scheduler-owned; pool counters roll in governor_reserve
  fi
  [ "$DRY_RUN" = 1 ] || admission_housekeeping
  local slot cand tries
  for slot in $(slot_names pinned); do
    if ! slot_free "$slot"; then log "slot $slot busy"; continue; fi
    cand="$(pick_pinned "$slot")"
    if [ -n "$cand" ]; then
      if dispatch "$slot" "$cand"; then DISPATCHED_PROJECTS+=("$cand")
      else DENIED_ENGINES+=("$(pj "$cand" '.engine')"); log "slot $slot reserve refused: $cand"; fi
    else
      log "slot $slot idle"
    fi
  done
  for slot in $(slot_names ladder); do
    if ! slot_free "$slot"; then log "slot $slot busy"; continue; fi
    tries=0
    while :; do
      cand="$(pick_ladder)"
      [ -n "$cand" ] || { log "slot $slot idle"; break; }
      if dispatch "$slot" "${cand#* }"; then DISPATCHED_PROJECTS+=("${cand#* }"); break; fi
      DENIED_ENGINES+=("$(pj "${cand#* }" '.engine')")
      log "slot $slot reserve refused: $cand — re-walking ladder without that engine"
      tries=$((tries + 1))
      [ "$tries" -lt 4 ] || break
    done
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
  bad="$(jq -r '.projects[] | select(has("delivery_hold") and (.delivery_hold | type) != "boolean") | .name' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: delivery_hold must be boolean on project(s): $bad" >&2; exit 2; fi
  case "$(cfg '.paused // false')" in
    true|false) ;;
    *) echo "config error: .paused must be true or false" >&2; exit 2 ;;
  esac
  bad="$(jq -r '.projects[] | select((.delivery_hold // false) and .container == "local") | .name' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: delivery_hold requires a container on project(s): $bad" >&2; exit 2; fi
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
  bad="$(jq -r '.slots // {} | keys[] | select(test("^[A-Za-z0-9_-]+$") | not)' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: slot names must match ^[A-Za-z0-9_-]+$: $bad" >&2; exit 2; fi
  bad="$(jq -r '. as $c | .slots // {} | to_entries[] | select(.value | has("pinned"))
                | .value.pinned as $pin
                | select(($pin | type) != "string"
                         or ([$c.projects[].name] | index($pin)) == null)
                | "slots.\(.key).pinned \($pin) is not a project"' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: $bad" >&2; exit 2; fi
  bad="$(jq -r '[.slots // {} | .[] | .pinned // empty] | group_by(.)[] | select(length > 1) | .[0]' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: project pinned on more than one slot: $bad" >&2; exit 2; fi
  local script; script="$(cd "$SCRIPT_DIR" && pwd)/mission-control.sh"
  cat <<EOF
mission-control is NOT armed by agents. A human installs ONE cron line, once.

1. Edit your persistent crontab file (on LinuxServer-style containers:
   /config/crontabs/<user> — edit the file, not 'crontab -e'). Add:

*/30 * * * * bash "$script" tick --config "$MC_CONFIG" >> "$MC_STATE_DIR/cron.log" 2>&1

2. In the same crontab file, DELETE any standalone lessons-deliver cron line —
   mission-control now dispatches lessons-deliver as the ladder's idle rung.
   Two schedulers would double-dip the same budget pools.

3. Export the push URL in the crontab environment block if you want
   notifications, e.g.:  $(cfg '.notify_env // "MC_NTFY_URL"')=https://ntfy.sh/<topic>

4. Verify before trusting it:  bash $script tick --config $MC_CONFIG --dry-run
EOF
}

cmd_status() {
  local s
  for s in $(jq -r '.slots // {} | keys[]' "$MC_CONFIG"); do
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
  local delivery_hold="${WRAP[delivery-hold]:-false}" run_id="${WRAP[run-id]:-}"
  local started started_ms ended_ms ended duration_ms rc outcome command canonical=""
  local context_var
  local terminal_status=not-applicable workflow_outcome="" workflow_reason="" total_tokens=""
  local account_json="" account_rc=0 helper_binding="" binding_rc=0 helper_surface="" tmpl blk
  local -a invocation_env=() docker_env=()
  if [ -n "$run_id" ]; then
    valid_run_id "$run_id" || { echo "mission-control: invalid --run-id" >&2; exit 2; }
  else
    run_id="$(new_run_id)" || { echo "mission-control: could not mint run id" >&2; exit 1; }
  fi
  command="$(pj "$name" '.command')"
  canonical="$(workflow_command "$command" 2>/dev/null || true)"
  while IFS= read -r context_var; do
    [ -n "$context_var" ] || continue
    invocation_env+=(-u "$context_var")
    docker_env+=(-e "$context_var=")
  done < <(workflow_context_vars)
  invocation_env+=("SAAS_INVOCATION_ID=$run_id" "SAAS_INVOCATION_COMMAND=$canonical")
  docker_env+=(-e "SAAS_INVOCATION_ID=$run_id" -e "SAAS_INVOCATION_COMMAND=$canonical")
  tmpl="$(cfg ".engines[\"$engine\"].cmd")"
  if [ -n "$canonical" ]; then
    if engine_template_is_codex_exec "$tmpl"; then helper_surface=codex
    else helper_surface=claude
    fi
    set +e
    helper_binding="$(workflow_helper_binding "$container" "$rp" "$helper_surface" 2>/dev/null)"
    binding_rc=$?
    set -e
  fi
  started="$(now)"; started_ms="$(now_ms)"
  if [ -n "$canonical" ] && [ "$binding_rc" -ne 0 ]; then
    echo "mission-control: workflow helper preflight failed; refusing model dispatch" >&2
    rc=1
  else
    set +e
    # inner bash -c: engine cmds may start with VAR=... assignment prefixes
    # (dedicated-subscription CODEX_HOME), which timeout(1) cannot exec directly
    if [ "$container" = "local" ]; then
      (cd "$rp" && env "${invocation_env[@]}" timeout "${envelope}m" bash -c "$rendered")
    elif [ "$delivery_hold" = true ]; then
      $DOCKER_CMD exec $DOCKER_USER_OPT "${docker_env[@]}" "$container" bash -c \
        'cd "$1" && shift && exec "$@"' _ "$rp" \
        /paat-reconcile/with-delivery-hold.sh timeout "${envelope}m" bash -c "$rendered"
    else
      $DOCKER_CMD exec $DOCKER_USER_OPT "${docker_env[@]}" "$container" bash -c "cd $(printf %q "$rp") && timeout ${envelope}m bash -c $(printf %q "$rendered")"
    fi
    rc=$?
    set -e
  fi
  ended_ms="$(now_ms)"; ended="$((ended_ms / 1000))"; duration_ms="$((ended_ms - started_ms))"
  [ "$duration_ms" -ge 0 ] || duration_ms=0

  if engine_template_is_codex_exec "$tmpl"; then
    total_tokens="$(codex_total_tokens "$base.log" || true)"
  fi
  if [ -n "$canonical" ]; then
    if [ "$binding_rc" -ne 0 ]; then
      terminal_status=invalid
    else
      set +e
      account_json="$(workflow_account "$container" "$rp" "$helper_binding" "$run_id" "$duration_ms" "$total_tokens" 2>/dev/null)"
      account_rc=$?
      set -e
      case "$account_rc" in
        0)
          if valid_account_json "$account_json" "$run_id" "$canonical" "$duration_ms" "$total_tokens"; then
            terminal_status=accounted
            workflow_outcome="$(jq -r '.outcome' <<< "$account_json")"
            workflow_reason="$(jq -r '.terminal_reason // empty' <<< "$account_json")"
            if [ "$rc" -ne 0 ] && [ "$rc" -ne 75 ] && [ "$rc" -ne 78 ] && [ "$rc" -ne 124 ]; then
              case "$workflow_outcome" in success|no-op|skipped) terminal_status=exit-conflict ;; esac
            fi
          else
            terminal_status=invalid
          fi
          ;;
        4) terminal_status=missing ;;
        20) terminal_status=unsupported ;;
        *) terminal_status=invalid ;;
      esac
    fi
    if [ "$terminal_status" = unsupported ]; then
      blk="$(grep -oE '^MC-BLOCKED([[:space:]].*)?$' "$base.log" 2>/dev/null | tail -1 || true)"
      if [ -n "$blk" ]; then
        terminal_status=legacy-blocked
        workflow_outcome=blocked
        workflow_reason="$(printf '%s' "$blk" | sed -E 's/^MC-BLOCKED *//; s/recheck_after=[0-9]+ *//; s/^reason= *//')"
        [ -n "$workflow_reason" ] || workflow_reason=unspecified
      fi
    fi
    [ "$terminal_status" = accounted ] || log "workflow terminal project=$name status=$terminal_status"
  fi
  outcome="$(governor_report "$engine" "$name" "$rc" "$base.log" "$delivery_hold" \
    "$terminal_status" "$workflow_outcome" "$workflow_reason")"
  jq -n --arg slot "$slot" --arg p "$name" --arg e "$engine" \
        --arg s "$started" --arg t "$ended" --arg rc "$rc" --arg o "$outcome" \
        --arg run_id "$run_id" --arg workflow_outcome "$workflow_outcome" \
        --arg workflow_reason "$workflow_reason" --arg total_tokens "$total_tokens" \
        --arg terminal_status "$terminal_status" \
        '{slot:$slot, project:$p, engine:$e, started_at:($s|tonumber),
          ended_at:($t|tonumber), exit_code:($rc|tonumber), outcome:$o,
          run_id:$run_id,
          workflow_outcome:(if $workflow_outcome == "" then null else $workflow_outcome end),
          workflow_reason:(if $workflow_reason == "" then null else $workflow_reason end),
          total_tokens:(if $total_tokens == "" then null else ($total_tokens|tonumber) end),
          terminal_status:$terminal_status}' \
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
