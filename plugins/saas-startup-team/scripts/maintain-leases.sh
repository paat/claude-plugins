#!/usr/bin/env bash
# Bridge current and legacy maintenance leases through one persisted lease set.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SINGLE_FLIGHT="$SCRIPT_DIR/single-flight.sh"
GUARDIAN="$SCRIPT_DIR/lease-guardian.sh"

usage() {
  cat >&2 <<'EOF'
usage: maintain-leases.sh primary-root --repo-root DIR
       maintain-leases.sh acquire --repo-root DIR --mode maintain|maintain-loop --run-id ID --state-file FILE [--worktree DIR]
       maintain-leases.sh controller-binding --repo-root DIR --worktree DIR --run-id ID --state-file FILE
       maintain-leases.sh activate --state-file FILE --run-state FILE --blocked-file FILE  # maintain-loop state only
       maintain-leases.sh available --repo-root DIR
       maintain-leases.sh heartbeat --state-file FILE [--repo-root DIR --worktree DIR --run-id ID]
       maintain-leases.sh hold --state-file FILE [--repo-root DIR --worktree DIR --run-id ID] [--interval-seconds N] [--max-seconds N] -- COMMAND...
       maintain-leases.sh reap-terminal --repo-root DIR --run-id ID
       maintain-leases.sh cleanup --state-file FILE [--run-state FILE --run-id ID]
EOF
  exit 2
}

valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; }
valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
worktree_lease_key() {
  printf '%s:worktree:%s\n' "$1" "$(printf '%s' "$2" | cksum | awk '{print $1}')"
}
declare -Ar LEASE_TTL_SECONDS=(
  [legacy-maintain]=1800
  [legacy-loop]=900
  [shared]=900
  [worktree]=900
)

