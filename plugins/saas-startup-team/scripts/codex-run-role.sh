#!/usr/bin/env bash
# Launch one Codex role with an explicit semantic profile, model, and effort.
#
# codex-run-role.sh --role ROLE --profile PROFILE \
#   (--task-file FILE | --handoff FILE)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROLE="" PROFILE="" TASK_FILE="" HANDOFF=""

safe_directory() {
  local path="$1" rest part current=""
  [ "$path" = / ] && return 0
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *$'\n'*|*$'\r'*|*$'\t'*|*//*|*/./*|*/../*|*/.|*/..) return 1 ;;
  esac
  rest=${path#/}
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) part=${rest%%/*}; rest=${rest#*/} ;;
      *) part=$rest; rest="" ;;
    esac
    [ -n "$part" ] && [ "$part" != . ] && [ "$part" != .. ] || return 1
    current="$current/$part"
    [ ! -L "$current" ] || return 1
    if [ -e "$current" ]; then
      [ -d "$current" ] || return 1
    else
      mkdir -m 700 -- "$current" 2>/dev/null || {
        [ -d "$current" ] && [ ! -L "$current" ] || return 1
      }
    fi
  done
  [ -d "$path" ] && [ ! -L "$path" ] \
    && [ "$(cd -- "$path" && pwd -P)" = "$path" ]
}

safe_output_path() {
  local path="$1" parent base canonical
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  parent=$(dirname -- "$path"); base=$(basename -- "$path")
  [ "$base" != . ] && [ "$base" != .. ] || return 1
  safe_directory "$parent" || return 1
  canonical=$(cd -- "$parent" && pwd -P) || return 1
  [ "$canonical" = "$parent" ] || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  fi
  printf '%s/%s\n' "$canonical" "$base"
}

safe_input_path() {
  local path="$1" parent base rest part current="" canonical
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *$'\n'*|*$'\r'*|*$'\t'*|*//*|*/./*|*/../*|*/.|*/..) return 1 ;;
  esac
  parent=$(dirname -- "$path") || return 1
  base=$(basename -- "$path") || return 1
  [ -n "$base" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
  rest=${parent#/}
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) part=${rest%%/*}; rest=${rest#*/} ;;
      *) part=$rest; rest="" ;;
    esac
    [ -n "$part" ] && [ "$part" != . ] && [ "$part" != .. ] || return 1
    current="$current/$part"
    [ -d "$current" ] && [ ! -L "$current" ] || return 1
  done
  canonical=$(cd -- "$parent" && pwd -P) || return 1
  [ "$canonical" = "$parent" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1
  if [ "$canonical" = / ]; then
    printf '/%s\n' "$base"
  else
    printf '%s/%s\n' "$canonical" "$base"
  fi
}

file_identity() {
  stat -Lc '%d:%i' -- "$1"
}

bounded_positive_bytes() {
  local value="$1" maximum="$2"
  [[ "$value" =~ ^[1-9][0-9]{0,8}$ ]] \
    && [ "$value" -le "$maximum" ]
}

duration_seconds() {
  local value="$1" number unit multiplier
  [[ "$value" =~ ^([1-9][0-9]{0,4})([smhd])$ ]] || return 1
  number=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}
  case "$unit" in s) multiplier=1 ;; m) multiplier=60 ;; h) multiplier=3600 ;; d) multiplier=86400 ;; esac
  printf '%s\n' "$((number * multiplier))"
}

usage() {
  echo "usage: codex-run-role.sh --role ROLE --profile light|standard|deep (--task-file FILE | --handoff FILE)" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --role) [ "$#" -ge 2 ] || usage; ROLE="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || usage; PROFILE="$2"; shift 2 ;;
    --task-file) [ "$#" -ge 2 ] || usage; TASK_FILE="$2"; shift 2 ;;
    --handoff) [ "$#" -ge 2 ] || usage; HANDOFF="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$ROLE" =~ ^[a-z][a-z0-9_.:-]{0,63}$ ]] || { echo "codex-run-role: invalid role" >&2; exit 2; }
case "$PROFILE" in
  light|standard|deep) : ;;
  mechanical) echo "codex-run-role: mechanical work must run as a script, not a model worker" >&2; exit 2 ;;
  *) usage ;;
esac
if { [ -n "$TASK_FILE" ] && [ -n "$HANDOFF" ]; } || { [ -z "$TASK_FILE" ] && [ -z "$HANDOFF" ]; }; then
  usage
fi

