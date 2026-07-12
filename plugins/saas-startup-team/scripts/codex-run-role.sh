#!/usr/bin/env bash
# Launch one Codex role with an explicit semantic profile, model, and effort.
#
# codex-run-role.sh --role ROLE --profile PROFILE \
#   (--task-file FILE | --handoff FILE)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROLE="" PROFILE="" TASK_FILE="" HANDOFF=""

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
SOURCE=${TASK_FILE:-$HANDOFF}
case "$SOURCE" in /*) : ;; *) SOURCE="$REPO_ROOT/$SOURCE" ;; esac
[ -f "$SOURCE" ] && [ -r "$SOURCE" ] || { echo "codex-run-role: task input is not readable" >&2; exit 4; }

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

case "$ROLE" in
  delivery-supervisor) ROLE_ACCESS=supervisor ;;
  *triage*|*review*|qa|qa-*|*-qa|*-qa-*) ROLE_ACCESS=read-only ;;
  business-founder|business-founder-*) ROLE_ACCESS=artifact-writer ;;
  tech-founder|tech-founder-*) ROLE_ACCESS=source-writer ;;
  *) ROLE_ACCESS=read-only ;;
esac

requested_sandbox=${CODEX_SANDBOX:-}
case "$ROLE_ACCESS" in
  read-only)
    [ -z "$requested_sandbox" ] || [ "$requested_sandbox" = read-only ] || {
      echo "codex-run-role: role $ROLE requires the read-only sandbox" >&2; exit 2; }
    SANDBOX=read-only
    ;;
  source-writer|artifact-writer)
    [ -z "$requested_sandbox" ] || [ "$requested_sandbox" = workspace-write ] || {
      echo "codex-run-role: writer role $ROLE requires the workspace-write sandbox" >&2; exit 2; }
    SANDBOX=workspace-write
    ;;
  *) SANDBOX=${requested_sandbox:-workspace-write} ;;
esac
case "$SANDBOX" in read-only|workspace-write|danger-full-access) : ;; *) echo "codex-run-role: invalid CODEX_SANDBOX" >&2; exit 2 ;; esac

if [ "$ROLE_ACCESS" = source-writer ] && [ "$SANDBOX" = workspace-write ]; then
  [ "${SAAS_CODEX_NETWORK_ACCESS:-off}" = off ] || {
    echo "codex-run-role: source writers require network-off workspace isolation" >&2
    exit 2
  }
  NETWORK_ACCESS=off
else
  NETWORK_ACCESS=${SAAS_CODEX_NETWORK_ACCESS:-default}
fi
CODEX_CONFIG_ARGS=()
case "$NETWORK_ACCESS" in
  default) : ;;
  off)
    [ "$SANDBOX" = workspace-write ] || {
      echo "codex-run-role: network-off mode requires workspace-write sandbox" >&2; exit 2; }
    CODEX_CONFIG_ARGS=(-c sandbox_workspace_write.network_access=false)
    ;;
  *) echo "codex-run-role: invalid SAAS_CODEX_NETWORK_ACCESS" >&2; exit 2 ;;
esac
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
    CODEX_CONFIG_ARGS+=(-c 'mcp_servers={}' -c 'shell_environment_policy.inherit="core"')
    ;;
  0) echo "codex-run-role: isolated Codex configuration cannot be disabled" >&2; exit 2 ;;
  *) echo "codex-run-role: invalid SAAS_CODEX_ISOLATED_CONFIG" >&2; exit 2 ;;
esac
TIMEOUT=${SAAS_CODEX_ROLE_TIMEOUT:-30m}
[[ "$TIMEOUT" =~ ^[1-9][0-9]*[smhd]$ ]] || { echo "codex-run-role: invalid SAAS_CODEX_ROLE_TIMEOUT" >&2; exit 2; }

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
  active_guards=("$GUARD_DIR"/*.active)
  shopt -u nullglob
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
  mkdir -p "$LOG_DIR"
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
    '{schema_version:2,buffer_id:$buffer_id,source:$source,destination:$destination,
      log_source:$log_source,log_destination:$log_destination}' > "$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -- "$receipt_tmp" "$GUARDED_RECEIPT"
fi
if [ -n "$LOG_FILE" ]; then
  case "$LOG_FILE" in /*) : ;; *) LOG_FILE="$REPO_ROOT/$LOG_FILE" ;; esac
  mkdir -p "$(dirname -- "$LOG_FILE")"
else
  mkdir -p "$LOG_DIR"
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

TASK_TEXT=$(cat "$SOURCE")
case "$ROLE" in
  delivery-supervisor)
    MUTATION_RULES='You are the sole supervisor mutation owner for this task. You may perform only the Git, GitHub, merge, deployment, and rollback operations explicitly authorized by the task, and only after its deterministic gates pass. Do not delegate mutations to review or QA roles.'
    ;;
  *triage*|*review*|qa|qa-*|*-qa|*-qa-*)
    MUTATION_RULES='This is a read-only/review role. Do not edit product files, commit, push, create or edit pull requests, merge, deploy, or roll back. Return only the requested structured verdict or review artifact.'
    ;;
  business-founder|business-founder-*)
    MUTATION_RULES='You may write only business/product briefs and proposed workflow-spec deltas in the task-designated artifact locations. Never modify product source, tests, or the canonical workflow-spec registry. Do not commit, push, create or edit pull requests, merge, deploy, or roll back.'
    ;;
  tech-founder|tech-founder-*)
    MUTATION_RULES='You are the source writer for this task and may modify only the required product source, tests, and canonical workflow-spec registry. Do not write business-founder verdicts. Do not commit, push, create or edit pull requests, merge, deploy, or roll back. Leave working-tree changes for the supervisor, which owns deterministic checks and the gated commit path.'
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
If the task is ambiguous or needs product, legal, security, architecture, payment, auth, data, migration, or concurrency judgment beyond the supplied requirements, stop and report that it requires deep escalation.
Run only local checks needed to validate your work. Never expose secrets or customer data.

================ TASK ================
${TASK_TEXT}
EOF
)

run_codex() {
  local model="$1" effort="$2" out="$3" err="$4" rc
  set +e
  timeout "$TIMEOUT" env TRIBUNAL_CALLER_PROVIDER=openai \
    TRIBUNAL_CALLER_MODEL="$model" TRIBUNAL_CALLER_EFFORT="$effort" \
    codex exec --json --ephemeral "${CODEX_GLOBAL_ARGS[@]}" -s "$SANDBOX" -m "$model" \
    "${CODEX_CONFIG_ARGS[@]}" \
    -c model_reasoning_effort="\"$effort\"" -C "$REPO_ROOT" - \
    <<< "$PROMPT" > "$out" 2> "$err"
  rc=$?
  set -e
  cat "$out"
  cat "$err" >&2
  return "$rc"
}

explicit_requested_model_unavailable() {
  local rc="$1" model="$2" out="$3" err="$4" model_re unavailable_re
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] && [ "$rc" -ne 143 ] || return 1
  if jq -se --arg model "$model" '
    any(.[];
      select(.type == "error" or .type == "turn.failed")
      | ((.error.code? // .code? // "") | tostring | ascii_downcase) as $code
      | ((.error.model? // .model? // "") | tostring | ascii_downcase) as $error_model
      | ((.error.message? // .message? // "") | tostring | ascii_downcase) as $message
      | ($code | test("^(model_(not_found|unavailable|unsupported|not_enabled)|unsupported_model)$"))
        and ($error_model == ($model | ascii_downcase) or ($message | contains($model | ascii_downcase)))
    )
  ' "$out" >/dev/null 2>&1; then
    return 0
  fi
  model_re=${model//./\\.}
  unavailable_re='unavailable|not[[:space:]]+available|not[[:space:]]+found|does[[:space:]]+not[[:space:]]+exist|unsupported|not[[:space:]]+enabled|no[[:space:]]+access'
  grep -qiE \
    "^(error:[[:space:]]*)?(the[[:space:]]+)?model[[:space:]\"']*${model_re}[\"']*[[:space:]]+(is[[:space:]]+)?(currently[[:space:]]+)?(${unavailable_re})[[:space:].]*$|^(error:[[:space:]]*)?model[[:space:]]+(${unavailable_re})[[:space:]]*:[[:space:]]*${model_re}[[:space:].]*$" \
    "$err"
}

OUT1=${LOG_FILE:-$LOG_DIR/$RUN_ID-$ROLE-$ATTEMPT.jsonl}
ERR1="$OUT1.stderr"
rc=0
run_codex "$MODEL" "$EFFORT" "$OUT1" "$ERR1" || rc=$?
EFFECTIVE_PROVIDER=openai
EFFECTIVE_MODEL=$MODEL
EFFECTIVE_EFFORT=$EFFORT

if explicit_requested_model_unavailable "$rc" "$MODEL" "$OUT1" "$ERR1"; then
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
    rc=0
    run_codex "$FALLBACK_MODEL" "$FALLBACK_EFFORT" "$OUT2" "$ERR2" || rc=$?
    FINAL_OUT=$OUT2
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
usage_line=$(jq -r 'select(.type == "turn.completed") | [(.usage.input_tokens // ""),(.usage.output_tokens // ""),(.usage.cached_input_tokens // "")] | @tsv' "$FINAL_OUT" 2>/dev/null | tail -n 1 || true)
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

exit "$rc"