resolve_repo() {
  local supplied="$1" raw record candidate candidate_common worktree_rows
  ROOT="$(cd -- "$supplied" && pwd -P)" || return 1
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  raw="$(git -C "$ROOT" rev-parse --git-common-dir)" || return 1
  case "$raw" in /*) COMMON="$raw" ;; *) COMMON="$ROOT/$raw" ;; esac
  COMMON="$(cd -- "$COMMON" && pwd -P)" || return 1
  worktree_rows=$(mktemp) || return 1
  if ! git -C "$ROOT" worktree list --porcelain -z > "$worktree_rows"; then
    rm -f -- "$worktree_rows"
    return 1
  fi
  PRIMARY=""
  while IFS= read -r -d '' record; do
    case "$record" in
      'worktree '*) candidate=${record#worktree }; PRIMARY="$(cd -- "$candidate" && pwd -P)"; break ;;
    esac
  done < "$worktree_rows"
  rm -f -- "$worktree_rows"
  [ -n "$PRIMARY" ] || return 1
  raw="$(git -C "$PRIMARY" rev-parse --git-common-dir)" || return 1
  case "$raw" in /*) candidate_common="$raw" ;; *) candidate_common="$PRIMARY/$raw" ;; esac
  candidate_common="$(cd -- "$candidate_common" && pwd -P)" || return 1
  [ "$candidate_common" = "$COMMON" ] || return 1
}

materialize_lease_rows() {
  local state_file="$1" output="$2" expected actual
  if ! jq -er '.leases[] | [.kind,.key,.state_dir,.owner_file] | @tsv' \
    "$state_file" > "$output"; then
    : > "$output"
    return 1
  fi
  expected=$(jq -er '.leases | length | select(. > 0)' "$state_file") || return 1
  actual=$(awk 'END { print NR + 0 }' "$output") || return 1
  [ "$actual" -eq "$expected" ]
}

validate_lease_rows() {
  local rows="$1" owner_parent="$2" worktree_key="$3"
  local kind key state_dir owner_file expected_owner
  while IFS=$'\t' read -r kind key state_dir owner_file; do
    case "$kind$key$state_dir$owner_file" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
    case "$kind:$key:$state_dir" in
      "legacy-maintain:maintain-pass:$COMMON/saas-startup-team/leases") : ;;
      "legacy-loop:maintain-loop:pass:$PRIMARY/.startup/leases") : ;;
      "shared:maintain-delivery:pass:$COMMON/saas-startup-team/leases") : ;;
      worktree:*:"$COMMON/saas-startup-team/leases")
        [ -n "$worktree_key" ] && [ "$key" = "$worktree_key" ] || return 1 ;;
      *) echo "maintain-leases: unrecognized lease binding" >&2; return 1 ;;
    esac
    case "$owner_file" in "$owner_parent"/*) : ;; *) return 1 ;; esac
    [ "$(dirname -- "$owner_file")" = "$owner_parent" ] || return 1
    expected_owner="$owner_parent/$MODE-$RUN_ID-$kind.owner"
    [ "$owner_file" = "$expected_owner" ] || {
      echo "maintain-leases: owner binding does not match this run" >&2
      return 1
    }
    [ ! -L "$owner_file" ] && [ ! -L "${owner_file}.key" ] || return 1
  done < "$rows"
}

state_path_for_acquire() {
  local supplied="$1" parent base state_root plugin_state
  plugin_state="$COMMON/saas-startup-team"
  if [ ! -e "$plugin_state" ] && [ ! -L "$plugin_state" ]; then
    mkdir -- "$plugin_state"
  fi
  [ -d "$plugin_state" ] && [ ! -L "$plugin_state" ] || return 1
  state_root="$COMMON/saas-startup-team/maintain-runtime"
  if [ ! -e "$state_root" ] && [ ! -L "$state_root" ]; then
    mkdir -- "$state_root"
  fi
  [ -d "$state_root" ] && [ ! -L "$state_root" ] || return 1
  state_root="$(cd -- "$state_root" && pwd -P)"
  case "$supplied" in /*) : ;; *) supplied="$ROOT/$supplied" ;; esac
  parent=$(dirname -- "$supplied"); base=$(basename -- "$supplied")
  [ "$base" != . ] && [ "$base" != .. ] && [ ! -L "$parent" ] || return 1
  parent="$(cd -- "$parent" && pwd -P)" || return 1
  [ "$parent" = "$state_root" ] || return 1
  STATE_FILE="$parent/$base"
}

load_state() {
  local supplied="$1" expected_root expected_primary expected_common expected_worktree owner_parent state_parent worktree_key
  case "$supplied" in /*) STATE_FILE="$supplied" ;; *) STATE_FILE="$PWD/$supplied" ;; esac
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || {
    echo "maintain-leases: lease state is missing or unsafe" >&2; return 1; }
  jq -e '
    (.run_id|type == "string")
    and (.mode == "maintain" or .mode == "maintain-loop")
    and (.repo_root|type == "string") and (.primary_root|type == "string")
    and (.common_dir|type == "string") and (.worktree|type == "string")
    and (.leases|type == "array")
    and all([.run_id,.repo_root,.primary_root,.common_dir,.worktree][];
      (test("[[:cntrl:]]")|not))
    and ((.schema_version == 2 and .mode == "maintain"
          and .worktree == "" and (.leases|length) == 3)
      or (.schema_version == 2 and .mode == "maintain-loop"
          and (.worktree|startswith("/")) and (.leases|length) == 4)
      or (.schema_version == 3 and .mode == "maintain"
          and (.worktree|startswith("/")) and (.leases|length) == 4))
    and all(.leases[];
      (.kind|type == "string") and (.key|type == "string")
      and (.state_dir|type == "string") and (.owner_file|type == "string")
      and all([.kind,.key,.state_dir,.owner_file][];
        (test("[[:cntrl:]]")|not)))
    and (([.leases[].kind] | unique | length) == (.leases|length))' \
    "$STATE_FILE" >/dev/null || {
      echo "maintain-leases: malformed lease state" >&2; return 1; }
  RUN_ID=$(jq -r .run_id "$STATE_FILE"); MODE=$(jq -r .mode "$STATE_FILE")
  STATE_SCHEMA=$(jq -r .schema_version "$STATE_FILE")
  valid_id "$RUN_ID" || { echo "maintain-leases: invalid state run id" >&2; return 1; }
  expected_root=$(jq -r .repo_root "$STATE_FILE")
  resolve_repo "$expected_root" || { echo "maintain-leases: state repository is invalid" >&2; return 1; }
  expected_primary=$(jq -r .primary_root "$STATE_FILE")
  expected_common=$(jq -r .common_dir "$STATE_FILE")
  expected_worktree=$(jq -r .worktree "$STATE_FILE")
  [ "$PRIMARY" = "$expected_primary" ] && [ "$COMMON" = "$expected_common" ] || {
    echo "maintain-leases: repository identity changed" >&2; return 1; }
  if [ -n "$expected_worktree" ] && { [ "$expected_root" != "$PRIMARY" ] || [ "$ROOT" != "$PRIMARY" ]; }; then
    echo "maintain-leases: bound controller root is not the primary worktree" >&2
    return 1
  fi
  case "$MODE" in
    maintain)
      case "$STATE_SCHEMA" in
        2) [ -z "$expected_worktree" ] || return 1 ;;
        3)
          [ "$expected_worktree" = "$PRIMARY/.worktrees/maintain" ] || {
            echo "maintain-leases: canonical worktree binding is invalid" >&2; return 1; }
          worktree_key=$(worktree_lease_key maintain "$expected_worktree") || return 1
          ;;
        *) return 1 ;;
      esac
      ;;
    maintain-loop)
      [ "$STATE_SCHEMA" = 2 ] || return 1
      [ "$expected_worktree" = "$PRIMARY/.worktrees/maintain-loop" ] || {
        echo "maintain-leases: legacy worktree binding is invalid" >&2; return 1; }
      worktree_key=$(worktree_lease_key maintain-loop "$expected_worktree") || return 1
      ;;
  esac
  WORKTREE_BINDING="$expected_worktree"
  state_parent=$(dirname -- "$STATE_FILE")
  [ -d "$state_parent" ] && [ ! -L "$state_parent" ] || return 1
  state_parent="$(cd -- "$state_parent" && pwd -P)" || return 1
  [ "$state_parent" = "$COMMON/saas-startup-team/maintain-runtime" ] || {
    echo "maintain-leases: state file left the common maintenance runtime directory" >&2
    return 1
  }
  STATE_FILE="$state_parent/$(basename -- "$STATE_FILE")"
  owner_parent="$COMMON/saas-startup-team/leases/.owners"
  LEASE_ROWS_FILE=$(mktemp) || return 1
  materialize_lease_rows "$STATE_FILE" "$LEASE_ROWS_FILE" \
    && validate_lease_rows "$LEASE_ROWS_FILE" "$owner_parent" "${worktree_key:-}" || {
      rm -f -- "$LEASE_ROWS_FILE"
      LEASE_ROWS_FILE=""
      echo "maintain-leases: could not materialize validated lease bindings" >&2
      return 1
    }
}

load_controller_state() {
  local supplied_repo=$1 supplied_worktree=$2 supplied_run=$3 supplied_state=$4
  local controller_primary controller_common
  valid_id "$supplied_run" || {
    echo "maintain-leases: invalid controller run id" >&2; return 1; }
  resolve_repo "$supplied_repo" || {
    echo "maintain-leases: cannot resolve controller repository" >&2; return 1; }
  controller_primary=$PRIMARY; controller_common=$COMMON
  supplied_worktree=$(realpath -m -- "$supplied_worktree") || {
    echo "maintain-leases: cannot resolve controller worktree" >&2; return 1; }
  load_state "$supplied_state" || return 1
  [ "$RUN_ID" = "$supplied_run" ] && [ -n "$WORKTREE_BINDING" ] \
    && [ "$PRIMARY" = "$controller_primary" ] && [ "$COMMON" = "$controller_common" ] \
    && [ "$WORKTREE_BINDING" = "$supplied_worktree" ] || {
      echo "maintain-leases: controller identity mismatch" >&2
      return 1
    }
}

load_requested_state() {
  local supplied_state=$1
  if [ -n "$repo_root$worktree$expected_run_id" ]; then
    [ -n "$repo_root" ] && [ -n "$worktree" ] && [ -n "$expected_run_id" ] || usage
    load_controller_state "$repo_root" "$worktree" "$expected_run_id" "$supplied_state"
  else
    load_state "$supplied_state"
  fi
}

lease_state() {
  local state_dir="$1" key="$2" ttl="$3" slug lease heartbeat now
  if [ -e "$state_dir" ] || [ -L "$state_dir" ]; then
    [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  else
    return 0
  fi
  slug="$(printf '%s' "$key" | tr '/: ' '---' | tr -cd 'A-Za-z0-9._-')"
  lease="$state_dir/$slug"
  [ -e "$lease" ] || [ -L "$lease" ] || return 0
  [ -d "$lease" ] && [ ! -L "$lease" ] || return 1
  [ -f "$lease/heartbeat" ] && [ ! -L "$lease/heartbeat" ] \
    && [ -f "$lease/owner" ] && [ ! -L "$lease/owner" ] \
    && [ -f "$lease/key" ] && [ ! -L "$lease/key" ] || return 1
  [ "$(cat "$lease/key" 2>/dev/null)" = "$key" ] || return 1
  heartbeat=$(cat "$lease/heartbeat" 2>/dev/null) || return 1
  [[ "$heartbeat" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  [ "$heartbeat" -le "$now" ] || return 1
  [ "$((now - heartbeat))" -le "$ttl" ] && return 2
  return 3
}

foreign_worktree_leases_available() {
  local held_mode="$1" held_worktree="$2" own_key="" key state rc=0
  local canonical_key legacy_key
  canonical_key=$(worktree_lease_key maintain "$PRIMARY/.worktrees/maintain") || return 1
  legacy_key=$(worktree_lease_key maintain-loop "$PRIMARY/.worktrees/maintain-loop") || return 1
  if [ -n "$held_worktree" ]; then
    own_key=$(worktree_lease_key "$held_mode" "$held_worktree") || return 1
  fi
  for key in "$canonical_key" "$legacy_key"; do
    [ "$key" != "$own_key" ] || continue
    state=0
    lease_state "$common_leases" "$key" "${LEASE_TTL_SECONDS[worktree]}" || state=$?
    case "$state" in
      0|3) : ;;
      1) echo "maintain-leases: unsafe foreign worktree lease blocks $key" >&2; rc=1 ;;
      2) echo "maintain-leases: active foreign worktree lease blocks $key" >&2; rc=1 ;;
      *) return 1 ;;
    esac
  done
  return "$rc"
}

release_specs() {
  local rc=0 kind key state_dir owner_file index
  local -a keys=() state_dirs=() owner_files=()
  while IFS=$'\t' read -r kind key state_dir owner_file; do
    keys+=("$key"); state_dirs+=("$state_dir"); owner_files+=("$owner_file")
  done < "$LEASE_ROWS_FILE"
  for ((index=${#keys[@]} - 1; index >= 0; index--)); do
    if ! bash "$SINGLE_FLIGHT" --release "${keys[$index]}" \
      --state-dir "${state_dirs[$index]}" --owner-file "${owner_files[$index]}" >/dev/null; then
      rc=1
    fi
  done
  return "$rc"
}

heartbeat_specs() {
  local rc=0 kind key state_dir owner_file
  while IFS=$'\t' read -r kind key state_dir owner_file; do
    if ! bash "$SINGLE_FLIGHT" --heartbeat "$key" --state-dir "$state_dir" \
      --owner-file "$owner_file" >/dev/null; then rc=1; fi
  done < "$LEASE_ROWS_FILE"
  return "$rc"
}

resolve_run_state_path() {
  local supplied="$1" create="$2" expected part current="$PRIMARY"
  case "$supplied" in /*) : ;; *) supplied="$ROOT/$supplied" ;; esac
  expected="$PRIMARY/.startup/$MODE/current-run.json"
  [ "$supplied" = "$expected" ] || return 1
  for part in .startup "$MODE"; do
    current="$current/$part"
    if [ ! -e "$current" ] && [ ! -L "$current" ]; then
      if [ "$create" -eq 1 ]; then mkdir -- "$current" || return 1
      else RUN_STATE_PATH="$expected"; return 0
      fi
    fi
    [ -d "$current" ] && [ ! -L "$current" ] \
      && [ "$(cd -- "$current" && pwd -P)" = "$current" ] || return 1
  done
  [ ! -L "$expected" ] && { [ ! -e "$expected" ] || [ -f "$expected" ]; } || return 1
  RUN_STATE_PATH="$expected"
}

action=${1:-}; [ -n "$action" ] || usage; shift
repo_root=""; mode=""; run_id=""; state_file=""; worktree=""
run_state=""; blocked_file=""; expected_run_id=""; interval=60; max_seconds=14400
command=(); LEASE_ROWS_FILE=""; WORKTREE_BINDING=""; STATE_SCHEMA=""
trap 'rm -f -- "${LEASE_ROWS_FILE:-}"' EXIT
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root) [ "$#" -ge 2 ] || usage; repo_root=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || usage; mode=$2; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; run_id=$2; expected_run_id=$2; shift 2 ;;
    --state-file) [ "$#" -ge 2 ] || usage; state_file=$2; shift 2 ;;
    --worktree) [ "$#" -ge 2 ] || usage; worktree=$2; shift 2 ;;
    --run-state) [ "$#" -ge 2 ] || usage; run_state=$2; shift 2 ;;
    --blocked-file) [ "$#" -ge 2 ] || usage; blocked_file=$2; shift 2 ;;
    --interval-seconds) [ "$#" -ge 2 ] || usage; interval=$2; shift 2 ;;
    --max-seconds) [ "$#" -ge 2 ] || usage; max_seconds=$2; shift 2 ;;
    --) shift; command=("$@"); break ;;
    *) usage ;;
  esac
done

case "$action" in
  primary-root)
    [ -n "$repo_root" ] && [ -z "$state_file$mode$run_id$worktree$run_state$blocked_file" ] || usage
    resolve_repo "$repo_root" || { echo "maintain-leases: cannot resolve primary worktree" >&2; exit 1; }
    printf '%s\n' "$PRIMARY"
    ;;

  available)
    [ -n "$repo_root" ] && [ -z "$state_file$mode$run_id$worktree$run_state$blocked_file" ] || usage
    resolve_repo "$repo_root" || { echo "maintain-leases: cannot resolve repository" >&2; exit 1; }
    shared="$COMMON/saas-startup-team/leases"
    legacy="$PRIMARY/.startup/leases"
    maintain_worktree="$PRIMARY/.worktrees/maintain"
    loop_worktree="$PRIMARY/.worktrees/maintain-loop"
    maintain_worktree_key=$(worktree_lease_key maintain "$maintain_worktree")
    loop_worktree_key=$(worktree_lease_key maintain-loop "$loop_worktree")
    kinds=(legacy-maintain legacy-loop shared worktree worktree)
    keys=(maintain-pass maintain-loop:pass maintain-delivery:pass
      "$maintain_worktree_key" "$loop_worktree_key")
    dirs=("$shared" "$legacy" "$shared" "$shared" "$shared")
    rc=0
    for ((i=0; i<${#keys[@]}; i++)); do
      kind=${kinds[$i]}; key=${keys[$i]}; dir=${dirs[$i]}
      lease_state "$dir" "$key" "${LEASE_TTL_SECONDS[$kind]}" || state=$?
      state=${state:-0}
      case "$state" in
        0) : ;;
        1) echo "maintain-leases: unsafe lease blocks $key" >&2; rc=1 ;;
        2) echo "maintain-leases: active lease blocks $key" >&2; rc=1 ;;
        3) echo "maintain-leases: expired lease is reclaimable for $key" >&2 ;;
      esac
      state=0
    done
    [ "$rc" -eq 0 ] || exit 1
    echo "maintain-leases: delivery pass is available"
    ;;

  acquire)
    [ -n "$repo_root" ] && [ -n "$mode" ] && [ -n "$run_id" ] && [ -n "$state_file" ] \
      && [ -z "$run_state$blocked_file" ] || usage
    valid_id "$run_id" || { echo "maintain-leases: invalid run id" >&2; exit 2; }
    case "$mode" in
      maintain) : ;;
      maintain-loop) [ -n "$worktree" ] || usage ;;
      *) usage ;;
    esac
    resolve_repo "$repo_root" || { echo "maintain-leases: cannot resolve repository" >&2; exit 1; }
    state_schema=2
    if [ -n "$worktree" ]; then
      worktree="$(realpath -m -- "$worktree")"
      [ "$ROOT" = "$PRIMARY" ] || {
        echo "maintain-leases: a bound controller must acquire from the primary worktree" >&2
        exit 2
      }
      case "$mode" in
        maintain)
          [ "$worktree" = "$PRIMARY/.worktrees/maintain" ] || {
            echo "maintain-leases: worktree must be the canonical maintain worktree" >&2
            exit 2
          }
          state_schema=3
          ;;
        maintain-loop)
          [ "$worktree" = "$PRIMARY/.worktrees/maintain-loop" ] || {
            echo "maintain-leases: worktree must be the legacy maintain-loop worktree" >&2
            exit 2
          }
          ;;
      esac
    fi
    state_path_for_acquire "$state_file" || {
      echo "maintain-leases: state file must use the common maintenance runtime directory" >&2; exit 2; }
    [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || {
      echo "maintain-leases: lease state already exists" >&2; exit 1; }
    common_leases="$COMMON/saas-startup-team/leases"
    legacy_leases="$PRIMARY/.startup/leases"
    owner_dir="$common_leases/.owners"
    if [ ! -e "$common_leases" ] && [ ! -L "$common_leases" ]; then
      mkdir -- "$common_leases"
    fi
    if [ ! -e "$owner_dir" ] && [ ! -L "$owner_dir" ]; then
      mkdir -- "$owner_dir"
    fi
    if [ ! -e "$PRIMARY/.startup" ] && [ ! -L "$PRIMARY/.startup" ]; then
      mkdir -- "$PRIMARY/.startup"
    fi
    [ -d "$PRIMARY/.startup" ] && [ ! -L "$PRIMARY/.startup" ] || {
      echo "maintain-leases: unsafe primary state directory" >&2; exit 1; }
    if [ ! -e "$legacy_leases" ] && [ ! -L "$legacy_leases" ]; then
      mkdir -- "$legacy_leases"
    fi
    [ -d "$COMMON/saas-startup-team" ] && [ ! -L "$COMMON/saas-startup-team" ] \
      && [ -d "$common_leases" ] && [ ! -L "$common_leases" ] \
      && [ -d "$owner_dir" ] && [ ! -L "$owner_dir" ] \
      && [ -d "$PRIMARY/.startup" ] && [ ! -L "$PRIMARY/.startup" ] \
      && [ -d "$legacy_leases" ] && [ ! -L "$legacy_leases" ] || {
        echo "maintain-leases: unsafe lease directory" >&2; exit 1; }
    kinds=(legacy-maintain legacy-loop shared)
    keys=(maintain-pass maintain-loop:pass maintain-delivery:pass)
    dirs=("$common_leases" "$legacy_leases" "$common_leases")
    if [ -n "$worktree" ]; then
      kinds+=(worktree)
      keys+=("$(worktree_lease_key "$mode" "$worktree")")
      dirs+=("$common_leases")
    fi
    owners=(); acquired=0
    for kind in "${kinds[@]}"; do owners+=("$owner_dir/$mode-$run_id-$kind.owner"); done
    cleanup_partial() {
      local i
      set +e
      for ((i=acquired-1; i>=0; i--)); do
        bash "$SINGLE_FLIGHT" --release "${keys[$i]}" --state-dir "${dirs[$i]}" \
          --owner-file "${owners[$i]}" >/dev/null 2>&1
      done
      rm -f -- "$STATE_FILE"
    }
    trap cleanup_partial EXIT
    for ((i=0; i<${#keys[@]}; i++)); do
      kind=${kinds[$i]}
      bash "$SINGLE_FLIGHT" --acquire "${keys[$i]}" --state-dir "${dirs[$i]}" \
        --owner-file "${owners[$i]}" --ttl-seconds "${LEASE_TTL_SECONDS[$kind]}" --replace-stale \
        --reason "maintenance lease expired before run $run_id" >/dev/null
      acquired=$((acquired + 1))
      if [ "$kind" = shared ] && ! foreign_worktree_leases_available "$mode" "$worktree"; then
        exit 1
      fi
    done
    leases_json=$(for ((i=0; i<${#keys[@]}; i++)); do
      jq -cn --arg kind "${kinds[$i]}" --arg key "${keys[$i]}" \
        --arg state_dir "${dirs[$i]}" --arg owner_file "${owners[$i]}" \
        '{kind:$kind,key:$key,state_dir:$state_dir,owner_file:$owner_file}'
    done | jq -s '.')
    state_tmp=$(mktemp "$STATE_FILE.tmp.XXXXXX")
    jq -n --argjson schema_version "$state_schema" \
      --arg run_id "$run_id" --arg mode "$mode" --arg repo_root "$ROOT" \
      --arg primary_root "$PRIMARY" --arg common_dir "$COMMON" --arg worktree "$worktree" \
      --argjson leases "$leases_json" \
      '{schema_version:$schema_version,run_id:$run_id,mode:$mode,repo_root:$repo_root,
        primary_root:$primary_root,common_dir:$common_dir,worktree:$worktree,leases:$leases}' > "$state_tmp"
    chmod 600 "$state_tmp"; mv -- "$state_tmp" "$STATE_FILE"
    trap - EXIT
    printf '%s\n' "$STATE_FILE"
    ;;

  controller-binding)
    [ -n "$repo_root" ] && [ -n "$worktree" ] && [ -n "$run_id" ] && [ -n "$state_file" ] \
      && [ -z "$mode$run_state$blocked_file" ] || usage
    valid_id "$run_id" || { echo "maintain-leases: invalid controller run id" >&2; exit 2; }
    load_controller_state "$repo_root" "$worktree" "$run_id" "$state_file" || exit 1
    echo "maintain-leases: controller binding valid"
    ;;

  activate)
    [ -n "$state_file" ] && [ -n "$run_state" ] \
      && [ -z "$repo_root$mode$run_id$worktree" ] || usage
    load_state "$state_file" || exit 1
    [ "$MODE" = maintain-loop ] || {
      echo "maintain-leases: activate accepts only maintain-loop lease state; normal maintain owns .startup/maintain/current-run.json" >&2
      exit 2
    }
    heartbeat_specs || {
      echo "maintain-leases: activation lease ownership is no longer valid" >&2
      exit 1
    }
    resolve_run_state_path "$run_state" 1 || {
      echo "maintain-leases: run state path is unsafe" >&2; exit 1; }
    if [ -e "$RUN_STATE_PATH" ] || [ -L "$RUN_STATE_PATH" ]; then
      [ -f "$RUN_STATE_PATH" ] && [ ! -L "$RUN_STATE_PATH" ] || {
        echo "maintain-leases: active run state is unsafe" >&2; exit 1; }
      if stale_run_id=$(jq -er '.run_id | select(type == "string" and length > 0)' "$RUN_STATE_PATH" 2>/dev/null); then
        [ "$stale_run_id" != "$RUN_ID" ] || {
          echo "maintain-leases: active run state matches this run" >&2; exit 1; }
      fi
      rm -f -- "$RUN_STATE_PATH"
    fi
    [ "$blocked_file" = "$COMMON/saas-startup-team/maintain/blocked.jsonl" ] || {
      echo "maintain-leases: blocked ledger binding is invalid" >&2; exit 1; }
    run_tmp=$(mktemp "$RUN_STATE_PATH.tmp.XXXXXX")
    jq -n --arg run_id "$RUN_ID" --arg repo_root "$PRIMARY" \
      --arg worktree "$WORKTREE_BINDING" --arg lease_state "$STATE_FILE" \
      --arg blocked_file "$blocked_file" \
      '{schema_version:1,run_id:$run_id,repo_root:$repo_root,worktree:$worktree,
        lease_state:$lease_state,blocked_file:$blocked_file}' > "$run_tmp"
    chmod 600 "$run_tmp"; mv -- "$run_tmp" "$RUN_STATE_PATH"
    printf '%s\n' "$RUN_STATE_PATH"
    ;;

  heartbeat)
    [ -n "$state_file" ] && [ -z "$mode$run_state$blocked_file" ] || usage
    load_requested_state "$state_file" || exit 1
    heartbeat_specs || exit 1
    echo "maintain-leases: heartbeat complete"
    ;;

  hold)
    [ -n "$state_file" ] && [ "${#command[@]}" -gt 0 ] \
      && [ -z "$mode$run_state$blocked_file" ] \
      && valid_uint "$interval" && valid_uint "$max_seconds" || usage
    [ "$interval" -le 60 ] || {
      echo "maintain-leases: heartbeat interval must be at most 60 seconds" >&2
      exit 2
    }
    [ "$max_seconds" -le 14400 ] || {
      echo "maintain-leases: maximum hold lifetime is 14400 seconds" >&2
      exit 2
    }
    load_requested_state "$state_file" || exit 1
    guardian_args=(hold --interval-seconds "$interval" --max-seconds "$max_seconds")
    while IFS=$'\t' read -r kind key state_dir owner_file; do
      guardian_args+=(--lease-at "$state_dir" "$key" "$owner_file")
    done < "$LEASE_ROWS_FILE"
    guardian_args+=(-- "${command[@]}")
    rm -f -- "$LEASE_ROWS_FILE"; LEASE_ROWS_FILE=""
    exec bash "$GUARDIAN" "${guardian_args[@]}"
    ;;

  reap-terminal)
    [ -n "$repo_root" ] && [ -n "$run_id" ] \
      && [ -z "$state_file$mode$worktree$run_state$blocked_file" ] || usage
    valid_id "$run_id" || { echo "maintain-leases: invalid run id" >&2; exit 2; }
    resolve_repo "$repo_root" || { echo "maintain-leases: cannot resolve repository" >&2; exit 1; }
    terminal_state="$COMMON/saas-startup-team/maintain-runtime/$run_id-leases.json"
    if [ ! -e "$terminal_state" ] && [ ! -L "$terminal_state" ]; then
      echo "maintain-leases: terminal run has no lease state"
      exit 0
    fi
    load_state "$terminal_state" || exit 1
    [ "$RUN_ID" = "$run_id" ] || {
      echo "maintain-leases: terminal run id does not match lease state" >&2; exit 1; }
    case "$MODE:$STATE_SCHEMA:$WORKTREE_BINDING" in
      "maintain:3:$PRIMARY/.worktrees/maintain"|"maintain-loop:2:$PRIMARY/.worktrees/maintain-loop") : ;;
      *) echo "maintain-leases: terminal lease state has no supported controller binding" >&2; exit 2 ;;
    esac
    rc=0
    release_specs || rc=1
    [ "$rc" -ne 0 ] || rm -f -- "$STATE_FILE"
    [ "$rc" -eq 0 ] || exit 1
    echo "maintain-leases: terminal run reaped"
    ;;

  cleanup)
    [ -n "$state_file" ] && [ -z "$repo_root$mode$worktree$blocked_file" ] || usage
    load_state "$state_file" || exit 1
    [ -z "$expected_run_id" ] || [ "$expected_run_id" = "$RUN_ID" ] || {
      echo "maintain-leases: cleanup run id does not match lease state" >&2; exit 1; }
    rc=0
    release_specs || rc=1
    if [ -n "$run_state" ]; then
      if ! resolve_run_state_path "$run_state" 0; then
        echo "maintain-leases: run state path is unsafe" >&2
        rc=1
      elif [ -e "$RUN_STATE_PATH" ] || [ -L "$RUN_STATE_PATH" ]; then
        if [ -f "$RUN_STATE_PATH" ] && [ ! -L "$RUN_STATE_PATH" ] \
          && jq -e --arg run_id "$RUN_ID" '.run_id == $run_id' "$RUN_STATE_PATH" >/dev/null 2>&1; then
          rm -f -- "$RUN_STATE_PATH" || rc=1
        else
          echo "maintain-leases: run state does not match cleanup identity" >&2
          rc=1
        fi
      fi
    fi
    [ "$rc" -ne 0 ] || rm -f -- "$STATE_FILE"
    [ "$rc" -eq 0 ] || exit 1
    echo "maintain-leases: cleanup complete"
    ;;

  *) usage ;;
esac
