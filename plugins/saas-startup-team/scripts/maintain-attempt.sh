#!/usr/bin/env bash
# Exact worktree reset, canonical base check, and one-shell source delivery.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LEASES="$SCRIPT_DIR/maintain-leases.sh"
SUPERVISOR="$SCRIPT_DIR/supervisor-commit.sh"
GUARD="$SCRIPT_DIR/delivery-mutation-guard.sh"
ROUTE="$SCRIPT_DIR/delivery-route.sh"
ROLE_RUNNER="$SCRIPT_DIR/codex-run-role.sh"
AUTH_HELPER="$SCRIPT_DIR/mutation-auth-token.sh"

usage() {
  cat >&2 <<'EOF'
usage: maintain-attempt.sh reset --repo-root DIR --worktree DIR --base-sha SHA --lease-state FILE --run-id ID
       maintain-attempt.sh base-check --repo-root DIR --base-sha SHA --lease-state FILE --run-id ID --cache-dir DIR [--check PATH]
       maintain-attempt.sh deliver --repo-root DIR --base-sha SHA --lease-state FILE --run-id ID --attempt N --profile light|standard|deep --task-file FILE --message TEXT [--check PATH] [--routing-reasons CODES] --allow PATH...
EOF
  exit 2
}

valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; }
valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; }

