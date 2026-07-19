#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_PATH=${PATH:-/usr/bin:/bin}
if [ -n "${SAAS_MAINTAIN_ESCALATION_GH_BIN:-}" ]; then
  GH_CANDIDATE=$SAAS_MAINTAIN_ESCALATION_GH_BIN
else
  GH_CANDIDATE=$(PATH="$ORIGINAL_PATH" type -P gh 2>/dev/null || true)
fi
unset SAAS_MAINTAIN_ESCALATION_GH_BIN
PATH=/usr/bin:/bin
export PATH
unset -f bash env gh git jq readlink realpath stat timeout 2>/dev/null || true
unset BASH_ENV ENV CDPATH GLOBIGNORE GH_REPO GH_HOST GH_CONFIG_DIR \
  LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE GIT_GRAFT_FILE GIT_CONFIG \
  GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT GIT_CEILING_DIRECTORIES GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT \
  GIT_ASKPASS SSH_ASKPASS SSH_ASKPASS_REQUIRE GIT_PROXY_COMMAND GIT_EXEC_PATH
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LEASES="$SCRIPT_DIR/maintain-leases.sh"
ATTEMPT_HELPER="$SCRIPT_DIR/maintain-attempt.sh"

usage() {
  cat >&2 <<'EOF'
usage: maintain-escalation.sh cleanup|authorize-restart
  --repo-root DIR --worktree DIR --lease-state FILE --run-id ORIGIN
  --controller-run-id CONTROLLER
  --issue N --attempt N --base-sha SHA --branch NAME
EOF
  exit 2
}

die() { printf 'maintain-escalation: %s\n' "$1" >&2; exit "${2:-1}"; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; }
valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; }