command -v codex >/dev/null 2>&1 || { echo "codex-run-role: codex CLI not found" >&2; exit 3; }
command -v timeout >/dev/null 2>&1 || { echo "codex-run-role: timeout is required" >&2; exit 4; }
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "codex-run-role: not inside a git worktree" >&2; exit 4; }
REPO_ROOT=$(cd "$REPO_ROOT" && pwd -P)
LOGIN_REPO_ROOT=$(cd "$REPO_ROOT" && timeout --signal=TERM --kill-after=1s 5s /bin/bash -lc 'pwd -P') || {
  echo "codex-run-role: could not verify the login-shell working directory" >&2
  exit 4
}
[ "$LOGIN_REPO_ROOT" = "$REPO_ROOT" ] || {
  echo "codex-run-role: login startup changes cwd; remove that cd or preserve the repository directory" >&2
  exit 4
}
SOURCE=${TASK_FILE:-$HANDOFF}
case "$SOURCE" in /*) : ;; *) SOURCE="$REPO_ROOT/$SOURCE" ;; esac
SOURCE=$(safe_input_path "$SOURCE") || {
  echo "codex-run-role: task input path is unsafe or unreadable" >&2; exit 4; }
TASK_INPUT_MAX_BYTES=${SAAS_CODEX_TASK_INPUT_MAX_BYTES:-1048576}
bounded_positive_bytes "$TASK_INPUT_MAX_BYTES" 1048576 || {
  echo "codex-run-role: invalid SAAS_CODEX_TASK_INPUT_MAX_BYTES" >&2; exit 2; }
exec 8< "$SOURCE" || {
  echo "codex-run-role: could not open task input safely" >&2; exit 4; }
# /proc is inherited from the parent mount namespace when lease-guardian
# creates its PID namespace. /proc/$$ would then address an unrelated host
# PID; /proc/self follows the process opening the pinned descriptor instead.
input_fd_path="/proc/self/fd/8"
input_identity=$(file_identity "$input_fd_path") \
  && input_path_identity=$(file_identity "$SOURCE") \
  && [ "$input_identity" = "$input_path_identity" ] \
  && input_size=$(stat -Lc '%s' -- "$input_fd_path") \
  && [[ "$input_size" =~ ^[0-9]+$ ]] \
  && [ "$input_size" -le "$TASK_INPUT_MAX_BYTES" ] || {
  exec 8<&-
  echo "codex-run-role: task input changed, is unsafe, or exceeds its byte budget" >&2
  exit 4
}
TASK_TEXT=$(LC_ALL=C head -c "$((TASK_INPUT_MAX_BYTES + 1))" <&8) || {
  exec 8<&-
  echo "codex-run-role: could not read task input" >&2
  exit 4
}
task_text_bytes=$(printf '%s' "$TASK_TEXT" | wc -c | tr -d ' ') \
  && [[ "$task_text_bytes" =~ ^[0-9]+$ ]] \
  && [ "$task_text_bytes" -le "$TASK_INPUT_MAX_BYTES" ] || {
  exec 8<&-
  echo "codex-run-role: task input exceeded its byte budget while being read" >&2
  exit 4
}
verified_source=$(safe_input_path "$SOURCE") \
  && [ "$verified_source" = "$SOURCE" ] \
  && [ "$(file_identity "$input_fd_path")" = "$input_identity" ] \
  && [ "$(file_identity "$SOURCE")" = "$input_identity" ] \
  && final_input_size=$(stat -Lc '%s' -- "$input_fd_path") \
  && [ "$final_input_size" = "$input_size" ] || {
  exec 8<&-
  echo "codex-run-role: task input changed while it was being read" >&2
  exit 4
}
exec 8<&-

upper=${PROFILE^^}
model_var="SAAS_CODEX_${upper}_MODEL"
effort_var="SAAS_CODEX_${upper}_EFFORT"
case "$PROFILE" in
  light) default_model=gpt-5.6-terra; default_effort=medium ;;
  standard|deep) default_model=gpt-5.6-sol; default_effort=high ;;
esac
MODEL=${!model_var:-$default_model}
EFFORT=${!effort_var:-$default_effort}
[[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$ ]] || { echo "codex-run-role: invalid model override" >&2; exit 2; }
case "$EFFORT" in low|medium|high|xhigh|max) : ;; *) echo "codex-run-role: invalid effort override" >&2; exit 2 ;; esac

# Every AI worker is unrestricted; the dev container is the security boundary.
# Legacy sandbox/network environment variables are intentionally ignored.
CODEX_CONFIG_ARGS=()
CODEX_SANDBOX_ARGS=(--dangerously-bypass-approvals-and-sandbox)
ISOLATED_CONFIG=${SAAS_CODEX_ISOLATED_CONFIG:-1}
CODEX_GLOBAL_ARGS=()
case "$ISOLATED_CONFIG" in
  1)
    CODEX_GLOBAL_ARGS=(
      --ignore-user-config --ignore-rules --strict-config
      --disable apps --disable plugins --disable hooks --disable multi_agent
      --disable browser_use --disable browser_use_external --disable browser_use_full_cdp_access
      --disable computer_use --disable in_app_browser --disable standalone_web_search
      --disable enable_mcp_apps --disable image_generation
    )
    CODEX_CONFIG_ARGS+=(
      -c 'mcp_servers={}'
      -c 'shell_environment_policy.inherit="core"'
    )
    ;;
  0) echo "codex-run-role: isolated Codex configuration cannot be disabled" >&2; exit 2 ;;
  *) echo "codex-run-role: invalid SAAS_CODEX_ISOLATED_CONFIG" >&2; exit 2 ;;
esac
TIMEOUT=${SAAS_CODEX_ROLE_TIMEOUT:-30m}
TIMEOUT_SECONDS=$(duration_seconds "$TIMEOUT") \
  && [ "$TIMEOUT_SECONDS" -le 7200 ] || {
  echo "codex-run-role: invalid SAAS_CODEX_ROLE_TIMEOUT (maximum 2h)" >&2; exit 2; }
LOG_RETENTION_FILES=${SAAS_CODEX_LOG_RETENTION_FILES:-300}
[[ "$LOG_RETENTION_FILES" =~ ^[1-9][0-9]{0,3}$ ]] || {
  echo "codex-run-role: invalid SAAS_CODEX_LOG_RETENTION_FILES" >&2; exit 2; }
JSONL_MAX_BYTES=${SAAS_CODEX_JSONL_MAX_BYTES:-8388608}
STDERR_MAX_BYTES=${SAAS_CODEX_STDERR_MAX_BYTES:-1048576}
LAST_MESSAGE_MAX_BYTES=${SAAS_CODEX_LAST_MESSAGE_MAX_BYTES:-1048576}
bounded_positive_bytes "$JSONL_MAX_BYTES" 8388608 \
  && bounded_positive_bytes "$STDERR_MAX_BYTES" 1048576 \
  && bounded_positive_bytes "$LAST_MESSAGE_MAX_BYTES" 1048576 || {
  echo "codex-run-role: invalid Codex evidence byte budget" >&2; exit 2; }
ATTEMPT_EVIDENCE_MAX_BYTES=$((JSONL_MAX_BYTES + STDERR_MAX_BYTES + LAST_MESSAGE_MAX_BYTES))
RUN_EVIDENCE_MAX_BYTES=$((ATTEMPT_EVIDENCE_MAX_BYTES * 2))
LOG_RETENTION_BYTES=${SAAS_CODEX_LOG_RETENTION_BYTES:-67108864}
bounded_positive_bytes "$LOG_RETENTION_BYTES" 67108864 \
  && [ "$LOG_RETENTION_BYTES" -gt "$RUN_EVIDENCE_MAX_BYTES" ] || {
  echo "codex-run-role: invalid SAAS_CODEX_LOG_RETENTION_BYTES" >&2; exit 2; }
MAX_EVIDENCE_FILE_BYTES=$JSONL_MAX_BYTES
[ "$STDERR_MAX_BYTES" -le "$MAX_EVIDENCE_FILE_BYTES" ] || MAX_EVIDENCE_FILE_BYTES=$STDERR_MAX_BYTES
[ "$LAST_MESSAGE_MAX_BYTES" -le "$MAX_EVIDENCE_FILE_BYTES" ] \
  || MAX_EVIDENCE_FILE_BYTES=$LAST_MESSAGE_MAX_BYTES
GUARDED_LOG_RETENTION_FILES=$(((LOG_RETENTION_BYTES - RUN_EVIDENCE_MAX_BYTES) / MAX_EVIDENCE_FILE_BYTES))
[ "$GUARDED_LOG_RETENTION_FILES" -ge 1 ] || {
  echo "codex-run-role: retained-log budget leaves no bounded history" >&2; exit 2; }
[ "$GUARDED_LOG_RETENTION_FILES" -le "$LOG_RETENTION_FILES" ] \
  || GUARDED_LOG_RETENTION_FILES=$LOG_RETENTION_FILES

RUN_ID=${SAAS_RUN_ID:-$("$SCRIPT_DIR/agent-events.sh" new-run-id)}
ATTEMPT=${SAAS_ATTEMPT:-1}
[[ "$ATTEMPT" =~ ^[1-9][0-9]*$ ]] || { echo "codex-run-role: invalid SAAS_ATTEMPT" >&2; exit 2; }
COMMAND=${SAAS_COMMAND:-codex-run-role}
PHASE=${SAAS_PHASE:-$ROLE}
WRITER_ID=${SAAS_WRITER_ID:-worker-$RUN_ID-$ATTEMPT}
[[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ]] || {
  echo "codex-run-role: invalid SAAS_RUN_ID" >&2; exit 2; }
[[ "$COMMAND" =~ ^[a-z][a-z0-9_.:-]{0,63}$ ]] || {
  echo "codex-run-role: invalid SAAS_COMMAND" >&2; exit 2; }
[[ "$PHASE" =~ ^[a-z][a-z0-9_.:-]{0,63}$ ]] || {
  echo "codex-run-role: invalid SAAS_PHASE" >&2; exit 2; }
[[ "$WRITER_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ]] || {
  echo "codex-run-role: invalid SAAS_WRITER_ID" >&2; exit 2; }
EVENTS_DESTINATION=${SAAS_AGENT_EVENTS_FILE:-$REPO_ROOT/.startup/runs/agent-events.jsonl}
LOG_DESTINATION=${SAAS_CODEX_LOG_DIR:-$REPO_ROOT/.startup/runs/codex}
case "$EVENTS_DESTINATION" in /*) : ;; *) EVENTS_DESTINATION="$REPO_ROOT/$EVENTS_DESTINATION" ;; esac
case "$LOG_DESTINATION" in /*) : ;; *) LOG_DESTINATION="$REPO_ROOT/$LOG_DESTINATION" ;; esac
EVENTS_FILE=$EVENTS_DESTINATION
LOG_DIR=$LOG_DESTINATION
LOG_FILE=${SAAS_CODEX_LOG_FILE:-}
GUARDED_TELEMETRY=0
GUARDED_RECEIPT=""
GIT_DIR=$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)
GIT_DIR=$(cd "$GIT_DIR" && pwd -P)
GUARD_DIR="$GIT_DIR/saas-startup-team"
ACTIVE_GUARD=""
if [ -d "$GUARD_DIR" ]; then
  [ ! -L "$GUARD_DIR" ] && [ "$(cd "$GUARD_DIR" && pwd -P)" = "$GUARD_DIR" ] || {
    echo "codex-run-role: unsafe mutation guard directory" >&2; exit 4; }
  shopt -s nullglob
  terminal_markers=("$GUARD_DIR"/*.verified)
  active_guards=("$GUARD_DIR"/*.active)
  shopt -u nullglob
  [ "${#terminal_markers[@]}" -eq 0 ] || {
    echo "codex-run-role: incomplete mutation guard import blocks a new worker" >&2; exit 4; }
  [ "${#active_guards[@]}" -le 1 ] || {
    echo "codex-run-role: multiple active mutation guards" >&2; exit 4; }
  if [ "${#active_guards[@]}" -eq 1 ]; then
    ACTIVE_GUARD=${active_guards[0]}
    [ -f "$ACTIVE_GUARD" ] && [ ! -L "$ACTIVE_GUARD" ] || {
      echo "codex-run-role: unsafe active mutation guard" >&2; exit 4; }
  fi
fi
BUFFER_REQUIRED=0
case "$EVENTS_DESTINATION" in "$REPO_ROOT"/*) BUFFER_REQUIRED=1 ;; esac
case "$LOG_DESTINATION" in "$REPO_ROOT"/*) BUFFER_REQUIRED=1 ;; esac
if [ -n "$ACTIVE_GUARD" ] && [ "$BUFFER_REQUIRED" -eq 1 ]; then
  case "$EVENTS_DESTINATION:$LOG_DESTINATION" in
    "$REPO_ROOT"/*:"$REPO_ROOT"/*) : ;;
    *) echo "codex-run-role: guarded telemetry destinations must both be inside or outside the guarded worktree" >&2; exit 4 ;;
  esac
  [ "$EVENTS_DESTINATION" = "$REPO_ROOT/.startup/runs/agent-events.jsonl" ] \
    && [ "$LOG_DESTINATION" = "$REPO_ROOT/.startup/runs/codex" ] || {
      echo "codex-run-role: guarded telemetry must use the canonical local destinations" >&2
      exit 4
    }
  GUARDED_TELEMETRY=1
  buffer_prefix=${ACTIVE_GUARD%.active}
  buffer_id=$("$SCRIPT_DIR/mutation-auth-token.sh")
  buffer_id=${buffer_id:0:32}
  EVENTS_FILE="$buffer_prefix.events-$buffer_id.jsonl"
  LOG_DIR="$buffer_prefix.logs-$buffer_id"
  LOG_FILE=""
  GUARDED_RECEIPT="$buffer_prefix.telemetry-$buffer_id.json"
  [ ! -e "$EVENTS_FILE" ] && [ ! -L "$EVENTS_FILE" ] \
    && [ ! -e "$LOG_DIR" ] && [ ! -L "$LOG_DIR" ] \
    && [ ! -e "$GUARDED_RECEIPT" ] && [ ! -L "$GUARDED_RECEIPT" ] || {
      echo "codex-run-role: guarded telemetry buffer collision" >&2; exit 4; }
  safe_directory "$LOG_DIR" || {
    echo "codex-run-role: unsafe guarded log buffer directory" >&2; exit 4; }
  guard_identity="${buffer_prefix}.telemetry-identity-key"
  if [ -e "$guard_identity" ] || [ -L "$guard_identity" ]; then
    [ -f "$guard_identity" ] && [ ! -L "$guard_identity" ] || {
      echo "codex-run-role: unsafe guarded telemetry identity" >&2; exit 4; }
  else
    identity_tmp=$(mktemp "${guard_identity}.tmp.XXXXXX")
    if [ -s "${EVENTS_DESTINATION}.identity-key" ]; then
      [ -f "${EVENTS_DESTINATION}.identity-key" ] && [ ! -L "${EVENTS_DESTINATION}.identity-key" ] || {
        rm -f "$identity_tmp"
        echo "codex-run-role: unsafe telemetry identity key" >&2; exit 4; }
      cp -- "${EVENTS_DESTINATION}.identity-key" "$identity_tmp"
    else
      "$SCRIPT_DIR/mutation-auth-token.sh" > "$identity_tmp"
    fi
    chmod 600 "$identity_tmp"
    if ! ln -- "$identity_tmp" "$guard_identity" 2>/dev/null; then
      [ -f "$guard_identity" ] && [ ! -L "$guard_identity" ] || {
        rm -f "$identity_tmp"
        echo "codex-run-role: could not initialize guarded telemetry identity" >&2; exit 4; }
    fi
    rm -f "$identity_tmp"
  fi
  cp -- "$guard_identity" "${EVENTS_FILE}.identity-key"
  chmod 600 "${EVENTS_FILE}.identity-key"
  : > "$EVENTS_FILE"
  chmod 600 "$EVENTS_FILE"
  receipt_tmp=$(mktemp "${GUARDED_RECEIPT}.tmp.XXXXXX")
  jq -n --arg buffer_id "$buffer_id" --arg source "$EVENTS_FILE" \
    --arg destination "$EVENTS_DESTINATION" --arg log_source "$LOG_DIR" \
    --arg log_destination "$LOG_DESTINATION" \
    --argjson log_retention_files "$GUARDED_LOG_RETENTION_FILES" \
    '{schema_version:2,buffer_id:$buffer_id,source:$source,destination:$destination,
      log_source:$log_source,log_destination:$log_destination,
      log_retention_files:$log_retention_files}' > "$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -- "$receipt_tmp" "$GUARDED_RECEIPT"
fi
if [ -n "$LOG_FILE" ]; then
  case "$LOG_FILE" in /*) : ;; *) LOG_FILE="$REPO_ROOT/$LOG_FILE" ;; esac
  LOG_FILE=$(safe_output_path "$LOG_FILE") || {
    echo "codex-run-role: unsafe explicit log output path" >&2; exit 4; }
else
  safe_directory "$LOG_DIR" || {
    echo "codex-run-role: unsafe log directory" >&2; exit 4; }
  LOG_DIR=$(cd -- "$LOG_DIR" && pwd -P) || {
    echo "codex-run-role: could not resolve log directory" >&2; exit 4; }
fi
BASE_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_MS=$(date +%s%3N 2>/dev/null || echo "$(( $(date +%s) * 1000 ))")

ROUTE_ARGS=()
if [ -n "${SAAS_ROUTING_REASONS:-}" ]; then
  IFS=',' read -r -a route_reasons <<< "$SAAS_ROUTING_REASONS"
  for reason in "${route_reasons[@]}"; do
    [ -n "$reason" ] && ROUTE_ARGS+=(--routing-reason "$reason")
  done
fi

record_event() {
  "$SCRIPT_DIR/agent-events.sh" append \
    --events "$EVENTS_FILE" --run-id "$RUN_ID" --command "$COMMAND" --phase "$PHASE" \
    --surface codex --profile "$PROFILE" --writer-id "$WRITER_ID" --attempt "$ATTEMPT" \
    --requested-provider openai --requested-model "$MODEL" --requested-effort "$EFFORT" \
    --base-sha "$BASE_SHA" "${ROUTE_ARGS[@]}" "$@" >/dev/null
}

record_event --event-type started --started-at "$STARTED_AT" \
  --tokens-available-before "${SAAS_TOKENS_AVAILABLE_BEFORE:-}" --outcome incomplete || {
    echo "codex-run-role: could not record start event" >&2
    exit 4
  }

SCOPE_RULES=""
case "$ROLE" in
  delivery-supervisor)
    MUTATION_RULES='You are the sole supervisor mutation owner for this task. You may perform only the Git, GitHub, merge, deployment, and rollback operations explicitly authorized by the task, and only after its deterministic gates pass. Do not delegate mutations to review or QA roles.'
    ;;
  growth-hacker|lawyer|ux-tester|incident-investigator|session-replay|support-triage)
    MUTATION_RULES='You may write only task-designated local artifacts. Never modify product source, tests, or the canonical workflow-spec registry. Do not commit, push, create or edit pull requests, merge, deploy, or roll back.'
    ;;
  *triage*|*review*|qa|qa-*|*-qa|*-qa-*)
    MUTATION_RULES='This is a read-only/review role. Do not edit product files, commit, push, create or edit pull requests, merge, deploy, or roll back. Return only the requested structured verdict or review artifact.'
    ;;
  business-founder|business-founder-*)
    MUTATION_RULES='You may write only business/product briefs and proposed workflow-spec deltas in the task-designated artifact locations. Never modify product source, tests, or the canonical workflow-spec registry. Do not commit, push, create or edit pull requests, merge, deploy, or roll back.'
    HANDOFF_TEMPLATE="$(cd "$SCRIPT_DIR/../templates" && pwd -P)/handoff-business-to-tech.md"
    SCOPE_RULES="When writing a tech implementation brief, follow ${HANDOFF_TEMPLATE} and explicitly fill Done, Preserve, and Out of Scope without inventing missing requirements."
    ;;
  tech-founder|tech-founder-*)
    MUTATION_RULES='You are the source writer for this task and may modify only the required product source, tests, and canonical workflow-spec registry. Do not write business-founder verdicts. Do not commit, push, create or edit pull requests, merge, deploy, or roll back. Leave working-tree changes for the supervisor, which owns deterministic checks and the gated commit path.'
    SCOPE_CONTRACT="$SCRIPT_DIR/../templates/delivery-scope-contract.md"
    [ -r "$SCOPE_CONTRACT" ] || {
      echo "codex-run-role: delivery scope contract is not readable" >&2
      exit 4
    }
    SCOPE_RULES=$(cat "$SCOPE_CONTRACT")
    ;;
  *)
    MUTATION_RULES='This role has no mutation grant and must remain read-only. Do not edit product files or workflow artifacts, commit, push, create or edit pull requests, merge, deploy, or roll back. Return only the requested analysis or artifact content to the caller.'
    ;;
esac
PROMPT=$(cat <<EOF
You are executing the ${ROLE} role for a production SaaS delivery.
Execution profile: ${PROFILE}.

Read only what this task needs, use targeted ranges, and do not re-read material already in context.
Keep the diff minimal and limited to the stated acceptance. Do not add speculative abstractions or unrelated cleanup.
${MUTATION_RULES}
${SCOPE_RULES}
If the task is ambiguous or needs product, legal, security, architecture, payment, auth, data, migration, or concurrency judgment beyond the supplied requirements, stop and report that it requires deep escalation.
Run only local checks needed to validate your work. Never expose secrets or customer data.

================ TASK ================
${TASK_TEXT}
EOF
)

evidence_fd_path() {
  case "$1" in
    5|6|7) printf '/proc/self/fd/%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

evidence_fd_size() {
  local fd_path size
  fd_path=$(evidence_fd_path "$1") || return 1
  [ -f "$fd_path" ] || return 1
  size=$(stat -Lc '%s' -- "$fd_path") || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

evidence_slot_valid() {
  local path="$1" fd="$2" expected="$3" fd_path path_identity fd_identity
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  fd_path=$(evidence_fd_path "$fd") || return 1
  [ -f "$fd_path" ] || return 1
  path_identity=$(file_identity "$path") || return 1
  fd_identity=$(file_identity "$fd_path") || return 1
  [ "$path_identity" = "$expected" ] && [ "$fd_identity" = "$expected" ]
}

pin_evidence_file() {
  local path="$1" fd="$2" fd_path identity path_identity
  case "$fd" in
    5) exec 5<> "$path" || return 1 ;;
    6) exec 6<> "$path" || return 1 ;;
    7) exec 7<> "$path" || return 1 ;;
    *) return 1 ;;
  esac
  fd_path=$(evidence_fd_path "$fd") || return 1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -f "$fd_path" ] || return 1
  identity=$(file_identity "$fd_path") || return 1
  path_identity=$(file_identity "$path") || return 1
  [ "$identity" = "$path_identity" ] || return 1
  evidence_fd_truncate "$fd" 0 || return 1
  [ "$(evidence_fd_size "$fd")" -eq 0 ] || return 1
  case "$fd" in
    5) EVIDENCE_OUT_ID=$identity ;;
    6) EVIDENCE_ERR_ID=$identity ;;
    7) EVIDENCE_LAST_ID=$identity ;;
  esac
}

close_evidence_fds() {
  exec 5>&- || true
  exec 6>&- || true
  exec 7>&- || true
}

cleanup_evidence_files() {
  close_evidence_fds
  rm -f -- "$@" || true
}

evidence_fd_truncate() {
  local fd="$1" size="$2" fd_path
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  fd_path=$(evidence_fd_path "$fd") || return 1
  [ -f "$fd_path" ] || return 1
  truncate -s "$size" -- "$fd_path"
}

append_bounded_diagnostic() {
  local fd="$1" maximum="$2" message="$3" fd_path size message_bytes keep
  fd_path=$(evidence_fd_path "$fd") || return 1
  size=$(evidence_fd_size "$fd") || return 1
  message_bytes=$(printf '%s\n' "$message" | wc -c | tr -d ' ') || return 1
  [[ "$message_bytes" =~ ^[0-9]+$ ]] || return 1
  [ "$message_bytes" -le "$maximum" ] || return 1
  keep=$((maximum - message_bytes))
  [ "$size" -le "$keep" ] || evidence_fd_truncate "$fd" "$keep" || return 1
  printf '%s\n' "$message" >> "$fd_path" || return 1
  size=$(evidence_fd_size "$fd") || return 1
  [ "$size" -le "$maximum" ]
}

publish_evidence_file() {
  local source="$1" destination="$2" fd="$3" expected="$4" maximum="$5"
  local resolved fd_path size destination_identity
  evidence_slot_valid "$source" "$fd" "$expected" || return 1
  size=$(evidence_fd_size "$fd") || return 1
  [ "$size" -le "$maximum" ] || return 1
  resolved=$(safe_output_path "$destination") || return 1
  [ "$resolved" = "$destination" ] || return 1
  fd_path=$(evidence_fd_path "$fd") || return 1
  chmod 600 "$fd_path" || return 1
  evidence_slot_valid "$source" "$fd" "$expected" || return 1
  mv -fT -- "$source" "$destination" || return 1
  [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  destination_identity=$(file_identity "$destination") || return 1
  [ "$destination_identity" = "$expected" ] \
    && [ "$(file_identity "$fd_path")" = "$expected" ] \
    && [ "$(evidence_fd_size "$fd")" -le "$maximum" ]
}

codex_terminal_valid() {
  timeout --signal=KILL 5s jq -ne '
    reduce inputs as $event (
      {count:0,objects:true,last:null};
      {count:(.count + 1),objects:(.objects and (($event | type) == "object")),last:$event}
    )
    | .count > 0 and .objects
      and (.last.type == "turn.completed")
      and (.last.usage | type == "object")
      and all([.last.usage.input_tokens,.last.usage.output_tokens,
        (.last.usage.cached_input_tokens // 0)][];
        type == "number" and . >= 0 and floor == .)' "$1" >/dev/null 2>&1
}

extract_last_agent_message() {
  local source="$1" maximum="$2"
  evidence_fd_truncate 7 0 || return 1
  timeout --signal=KILL 5s jq -nrj '
    reduce inputs as $event (null;
      if (($event | type) == "object")
        and ($event.type? == "item.completed")
        and ($event.item.type? == "agent_message")
        and (($event.item.text? | type) == "string")
      then $event.item.text else . end)
    | if . == null then empty else . end' "$source" \
    | LC_ALL=C head -c "$((maximum + 1))" >&7
}

ACTIVE_CODEX_PID=""
ACTIVE_SIGNAL_FORWARDED=0
ACTIVE_LAUNCHING=0
ACTIVE_PENDING_SIGNAL=""
ACTIVE_PENDING_STATUS=0
ACTIVE_RELAY_DIR=""
ACTIVE_RELAY_PIDS=()
ACTIVE_EVIDENCE_FILES=()

close_relay_fds() {
  exec 9>&- 10>&- 11>&- 12>&- 13>&- 14>&- || true
}

job_pid_running() {
  local target="$1" candidate
  for candidate in $(jobs -pr); do
    [ "$candidate" = "$target" ] && return 0
  done
  return 1
}

codex_group_alive() {
  local group="$1"
  [ -n "$group" ] || return 1
  kill -0 -- "-$group" 2>/dev/null || kill -0 "$group" 2>/dev/null
}

signal_codex_group() {
  local signal="$1" group="$2"
  [ -n "$group" ] || return 1
  kill -s "$signal" -- "-$group" 2>/dev/null \
    || kill -s "$signal" "$group" 2>/dev/null
}

stop_relay_readers() {
  local i relay_pid running
  for relay_pid in "${ACTIVE_RELAY_PIDS[@]}"; do
    kill -TERM "$relay_pid" 2>/dev/null || true
  done
  for ((i=0; i<20; i++)); do
    running=0
    for relay_pid in "${ACTIVE_RELAY_PIDS[@]}"; do
      job_pid_running "$relay_pid" && running=1
    done
    [ "$running" -eq 1 ] || break
    sleep 0.05
  done
  for relay_pid in "${ACTIVE_RELAY_PIDS[@]}"; do
    job_pid_running "$relay_pid" && kill -KILL "$relay_pid" 2>/dev/null || true
  done
  for ((i=0; i<20; i++)); do
    running=0
    for relay_pid in "${ACTIVE_RELAY_PIDS[@]}"; do
      job_pid_running "$relay_pid" && running=1
    done
    [ "$running" -eq 1 ] || break
    sleep 0.05
  done
  for relay_pid in "${ACTIVE_RELAY_PIDS[@]}"; do
    if job_pid_running "$relay_pid"; then
      disown "$relay_pid" 2>/dev/null || true
    else
      wait "$relay_pid" 2>/dev/null || true
    fi
  done
  ACTIVE_RELAY_PIDS=()
}

drain_evidence_relays() {
  local group="$1" i relay_pid running rc=0
  for ((i=0; i<20; i++)); do
    running=0
    for relay_pid in "${ACTIVE_RELAY_PIDS[@]}"; do
      job_pid_running "$relay_pid" && running=1
    done
    [ "$running" -eq 1 ] || break
    sleep 0.05
  done
  if [ "$running" -eq 1 ]; then
    signal_codex_group TERM "$group" || true
    for ((i=0; i<20; i++)); do
      running=0
      for relay_pid in "${ACTIVE_RELAY_PIDS[@]}"; do
        job_pid_running "$relay_pid" && running=1
      done
      [ "$running" -eq 1 ] || break
      sleep 0.05
    done
    signal_codex_group KILL "$group" || true
    stop_relay_readers
    return 1
  fi
  for relay_pid in "${ACTIVE_RELAY_PIDS[@]}"; do
    wait "$relay_pid" || rc=1
  done
  ACTIVE_RELAY_PIDS=()
  return "$rc"
}

cleanup_active_codex() {
  local i
  close_relay_fds
  if codex_group_alive "$ACTIVE_CODEX_PID"; then
    if [ "$ACTIVE_SIGNAL_FORWARDED" -eq 0 ]; then
      signal_codex_group TERM "$ACTIVE_CODEX_PID" || true
    fi
    for ((i=0; i<20; i++)); do
      codex_group_alive "$ACTIVE_CODEX_PID" || break
      sleep 0.05
    done
    signal_codex_group KILL "$ACTIVE_CODEX_PID" || true
  fi
  [ -z "$ACTIVE_CODEX_PID" ] || wait "$ACTIVE_CODEX_PID" 2>/dev/null || true
  ACTIVE_CODEX_PID=""
  stop_relay_readers
  if [ -n "$ACTIVE_RELAY_DIR" ]; then
    rm -f -- "$ACTIVE_RELAY_DIR/stdout" "$ACTIVE_RELAY_DIR/stderr" || true
    rmdir -- "$ACTIVE_RELAY_DIR" 2>/dev/null || true
    ACTIVE_RELAY_DIR=""
  fi
  if [ "${#ACTIVE_EVIDENCE_FILES[@]}" -gt 0 ]; then
    cleanup_evidence_files "${ACTIVE_EVIDENCE_FILES[@]}"
    ACTIVE_EVIDENCE_FILES=()
  fi
  ACTIVE_SIGNAL_FORWARDED=0
  ACTIVE_LAUNCHING=0
  ACTIVE_PENDING_SIGNAL=""
  ACTIVE_PENDING_STATUS=0
}

forward_active_signal() {
  local signal="$1" status="$2"
  trap - HUP INT TERM
  if codex_group_alive "$ACTIVE_CODEX_PID"; then
    signal_codex_group "$signal" "$ACTIVE_CODEX_PID" || true
    ACTIVE_SIGNAL_FORWARDED=1
  fi
  exit "$status"
}

handle_active_signal() {
  local signal="$1" status="$2"
  if [ "$ACTIVE_LAUNCHING" -eq 1 ]; then
    if [ -z "$ACTIVE_PENDING_SIGNAL" ]; then
      ACTIVE_PENDING_SIGNAL=$signal
      ACTIVE_PENDING_STATUS=$status
    fi
    return 0
  fi
  forward_active_signal "$signal" "$status"
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  cleanup_active_codex
  exit "$status"
}

trap cleanup_on_exit EXIT
trap 'handle_active_signal HUP 129' HUP
trap 'handle_active_signal INT 130' INT
trap 'handle_active_signal TERM 143' TERM

start_evidence_relays() {
  local parent="$1"
  ACTIVE_RELAY_DIR=$(mktemp -d "$parent/.codex-relay.XXXXXX") || return 1
  chmod 700 "$ACTIVE_RELAY_DIR" || return 1
  mkfifo -m 600 "$ACTIVE_RELAY_DIR/stdout" "$ACTIVE_RELAY_DIR/stderr" || return 1
  exec 11<> "$ACTIVE_RELAY_DIR/stdout" || return 1
  exec 12<> "$ACTIVE_RELAY_DIR/stderr" || return 1
  exec 13< "$ACTIVE_RELAY_DIR/stdout" || return 1
  exec 14< "$ACTIVE_RELAY_DIR/stderr" || return 1
  (exec 11>&- 12>&- 14>&-; LC_ALL=C head -c "$((JSONL_MAX_BYTES + 1))" <&13 >&5) &
  ACTIVE_RELAY_PIDS+=("$!")
  (exec 11>&- 12>&- 13>&-; LC_ALL=C head -c "$((STDERR_MAX_BYTES + 1))" <&14 >&6) &
  ACTIVE_RELAY_PIDS+=("$!")
  exec 9> "$ACTIVE_RELAY_DIR/stdout" || return 1
  exec 10> "$ACTIVE_RELAY_DIR/stderr" || return 1
  exec 11>&- 12>&- 13>&- 14>&-
  rm -f -- "$ACTIVE_RELAY_DIR/stdout" "$ACTIVE_RELAY_DIR/stderr" || return 1
  rmdir -- "$ACTIVE_RELAY_DIR" || return 1
  ACTIVE_RELAY_DIR=""
}

run_codex() {
  local model="$1" effort="$2" out="$3" err="$4" last_message="$5"
  local out_parent err_parent last_parent out_tmp="" err_tmp="" last_tmp=""
  local out_fd_path last_fd_path relay_rc=0 signal status
  local rc pid running size_out size_err size_last limit_reason="" unsafe=0 i
  EVIDENCE_PUBLISHED=0
  EVIDENCE_OUT_ID="" EVIDENCE_ERR_ID="" EVIDENCE_LAST_ID=""
  out=$(safe_output_path "$out") || {
    echo "codex-run-role: unsafe JSONL evidence path" >&2; return 4; }
  err=$(safe_output_path "$err") || {
    echo "codex-run-role: unsafe stderr evidence path" >&2; return 4; }
  last_message=$(safe_output_path "$last_message") || {
    echo "codex-run-role: unsafe last-message evidence path" >&2; return 4; }
  out_parent=$(dirname -- "$out"); err_parent=$(dirname -- "$err")
  last_parent=$(dirname -- "$last_message")
  out_tmp=$(mktemp "$out_parent/.codex-jsonl.XXXXXX") || return 4
  err_tmp=$(mktemp "$err_parent/.codex-stderr.XXXXXX") || {
    rm -f -- "$out_tmp"; return 4; }
  last_tmp=$(mktemp "$last_parent/.codex-last-message.XXXXXX") || {
    rm -f -- "$out_tmp" "$err_tmp"; return 4; }
  chmod 600 "$out_tmp" "$err_tmp" "$last_tmp" || {
    cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"
    echo "codex-run-role: could not secure Codex evidence files" >&2
    return 4
  }
  pin_evidence_file "$out_tmp" 5 \
    && pin_evidence_file "$err_tmp" 6 \
    && pin_evidence_file "$last_tmp" 7 || {
    cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"
    echo "codex-run-role: could not pin Codex evidence files" >&2
    return 4
  }
  ACTIVE_EVIDENCE_FILES=("$out_tmp" "$err_tmp" "$last_tmp")
  out_fd_path=$(evidence_fd_path 5) || return 4
  last_fd_path=$(evidence_fd_path 7) || return 4
  start_evidence_relays "$out_parent" || {
    cleanup_active_codex
    echo "codex-run-role: could not initialize bounded evidence relays" >&2
    return 4
  }

  ACTIVE_LAUNCHING=1
  (
    ulimit -S -c 0 || exit 125
    exec timeout --signal=TERM --kill-after=2s "$TIMEOUT" \
      env TRIBUNAL_CALLER_PROVIDER=openai \
      TRIBUNAL_CALLER_MODEL="$model" TRIBUNAL_CALLER_EFFORT="$effort" \
      codex exec --json --ephemeral "${CODEX_GLOBAL_ARGS[@]}" "${CODEX_SANDBOX_ARGS[@]}" -m "$model" \
      "${CODEX_CONFIG_ARGS[@]}" \
      -c model_reasoning_effort="\"$effort\"" -C "$REPO_ROOT" - <<< "$PROMPT"
  ) >&9 2>&10 &
  pid=$!
  ACTIVE_CODEX_PID=$pid
  ACTIVE_LAUNCHING=0
  exec 9>&- 10>&-
  if [ -n "$ACTIVE_PENDING_SIGNAL" ]; then
    signal=$ACTIVE_PENDING_SIGNAL
    status=$ACTIVE_PENDING_STATUS
    ACTIVE_PENDING_SIGNAL=""
    ACTIVE_PENDING_STATUS=0
    forward_active_signal "$signal" "$status"
  fi
  while :; do
    running=0
    for i in $(jobs -pr); do [ "$i" = "$pid" ] && running=1; done
    [ "$running" -eq 1 ] || break
    evidence_slot_valid "$out_tmp" 5 "$EVIDENCE_OUT_ID" \
      && evidence_slot_valid "$err_tmp" 6 "$EVIDENCE_ERR_ID" \
      && evidence_slot_valid "$last_tmp" 7 "$EVIDENCE_LAST_ID" \
      || { unsafe=1; break; }
    size_out=$(evidence_fd_size 5) || { unsafe=1; break; }
    size_err=$(evidence_fd_size 6) || { unsafe=1; break; }
    size_last=$(evidence_fd_size 7) || { unsafe=1; break; }
    if [ "$size_out" -gt "$JSONL_MAX_BYTES" ] \
      || [ "$size_err" -gt "$STDERR_MAX_BYTES" ] \
      || [ "$size_last" -gt "$LAST_MESSAGE_MAX_BYTES" ] \
      || [ "$((size_out + size_err + size_last))" -gt "$ATTEMPT_EVIDENCE_MAX_BYTES" ]; then
      limit_reason="Codex evidence exceeded its bounded byte budget"
      break
    fi
    sleep 0.05
  done
  if [ "$unsafe" -eq 1 ] || [ -n "$limit_reason" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    for ((i=0; i<20; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rc=0
  wait "$pid" || rc=$?
  drain_evidence_relays "$pid" || relay_rc=1
  ACTIVE_CODEX_PID=""
  [ "$relay_rc" -eq 0 ] || unsafe=1
  extract_last_agent_message "$out_fd_path" "$LAST_MESSAGE_MAX_BYTES" || true

  evidence_slot_valid "$out_tmp" 5 "$EVIDENCE_OUT_ID" \
    && evidence_slot_valid "$err_tmp" 6 "$EVIDENCE_ERR_ID" \
    && evidence_slot_valid "$last_tmp" 7 "$EVIDENCE_LAST_ID" || unsafe=1
  size_out=$(evidence_fd_size 5) || unsafe=1
  size_err=$(evidence_fd_size 6) || unsafe=1
  size_last=$(evidence_fd_size 7) || unsafe=1
  if [ "$relay_rc" -ne 0 ]; then
    cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"
    echo "codex-run-role: Codex evidence relays did not drain after worker exit" >&2
    return 4
  fi
  if [ "$unsafe" -eq 1 ]; then
    cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"
    echo "codex-run-role: Codex evidence slot became unsafe" >&2
    return 4
  fi
  if [ "$size_out" -gt "$JSONL_MAX_BYTES" ] \
    || [ "$size_err" -gt "$STDERR_MAX_BYTES" ] \
    || [ "$size_last" -gt "$LAST_MESSAGE_MAX_BYTES" ] \
    || [ "$((size_out + size_err + size_last))" -gt "$ATTEMPT_EVIDENCE_MAX_BYTES" ]; then
    limit_reason="Codex evidence exceeded its bounded byte budget"
  fi
  if [ -n "$limit_reason" ]; then
    { [ "$size_out" -le "$JSONL_MAX_BYTES" ] \
        || evidence_fd_truncate 5 "$JSONL_MAX_BYTES"; } \
      && { [ "$size_err" -le "$STDERR_MAX_BYTES" ] \
        || evidence_fd_truncate 6 "$STDERR_MAX_BYTES"; } \
      && { [ "$size_last" -le "$LAST_MESSAGE_MAX_BYTES" ] \
        || evidence_fd_truncate 7 "$LAST_MESSAGE_MAX_BYTES"; } || {
      cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"
      echo "codex-run-role: could not truncate Codex evidence safely" >&2
      return 4
    }
    append_bounded_diagnostic 6 "$STDERR_MAX_BYTES" \
      "codex-run-role: $limit_reason; raw evidence was truncated" || {
      cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"; return 4; }
    rc=1
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    append_bounded_diagnostic 6 "$STDERR_MAX_BYTES" \
      "codex-run-role: role execution exceeded the $TIMEOUT deadline" || {
      cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"; return 4; }
  fi
  if [ "$rc" -eq 0 ]; then
    if ! codex_terminal_valid "$out_fd_path"; then
      append_bounded_diagnostic 6 "$STDERR_MAX_BYTES" \
        'codex-run-role: successful CLI exit lacked a valid terminal turn.completed event' || {
        cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"; return 4; }
      rc=1
    elif [ ! -s "$last_fd_path" ] \
      || ! timeout --signal=KILL 5s env LC_ALL=C grep -q '[^[:space:]]' "$last_fd_path"; then
      append_bounded_diagnostic 6 "$STDERR_MAX_BYTES" \
        'codex-run-role: successful CLI exit produced no final role message' || {
        cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"; return 4; }
      rc=1
    fi
  fi

  evidence_slot_valid "$out_tmp" 5 "$EVIDENCE_OUT_ID" \
    && evidence_slot_valid "$err_tmp" 6 "$EVIDENCE_ERR_ID" \
    && evidence_slot_valid "$last_tmp" 7 "$EVIDENCE_LAST_ID" \
    && size_out=$(evidence_fd_size 5) \
    && size_err=$(evidence_fd_size 6) \
    && size_last=$(evidence_fd_size 7) \
    && [ "$size_out" -le "$JSONL_MAX_BYTES" ] \
    && [ "$size_err" -le "$STDERR_MAX_BYTES" ] \
    && [ "$size_last" -le "$LAST_MESSAGE_MAX_BYTES" ] || {
    cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"
    echo "codex-run-role: final Codex evidence validation failed" >&2
    return 4
  }

  publish_evidence_file "$out_tmp" "$out" 5 "$EVIDENCE_OUT_ID" "$JSONL_MAX_BYTES" \
    && publish_evidence_file "$err_tmp" "$err" 6 "$EVIDENCE_ERR_ID" "$STDERR_MAX_BYTES" \
    && publish_evidence_file "$last_tmp" "$last_message" 7 "$EVIDENCE_LAST_ID" "$LAST_MESSAGE_MAX_BYTES" \
    && evidence_slot_valid "$out" 5 "$EVIDENCE_OUT_ID" \
    && evidence_slot_valid "$err" 6 "$EVIDENCE_ERR_ID" \
    && evidence_slot_valid "$last_message" 7 "$EVIDENCE_LAST_ID" || {
    cleanup_evidence_files "$out_tmp" "$err_tmp" "$last_tmp"
    echo "codex-run-role: could not publish bounded Codex evidence safely" >&2
    return 4
  }
  close_evidence_fds
  ACTIVE_EVIDENCE_FILES=()
  EVIDENCE_PUBLISHED=1
  return "$rc"
}

bounded_terminal_stream() {
  LC_ALL=C awk -v max_bytes=8192 -v max_lines=80 '
    BEGIN { bytes=0; lines=0; truncated=0 }
    {
      if (bytes >= max_bytes || lines >= max_lines) { truncated=1; next }
      text=$0
      gsub(/[[:cntrl:]]/, "", text)
      text="codex-worker: " text ORS
      remaining=max_bytes-bytes
      if (length(text) > remaining) {
        printf "%s", substr(text, 1, remaining)
        bytes=max_bytes
        truncated=1
        next
      }
      printf "%s", text
      bytes+=length(text)
      lines++
    }
    END { if (truncated) print "codex-worker: [output truncated]" }
  '
}

prune_log_dir() {
  local excess i log timestamp index parent canonical listing unsafe_listing order sorted
  local total_bytes=0 log_bytes
  local -a candidates=() retained_logs=() old_logs=()
  [ -z "$LOG_FILE" ] && [ "$GUARDED_TELEMETRY" -eq 0 ] || return 0
  listing=$(mktemp) || return 1
  unsafe_listing=$(mktemp) || { rm -f -- "$listing"; return 1; }
  order=$(mktemp) || { rm -f -- "$listing" "$unsafe_listing"; return 1; }
  sorted=$(mktemp) || {
    rm -f -- "$listing" "$unsafe_listing" "$order"; return 1; }
  if ! find "$LOG_DIR" -mindepth 1 -maxdepth 1 \
    \( -name '*.jsonl' -o -name '*.jsonl.stderr' -o -name '*.jsonl.last-message' \) \
    ! -type f -print0 > "$unsafe_listing"; then
    rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"
    return 1
  fi
  if [ -s "$unsafe_listing" ]; then
    rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"
    echo "codex-run-role: unsafe log retention entry" >&2
    return 1
  fi
  if ! find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f \
    \( -name '*.jsonl' -o -name '*.jsonl.stderr' -o -name '*.jsonl.last-message' \) \
    -printf '%T@\0%p\0' > "$listing"; then
    rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"
    return 1
  fi
  while IFS= read -r -d '' timestamp && IFS= read -r -d '' log; do
    timestamp=${timestamp%%.*}
    [[ "$timestamp" =~ ^[0-9]+$ ]] || {
      rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"; return 1; }
    [ -f "$log" ] && [ ! -L "$log" ] || {
      rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"; return 1; }
    parent=$(dirname -- "$log")
    canonical=$(cd -- "$parent" && pwd -P) || {
      rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"; return 1; }
    [ "$canonical" = "$LOG_DIR" ] || {
      rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"; return 1; }
    index=${#candidates[@]}
    candidates[$index]=$log
    printf '%s\t%s\n' "$timestamp" "$index" >> "$order"
  done < "$listing"
  if ! LC_ALL=C sort -n -k1,1 -k2,2 "$order" > "$sorted"; then
    rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"
    return 1
  fi
  while IFS=$'\t' read -r timestamp index; do
    [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -lt "${#candidates[@]}" ] || {
      rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"; return 1; }
    retained_logs+=("${candidates[$index]}")
  done < "$sorted"
  rm -f -- "$listing" "$unsafe_listing" "$order" "$sorted"
  for log in "${retained_logs[@]}"; do
    log_bytes=$(stat -Lc '%s' -- "$log") || return 1
    total_bytes=$((total_bytes + log_bytes))
  done
  for log in "${retained_logs[@]}"; do
    case "$log" in
      "$OUT1"|"$ERR1"|"$LAST1"|"$FINAL_OUT"|"$FINAL_ERR"|"$FINAL_LAST"|\
      "${OUT2:-}"|"${ERR2:-}"|"${LAST2:-}") : ;;
      *) old_logs+=("$log") ;;
    esac
  done
  excess=$((${#old_logs[@]} - LOG_RETENTION_FILES))
  [ "$excess" -gt 0 ] || excess=0
  for ((i=0; i<${#old_logs[@]}; i++)); do
    [ "$i" -lt "$excess" ] || [ "$total_bytes" -gt "$LOG_RETENTION_BYTES" ] || break
    log=${old_logs[$i]}
    [ -f "$log" ] && [ ! -L "$log" ] || return 1
    parent=$(dirname -- "$log")
    canonical=$(cd -- "$parent" && pwd -P) || return 1
    [ "$canonical" = "$LOG_DIR" ] || return 1
    log_bytes=$(stat -Lc '%s' -- "$log") || return 1
    rm -f -- "$log" || return 1
    total_bytes=$((total_bytes - log_bytes))
  done
  [ "$total_bytes" -le "$LOG_RETENTION_BYTES" ] || {
    echo "codex-run-role: current evidence exceeds the retained-log byte budget" >&2
    return 1
  }
}

explicit_requested_model_unavailable() {
  local rc="$1" model="$2" out="$3" err="$4" model_re unavailable_re
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] && [ "$rc" -ne 143 ] || return 1
  if timeout --signal=KILL 5s jq -ne --arg model "$model" '
    reduce inputs as $event (false;
      . or (($event | type) == "object" and
        (($event.type? == "error") or ($event.type? == "turn.failed")) and
        (((($event.error.code? // $event.code? // "") | tostring | ascii_downcase)
          | test("^(model_(not_found|unavailable|unsupported|not_enabled)|unsupported_model)$")) and
        (((($event.error.model? // $event.model? // "") | tostring | ascii_downcase)
          == ($model | ascii_downcase)) or
         ((($event.error.message? // $event.message? // "") | tostring | ascii_downcase)
          | contains($model | ascii_downcase))))))
    )' "$out" >/dev/null 2>&1; then
    return 0
  fi
  model_re=${model//./\\.}
  unavailable_re='unavailable|not[[:space:]]+available|not[[:space:]]+found|does[[:space:]]+not[[:space:]]+exist|unsupported|not[[:space:]]+enabled|no[[:space:]]+access'
  timeout --signal=KILL 5s grep -qiE \
    "^(error:[[:space:]]*)?(the[[:space:]]+)?model[[:space:]\"']*${model_re}[\"']*[[:space:]]+(is[[:space:]]+)?(currently[[:space:]]+)?(${unavailable_re})[[:space:].]*$|^(error:[[:space:]]*)?model[[:space:]]+(${unavailable_re})[[:space:]]*:[[:space:]]*${model_re}[[:space:].]*$" \
    "$err"
}

OUT1=${LOG_FILE:-$LOG_DIR/$RUN_ID-$ROLE-$ATTEMPT.jsonl}
ERR1="$OUT1.stderr"
LAST1="$OUT1.last-message"
EVIDENCE_PUBLISHED=0
rc=0
run_codex "$MODEL" "$EFFORT" "$OUT1" "$ERR1" "$LAST1" || rc=$?
EFFECTIVE_PROVIDER=openai
EFFECTIVE_MODEL=$MODEL
EFFECTIVE_EFFORT=$EFFORT
FINAL_OUT=$OUT1
FINAL_ERR=$ERR1
FINAL_LAST=$LAST1

if [ "$EVIDENCE_PUBLISHED" -eq 1 ] \
  && explicit_requested_model_unavailable "$rc" "$MODEL" "$OUT1" "$ERR1"; then
  EFFECTIVE_PROVIDER=""
  EFFECTIVE_MODEL=""
  EFFECTIVE_EFFORT=""
  if [ "$MODEL" = gpt-5.6-terra ]; then
    ROUTE_ARGS+=(--routing-reason terra_unavailable_fallback)
    FALLBACK_MODEL=gpt-5.6-sol
    FALLBACK_EFFORT=medium
    OUT2=${LOG_FILE:+${LOG_FILE}.fallback}
    OUT2=${OUT2:-$LOG_DIR/$RUN_ID-$ROLE-$ATTEMPT-fallback.jsonl}
    ERR2="$OUT2.stderr"
    LAST2="$OUT2.last-message"
    rc=0
    run_codex "$FALLBACK_MODEL" "$FALLBACK_EFFORT" "$OUT2" "$ERR2" "$LAST2" || rc=$?
    FINAL_OUT=$OUT2
    FINAL_ERR=$ERR2
    FINAL_LAST=$LAST2
    if ! explicit_requested_model_unavailable "$rc" "$FALLBACK_MODEL" "$OUT2" "$ERR2"; then
      EFFECTIVE_PROVIDER=openai
      EFFECTIVE_MODEL=$FALLBACK_MODEL
      EFFECTIVE_EFFORT=$FALLBACK_EFFORT
    fi
  else
    FINAL_OUT=$OUT1
  fi
else
  FINAL_OUT=$OUT1
fi

INPUT_TOKENS="" OUTPUT_TOKENS="" CACHED_INPUT_TOKENS=""
usage_line=""
if [ "$EVIDENCE_PUBLISHED" -eq 1 ]; then
usage_line=$(timeout --signal=KILL 5s jq -nr '
  reduce inputs as $event (null;
    if (($event | type) == "object" and $event.type? == "turn.completed"
      and (($event.usage? | type) == "object"))
    then [($event.usage.input_tokens // ""),($event.usage.output_tokens // ""),
      ($event.usage.cached_input_tokens // "")]
    else . end)
  | if . == null then empty else @tsv end' "$FINAL_OUT" 2>/dev/null || true)
fi
if [ -n "$usage_line" ]; then
  IFS=$'\t' read -r INPUT_TOKENS OUTPUT_TOKENS CACHED_INPUT_TOKENS <<< "$usage_line"
fi
FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
END_MS=$(date +%s%3N 2>/dev/null || echo "$(( $(date +%s) * 1000 ))")
DURATION_MS=$((END_MS - START_MS))
OUTCOME=failure
[ "$rc" -eq 0 ] && OUTCOME=success

record_event --event-type completed --started-at "$STARTED_AT" --finished-at "$FINISHED_AT" \
  --duration-ms "$DURATION_MS" --effective-provider "$EFFECTIVE_PROVIDER" --effective-model "$EFFECTIVE_MODEL" \
  --effective-effort "$EFFECTIVE_EFFORT" --tokens-available-before "${SAAS_TOKENS_AVAILABLE_BEFORE:-}" \
  --tokens-available-after "${SAAS_TOKENS_AVAILABLE_AFTER:-}" --input-tokens "$INPUT_TOKENS" \
  --output-tokens "$OUTPUT_TOKENS" --cached-input-tokens "$CACHED_INPUT_TOKENS" \
  --cost-microunits "${SAAS_COST_MICROUNITS:-}" --checks not_run --outcome "$OUTCOME" || {
    echo "codex-run-role: could not record completion event" >&2
    exit 4
  }

if [ "$GUARDED_TELEMETRY" -eq 1 ]; then
  echo "codex-run-role: guarded telemetry buffered for supervisor import" >&2
fi

if [ "$EVIDENCE_PUBLISHED" -eq 1 ]; then
  prune_log_dir
fi

printf 'codex-run-role: role=%s profile=%s model=%s effort=%s exit=%d usage[input=%s output=%s cached=%s] full-log=%q\n' \
  "$ROLE" "$PROFILE" "${EFFECTIVE_MODEL:-unknown}" "${EFFECTIVE_EFFORT:-unknown}" "$rc" \
  "${INPUT_TOKENS:-unknown}" "${OUTPUT_TOKENS:-unknown}" "${CACHED_INPUT_TOKENS:-unknown}" \
  "$([ "$EVIDENCE_PUBLISHED" -eq 1 ] && printf '%s' "$FINAL_OUT" || printf '%s' unavailable)"
if [ "$EVIDENCE_PUBLISHED" -eq 1 ] && [ -s "$FINAL_LAST" ]; then
  printf '%s\n' 'codex-run-role: trailing role verdict'
  tail -c 8192 "$FINAL_LAST" | tail -n 80 | bounded_terminal_stream
fi
if [ "$EVIDENCE_PUBLISHED" -eq 1 ] && [ "$rc" -ne 0 ] && [ -s "$FINAL_ERR" ]; then
  printf '%s\n' 'codex-run-role: worker diagnostic (tail)' >&2
  tail -c 8192 "$FINAL_ERR" | tail -n 80 | bounded_terminal_stream >&2
fi

exit "$rc"