resolve_repo() {
  ROOT="$(cd -- "$1" && pwd -P)" || return 1
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir)" || return 1
  GIT_DIR="$(cd -- "$GIT_DIR" && pwd -P)" || return 1
  COMMON="$(git -C "$ROOT" rev-parse --git-common-dir)" || return 1
  case "$COMMON" in /*) : ;; *) COMMON="$ROOT/$COMMON" ;; esac
  COMMON="$(cd -- "$COMMON" && pwd -P)" || return 1
}

normalize_base() {
  valid_sha "$base_sha" || { echo "maintain-attempt: invalid base SHA" >&2; return 1; }
  resolved_base=$(git -C "$ROOT" rev-parse "$base_sha^{commit}") || return 1
  [ "$resolved_base" = "$base_sha" ] || {
    echo "maintain-attempt: base SHA must be exact" >&2; return 1; }
}

normalize_check() {
  local rel mode
  case "$check_script" in
    /*) case "$check_script" in "$ROOT"/*) rel=${check_script#"$ROOT"/} ;; *) return 1 ;; esac ;;
    *) rel=${check_script#./} ;;
  esac
  case "$rel" in ''|/*|../*|*/../*|*/..|./*|*/./*|*//*) return 1 ;; esac
  git -C "$ROOT" cat-file -e "$base_sha:$rel" 2>/dev/null || return 1
  mode=$(git -C "$ROOT" ls-tree "$base_sha" -- "$rel" | awk 'NR == 1 {print $1}')
  case "$mode" in 100644|100755) : ;; *) return 1 ;; esac
  [ -f "$ROOT/$rel" ] && [ ! -L "$ROOT/$rel" ] || return 1
  CHECK_OID=$(git -C "$ROOT" rev-parse "$base_sha:$rel") || return 1
  CHECK_REL="$rel"; CHECK_SCRIPT="./$rel"
}

assert_exact_clean_base() {
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$base_sha" ] || {
    echo "maintain-attempt: worktree HEAD does not equal BASE_SHA" >&2; return 1; }
  git -C "$ROOT" diff --quiet -- . && git -C "$ROOT" diff --cached --quiet -- . || {
    echo "maintain-attempt: base worktree is dirty" >&2; return 1; }
  [ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ] || {
    echo "maintain-attempt: base worktree has untracked state" >&2; return 1; }
}

registered_worktree() {
  local record candidate rows found=1
  rows=$(mktemp) || return 1
  if ! git -C "$ROOT" worktree list --porcelain -z > "$rows"; then
    rm -f -- "$rows"
    return 1
  fi
  while IFS= read -r -d '' record; do
    case "$record" in
      'worktree '*)
        candidate=${record#worktree }
        if [ "$candidate" = "$worktree" ]; then found=0; break; fi
        ;;
    esac
  done < "$rows"
  rm -f -- "$rows"
  return "$found"
}

reset_once() {
  git -C "$worktree" checkout --detach --quiet "$base_sha" || return 1
  git -C "$worktree" reset --hard "$base_sha" >/dev/null || return 1
  git -C "$worktree" clean -ffdx -q || return 1
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$base_sha" ] || return 1
  git -C "$worktree" diff --quiet -- . || return 1
  git -C "$worktree" diff --cached --quiet -- . || return 1
  [ -z "$(git -C "$worktree" status --porcelain=v1 --untracked-files=all)" ] || return 1
}

load_lease_identity() {
  local expected_worktree="${1:-$ROOT}" lease_common lease_repo lease_primary state_primary state_parent state_worktree
  [ -f "$lease_state" ] && [ ! -L "$lease_state" ] || return 1
  jq -e --arg run_id "$run_id" '
    .schema_version == 2 and .mode == "maintain-loop" and .run_id == $run_id
    and (.primary_root|type == "string") and (.common_dir|type == "string")
    and (.worktree|type == "string" and startswith("/"))' \
    "$lease_state" >/dev/null || return 1
  state_primary=$(jq -r .primary_root "$lease_state")
  lease_common=$(jq -r .common_dir "$lease_state")
  lease_repo=$(jq -r .repo_root "$lease_state")
  state_worktree=$(jq -r .worktree "$lease_state")
  PRIMARY=$(bash "$LEASES" primary-root --repo-root "$ROOT") || return 1
  lease_primary=$(bash "$LEASES" primary-root --repo-root "$lease_repo") || return 1
  [ "$PRIMARY" = "$state_primary" ] && [ "$lease_primary" = "$PRIMARY" ] || return 1
  [ "$lease_common" = "$COMMON" ] || return 1
  expected_worktree=$(realpath -m -- "$expected_worktree") || return 1
  [ "$state_worktree" = "$expected_worktree" ] \
    && [ "$state_worktree" = "$PRIMARY/.worktrees/maintain" ] || return 1
  state_parent=$(dirname -- "$lease_state")
  [ -d "$state_parent" ] && [ ! -L "$state_parent" ] || return 1
  [ "$(cd -- "$state_parent" && pwd -P)" = "$COMMON/saas-startup-team/maintain-runtime" ] || return 1
}

require_base_gate() {
  local gate
  ensure_common_dir "saas-startup-team/maintain-runtime/base-checks/$run_id" 0 || return 1
  gate="$SAFE_DIR/$base_sha.json"
  [ -f "$gate" ] && [ ! -L "$gate" ] || {
    echo "maintain-attempt: protected base-check cache is missing" >&2; return 1; }
  jq -e --arg run_id "$run_id" --arg base "$base_sha" --arg check_rel "$CHECK_REL" --arg check_oid "$CHECK_OID" '
    .schema_version == 1 and .run_id == $run_id and .base_sha == $base and .status == "passed"
    and .check_rel == $check_rel and .check_oid == $check_oid' "$gate" >/dev/null || {
      echo "maintain-attempt: base-check cache does not match CHECK_SCRIPT" >&2
      return 1
    }
}

ensure_primary_dir() {
  local rel="$1" create="$2" part current="$PRIMARY"
  case "$rel" in ''|/*|../*|*/../*|*/..|*//*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  IFS=/ read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    [ -n "$part" ] && [ "$part" != . ] && [ "$part" != .. ] || return 1
    current="$current/$part"
    if [ ! -e "$current" ] && [ ! -L "$current" ] && [ "$create" -eq 1 ]; then
      mkdir -- "$current" || return 1
    fi
    [ -d "$current" ] && [ ! -L "$current" ] \
      && [ "$(cd -- "$current" && pwd -P)" = "$current" ] || return 1
  done
  SAFE_DIR="$current"
}

ensure_common_dir() {
  local rel="$1" create="$2" part current="$COMMON"
  case "$rel" in ''|/*|../*|*/../*|*/..|*//*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  IFS=/ read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    [ -n "$part" ] && [ "$part" != . ] && [ "$part" != .. ] || return 1
    current="$current/$part"
    if [ ! -e "$current" ] && [ ! -L "$current" ] && [ "$create" -eq 1 ]; then
      mkdir -- "$current" || return 1
    fi
    [ -d "$current" ] && [ ! -L "$current" ] \
      && [ "$(cd -- "$current" && pwd -P)" = "$current" ] || return 1
  done
  SAFE_DIR="$current"
}