absolute_path_has_no_symlink() {
  local path=$1 part cursor="" old_ifs owner mode
  case "$path" in /*) : ;; *) return 1 ;; esac
  old_ifs=$IFS; IFS=/
  for part in ${path#/}; do
    [ -n "$part" ] || { IFS=$old_ifs; return 1; }
    cursor="$cursor/$part"
    [ ! -L "$cursor" ] || { IFS=$old_ifs; return 1; }
    owner=$(/usr/bin/stat -c %u -- "$cursor") || { IFS=$old_ifs; return 1; }
    mode=$(/usr/bin/stat -c %a -- "$cursor") || { IFS=$old_ifs; return 1; }
    [ "$owner" = 0 ] && (( (8#$mode & 022) == 0 )) \
      || { IFS=$old_ifs; return 1; }
  done
  IFS=$old_ifs
}

resolve_repo_slug() {
  local origin slug
  origin=$(/usr/bin/git -C "$PRIMARY" config --local --get remote.origin.url) \
    || die "cannot resolve the origin repository"
  case "$origin" in
    https://github.com/*) slug=${origin#https://github.com/} ;;
    git@github.com:*) slug=${origin#git@github.com:} ;;
    ssh://git@github.com/*) slug=${origin#ssh://git@github.com/} ;;
    *) die "origin must identify an explicit github.com repository" ;;
  esac
  slug=${slug%/}; slug=${slug%.git}
  [[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || die "origin GitHub repository is malformed"
  printf '%s\n' "$slug"
}

GH_BIN=""
ensure_gh_bin() {
  local candidate canonical owner mode
  [ -z "$GH_BIN" ] || return 0
  candidate=$GH_CANDIDATE; [ -n "$candidate" ] || die "gh is required" 2
  case "$candidate" in /*) : ;; *) die "gh must resolve to an absolute executable" ;; esac
  case "$candidate" in "$ROOT"/*|"$PRIMARY"/*) die "repository-controlled gh is not trusted" ;; esac
  canonical=$(/usr/bin/readlink -f -- "$candidate") || die "cannot resolve gh executable"
  [ "$canonical" = "$candidate" ] && absolute_path_has_no_symlink "$candidate" \
    && [ -f "$candidate" ] && [ -x "$candidate" ] || die "gh executable or ancestry is unsafe"
  owner=$(/usr/bin/stat -c %u -- "$candidate") || die "cannot inspect gh owner"
  mode=$(/usr/bin/stat -c %a -- "$candidate") || die "cannot inspect gh mode"
  [ "$owner" = 0 ] && (( (8#$mode & 022) == 0 )) \
    || die "gh must be root-owned and not group/world-writable"
  GH_BIN=$candidate
}

trusted_gh() (
  local name
  local -a clean_env
  ensure_gh_bin
  unset BASH_ENV ENV CDPATH GLOBIGNORE GH_REPO GH_HOST GH_CONFIG_DIR \
    LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE \
    DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
  clean_env=("PATH=${GH_BIN%/*}:/usr/bin:/bin" "HOME=${HOME:-/nonexistent}"
    "GH_PROMPT_DISABLED=1" "GH_PAGER=cat" "PAGER=cat" "NO_COLOR=1" "LC_ALL=C")
  for name in GH_TOKEN GITHUB_TOKEN; do
    if [ "${!name+x}" = x ]; then clean_env+=("$name=${!name}"); fi
  done
  ulimit -f 32768
  exec /usr/bin/timeout -k 5s 120s /usr/bin/env -i "${clean_env[@]}" "$GH_BIN" "$@"
)

action=${1:-}; [ -n "$action" ] || usage; shift
repo_root=""; worktree=""; lease_state=""; run_id=""; controller_run_id=""
issue=""; attempt=""
base_sha=""; branch=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root) [ "$#" -ge 2 ] || usage; repo_root=$2; shift 2 ;;
    --worktree) [ "$#" -ge 2 ] || usage; worktree=$2; shift 2 ;;
    --lease-state) [ "$#" -ge 2 ] || usage; lease_state=$2; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; run_id=$2; shift 2 ;;
    --controller-run-id) [ "$#" -ge 2 ] || usage; controller_run_id=$2; shift 2 ;;
    --issue) [ "$#" -ge 2 ] || usage; issue=$2; shift 2 ;;
    --attempt) [ "$#" -ge 2 ] || usage; attempt=$2; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; base_sha=$2; shift 2 ;;
    --branch) [ "$#" -ge 2 ] || usage; branch=$2; shift 2 ;;
    *) usage ;;
  esac
done

case "$action" in cleanup|authorize-restart|_cleanup-held|_authorize-held) : ;; *) usage ;; esac
[ -n "$repo_root" ] && [ -n "$worktree" ] && [ -n "$lease_state" ] \
  && valid_id "$run_id" && valid_id "$controller_run_id" \
  && valid_uint "$issue" && valid_uint "$attempt" \
  && valid_sha "$base_sha" && [ -n "$branch" ] || usage

held_args=(--repo-root "$repo_root" --worktree "$worktree" --lease-state "$lease_state"
  --run-id "$run_id" --controller-run-id "$controller_run_id" --issue "$issue"
  --attempt "$attempt" --base-sha "$base_sha" --branch "$branch")
if [ "$action" = cleanup ] || [ "$action" = authorize-restart ]; then
  token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [[ "$token" =~ ^[0-9a-f]{32}$ ]] || die "cannot create held-operation identity"
  private=_cleanup-held; [ "$action" = cleanup ] || private=_authorize-held
  exec bash "$LEASES" hold --state-file "$lease_state" --repo-root "$repo_root" \
    --worktree "$worktree" --run-id "$controller_run_id" --interval-seconds 1 \
    --max-seconds 300 -- env SAAS_MAINTAIN_ESCALATION_HOLD_TOKEN="$token" \
    SAAS_MAINTAIN_ESCALATION_GH_BIN="$GH_CANDIDATE" \
    bash "$0" "$private" "${held_args[@]}"
fi

[[ "${SAAS_MAINTAIN_ESCALATION_HOLD_TOKEN:-}" =~ ^[0-9a-f]{32}$ ]] \
  || die "operation must run under the lease holder"
unset SAAS_MAINTAIN_ESCALATION_HOLD_TOKEN
command -v jq >/dev/null 2>&1 || die "jq is required" 2

ROOT="$(cd -- "$repo_root" && pwd -P)" || die "cannot resolve repository"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "repository is not a Git worktree"
PRIMARY=$(bash "$LEASES" primary-root --repo-root "$ROOT") \
  || die "cannot resolve primary worktree"
[ "$ROOT" = "$PRIMARY" ] || die "--repo-root must be the primary worktree"
bash "$LEASES" assert-primary-only --repo-root "$PRIMARY" >/dev/null \
  || die "primary-only gate failed (no linked worktrees)"
REPO_SLUG=$(resolve_repo_slug)
REPO_SPEC="github.com/$REPO_SLUG"
ensure_gh_bin
COMMON=$(git -C "$PRIMARY" rev-parse --git-common-dir) || die "cannot resolve common Git directory"
case "$COMMON" in /*) : ;; *) COMMON="$PRIMARY/$COMMON" ;; esac
COMMON="$(cd -- "$COMMON" && pwd -P)" || die "cannot resolve common Git directory"
worktree=$(realpath -m -- "$worktree") || die "cannot resolve worktree"
[ "$worktree" = "$PRIMARY" ] || die "controller tree must be the primary working directory"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid branch" 2

bash "$LEASES" heartbeat --state-file "$lease_state" --repo-root "$PRIMARY" \
  --worktree "$worktree" --run-id "$controller_run_id" >/dev/null \
  || die "lease ownership is no longer valid"

ensure_primary_dir() {
  local rel=$1 create=$2 part current=$PRIMARY
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
  SAFE_DIR=$current
}

ensure_primary_dir ".startup/maintain-loop/attempt-results/$run_id" 0 \
  || die "attempt-result directory is unsafe"
attempt_result="$SAFE_DIR/issue-$issue-attempt-$attempt.json"
[ -f "$attempt_result" ] && [ ! -L "$attempt_result" ] \
  || die "escalated attempt result is missing or unsafe"
jq -e --arg run "$run_id" --argjson attempt "$attempt" --arg base "$base_sha" '
    type == "object"
    and (keys == ["attempt","base_sha","head_sha","route","run_id","schema_version","status"])
    and .schema_version == 1 and .run_id == $run and .attempt == $attempt
    and .base_sha == $base and .status == "escalated"
    and (.head_sha|type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))
    and (.route|type == "object"
      and keys == ["decision","profile","reasons","requires_legal_judgment","requires_product_judgment","schema_version","sensitive","ui_touch"]
      and .schema_version == 1 and .profile == "deep" and .decision == "restart_deep"
      and (.reasons|type == "array" and length > 0
        and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9_.-]{0,127}$")))
      and (.sensitive|type == "boolean") and (.ui_touch|type == "boolean")
      and (.requires_legal_judgment|type == "boolean")
      and (.requires_product_judgment|type == "boolean"))
  ' "$attempt_result" >/dev/null || die "escalated attempt result is malformed"
attempt_head=$(jq -r .head_sha "$attempt_result")
git -C "$PRIMARY" cat-file -e "$attempt_head^{commit}" 2>/dev/null \
  || die "attempt head is unavailable"
reason=$(jq -r '.route.reasons | sort | join(",")' "$attempt_result")
[[ "$reason" =~ ^[a-z0-9][a-z0-9_.-]*(,[a-z0-9][a-z0-9_.-]*)*$ ]] \
  || die "attempt routing reason is invalid"

ensure_primary_dir ".startup/maintain-loop/escalations/$run_id" 1 \
  || die "escalation directory is unsafe"
receipt="$SAFE_DIR/issue-$issue-attempt-$attempt.json"
if [ -e "$receipt" ] || [ -L "$receipt" ]; then
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || die "escalation receipt is unsafe"
fi

receipt_valid() {
  local file=$1
  jq -e --arg run "$run_id" --argjson issue "$issue" --argjson attempt "$attempt" \
    --arg base "$base_sha" --arg branch "$branch" --arg reason "$reason" '
    type == "object"
    and (keys == ["attempt","base_sha","branch","cleanup","issue_number","profile","reason","recorded_at","run_id","schema_version"])
    and .schema_version == 1 and .run_id == $run and .issue_number == $issue
    and .attempt == $attempt and .base_sha == $base and .branch == $branch
    and .profile == "deep" and .reason == $reason
    and (.recorded_at|type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .cleanup == {open_pr:false,remote_branch:false,head_at_base:true,worktree_clean:true}
  ' "$file" >/dev/null 2>&1
}
if [ -e "$receipt" ] && ! receipt_valid "$receipt"; then
  die "existing escalation receipt is malformed or contradictory"
fi

query_open_prs() {
  local out
  out=$(cd "$PRIMARY" && trusted_gh pr list --state open --head "$branch" --limit 100 \
    --json number,headRefName,headRefOid,isCrossRepository --repo "$REPO_SPEC") \
    || die "cannot query branch pull requests"
  jq -e --arg branch "$branch" --arg head "$attempt_head" '
    type == "array" and all(.[];
      type == "object" and keys == ["headRefName","headRefOid","isCrossRepository","number"]
      and (.number|type == "number" and . >= 1 and floor == .)
      and .headRefName == $branch and .headRefOid == $head
      and .isCrossRepository == false)
  ' <<<"$out" >/dev/null || die "branch pull-request evidence is malformed or unrelated"
  PR_JSON=$out
}

query_remote_sha() {
  local out count ref sha
  out=$(git -C "$PRIMARY" ls-remote --heads origin "refs/heads/$branch") \
    || die "cannot query remote branch"
  count=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$count" -le 1 ] || die "remote branch query is ambiguous"
  if [ "$count" -eq 0 ]; then REMOTE_SHA=""; return 0; fi
  read -r sha ref <<<"$out"
  valid_sha "$sha" && [ "$ref" = "refs/heads/$branch" ] \
    || die "remote branch evidence is malformed"
  REMOTE_SHA=$sha
}

query_local_sha() {
  local rc=0
  git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null || rc=$?
  case "$rc" in 0)
      LOCAL_SHA=$(git -C "$PRIMARY" rev-parse --verify "refs/heads/$branch^{commit}") \
        || die "cannot resolve local escalation branch"
      valid_sha "$LOCAL_SHA" || die "local branch evidence is malformed"
      ;;
    1) LOCAL_SHA="" ;;
    *) die "cannot inspect local escalation branch" ;;
  esac
}

prove_local_clean() {
  local head status
  [ -d "$worktree" ] && [ ! -L "$worktree" ] \
    && [ "$(cd -- "$worktree" && pwd -P)" = "$worktree" ] \
    || die "dedicated worktree is unsafe"
  head=$(git -C "$worktree" rev-parse HEAD) || die "cannot inspect worktree HEAD"
  [ "$head" = "$base_sha" ] || die "worktree HEAD is not the exact base"
  status=$(git -C "$worktree" status --porcelain=v1 --untracked-files=all -- \
    . ':(exclude).startup' ':(exclude).startup/**') \
    || die "cannot inspect worktree status"
  [ -z "$status" ] || die "worktree is not clean"
  query_local_sha
  [ -z "$LOCAL_SHA" ] || die "local escalation branch still exists"
}

prove_restart_state() {
  query_open_prs
  [ "$(jq 'length' <<<"$PR_JSON")" -eq 0 ] || die "an open branch pull request remains"
  query_remote_sha
  [ -z "$REMOTE_SHA" ] || die "remote escalation branch remains"
  prove_local_clean
}

if [ "$action" = _authorize-held ]; then
  [ -e "$receipt" ] && receipt_valid "$receipt" \
    || die "canonical escalation receipt is missing"
  prove_restart_state
  cat "$receipt"
  exit 0
fi

default_branch=$(cd "$PRIMARY" && trusted_gh repo view --repo "$REPO_SPEC" \
  --json defaultBranchRef --jq '.defaultBranchRef.name') || die "cannot resolve default branch"
[ -n "$default_branch" ] && git check-ref-format --branch "$default_branch" >/dev/null 2>&1 \
  || die "default branch evidence is malformed"
[ "$branch" != "$default_branch" ] || die "refusing to clean the default branch"

query_local_sha
if [ -n "$LOCAL_SHA" ]; then
  [ "$LOCAL_SHA" = "$attempt_head" ] || die "local branch no longer matches the escalated attempt"
fi
current_head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) \
  || die "cannot inspect dedicated worktree"
branch_rc=0
current_branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch_rc=$?
case "$branch_rc" in 0) : ;; 1) current_branch="" ;; *) die "cannot inspect worktree branch" ;; esac
worktree_status=$(git -C "$worktree" status --porcelain=v1 --untracked-files=all -- \
  . ':(exclude).startup' ':(exclude).startup/**') \
  || die "cannot inspect worktree status"
if [ "$current_head" != "$base_sha" ] \
  || [ -n "$worktree_status" ]; then
  [ "$current_head" = "$attempt_head" ] && [ "$current_branch" = "$branch" ] \
    || die "worktree does not match the escalated attempt"
elif [ -n "$current_branch" ] && [ "$current_branch" != "$branch" ]; then
  die "clean worktree is attached to an unrelated branch"
fi

query_open_prs
query_remote_sha
[ -z "$REMOTE_SHA" ] || [ "$REMOTE_SHA" = "$attempt_head" ] \
  || die "remote branch moved after escalation"
while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  (cd "$PRIMARY" && trusted_gh pr close "$pr" --repo "$REPO_SPEC" >/dev/null) \
    || die "cannot close escalation pull request"
done < <(jq -r '.[].number' <<<"$PR_JSON")
if [ -n "$REMOTE_SHA" ]; then
  git -C "$PRIMARY" push origin --delete "$branch" >/dev/null \
    || die "cannot delete escalation remote branch"
fi

reset_token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[[ "$reset_token" =~ ^[0-9a-f]{32}$ ]] || die "cannot create reset identity"
SAAS_MAINTAIN_RESET_HOLD_TOKEN="$reset_token" bash "$ATTEMPT_HELPER" _reset-held \
  --repo-root "$PRIMARY" --worktree "$worktree" --base-sha "$base_sha" \
  --lease-state "$lease_state" --run-id "$run_id" \
  --controller-run-id "$controller_run_id" >/dev/null \
  || die "cannot reset escalation worktree"
query_local_sha
if [ -n "$LOCAL_SHA" ]; then
  [ "$LOCAL_SHA" = "$attempt_head" ] || die "local branch changed during cleanup"
  git -C "$worktree" branch -D -- "$branch" >/dev/null \
    || die "cannot delete local escalation branch"
fi
prove_restart_state

if [ ! -e "$receipt" ]; then
  tmp=$(mktemp "$receipt.tmp.XXXXXX") || die "cannot create escalation receipt"
  if ! jq -n --arg run "$run_id" --argjson issue "$issue" --argjson attempt "$attempt" \
      --arg base "$base_sha" --arg branch "$branch" --arg reason "$reason" \
      --arg now "$(date -u +%FT%TZ)" '
      {schema_version:1,run_id:$run,issue_number:$issue,attempt:$attempt,
       base_sha:$base,branch:$branch,profile:"deep",reason:$reason,recorded_at:$now,
       cleanup:{open_pr:false,remote_branch:false,head_at_base:true,worktree_clean:true}}
    ' >"$tmp" || ! chmod 600 "$tmp" || ! mv -T -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    die "cannot install escalation receipt"
  fi
fi
[ -f "$receipt" ] && [ ! -L "$receipt" ] && receipt_valid "$receipt" \
  || die "installed escalation receipt failed validation"
cat "$receipt"