cleanup_trust() {
  local receipt="$1"
  [ -n "$receipt" ] || return 0
  chmod -R u+w -- "${receipt}.hooks" "${receipt}.firewall" 2>/dev/null || true
  rm -rf -- "$receipt" "${receipt}.hooks" "${receipt}.firewall"
}

cleanup_role_guard() {
  local guard="$1" artifact rc=0
  [ -n "$guard" ] || return 0
  shopt -s nullglob
  for artifact in "$guard" "$guard.active" "$guard.verified" \
    "$guard.telemetry-identity-key" "$guard.telemetry-"*.json \
    "$guard.events-"*.jsonl "$guard.events-"*.jsonl.identity-key \
    "$guard.events-"*.jsonl.lock "$guard.logs-"*; do
    rm -rf -- "$artifact" || rc=1
  done
  shopt -u nullglob
  return "$rc"
}

resolve_worktree_metadata() {
  local target_git_dir metadata_root backpointer
  [ -d "$worktree" ] && [ ! -L "$worktree" ] \
    && [ "$(cd -- "$worktree" && pwd -P)" = "$worktree" ] || return 1
  [ -f "$worktree/.git" ] && [ ! -L "$worktree/.git" ] || return 1
  target_git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  case "$target_git_dir" in /*) : ;; *) return 1 ;; esac
  [ -d "$target_git_dir" ] && [ ! -L "$target_git_dir" ] \
    && [ "$(cd -- "$target_git_dir" && pwd -P)" = "$target_git_dir" ] || return 1
  metadata_root="$COMMON/worktrees"
  [ -d "$metadata_root" ] && [ ! -L "$metadata_root" ] \
    && [ "$(cd -- "$metadata_root" && pwd -P)" = "$metadata_root" ] \
    && [ "$(dirname -- "$target_git_dir")" = "$metadata_root" ] || return 1
  [ -f "$target_git_dir/gitdir" ] && [ ! -L "$target_git_dir/gitdir" ] || return 1
  backpointer=$(cat "$target_git_dir/gitdir") || return 1
  [ "$(realpath -m -- "$backpointer")" = "$worktree/.git" ] || return 1
  WORKTREE_GIT_DIR="$target_git_dir"
}

atomic_pointer_write() {
  local target="$1" value="$2" parent base tmp
  parent=$(dirname -- "$target"); base=$(basename -- "$target")
  if [ -e "$target" ] || [ -L "$target" ]; then
    { [ -f "$target" ] && [ ! -L "$target" ]; } || return 1
  fi
  tmp=$(mktemp "$parent/.$base.repair.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! chmod 600 "$tmp" \
    || ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

repair_worktree_metadata() {
  local metadata_root candidate="" entry backpointer resolved commondir
  [ -d "$worktree" ] && [ ! -L "$worktree" ] \
    && [ "$(cd -- "$worktree" && pwd -P)" = "$worktree" ] || return 1
  [ -f "$worktree/.git" ] && [ ! -L "$worktree/.git" ] || return 1
  metadata_root="$COMMON/worktrees"
  [ -d "$metadata_root" ] && [ ! -L "$metadata_root" ] \
    && [ "$(cd -- "$metadata_root" && pwd -P)" = "$metadata_root" ] || return 1

  shopt -s nullglob
  for entry in "$metadata_root"/*; do
    [ -d "$entry" ] && [ ! -L "$entry" ] \
      && [ "$(cd -- "$entry" && pwd -P)" = "$entry" ] || continue
    [ -f "$entry/gitdir" ] && [ ! -L "$entry/gitdir" ] || continue
    backpointer=$(cat "$entry/gitdir") || { shopt -u nullglob; return 1; }
    case "$backpointer" in /*) : ;; *) backpointer="$entry/$backpointer" ;; esac
    resolved=$(realpath -m -- "$backpointer") || { shopt -u nullglob; return 1; }
    if [ "$resolved" = "$worktree/.git" ]; then
      [ -z "$candidate" ] || {
        shopt -u nullglob
        return 1
      }
      candidate=$entry
    fi
  done
  shopt -u nullglob

  [ -n "$candidate" ] || return 1
  [ -f "$candidate/gitdir" ] && [ ! -L "$candidate/gitdir" ] \
    && [ -f "$candidate/commondir" ] && [ ! -L "$candidate/commondir" ] || return 1
  commondir=$(cat "$candidate/commondir") || return 1
  case "$commondir" in /*) : ;; *) commondir="$candidate/$commondir" ;; esac
  [ "$(realpath -m -- "$commondir")" = "$COMMON" ] || return 1

  atomic_pointer_write "$worktree/.git" "gitdir: $candidate" \
    && resolve_worktree_metadata
}

cleanup_abandoned_role_guards() {
  local target_git_dir guard_dir marker base prefix_base prefix artifact unsafe
  local -a markers=() prefixes=() family=()
  local -A seen=()
  if [ ! -e "$worktree" ] && [ ! -L "$worktree" ]; then return 0; fi
  resolve_worktree_metadata || return 1
  target_git_dir=$WORKTREE_GIT_DIR
  guard_dir="$target_git_dir/saas-startup-team"
  if [ ! -e "$guard_dir" ] && [ ! -L "$guard_dir" ]; then return 0; fi
  [ -d "$guard_dir" ] && [ ! -L "$guard_dir" ] \
    && [ "$(cd -- "$guard_dir" && pwd -P)" = "$guard_dir" ] || return 1

  shopt -s nullglob
  markers=("$guard_dir"/*.active "$guard_dir"/*.verified)
  shopt -u nullglob
  for marker in "${markers[@]}"; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    base=$(basename -- "$marker")
    case "$base" in
      *.active) prefix_base=${base%.active} ;;
      *.verified) prefix_base=${base%.verified} ;;
      *) return 1 ;;
    esac
    [[ "$prefix_base" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,190}$ ]] || return 1
    if [ -z "${seen[$prefix_base]+x}" ]; then
      seen[$prefix_base]=1
      prefixes+=("$guard_dir/$prefix_base")
    fi
  done

  for prefix in "${prefixes[@]}"; do
    family=()
    for artifact in "$prefix" "$prefix.active" "$prefix.verified" \
      "$prefix.telemetry-identity-key"; do
      if [ -e "$artifact" ] || [ -L "$artifact" ]; then family+=("$artifact"); fi
    done
    shopt -s nullglob
    family+=("$prefix.telemetry-"*.json \
      "$prefix.events-"*.jsonl "$prefix.events-"*.jsonl.identity-key \
      "$prefix.events-"*.jsonl.lock "$prefix.logs-"*)
    shopt -u nullglob
    for artifact in "${family[@]}"; do
      case "$artifact" in
        "$prefix.logs-"*)
          [ -d "$artifact" ] && [ ! -L "$artifact" ] || return 1
          unsafe=$(find -P "$artifact" -mindepth 1 \
            \( -type l -o \( ! -type f -a ! -type d \) \) -print -quit 2>/dev/null) \
            || return 1
          [ -z "$unsafe" ] || return 1
          ;;
        *) [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 1 ;;
      esac
    done
  done
  for prefix in "${prefixes[@]}"; do cleanup_role_guard "$prefix" || return 1; done
}

write_attempt_result() {
  local status="$1" route_json="$2" result_dir result tmp head
  ensure_primary_dir ".startup/maintain-loop/attempt-results/$run_id" 1 || return 1
  result_dir="$SAFE_DIR"
  result="$result_dir/issue-$ISSUE_NUMBER-attempt-$attempt.json"
  if [ -e "$result" ] || [ -L "$result" ]; then
    [ -f "$result" ] && [ ! -L "$result" ] || return 1
  fi
  tmp=$(mktemp "$result.tmp.XXXXXX") || return 1
  head=$(git -C "$ROOT" rev-parse HEAD) || { rm -f -- "$tmp"; return 1; }
  if ! jq -n --arg run_id "$run_id" --argjson attempt "$attempt" --arg status "$status" \
      --arg base_sha "$base_sha" --arg head_sha "$head" --argjson route "$route_json" \
      '{schema_version:1,run_id:$run_id,attempt:$attempt,status:$status,
        base_sha:$base_sha,head_sha:$head_sha,route:$route}' > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -T -- "$tmp" "$result"; then
    rm -f -- "$tmp"
    return 1
  fi
  [ -f "$result" ] && [ ! -L "$result" ] \
    && jq -e --arg run_id "$run_id" --argjson attempt "$attempt" --arg status "$status" \
      --arg base_sha "$base_sha" --arg head_sha "$head" --argjson route "$route_json" '
      type == "object"
      and (keys == ["attempt","base_sha","head_sha","route","run_id","schema_version","status"])
      and .schema_version == 1 and .run_id == $run_id and .attempt == $attempt
      and .status == $status and .base_sha == $base_sha and .head_sha == $head_sha
      and .route == $route
    ' "$result" >/dev/null
}

normalize_task_file() {
  local supplied="$task_file" prompt_dir base
  case "$supplied" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  case "$supplied" in /*) : ;; *) supplied="$ROOT/$supplied" ;; esac
  [ ! -L "$supplied" ] || return 1
  task_file="$(realpath -e -- "$supplied")" || return 1
  [ -f "$task_file" ] && [ ! -L "$task_file" ] || return 1
  ensure_primary_dir ".startup/maintain-loop/prompts/$run_id" 0 || return 1
  prompt_dir="$SAFE_DIR"
  [ "$(dirname -- "$task_file")" = "$prompt_dir" ] || return 1
  base=$(basename -- "$task_file")
  if [[ "$base" =~ ^issue-([1-9][0-9]*)-attempt-${attempt}\.md$ ]]; then
    ISSUE_NUMBER=${BASH_REMATCH[1]}
  else
    return 1
  fi
}

action=${1:-}; [ -n "$action" ] || usage; shift
repo_root=""; worktree=""; base_sha=""; lease_state=""; run_id=""
cache_dir=""; check_script="./check.sh"; attempt=""; profile=""; task_file=""
message=""; routing_reasons=""; allow=()
ISSUE_NUMBER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root) [ "$#" -ge 2 ] || usage; repo_root=$2; shift 2 ;;
    --worktree) [ "$#" -ge 2 ] || usage; worktree=$2; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; base_sha=$2; shift 2 ;;
    --lease-state) [ "$#" -ge 2 ] || usage; lease_state=$2; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; run_id=$2; shift 2 ;;
    --cache-dir) [ "$#" -ge 2 ] || usage; cache_dir=$2; shift 2 ;;
    --check) [ "$#" -ge 2 ] || usage; check_script=$2; shift 2 ;;
    --attempt) [ "$#" -ge 2 ] || usage; attempt=$2; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || usage; profile=$2; shift 2 ;;
    --task-file) [ "$#" -ge 2 ] || usage; task_file=$2; shift 2 ;;
    --message) [ "$#" -ge 2 ] || usage; message=$2; shift 2 ;;
    --routing-reasons) [ "$#" -ge 2 ] || usage; routing_reasons=$2; shift 2 ;;
    --allow) [ "$#" -ge 2 ] || usage; allow+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done

valid_reset_args() {
  [ -n "$repo_root" ] && [ -n "$worktree" ] && [ -n "$base_sha" ] \
    && [ -n "$lease_state" ] && [ -n "$run_id" ] && valid_id "$run_id" \
    && [ -z "$cache_dir$attempt$profile$task_file$message$routing_reasons" ] \
    && [ "${#allow[@]}" -eq 0 ]
}

case "$action" in
  reset)
    valid_reset_args || usage
    reset_hold_token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [[ "$reset_hold_token" =~ ^[0-9a-f]{32}$ ]] || {
      echo "maintain-attempt: cannot create reset hold identity" >&2; exit 1; }
    exec bash "$LEASES" hold --state-file "$lease_state" --interval-seconds 1 \
      --max-seconds 300 -- env SAAS_MAINTAIN_RESET_HOLD_TOKEN="$reset_hold_token" \
      bash "$SCRIPT_DIR/maintain-attempt.sh" _reset-held \
        --repo-root "$repo_root" --worktree "$worktree" --base-sha "$base_sha" \
        --lease-state "$lease_state" --run-id "$run_id"
    ;;

  _reset-held)
    valid_reset_args || usage
    [[ "${SAAS_MAINTAIN_RESET_HOLD_TOKEN:-}" =~ ^[0-9a-f]{32}$ ]] || {
      echo "maintain-attempt: reset must run under the lease holder" >&2; exit 1; }
    unset SAAS_MAINTAIN_RESET_HOLD_TOKEN
    resolve_repo "$repo_root" || { echo "maintain-attempt: invalid repository" >&2; exit 1; }
    normalize_base || exit 1
    worktree="$(realpath -m -- "$worktree")"
    load_lease_identity "$worktree" || {
      echo "maintain-attempt: reset target does not match the acquired worktree" >&2; exit 1; }
    bash "$LEASES" heartbeat --state-file "$lease_state" >/dev/null || {
      echo "maintain-attempt: reset lease ownership is no longer valid" >&2; exit 1; }
    if [ -e "$worktree" ] || [ -L "$worktree" ]; then
      resolve_worktree_metadata || repair_worktree_metadata || {
        echo "maintain-attempt: existing worktree metadata is unsafe" >&2; exit 1; }
      registered_worktree || {
        echo "maintain-attempt: unregistered worktree path exists" >&2; exit 1; }
    elif ! registered_worktree; then
      git -C "$ROOT" worktree add --detach --quiet "$worktree" "$base_sha" || exit 1
    fi
    cleanup_abandoned_role_guards || {
      echo "maintain-attempt: abandoned mutation guard metadata is unsafe" >&2
      exit 1
    }
    if ! reset_once; then
      git -C "$ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || {
        echo "maintain-attempt: cannot recreate dedicated worktree" >&2; exit 1; }
      git -C "$ROOT" worktree add --detach --quiet "$worktree" "$base_sha" || exit 1
      reset_once || {
        echo "maintain-attempt: exact worktree reset failed" >&2
        { git -C "$worktree" status --porcelain=v1 --untracked-files=all
          git -C "$worktree" clean -ndffx; } | sed -n '1,20p' >&2
        exit 1
      }
    fi
    [ "$(git -C "$worktree" rev-parse HEAD)" = "$base_sha" ] \
      && [ -z "$(git -C "$worktree" status --porcelain=v1 --untracked-files=all)" ] || {
        echo "maintain-attempt: exact post-reset BASE_SHA assertion failed" >&2; exit 1; }
    printf 'maintain-attempt: reset %s\n' "$base_sha"
    ;;

  base-check)
    [ -n "$repo_root" ] && [ -n "$base_sha" ] && [ -n "$lease_state" ] \
      && [ -n "$run_id" ] && [ -n "$cache_dir" ] && valid_id "$run_id" || usage
    resolve_repo "$repo_root" || { echo "maintain-attempt: invalid worktree" >&2; exit 1; }
    normalize_base || exit 1
    load_lease_identity || { echo "maintain-attempt: lease identity mismatch" >&2; exit 1; }
    normalize_check || { echo "maintain-attempt: CHECK_SCRIPT is not a tracked regular base file" >&2; exit 1; }
    assert_exact_clean_base || exit 1
    ensure_common_dir "saas-startup-team/maintain-runtime/base-checks/$run_id" 1 || {
      echo "maintain-attempt: unsafe base-check cache directory" >&2; exit 1; }
    expected_cache="$SAFE_DIR"
    case "$cache_dir" in /*) cache_supplied=$cache_dir ;; *) cache_supplied="$ROOT/$cache_dir" ;; esac
    [ ! -L "$cache_supplied" ] && [ "$(realpath -m -- "$cache_supplied")" = "$expected_cache" ] || {
      echo "maintain-attempt: invalid base-check cache directory" >&2; exit 2; }
    cache_dir="$expected_cache"
    ensure_primary_dir ".startup/maintain-loop/base-checks/$run_id" 1 || {
      echo "maintain-attempt: unsafe base-check evidence directory" >&2; exit 1; }
    summary="$SAFE_DIR/$base_sha.summary"
    [ ! -L "$summary" ] && { [ ! -e "$summary" ] || [ -f "$summary" ]; } || {
      echo "maintain-attempt: unsafe base-check summary" >&2; exit 1; }
    gate="$cache_dir/$base_sha.json"
    if [ -e "$gate" ] || [ -L "$gate" ]; then
      assert_exact_clean_base || exit 1
      [ -f "$gate" ] && [ ! -L "$gate" ] \
        && jq -e --arg run_id "$run_id" --arg base "$base_sha" --arg check_rel "$CHECK_REL" \
          --arg check_oid "$CHECK_OID" \
          '.schema_version == 1 and .run_id == $run_id and .base_sha == $base and .status == "passed"
            and .check_rel == $check_rel and .check_oid == $check_oid' \
          "$gate" >/dev/null || { echo "maintain-attempt: invalid base-check cache" >&2; exit 1; }
      echo "maintain-attempt: cached base checks passed"
      exit 0
    fi
    auth=$(bash "$AUTH_HELPER")
    trust=$(git -C "$ROOT" rev-parse --git-path "saas-startup-team/base-check-$run_id-$base_sha.json")
    summary_tmp=$(mktemp "$summary.tmp.XXXXXX")
    cleanup_base_attempt() {
      cleanup_trust "$trust"
      [ -z "${summary_tmp:-}" ] || rm -f -- "$summary_tmp"
    }
    trap cleanup_base_attempt EXIT
    assert_exact_clean_base || exit 1
    bash "$LEASES" hold --state-file "$lease_state" -- \
      bash "$SUPERVISOR" --repo-root "$ROOT" --snapshot-trust "$trust" \
        --check-only --check "$CHECK_SCRIPT" --auth-stdin <<<"$auth" >/dev/null
    check_rc=0
    bash "$LEASES" hold --state-file "$lease_state" -- \
      bash "$SUPERVISOR" --repo-root "$ROOT" --check-only --trust-receipt "$trust" \
        --check "$CHECK_SCRIPT" --auth-stdin <<<"$auth" >"$summary_tmp" 2>&1 || check_rc=$?
    unset auth
    chmod 600 "$summary_tmp"; mv -- "$summary_tmp" "$summary"; summary_tmp=""
    if [ "$check_rc" -ne 0 ]; then
      [ ! -s "$summary" ] || sed -n '1,20p' "$summary" >&2
      exit "$check_rc"
    fi
    assert_exact_clean_base || exit 1
    gate_tmp=$(mktemp "$gate.tmp.XXXXXX")
    jq -n --arg run_id "$run_id" --arg base_sha "$base_sha" --arg check_rel "$CHECK_REL" \
      --arg check_oid "$CHECK_OID" --arg checked_at "$(date -u +%FT%TZ)" \
      '{schema_version:1,run_id:$run_id,base_sha:$base_sha,check_rel:$check_rel,check_oid:$check_oid,
        status:"passed",checked_at:$checked_at}' > "$gate_tmp"
    chmod 600 "$gate_tmp"; mv -- "$gate_tmp" "$gate"
    cleanup_base_attempt
    trap - EXIT
    echo "maintain-attempt: base checks passed"
    ;;

  deliver)
    [ -n "$repo_root" ] && [ -n "$base_sha" ] && [ -n "$lease_state" ] \
      && [ -n "$run_id" ] && [ -n "$attempt" ] && [ -n "$profile" ] \
      && [ -n "$task_file" ] && [ -n "$message" ] && [ "${#allow[@]}" -gt 0 ] \
      && valid_id "$run_id" && valid_uint "$attempt" || usage
    case "$profile" in light|standard|deep) : ;; *) usage ;; esac
    resolve_repo "$repo_root" || { echo "maintain-attempt: invalid worktree" >&2; exit 1; }
    normalize_base || exit 1
    load_lease_identity || { echo "maintain-attempt: lease identity mismatch" >&2; exit 1; }
    normalize_check || { echo "maintain-attempt: CHECK_SCRIPT is not a tracked regular base file" >&2; exit 1; }
    [ "$(git -C "$ROOT" rev-parse HEAD)" = "$base_sha" ] \
      && [ -n "$(git -C "$ROOT" symbolic-ref -q HEAD 2>/dev/null || true)" ] || {
        echo "maintain-attempt: delivery branch is not at BASE_SHA" >&2; exit 1; }
    assert_exact_clean_base || exit 1
    require_base_gate || exit 1
    normalize_task_file || {
      echo "maintain-attempt: task file is unsafe" >&2; exit 1; }
    auth=$(bash "$AUTH_HELPER")
    role_guard=$(git -C "$ROOT" rev-parse --git-path "saas-startup-team/role-$run_id-$attempt.json")
    commit_trust=$(git -C "$ROOT" rev-parse --git-path "saas-startup-team/commit-$run_id-$attempt.json")
    cleanup_delivery_attempt() {
      cleanup_role_guard "$role_guard"
      cleanup_trust "$commit_trust"
    }
    trap cleanup_delivery_attempt EXIT
    role_args=(bash "$GUARD" --repo-root "$ROOT" --snapshot "$role_guard" --auth-stdin)
    for path in "${allow[@]}"; do role_args+=(--allow "$path"); done
    bash "$LEASES" hold --state-file "$lease_state" -- "${role_args[@]}" \
      <<<"$auth" >/dev/null
    worker_rc=0
    bash "$LEASES" hold --state-file "$lease_state" -- \
      env SAAS_RUN_ID="$run_id" SAAS_ATTEMPT="$attempt" SAAS_COMMAND=maintain-loop \
        SAAS_PHASE=implementation SAAS_ROUTING_REASONS="$routing_reasons" \
        SAAS_AGENT_EVENTS_FILE="$PRIMARY/.startup/runs/agent-events.jsonl" \
        SAAS_CODEX_LOG_DIR="$PRIMARY/.startup/runs/codex" \
        bash -c 'root=$1; shift; cd -- "$root" && exec "$@"' maintain-worker "$ROOT" \
          bash "$ROLE_RUNNER" --role tech-founder --profile "$profile" --task-file "$task_file" \
        || worker_rc=$?
    verify_rc=0
    bash "$LEASES" hold --state-file "$lease_state" -- \
      bash "$GUARD" --repo-root "$ROOT" --verify "$role_guard" --auth-stdin \
      <<<"$auth" >/dev/null || verify_rc=$?
    [ "$verify_rc" -eq 0 ] || { unset auth; exit "$verify_rc"; }
    [ "$worker_rc" -eq 0 ] || { unset auth; exit "$worker_rc"; }
    bash "$LEASES" heartbeat --state-file "$lease_state" >/dev/null
    route_rc=0
    route_json=$(cd "$ROOT" && bash "$ROUTE" check-diff --base "$base_sha" --guard-verified) || route_rc=$?
    jq -e '.schema_version == 1 and (.profile|type == "string")
      and (.ui_touch|type == "boolean") and (.decision|type == "string")' \
      <<<"$route_json" >/dev/null || { unset auth; exit 1; }
    route_profile=$(jq -r .profile <<<"$route_json")
    [ "$route_profile" != mechanical ] || {
      echo "maintain-attempt: source worker produced no delivery diff" >&2; unset auth; exit 1; }
    case "$route_rc" in
      0) : ;;
      20)
        if [ "$profile" != deep ]; then
          write_attempt_result escalated "$route_json"
          unset auth
          printf '%s\n' "$route_json"
          exit 20
        fi ;;
      *) unset auth; exit "$route_rc" ;;
    esac
    if [ "$profile" = light ] \
      && { [ "$route_profile" != light ] || [ "$(jq -r .ui_touch <<<"$route_json")" != false ]; }; then
      write_attempt_result escalated "$route_json"
      unset auth
      printf '%s\n' "$route_json"
      exit 20
    fi
    trust_args=(bash "$SUPERVISOR" --repo-root "$ROOT" --snapshot-trust "$commit_trust" --auth-stdin)
    for path in "${allow[@]}"; do trust_args+=(--allow "$path"); done
    bash "$LEASES" hold --state-file "$lease_state" -- "${trust_args[@]}" \
      <<<"$auth" >/dev/null
    commit_rc=0
    bash "$LEASES" hold --state-file "$lease_state" -- \
      bash "$SUPERVISOR" --repo-root "$ROOT" --message "$message" \
        --check "$CHECK_SCRIPT" --trust-receipt "$commit_trust" --auth-stdin \
      <<<"$auth" || commit_rc=$?
    unset auth
    [ "$commit_rc" -eq 0 ] || exit "$commit_rc"
    [ "$(git -C "$ROOT" rev-parse 'HEAD^')" = "$base_sha" ] || {
      echo "maintain-attempt: supervisor commit parent mismatch" >&2; exit 1; }
    write_attempt_result committed "$route_json"
    cleanup_delivery_attempt
    trap - EXIT
    printf '%s\n' "$route_json"
    ;;

  *) usage ;;
esac
