#!/usr/bin/env bash
# Durable supervisor-owned lifecycle for one maintain-loop issue delivery.
set -euo pipefail

ORIGINAL_PATH=${PATH:-/usr/bin:/bin}
JQ_CANDIDATE=$(PATH="$ORIGINAL_PATH" type -P jq 2>/dev/null || true)
GH_CANDIDATE=$(PATH="$ORIGINAL_PATH" type -P gh 2>/dev/null || true)
PATH=/usr/bin:/bin
export PATH
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE GIT_GRAFT_FILE GIT_CONFIG \
  GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT GIT_CEILING_DIRECTORIES GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT \
  GIT_ASKPASS SSH_ASKPASS SSH_ASKPASS_REQUIRE GIT_PROXY_COMMAND GIT_EXEC_PATH
case "${BASH_SOURCE[0]}" in */*) SCRIPT_SOURCE_DIR=${BASH_SOURCE[0]%/*} ;; *) SCRIPT_SOURCE_DIR=. ;; esac
SCRIPT_DIR="$(cd -- "$SCRIPT_SOURCE_DIR" && pwd -P)"

usage() {
  cat >&2 <<'EOF'
usage: maintain-delivery.sh pending --repo-root DIR [--issue N]
       maintain-delivery.sh show --repo-root DIR --issue N
       maintain-delivery.sh archive-claimed --repo-root DIR --issue N
       maintain-delivery.sh begin --repo-root DIR --issue N --run-id ID
         --delivery-id ID --merge-budget N --scope-json FILE --lease-state FILE
         [--reopen-event-id N --reopen-event-at TIME] [--retry-after-rollback]
       maintain-delivery.sh plan-pr --repo-root DIR --issue N --role normal|rollback
         --branch NAME --base-sha SHA --head-sha SHA
       maintain-delivery.sh bind-pr|match-pr --repo-root DIR --issue N
         --role normal|rollback --pr-json FILE
       maintain-delivery.sh collect-tribunal --repo-root DIR --issue N
         --role normal|rollback --tribunal-plugin-root DIR
       maintain-delivery.sh record-proof --repo-root DIR --issue N
         --role normal|rollback --kind qa [--command-file FILE|--not-applicable]
       maintain-delivery.sh record-proof --repo-root DIR --issue N
         --role normal|rollback --kind tribunal --artifact FILE
         --tribunal-plugin-root DIR
       maintain-delivery.sh record-proof --repo-root DIR --issue N
         --role normal|rollback --kind live --command-file FILE
         [--live-command-contract structured|monitor-hook]
         [--deploy-run-id N --live-target-source ID]
       maintain-delivery.sh authorize-merge --repo-root DIR --issue N
         --role normal|rollback
       maintain-delivery.sh merge-pr --repo-root DIR --issue N
         --role normal|rollback --merge-method merge|squash
       maintain-delivery.sh record-merge --repo-root DIR --issue N
         --role normal|rollback
       maintain-delivery.sh record-release --repo-root DIR --issue N
         --role normal|rollback --deploy-run-id N --live-target-source ID
       maintain-delivery.sh close-intent --repo-root DIR --issue N
       maintain-delivery.sh close-issue --repo-root DIR --issue N
       maintain-delivery.sh observe-closed --repo-root DIR --issue N
       maintain-delivery.sh render-result --repo-root DIR --issue N
       maintain-delivery.sh finalize --repo-root DIR --issue N
         --result-source FILE --profile mechanical|light|standard|deep
EOF
  exit 2
}

die() { printf 'maintain-delivery: %s\n' "$1" >&2; exit "${2:-1}"; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; }
valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_natural() { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; }
valid_digest() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
valid_time() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }
now_iso() { date -u +%FT%TZ; }
stamp_is_fresh() {
  local stamp=$1 max_age=$2 observed_epoch now_epoch age
  valid_time "$stamp" && valid_uint "$max_age" || return 1
  observed_epoch=$(date -u -d "$stamp" +%s 2>/dev/null) || return 1
  now_epoch=$(date -u +%s) || return 1
  age=$((now_epoch - observed_epoch))
  [ "$age" -ge 0 ] && [ "$age" -le "$max_age" ]
}

early_absolute_path_has_no_symlink() {
  local path=$1 part cursor="" old_ifs
  case "$path" in /*) : ;; *) return 1 ;; esac
  old_ifs=$IFS; IFS=/
  for part in ${path#/}; do
    [ -n "$part" ] || { IFS=$old_ifs; return 1; }
    cursor="$cursor/$part"; [ ! -L "$cursor" ] || { IFS=$old_ifs; return 1; }
  done
  IFS=$old_ifs
}

validate_controller_tool() {
  local candidate=$1 name=$2 canonical owner mode current_uid
  [ -n "$candidate" ] || die "$name is required" 2
  case "$candidate" in /*) : ;; *) die "$name must resolve to an absolute executable" ;; esac
  canonical=$(/usr/bin/readlink -f -- "$candidate") || die "cannot resolve $name executable"
  [ "$canonical" = "$candidate" ] && early_absolute_path_has_no_symlink "$candidate" \
    && [ -f "$candidate" ] && [ -x "$candidate" ] || die "$name executable or ancestry is unsafe"
  case "$candidate" in "$ROOT"/*|"$PRIMARY"/*) die "repository-controlled $name is not trusted" ;; esac
  owner=$(/usr/bin/stat -c %u -- "$candidate") || die "cannot inspect $name owner"
  mode=$(/usr/bin/stat -c %a -- "$candidate") || die "cannot inspect $name mode"
  current_uid=$(/usr/bin/id -u) || die "cannot inspect controller uid"
  { [ "$owner" = 0 ] || [ "$owner" = "$current_uid" ]; } && (( (8#$mode & 022) == 0 )) \
    || die "$name must be controller-owned and not group/world-writable"
}

resolve_repo_slug() {
  local origin slug
  origin=$(git -C "$PRIMARY" config --local --get remote.origin.url) \
    || die "cannot resolve the origin repository"
  case "$origin" in
    https://github.com/*) slug=${origin#https://github.com/} ;;
    git@github.com:*) slug=${origin#git@github.com:} ;;
    ssh://git@github.com/*) slug=${origin#ssh://git@github.com/} ;;
    *) die "origin must identify an explicit github.com repository" ;;
  esac
  slug=${slug%/}; slug=${slug%.git}
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "origin GitHub repository is malformed"
  printf '%s\n' "$slug"
}

ACTION=${1:-}; [ -n "$ACTION" ] || usage; shift
REPO_ROOT=""; ISSUE=""; RUN_ID=""; DELIVERY_ID=""; LEASE_STATE=""
REOPEN_EVENT_ID=""; REOPEN_EVENT_AT=""; RETRY_AFTER_ROLLBACK=0
ROLE=""; BRANCH=""; BASE_SHA=""; HEAD_SHA=""
PR_JSON=""; SCOPE_JSON=""; KIND=""; COMMAND_FILE=""; ARTIFACT=""; NOT_APPLICABLE=0
TRIBUNAL_PLUGIN_ROOT=""
DEPLOY_RUN_ID=""; RESULT_SOURCE=""; PROFILE=""
MERGE_METHOD=""
MERGE_BUDGET=""; LIVE_TARGET_SOURCE=""; LIVE_COMMAND_CONTRACT=structured

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root) [ "$#" -ge 2 ] || usage; REPO_ROOT=$2; shift 2 ;;
    --issue) [ "$#" -ge 2 ] || usage; ISSUE=$2; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; RUN_ID=$2; shift 2 ;;
    --delivery-id) [ "$#" -ge 2 ] || usage; DELIVERY_ID=$2; shift 2 ;;
    --lease-state) [ "$#" -ge 2 ] || usage; LEASE_STATE=$2; shift 2 ;;
    --reopen-event-id) [ "$#" -ge 2 ] || usage; REOPEN_EVENT_ID=$2; shift 2 ;;
    --reopen-event-at) [ "$#" -ge 2 ] || usage; REOPEN_EVENT_AT=$2; shift 2 ;;
    --retry-after-rollback) RETRY_AFTER_ROLLBACK=1; shift ;;
    --role) [ "$#" -ge 2 ] || usage; ROLE=$2; shift 2 ;;
    --branch) [ "$#" -ge 2 ] || usage; BRANCH=$2; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; BASE_SHA=$2; shift 2 ;;
    --head-sha) [ "$#" -ge 2 ] || usage; HEAD_SHA=$2; shift 2 ;;
    --merge-method) [ "$#" -ge 2 ] || usage; MERGE_METHOD=$2; shift 2 ;;
    --merge-budget) [ "$#" -ge 2 ] || usage; MERGE_BUDGET=$2; shift 2 ;;
    --scope-json) [ "$#" -ge 2 ] || usage; SCOPE_JSON=$2; shift 2 ;;
    --pr-json) [ "$#" -ge 2 ] || usage; PR_JSON=$2; shift 2 ;;
    --kind) [ "$#" -ge 2 ] || usage; KIND=$2; shift 2 ;;
    --command-file) [ "$#" -ge 2 ] || usage; COMMAND_FILE=$2; shift 2 ;;
    --artifact) [ "$#" -ge 2 ] || usage; ARTIFACT=$2; shift 2 ;;
    --tribunal-plugin-root) [ "$#" -ge 2 ] || usage; TRIBUNAL_PLUGIN_ROOT=$2; shift 2 ;;
    --not-applicable) NOT_APPLICABLE=1; shift ;;
    --deploy-run-id) [ "$#" -ge 2 ] || usage; DEPLOY_RUN_ID=$2; shift 2 ;;
    --live-target-source) [ "$#" -ge 2 ] || usage; LIVE_TARGET_SOURCE=$2; shift 2 ;;
    --live-command-contract) [ "$#" -ge 2 ] || usage; LIVE_COMMAND_CONTRACT=$2; shift 2 ;;
    --result-source) [ "$#" -ge 2 ] || usage; RESULT_SOURCE=$2; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || usage; PROFILE=$2; shift 2 ;;
    *) usage ;;
  esac
done

case "$ACTION" in
  pending|show|archive-claimed|begin|plan-pr|bind-pr|match-pr|collect-tribunal|record-proof|authorize-merge|merge-pr|record-merge|record-release|close-intent|close-issue|observe-closed|render-result|finalize) : ;;
  *) usage ;;
esac
[ "$ACTION" = begin ] || [ -z "$MERGE_BUDGET" ] || usage
if [ "$ACTION" = begin ]; then
  [ -n "$SCOPE_JSON" ] || usage
else
  [ -z "$SCOPE_JSON" ] || usage
fi
[ -n "$REPO_ROOT" ] || usage
case "$ISSUE" in "") [ "$ACTION" = pending ] || usage ;; *) valid_uint "$ISSUE" || die "--issue must be a positive integer" 2 ;; esac
command -v flock >/dev/null 2>&1 || die "flock is required" 2

ROOT="$(cd -- "$REPO_ROOT" && pwd -P)" || die "cannot resolve repository"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree"
PRIMARY="$(bash "$SCRIPT_DIR/maintain-leases.sh" primary-root --repo-root "$ROOT")" \
  || die "cannot resolve primary worktree"
validate_controller_tool "$JQ_CANDIDATE" jq
validate_controller_tool /usr/bin/sha256sum sha256sum
case "$JQ_CANDIDATE" in /usr/bin/*|/bin/*) : ;; *) PATH="$PATH:${JQ_CANDIDATE%/*}"; export PATH ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required" 2
REPO_SLUG=""
common_raw="$(git -C "$PRIMARY" rev-parse --git-common-dir)" || die "cannot resolve common Git directory"
case "$common_raw" in /*) COMMON=$common_raw ;; *) COMMON="$PRIMARY/$common_raw" ;; esac
COMMON="$(cd -- "$COMMON" && pwd -P)" || die "cannot resolve common Git directory"
STATE_ROOT="$COMMON/saas-startup-team/maintain-runtime/deliveries"

TEMP_PATHS=()
ARCHIVE_LEASE_STATE=""; ARCHIVE_LEASE_RUN=""
register_temp() { TEMP_PATHS+=("$1"); }
forget_temp() {
  local target=$1 index
  for index in "${!TEMP_PATHS[@]}"; do
    [ "${TEMP_PATHS[$index]}" = "$target" ] && TEMP_PATHS[$index]=""
  done
  return 0
}
cleanup_temps() {
  local path
  for path in "${TEMP_PATHS[@]}"; do
    [ -n "$path" ] || continue
    case "$path" in "$STATE_ROOT"/.*) rm -rf -- "$path" ;; esac
  done
  if [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ]; then
    shopt -s nullglob
    for path in "$STATE_ROOT"/.*.*; do rm -rf -- "$path"; done
    shopt -u nullglob
  fi
  if [ -n "$ARCHIVE_LEASE_STATE" ] && [ -f "$ARCHIVE_LEASE_STATE" ] \
    && [ ! -L "$ARCHIVE_LEASE_STATE" ]; then
    bash "$SCRIPT_DIR/maintain-leases.sh" cleanup --state-file "$ARCHIVE_LEASE_STATE" \
      --run-id "$ARCHIVE_LEASE_RUN" >/dev/null 2>&1 || true
  fi
}
trap cleanup_temps EXIT

safe_existing_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(cd -- "$1" && pwd -P)" = "$1" ]; }
ensure_child_dir() {
  local parent=$1 child=$2 path="$1/$2"
  safe_existing_dir "$parent" || return 1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then mkdir -- "$path" || return 1; fi
  safe_existing_dir "$path"
}
ensure_state_root() {
  ensure_child_dir "$COMMON" saas-startup-team || return 1
  ensure_child_dir "$COMMON/saas-startup-team" maintain-runtime || return 1
  ensure_child_dir "$COMMON/saas-startup-team/maintain-runtime" deliveries
}

# All receipt fields are controller facts. Text, URLs, paths, and issue bodies stay elsewhere.
receipt_valid() {
  jq -e '
    def sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def id: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$");
    def merge: . == null or
      (type == "object" and (keys == ["default_sha","merge_budget","merge_count","observed_at","sha"])
       and (.default_sha|sha) and (.observed_at|stamp) and (.sha|sha)
       and (.merge_budget|type == "number" and . >= 0 and floor == .)
       and (.merge_count|type == "number" and . >= 1 and floor == .));
    def premerge: . == null or
      (type == "object"
       and (keys == ["authorized_at","base_branch","checks","closure_audit","default_sha","head_sha","pr_number","qa","tribunal"])
       and (.authorized_at|stamp) and (.base_branch|type == "string" and length > 0)
       and (.default_sha|sha) and (.head_sha|sha)
       and (.pr_number|type == "number" and . >= 1 and floor == .)
       and (.checks == {evidence_id:.checks.evidence_id,head_sha:.head_sha,status:"passed"})
       and (.checks.evidence_id|id)
       and (.closure_audit == {status:"passed",head_sha:.head_sha})
       and (.tribunal == {evidence_id:.tribunal.evidence_id,head_sha:.head_sha,status:"passed"})
       and (.tribunal.evidence_id|id)
       and (.qa == {evidence_id:.qa.evidence_id,head_sha:.head_sha,
         reason_code:.qa.reason_code,status:.qa.status})
       and (.qa.status == "passed" or .qa.status == "not_applicable")
       and (.qa.evidence_id|id) and (.qa.reason_code|id));
    def pr($rollback): . == null or
      (type == "object"
       and (if $rollback then
         keys == ["action_id","base_branch","base_sha","body_digest","branch","head_sha","merge","merge_method","pr_number","premerge","state","target_merge_sha"]
       else keys == ["action_id","base_branch","base_sha","body_digest","branch","head_sha","merge","merge_method","pr_number","premerge","state"] end)
       and (.action_id|id) and (.base_sha|sha) and (.branch|type == "string" and length > 0)
       and (.head_sha|sha) and (.base_branch == null or (.base_branch|type == "string" and length > 0))
       and (.pr_number == null or (.pr_number|type == "number" and . >= 1 and floor == .))
       and ((.pr_number == null and .body_digest == null)
         or (.pr_number != null and (.body_digest|digest)))
       and (.state == "planned" or .state == "open" or .state == "merge_authorized" or .state == "merged")
       and (.merge_method == null or .merge_method == "merge" or .merge_method == "squash")
       and (.premerge|premerge) and (.merge|merge)
       and (if $rollback then (.target_merge_sha|sha) else true end));
    type == "object"
    and (keys == ["close","delivery_id","final","generation","issue_number","issue_updated_at","normal","origin_issue_digest","origin_run_id","release","reopened_event","rollback","schema_version","state","updated_at"])
    and .schema_version == 1 and (.delivery_id|id) and (.origin_run_id|id)
    and (.generation|type == "number" and . >= 1 and floor == .)
    and (.issue_number|type == "number" and . >= 1 and floor == .)
    and (.issue_updated_at|stamp) and (.origin_issue_digest|digest) and (.updated_at|stamp)
    and (.state == "claimed" or .state == "normal_planned" or .state == "normal_open"
      or .state == "normal_merge_authorized" or .state == "post_merge"
      or .state == "release_verified" or .state == "rollback_planned"
      or .state == "rollback_open" or .state == "rollback_merge_authorized"
      or .state == "rollback_merged" or .state == "rollback_release_verified" or .state == "close_intent"
      or .state == "closed_observed" or .state == "archived_claim" or .state == "finalized_success"
      or .state == "finalized_rolled_back")
    and (.reopened_event == null or
      (.reopened_event|type == "object" and keys == ["at","id"]
       and (.id|type == "number" and . >= 1 and floor == .) and (.at|stamp)))
    and (.normal|pr(false)) and (.rollback|pr(true))
    and (.normal.merge == null or .normal.merge.merge_count <= .normal.merge.merge_budget)
    and (.rollback.merge == null or
      (.normal.merge != null
       and .rollback.merge.merge_budget == .normal.merge.merge_budget
       and .rollback.merge.merge_count == (.normal.merge.merge_count + 1)
       and .rollback.merge.merge_count <= (.rollback.merge.merge_budget + 1)))
    and (.release == null or
      (.release|type == "object" and keys == ["deploy_run_id","live_evidence_digest","live_target_source","sha","verified_at"]
       and (.deploy_run_id|id) and (.live_evidence_digest|digest) and (.live_target_source|id)
       and (.sha|sha) and (.verified_at|stamp)))
    and (.close == null or
      (.close|type == "object" and keys == ["audit","claim_label_removed","closed_at","issue_digest","issue_updated_at","prepared_at","status"]
       and (.status == "ready_to_close" or .status == "closed")
       and (.issue_updated_at|stamp) and (.prepared_at|stamp)
       and .claim_label_removed == true
       and (.closed_at == null or (.closed_at|stamp))
       and (.issue_digest|digest)
       and (.audit|type == "object"
         and keys == ["audited_at","issue_digest","issue_number","issue_updated_at","merge_sha","pr_number","status"]
         and (.audited_at|stamp) and (.issue_digest|digest) and (.issue_updated_at|stamp)
         and .status == "passed")))
    and (.close == null or
      (.close.audit.issue_number == .issue_number
       and .close.audit.issue_updated_at == .close.issue_updated_at
       and .close.audit.issue_digest == .close.issue_digest
       and .close.audit.pr_number == .normal.pr_number
       and .close.audit.merge_sha == .normal.merge.sha))
    and (.final == null or
      (.final|type == "object" and keys == ["event_identity","finalized_at","outcome","result_path"]
       and (.event_identity|id) and (.finalized_at|stamp)
       and (.outcome == "success" or .outcome == "rolled_back")
       and (.result_path|type == "string" and length > 0)))
    and (if .state == "archived_claim" then
      .normal == null and .rollback == null and .release == null and .close == null and .final == null
      else true end)
  ' "$1" >/dev/null 2>&1
}

prepare_root=0
case "$ACTION" in pending|show|archive-claimed) : ;; *) prepare_root=1 ;; esac
if [ ! -e "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ]; then
  if [ "$prepare_root" -eq 0 ]; then
    [ "$ACTION" = pending ] && { printf '[]\n'; exit 0; }
    die "delivery receipt is missing"
  fi
  umask 077
  ensure_state_root || die "cannot create safe delivery state directory"
fi
safe_existing_dir "$STATE_ROOT" || die "delivery state directory is unsafe"
[ ! -L "$STATE_ROOT/.lock" ] && { [ ! -e "$STATE_ROOT/.lock" ] || [ -f "$STATE_ROOT/.lock" ]; } \
  || die "delivery state lock is unsafe"
exec 9>>"$STATE_ROOT/.lock"
flock 9

issue_dir=""; current=""
set_issue_paths() {
  issue_dir="$STATE_ROOT/issue-$ISSUE"
  current="$issue_dir/current.json"
}
safe_receipt_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(dirname -- "$1")" = "$issue_dir" ]; }
load_current() {
  set_issue_paths
  safe_existing_dir "$issue_dir" || die "delivery receipt directory is missing or unsafe"
  safe_receipt_file "$current" || die "delivery receipt is missing or unsafe"
  receipt_valid "$current" || die "delivery receipt is malformed"
  [ "$(jq -r .issue_number "$current")" = "$ISSUE" ] || die "delivery receipt issue mismatch"
}
atomic_update() {
  local filter=$1; shift
  local tmp
  tmp=$(mktemp "$current.tmp.XXXXXX") || die "cannot create receipt update"
  if ! jq "$@" "$filter" "$current" > "$tmp" || ! receipt_valid "$tmp"; then
    rm -f -- "$tmp"; die "invalid delivery state transition"
  fi
  chmod 600 "$tmp" && mv -- "$tmp" "$current" || { rm -f -- "$tmp"; die "cannot persist delivery state"; }
}
terminal_state() { case "$1" in archived_claim|finalized_success|finalized_rolled_back) return 0 ;; *) return 1 ;; esac; }

require_active_controller() {
  local expected_run=$1 allow_resume=$2
  case "$allow_resume" in 0|1) : ;; *) die "invalid controller resume policy" ;; esac
  [ -n "$LEASE_STATE" ] || die "mutating delivery actions require --lease-state" 2
  if ! bash "$SCRIPT_DIR/maintain-leases.sh" heartbeat --state-file "$LEASE_STATE" >/dev/null; then
    die "delivery controller no longer owns the maintenance leases" 3
  fi
  jq -e --arg run "$expected_run" --argjson allow_resume "$allow_resume" \
    --arg primary "$PRIMARY" --arg common "$COMMON" --arg root "$ROOT" '
    .schema_version == 2 and .repo_root == $primary
    and .primary_root == $primary and .common_dir == $common
    and ((.mode == "maintain-loop" and .worktree == $root
          and (.run_id == $run or $allow_resume == 1))
      or (.run_id == $run and .mode == "maintain"
          and .worktree == "" and $root == $primary))
  ' "$LEASE_STATE" >/dev/null 2>&1 \
    || die "lease state does not bind this controller, run, and worktree" 3
}

GH_BIN=""
ensure_gh_bin() {
  local candidate canonical owner mode
  [ -z "$GH_BIN" ] || return 0
  candidate=$GH_CANDIDATE; [ -n "$candidate" ] || die "gh is required" 2
  case "$candidate" in /*) : ;; *) die "gh must resolve to an absolute executable" ;; esac
  canonical=$(PATH=/usr/bin:/bin readlink -f -- "$candidate") || die "cannot resolve gh executable"
  [ "$canonical" = "$candidate" ] && early_absolute_path_has_no_symlink "$candidate" \
    && [ -f "$candidate" ] && [ -x "$candidate" ] || die "gh executable or ancestry is unsafe"
  case "$candidate" in "$ROOT"/*|"$PRIMARY"/*) die "repository-controlled gh is not trusted" ;; esac
  owner=$(PATH=/usr/bin:/bin stat -c %u -- "$candidate") || die "cannot inspect gh owner"
  mode=$(PATH=/usr/bin:/bin stat -c %a -- "$candidate") || die "cannot inspect gh mode"
  [ "$owner" = 0 ] && (( (8#$mode & 022) == 0 )) \
    || die "gh must be root-owned and not group/world-writable"
  GH_BIN=$candidate
}
trusted_gh() (
  local name
  local -a clean_env
  ensure_gh_bin
  clean_env=("PATH=$(dirname -- "$GH_BIN"):/usr/bin:/bin" "HOME=${HOME:-/nonexistent}"
    "GH_PROMPT_DISABLED=1" "GH_PAGER=cat" "PAGER=cat" "NO_COLOR=1" "LC_ALL=C")
  for name in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN; do
    if [ "${!name+x}" = x ]; then clean_env+=("$name=${!name}"); fi
  done
  ulimit -f 32768
  exec /usr/bin/timeout -k 5s 120s /usr/bin/env -i "${clean_env[@]}" "$GH_BIN" "$@"
)
ensure_repo_slug() {
  [ -n "$REPO_SLUG" ] || REPO_SLUG=$(resolve_repo_slug)
}
trusted_repo_gh() {
  ensure_repo_slug
  trusted_gh "$@" --repo "$REPO_SLUG"
}
fresh_issue_snapshot() {
  local destination=$1
  (cd "$PRIMARY" && trusted_repo_gh issue view "$ISSUE" \
    --json number,state,title,body,updatedAt > "$destination") \
    || die "cannot refresh issue"
  jq -e --argjson issue "$ISSUE" '
    type == "object" and keys == ["body","number","state","title","updatedAt"]
    and .number == $issue and .state == "OPEN"
    and (.title|type == "string") and (.body|type == "string")
    and (.updatedAt|type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' "$destination" >/dev/null || die "issue snapshot is not an exact open issue"
}

fresh_closed_issue_snapshot() {
  local destination=$1
  (cd "$PRIMARY" && trusted_repo_gh issue view "$ISSUE" \
    --json number,state,title,body,updatedAt > "$destination") \
    || die "cannot refresh claimed receipt issue"
  jq -e --argjson issue "$ISSUE" '
    type == "object" and keys == ["body","number","state","title","updatedAt"]
    and .number == $issue and .state == "CLOSED"
    and (.title|type == "string") and (.body|type == "string")
    and (.updatedAt|type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' "$destination" >/dev/null || die "claimed receipt issue is not exactly closed"
}

canonical_issue_scope() {
  local source=$1
  [ -n "$source" ] && [ -f "$source" ] && [ ! -L "$source" ] || return 1
  jq -ceS -s --argjson issue "$ISSUE" '
    if length == 1 and (.[0] |
      type == "object" and keys == ["body","number","state","title","updatedAt"]
      and .number == $issue and .state == "OPEN"
      and (.title|type == "string") and (.body|type == "string")
      and (.updatedAt|type == "string"
        and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
    then .[0] | {number,state,title,body,updatedAt}
    else error("invalid issue scope") end
  ' "$source"
}

RUN_LEDGER=""
run_ledger_valid() {
  jq -e '
    def sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
    def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def id: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$");
    type == "object"
    and keys == ["events","merge_budget","normal_merge_count","run_id","schema_version"]
    and .schema_version == 1 and (.run_id|id)
    and (.merge_budget|type == "number" and . >= 0 and floor == .)
    and (.normal_merge_count|type == "number" and . >= 0 and floor == .)
    and .normal_merge_count <= .merge_budget
    and (.events|type == "array")
    and all(.events[];
      type == "object" and keys == ["delivery_id","issue_number","observed_at","role","sha"]
      and (.delivery_id|id) and (.issue_number|type == "number" and . >= 1 and floor == .)
      and (.role == "normal" or .role == "rollback") and (.sha|sha) and (.observed_at|stamp))
    and (. as $ledger
      | ([.events[]|select(.role == "normal")]|length) == $ledger.normal_merge_count)
    and (. as $ledger
      | ([.events[]|(.delivery_id + ":" + .role)]|unique|length) == ($ledger.events|length))
  ' "$1" >/dev/null 2>&1
}
set_run_ledger() {
  local run=$1
  valid_id "$run" || die "delivery run id is invalid"
  RUN_LEDGER="$STATE_ROOT/run-$run.json"
}
ensure_run_ledger() {
  local run=$1 budget=$2 tmp
  set_run_ledger "$run"
  if [ -e "$RUN_LEDGER" ] || [ -L "$RUN_LEDGER" ]; then
    [ -f "$RUN_LEDGER" ] && [ ! -L "$RUN_LEDGER" ] && run_ledger_valid "$RUN_LEDGER" \
      || die "run merge ledger is missing, unsafe, or malformed"
    [ "$(jq -r .merge_budget "$RUN_LEDGER")" = "$budget" ] \
      || die "run merge budget cannot change"
    return 0
  fi
  tmp=$(mktemp "$RUN_LEDGER.tmp.XXXXXX") || die "cannot create run merge ledger"
  jq -n --arg run "$run" --argjson budget "$budget" \
    '{schema_version:1,run_id:$run,merge_budget:$budget,normal_merge_count:0,events:[]}' > "$tmp"
  run_ledger_valid "$tmp" && chmod 600 "$tmp" && mv -T -- "$tmp" "$RUN_LEDGER" \
    || { rm -f -- "$tmp"; die "cannot persist run merge ledger"; }
}
load_run_ledger() {
  local run=$1
  set_run_ledger "$run"
  [ -f "$RUN_LEDGER" ] && [ ! -L "$RUN_LEDGER" ] && run_ledger_valid "$RUN_LEDGER" \
    || die "run merge ledger is missing, unsafe, or malformed"
}
atomic_update_run_ledger() {
  local filter=$1; shift
  local tmp
  tmp=$(mktemp "$RUN_LEDGER.tmp.XXXXXX") || die "cannot create run ledger update"
  if ! jq "$@" "$filter" "$RUN_LEDGER" > "$tmp" || ! run_ledger_valid "$tmp"; then
    rm -f -- "$tmp"; die "invalid run merge ledger transition"
  fi
  chmod 600 "$tmp" && mv -T -- "$tmp" "$RUN_LEDGER" \
    || { rm -f -- "$tmp"; die "cannot persist run merge ledger"; }
}

claim_branch_refs_absent() {
  local claim_time claim_epoch reflog selector event_epoch subject branch latest remote_rc
  local -A candidates=()
  claim_time=$(jq -r .updated_at "$current")
  claim_epoch=$(date -u -d "$claim_time" +%s) || die "claimed receipt timestamp is invalid"
  reflog=$(mktemp "$STATE_ROOT/.archive-reflog.XXXXXX") \
    || die "cannot create claimed receipt reflog snapshot"
  register_temp "$reflog"
  git -C "$PRIMARY/.worktrees/maintain" reflog show --date=unix \
    --format='%gD%x09%gs' HEAD > "$reflog" \
    || die "cannot inspect claimed receipt worktree reflog"
  [ -s "$reflog" ] || die "claimed receipt worktree reflog is missing"
  while IFS=$'\t' read -r selector subject; do
    [[ "$selector" =~ @\{([0-9]+)\}$ ]] \
      || die "claimed receipt worktree reflog is malformed"
    event_epoch=${BASH_REMATCH[1]}
    [ "$event_epoch" -ge "$claim_epoch" ] || continue
    case "$subject" in
      'checkout: moving from '*' to '*)
        branch=${subject##* to }
        valid_sha "$branch" && continue
        git check-ref-format --branch "$branch" >/dev/null 2>&1 || continue
        candidates["$branch"]=1
        ;;
    esac
  done < "$reflog"
  rm -f -- "$reflog"; forget_temp "$reflog"

  for branch in "${!candidates[@]}"; do
    if git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$branch"; then
      latest=$(git -C "$PRIMARY" reflog show -1 --date=unix --format='%gD' "refs/heads/$branch") \
        || die "cannot inspect claimed receipt branch reflog"
      [[ "$latest" =~ @\{([0-9]+)\}$ ]] \
        || die "claimed receipt branch lacks ownership history"
      latest=${BASH_REMATCH[1]}
      [ "$latest" -lt "$claim_epoch" ] \
        || die "claimed receipt still has a local branch ref"
      continue
    fi
    remote_rc=0
    GIT_TERMINAL_PROMPT=0 /usr/bin/timeout -k 5s 120s \
      git -C "$PRIMARY" ls-remote --exit-code --heads origin "refs/heads/$branch" \
      >/dev/null 2>&1 || remote_rc=$?
    case "$remote_rc" in
      0) die "claimed receipt still has a remote branch ref" ;;
      2) : ;;
      *) die "cannot disprove a claimed receipt remote branch" ;;
    esac
  done
}

claim_source_state_absent() {
  local run=$1 dir found worktree top worktree_common status head gate_dir gate
  local guard_dir artifact
  local -a guard_dirs=()
  for dir in \
    "$PRIMARY/.startup/maintain-loop/attempt-results/$run" \
    "$PRIMARY/.startup/maintain-loop/escalations/$run"; do
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    safe_existing_dir "$dir" || die "claimed receipt source-state directory is unsafe"
    found=$(find -P "$dir" -maxdepth 1 -name "issue-$ISSUE-attempt-*" -print -quit) \
      || die "cannot inspect claimed receipt source state"
    [ -z "$found" ] || die "claimed receipt has protected source-attempt state"
  done

  worktree="$PRIMARY/.worktrees/maintain"
  [ -e "$worktree" ] || [ -L "$worktree" ] \
    || die "claimed receipt worktree is missing; source state cannot be disproved"
  safe_existing_dir "$worktree" || die "claimed receipt worktree is unsafe"
  top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) \
    || die "claimed receipt worktree is not a Git worktree"
  [ "$top" = "$worktree" ] || die "claimed receipt worktree identity is ambiguous"
  worktree_common=$(git -C "$worktree" rev-parse --git-common-dir) \
    || die "cannot inspect claimed receipt worktree"
  case "$worktree_common" in /*) : ;; *) worktree_common="$worktree/$worktree_common" ;; esac
  worktree_common=$(cd -- "$worktree_common" && pwd -P) \
    || die "cannot resolve claimed receipt worktree metadata"
  [ "$worktree_common" = "$COMMON" ] || die "claimed receipt worktree repository changed"
  if git -C "$worktree" symbolic-ref -q HEAD >/dev/null 2>&1; then
    die "claimed receipt worktree is still attached to a branch"
  fi
  status=$(git -C "$worktree" status --porcelain=v1 --untracked-files=all) \
    || die "cannot inspect claimed receipt worktree status"
  [ -z "$status" ] || die "claimed receipt worktree still has source state"
  head=$(git -C "$worktree" rev-parse HEAD) || die "cannot inspect claimed receipt worktree HEAD"
  valid_sha "$head" || die "claimed receipt worktree HEAD is invalid"
  gate_dir="$COMMON/saas-startup-team/maintain-runtime/base-checks/$run"
  safe_existing_dir "$gate_dir" || die "claimed receipt base-check directory is missing or unsafe"
  gate="$gate_dir/$head.json"
  [ -f "$gate" ] && [ ! -L "$gate" ] || die "claimed receipt worktree is not at a validated base"
  jq -e --arg run "$run" --arg base "$head" '
    type == "object"
    and keys == ["base_sha","check_oid","check_rel","checked_at","run_id","schema_version","status"]
    and .schema_version == 1 and .run_id == $run and .base_sha == $base and .status == "passed"
    and (.check_oid|type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))
    and (.check_rel|type == "string" and length > 0)
    and (.checked_at|type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' "$gate" >/dev/null || die "claimed receipt base-check proof is malformed"
  claim_branch_refs_absent

  guard_dirs+=("$COMMON/saas-startup-team")
  shopt -s nullglob
  guard_dirs+=("$COMMON"/worktrees/*/saas-startup-team)
  shopt -u nullglob
  for guard_dir in "${guard_dirs[@]}"; do
    [ -e "$guard_dir" ] || [ -L "$guard_dir" ] || continue
    safe_existing_dir "$guard_dir" || die "claimed receipt guard directory is unsafe"
    artifact=$(find -P "$guard_dir" -maxdepth 1 \
      \( -name "role-$run-*" -o -name "commit-$run-*" \) -print -quit) \
      || die "cannot inspect claimed receipt transaction guards"
    [ -z "$artifact" ] || die "claimed receipt has an in-flight source transaction guard"
  done
}

claim_delivery_pr_absent() {
  local snapshot marker="Maintain-Loop-Delivery: $DELIVERY_ID"
  snapshot=$(mktemp "$STATE_ROOT/.archive-prs.XXXXXX") \
    || die "cannot create claimed receipt PR snapshot"
  register_temp "$snapshot"
  (cd "$PRIMARY" && trusted_repo_gh pr list --state all --limit 10000 \
    --json number,state,body > "$snapshot") || die "cannot list claimed receipt pull requests"
  jq -e '
    type == "array" and length < 10000
    and all(.[];
      type == "object" and keys == ["body","number","state"]
      and (.number|type == "number" and . >= 1 and floor == .)
      and (.state == "OPEN" or .state == "CLOSED" or .state == "MERGED")
      and (.body|type == "string"))
  ' "$snapshot" >/dev/null || die "claimed receipt PR list is malformed or truncated"
  if jq -e --arg marker "$marker" \
    'any(.[]; (.body | split("\n") | any(. == $marker)))' "$snapshot" >/dev/null; then
    die "a pull request still carries this claimed receipt delivery marker"
  fi
  rm -f -- "$snapshot"; forget_temp "$snapshot"
}

if [ "$ACTION" = pending ]; then
  rows=()
  shopt -s nullglob
  for dir in "$STATE_ROOT"/issue-*; do
    [ -L "$dir" ] && die "delivery issue directory is unsafe"
    [ -d "$dir" ] || die "unexpected delivery state entry"
    n=${dir##*/issue-}; valid_uint "$n" || die "invalid delivery issue directory"
    [ -z "$ISSUE" ] || [ "$n" = "$ISSUE" ] || continue
    for history in "$dir"/history-*.json; do
      [ -f "$history" ] && [ ! -L "$history" ] && receipt_valid "$history" \
        || die "delivery history is malformed or unsafe"
    done
    [ -e "$dir/current.json" ] || [ -L "$dir/current.json" ] || continue
    [ -f "$dir/current.json" ] && [ ! -L "$dir/current.json" ] && receipt_valid "$dir/current.json" \
      || die "delivery receipt is malformed or unsafe"
    state=$(jq -r .state "$dir/current.json")
    terminal_state "$state" && continue
    rows+=("$(jq -c --arg receipt "$dir/current.json" '{issue_number,delivery_id,state,receipt:$receipt}' "$dir/current.json")")
  done
  printf '%s\n' "${rows[@]:-}" | jq -s 'map(select(type == "object")) | sort_by(.issue_number)'
  exit 0
fi

if [ "$ACTION" = begin ]; then
  valid_id "$RUN_ID" || die "invalid --run-id" 2
  valid_id "$DELIVERY_ID" || die "invalid --delivery-id" 2
  valid_natural "$MERGE_BUDGET" || die "invalid --merge-budget" 2
  require_active_controller "$RUN_ID" 0
  if [ -n "$REOPEN_EVENT_ID$REOPEN_EVENT_AT" ]; then
    valid_uint "$REOPEN_EVENT_ID" && valid_time "$REOPEN_EVENT_AT" \
      || die "reopen event needs a positive id and UTC timestamp" 2
  fi
  expected_issue_scope=$(canonical_issue_scope "$SCOPE_JSON") \
    || die "--scope-json must be an exact regular open-issue snapshot" 2
  issue_snapshot=$(mktemp "$STATE_ROOT/.begin-issue.XXXXXX") || die "cannot create issue snapshot"
  register_temp "$issue_snapshot"
  fresh_issue_snapshot "$issue_snapshot"
  current_issue_scope=$(canonical_issue_scope "$issue_snapshot") \
    || die "cannot canonicalize refreshed issue scope"
  [ "$current_issue_scope" = "$expected_issue_scope" ] \
    || die "issue scope changed after queue classification"
  ISSUE_UPDATED_AT=$(jq -r .updatedAt "$issue_snapshot")
  issue_scope=$(jq -cS '{number,title,body}' "$issue_snapshot") \
    || die "cannot canonicalize issue scope"
  digest_line=$(printf '%s' "$issue_scope" | /usr/bin/sha256sum) \
    || die "cannot digest issue scope"
  ORIGIN_ISSUE_DIGEST=${digest_line%% *}
  valid_digest "$ORIGIN_ISSUE_DIGEST" || die "issue scope digest is invalid"
  rm -f -- "$issue_snapshot"; forget_temp "$issue_snapshot"
  shopt -s nullglob
  for other in "$STATE_ROOT"/issue-*/current.json; do
    [ -f "$other" ] && [ ! -L "$other" ] && receipt_valid "$other" \
      || die "existing delivery receipt is malformed or unsafe"
    other_issue=$(jq -r .issue_number "$other"); other_state=$(jq -r .state "$other")
    if [ "$other_issue" != "$ISSUE" ] && ! terminal_state "$other_state"; then
      die "another issue has a nonterminal delivery receipt" 3
    fi
  done
  ensure_run_ledger "$RUN_ID" "$MERGE_BUDGET"
  set_issue_paths
  if [ ! -e "$issue_dir" ] && [ ! -L "$issue_dir" ]; then mkdir -- "$issue_dir" || die "cannot create issue receipt directory"; fi
  safe_existing_dir "$issue_dir" || die "issue receipt directory is unsafe"
  latest_generation=0; latest_terminal=""; latest_close=""; latest_file=""
  for receipt in "$issue_dir"/history-*.json "$current"; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    [ -f "$receipt" ] && [ ! -L "$receipt" ] && receipt_valid "$receipt" \
      || die "existing delivery receipt is malformed or unsafe"
    [ "$(jq -r .issue_number "$receipt")" = "$ISSUE" ] || die "existing receipt issue mismatch"
    [ "$(jq -r .delivery_id "$receipt")" != "$DELIVERY_ID" ] || die "delivery id was already used"
    generation=$(jq -r .generation "$receipt")
    if [ "$generation" -ge "$latest_generation" ]; then
      latest_generation=$generation; latest_terminal=$(jq -r .state "$receipt")
      latest_close=$(jq -r '.close.closed_at // ""' "$receipt"); latest_file=$receipt
    fi
  done
  if [ -e "$current" ] || [ -L "$current" ]; then
    state=$(jq -r .state "$current")
    terminal_state "$state" || die "a nonterminal delivery receipt already exists" 3
    archive="$issue_dir/history-$(jq -r .delivery_id "$current").json"
    [ ! -e "$archive" ] && [ ! -L "$archive" ] || die "delivery history target already exists"
  fi
  case "$latest_terminal" in
    archived_claim) : ;;
    finalized_success)
      [ -n "$REOPEN_EVENT_ID" ] && [ -n "$latest_close" ] && [[ "$REOPEN_EVENT_AT" > "$latest_close" ]] \
        || die "finalized delivery requires a later verified reopen event" ;;
    finalized_rolled_back)
      [ "$RETRY_AFTER_ROLLBACK" -eq 1 ] || die "rolled-back delivery requires an explicit retry generation" ;;
    "") : ;;
    *) die "latest delivery history is not terminal" ;;
  esac
  if [ -e "$current" ]; then mv -- "$current" "$archive" || die "cannot archive terminal delivery"; fi
  generation=$((latest_generation + 1)); created=$(now_iso); tmp=$(mktemp "$current.tmp.XXXXXX")
  reopen_json=null
  if [ -n "$REOPEN_EVENT_ID" ]; then
    reopen_json=$(jq -cn --argjson id "$REOPEN_EVENT_ID" --arg at "$REOPEN_EVENT_AT" '{id:$id,at:$at}')
  fi
  jq -n --arg delivery "$DELIVERY_ID" --arg run "$RUN_ID" --argjson issue "$ISSUE" \
    --argjson generation "$generation" --arg updated "$ISSUE_UPDATED_AT" --arg now "$created" \
    --arg origin_issue_digest "$ORIGIN_ISSUE_DIGEST" --argjson reopened "$reopen_json" '
      {schema_version:1,delivery_id:$delivery,origin_run_id:$run,issue_number:$issue,
       generation:$generation,issue_updated_at:$updated,origin_issue_digest:$origin_issue_digest,
       reopened_event:$reopened,
       state:"claimed",normal:null,rollback:null,release:null,close:null,final:null,updated_at:$now}' \
    > "$tmp"
  receipt_valid "$tmp" || { rm -f -- "$tmp"; die "cannot build delivery receipt"; }
  chmod 600 "$tmp" && mv -- "$tmp" "$current" || { rm -f -- "$tmp"; die "cannot persist delivery receipt"; }
  printf '%s\n' "$current"
  exit 0
fi

load_current
TOP_STATE=$(jq -r .state "$current")
DELIVERY_ID=$(jq -r .delivery_id "$current")

if [ "$ACTION" = show ]; then jq '.' "$current"; exit 0; fi

if [ "$ACTION" = archive-claimed ]; then
  [ "$TOP_STATE" = claimed ] || die "only a claimed receipt can be archived"
  jq -e '
    .normal == null and .rollback == null and .release == null and .close == null and .final == null
  ' "$current" >/dev/null || die "claimed receipt already owns delivery state"

  origin_run=$(jq -r .origin_run_id "$current")
  ARCHIVE_LEASE_RUN="claim-archive-$ISSUE-$$-$RANDOM"
  valid_id "$ARCHIVE_LEASE_RUN" || die "cannot create claimed receipt cleanup identity"
  ARCHIVE_LEASE_STATE="$COMMON/saas-startup-team/maintain-runtime/$ARCHIVE_LEASE_RUN-leases.json"
  if ! bash "$SCRIPT_DIR/maintain-leases.sh" acquire --repo-root "$PRIMARY" --mode maintain \
    --run-id "$ARCHIVE_LEASE_RUN" --state-file "$ARCHIVE_LEASE_STATE" >/dev/null; then
    die "claimed receipt cleanup requires all maintenance leases to be idle" 3
  fi

  issue_snapshot=$(mktemp "$STATE_ROOT/.archive-issue.XXXXXX") \
    || die "cannot create claimed receipt issue snapshot"
  register_temp "$issue_snapshot"
  fresh_closed_issue_snapshot "$issue_snapshot"
  rm -f -- "$issue_snapshot"; forget_temp "$issue_snapshot"

  load_run_ledger "$origin_run"
  jq -e --arg delivery "$DELIVERY_ID" \
    'all(.events[]; .delivery_id != $delivery)' "$RUN_LEDGER" >/dev/null \
    || die "claimed receipt already has a merge-ledger event"
  claim_source_state_absent "$origin_run"
  claim_delivery_pr_absent

  updated=$(now_iso)
  atomic_update '.state = "archived_claim" | .updated_at = $now' --arg now "$updated"
  if ! bash "$SCRIPT_DIR/maintain-leases.sh" cleanup --state-file "$ARCHIVE_LEASE_STATE" \
    --run-id "$ARCHIVE_LEASE_RUN" >/dev/null; then
    die "claimed receipt was archived but its cleanup lease could not be released"
  fi
  ARCHIVE_LEASE_STATE=""; ARCHIVE_LEASE_RUN=""
  printf '%s\n' "$current"
  exit 0
fi

case "$ACTION" in
  match-pr|render-result) : ;;
  *) require_active_controller "$(jq -r .origin_run_id "$current")" 1 ;;
esac

case "$ROLE" in normal|rollback) : ;; "") case "$ACTION" in close-intent|close-issue|observe-closed|render-result|finalize) : ;; *) usage ;; esac ;; *) usage ;; esac
role_key() { [ "$1" = normal ] && printf '.normal' || printf '.rollback'; }
role_line() { [ "$1" = normal ] && printf 'normal' || printf 'rollback:1'; }
role_object() { jq -c "$(role_key "$1")" "$current"; }

require_json_file() {
  [ -n "$1" ] && [ -f "$1" ] && [ ! -L "$1" ] && jq -e . "$1" >/dev/null 2>&1 \
    || die "missing, unsafe, or malformed JSON input"
}
safe_json_artifact() {
  local input=$1 absolute part old_ifs
  [ -n "$input" ] || die "JSON artifact path is empty"
  case "$input" in /*) absolute=$input ;; *) absolute="$PWD/$input" ;; esac
  old_ifs=$IFS; IFS=/
  for part in ${absolute#/}; do
    case "$part" in ""|.|..) IFS=$old_ifs; die "JSON artifact path is not canonical" ;; esac
  done
  IFS=$old_ifs
  absolute_path_has_no_symlink "$absolute" && [ -f "$absolute" ] && [ ! -L "$absolute" ] \
    && jq -e . "$absolute" >/dev/null 2>&1 || die "JSON artifact is missing, unsafe, or malformed"
  printf '%s\n' "$absolute"
}
exact_body_line() { [ "$(grep -Fxc -- "$1" <<<"$2" || true)" -eq 1 ]; }
verify_pr() {
  local role=$1 file=$2 obj body expected_role action pr_number bound state stored_base stored_body actual_body
  require_json_file "$file"
  jq -e '
    type == "object" and (.number|type == "number" and . >= 1 and floor == .)
    and (.state == "OPEN" or .state == "MERGED")
    and (.headRefName|type == "string") and (.headRefOid|type == "string")
    and (.baseRefName|type == "string") and (.body|type == "string")
    and (.mergeCommit == null or
      (.mergeCommit|type == "object" and (.oid|type == "string")))
  ' "$file" >/dev/null || die "PR snapshot is malformed"
  obj=$(role_object "$role"); [ "$obj" != null ] || die "PR marker has no matching supervisor receipt"
  body=$(jq -r .body "$file"); expected_role=$(role_line "$role"); action=$(jq -r .action_id <<<"$obj")
  exact_body_line "Maintain-Loop-Issue: #$ISSUE" "$body" \
    && exact_body_line "Maintain-Loop-Delivery: $DELIVERY_ID" "$body" \
    && exact_body_line "Maintain-Loop-Role: $expected_role" "$body" \
    && exact_body_line "Maintain-Loop-Action: $action" "$body" \
    || die "PR markers do not match the supervisor receipt"
  stored_body=$(jq -r '.body_digest // ""' <<<"$obj")
  if [ -n "$stored_body" ]; then
    actual_body=$(content_digest "$body")
    [ "$actual_body" = "$stored_body" ] || die "PR body changed after delivery binding"
  fi
  [ "$(jq -r .headRefName "$file")" = "$(jq -r .branch <<<"$obj")" ] \
    && [ "$(jq -r .headRefOid "$file")" = "$(jq -r .head_sha <<<"$obj")" ] \
    || die "PR branch or head does not match the supervisor receipt"
  stored_base=$(jq -r '.base_branch // ""' <<<"$obj")
  [ -z "$stored_base" ] || [ "$(jq -r .baseRefName "$file")" = "$stored_base" ] \
    || die "PR base branch does not match the supervisor receipt"
  bound=$(jq -r '.pr_number // ""' <<<"$obj"); pr_number=$(jq -r .number "$file")
  [ -z "$bound" ] || [ "$bound" = "$pr_number" ] || die "PR number does not match the supervisor receipt"
  state=$(jq -r .state "$file")
  if [ "$state" = MERGED ]; then
    case "$(jq -r .state <<<"$obj")" in merge_authorized|merged) : ;;
      *) die "merged PR lacks durable supervisor premerge authorization" ;;
    esac
    case "$(jq -r '.merge_method // ""' <<<"$obj")" in merge|squash) : ;;
      *) die "merged PR lacks helper-owned head-pinned merge intent" ;;
    esac
  fi
}

SHA256_BIN=""
ensure_sha256_bin() {
  local candidate canonical owner mode
  [ -z "$SHA256_BIN" ] || return 0
  candidate=$(type -P sha256sum 2>/dev/null || true); [ -n "$candidate" ] || die "sha256sum is required" 2
  case "$candidate" in /*) : ;; *) die "sha256sum must resolve to an absolute executable" ;; esac
  canonical=$(PATH=/usr/bin:/bin readlink -f -- "$candidate") || die "cannot resolve sha256sum executable"
  absolute_path_has_no_symlink "$canonical" && [ -f "$canonical" ] && [ -x "$canonical" ] \
    || die "sha256sum executable or ancestry is unsafe"
  case "$canonical" in "$ROOT"/*|"$PRIMARY"/*) die "repository-controlled sha256sum is not trusted" ;; esac
  owner=$(PATH=/usr/bin:/bin stat -c %u -- "$canonical") || die "cannot inspect sha256sum owner"
  mode=$(PATH=/usr/bin:/bin stat -c %a -- "$canonical") || die "cannot inspect sha256sum mode"
  [ "$owner" = 0 ] && (( (8#$mode & 022) == 0 )) \
    || die "sha256sum must be root-owned and not group/world-writable"
  SHA256_BIN=$canonical
}

file_digest() {
  local output digest
  ensure_sha256_bin
  output=$(PATH=/usr/bin:/bin "$SHA256_BIN" -- "$1") || die "cannot digest file"
  digest=${output%% *}; valid_digest "$digest" || die "sha256sum returned an invalid digest"
  printf '%s\n' "$digest"
}

content_digest() {
  local value=$1 output digest
  ensure_sha256_bin
  output=$(printf '%s' "$value" | PATH=/usr/bin:/bin "$SHA256_BIN") || die "cannot digest content"
  digest=${output%% *}; valid_digest "$digest" || die "sha256sum returned an invalid digest"
  printf '%s\n' "$digest"
}

qa_classifier_digest() {
  local classifier="$SCRIPT_DIR/ui-touch.sh" delivery_digest classifier_digest
  [ -f "$classifier" ] && [ ! -L "$classifier" ] || die "UI-touch classifier is missing or unsafe"
  delivery_digest=$(file_digest "${BASH_SOURCE[0]}")
  classifier_digest=$(file_digest "$classifier")
  content_digest "$delivery_digest:$classifier_digest"
}

path_has_no_symlink() {
  local root=$1 path=$2 rel part cursor=$1 old_ifs
  case "$path" in "$root"/*) rel=${path#"$root"/} ;; *) return 1 ;; esac
  old_ifs=$IFS; IFS=/
  for part in $rel; do
    [ -n "$part" ] || { IFS=$old_ifs; return 1; }
    cursor="$cursor/$part"
    [ ! -L "$cursor" ] || { IFS=$old_ifs; return 1; }
  done
  IFS=$old_ifs
}

absolute_path_has_no_symlink() {
  local path=$1 part cursor="" old_ifs
  case "$path" in /*) : ;; *) return 1 ;; esac
  old_ifs=$IFS; IFS=/
  for part in ${path#/}; do
    [ -n "$part" ] || { IFS=$old_ifs; return 1; }
    cursor="$cursor/$part"
    [ ! -L "$cursor" ] || { IFS=$old_ifs; return 1; }
  done
  IFS=$old_ifs
}

TRIBUNAL_BUNDLE_SHA256=772148ee2c99214cf9d6d56bcf3389160997e885d388936ffd7783f75d42e0b5
TRIBUNAL_ROOT=""; TRIBUNAL_COLLECTOR=""; TRIBUNAL_PATH=""

tribunal_bash() (
  local kill_after=$1 max_seconds=$2
  shift 2
  unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
    LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH
  export PATH="$TRIBUNAL_PATH"
  exec /usr/bin/env -u BASHOPTS -u SHELLOPTS \
    /usr/bin/timeout -k "$kill_after" "$max_seconds" /usr/bin/bash -p "$@"
)

tribunal_hold() (
  local interval=$1 max_seconds=$2 kill_after=$3 command_seconds=$4
  shift 4
  unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
    LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH
  export PATH="$TRIBUNAL_PATH"
  exec /usr/bin/env -u BASHOPTS -u SHELLOPTS \
    /usr/bin/bash -p "$SCRIPT_DIR/maintain-leases.sh" hold --state-file "$LEASE_STATE" \
      --interval-seconds "$interval" --max-seconds "$max_seconds" -- \
      /usr/bin/timeout -k "$kill_after" "$command_seconds" /usr/bin/bash -p "$@"
)

proof_hold() (
  unset BASH_ENV ENV CDPATH GLOBIGNORE PYTHONHOME PYTHONPATH \
    LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH
  exec /usr/bin/env -u BASHOPTS -u SHELLOPTS \
    /usr/bin/bash -p "$SCRIPT_DIR/maintain-leases.sh" hold --state-file "$LEASE_STATE" \
      --interval-seconds 60 --max-seconds 1900 -- \
      /usr/bin/timeout -k 10s 1800s /usr/bin/python3 -I -E \
      "$SCRIPT_DIR/proof-landlock.py" "$@"
)

trusted_external_path() {
  local raw dir canonical owner mode uid result=/usr/bin:/bin old_ifs
  uid=$(/usr/bin/id -u) || die "cannot inspect controller uid"
  old_ifs=$IFS; IFS=:
  for raw in $ORIGINAL_PATH; do
    case "$raw" in /*) : ;; *) continue ;; esac
    canonical=$(/usr/bin/readlink -f -- "$raw" 2>/dev/null || true)
    [ -n "$canonical" ] && [ -d "$canonical" ] || continue
    case "$canonical" in "$ROOT"|"$ROOT"/*|"$PRIMARY"|"$PRIMARY"/*) continue ;; esac
    owner=$(/usr/bin/stat -c %u -- "$canonical") || continue
    mode=$(/usr/bin/stat -c %a -- "$canonical") || continue
    { [ "$owner" = 0 ] || [ "$owner" = "$uid" ]; } && (( (8#$mode & 002) == 0 )) || continue
    case ":$result:" in *":$canonical:"*) : ;; *) result="$result:$canonical" ;; esac
  done
  IFS=$old_ifs
  printf '%s\n' "$result"
}

validate_tribunal_plugin() {
  local requested=$1 root manifest checker expected_checker result
  [ -n "$requested" ] && [ -d "$requested" ] || die "tribunal-review plugin root is required"
  root=$(cd -- "$requested" && pwd -P) || die "cannot resolve tribunal-review plugin root"
  absolute_path_has_no_symlink "$root" || die "tribunal-review plugin ancestry is unsafe"
  case "$root" in "$ROOT"|"$ROOT"/*|"$PRIMARY"|"$PRIMARY"/*) die "repository-controlled tribunal-review is not trusted" ;; esac
  manifest="$root/integrity/runner-bundle.json"; checker="$root/scripts/check-runner-bundle.sh"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -f "$checker" ] && [ ! -L "$checker" ] \
    || die "tribunal-review runner bundle is incomplete"
  [ "$(file_digest "$manifest")" = "$TRIBUNAL_BUNDLE_SHA256" ] \
    || die "tribunal-review runner bundle is not the required release"
  expected_checker=$(jq -er '.files[] | select(.path == "scripts/check-runner-bundle.sh") | .sha256' "$manifest") \
    || die "tribunal-review runner checker is not pinned"
  [ "$(file_digest "$checker")" = "$expected_checker" ] \
    || die "tribunal-review runner checker differs from its pinned bundle"
  TRIBUNAL_PATH=$(trusted_external_path)
  result=$(tribunal_bash 5s 60s "$checker" \
    --expected-manifest-sha256 "$TRIBUNAL_BUNDLE_SHA256") \
    || die "tribunal-review runner bundle failed integrity validation"
  jq -e --arg sha "$TRIBUNAL_BUNDLE_SHA256" '.status == "valid" and .sha256 == $sha' \
    <<<"$result" >/dev/null || die "tribunal-review runner checker returned an invalid result"
  TRIBUNAL_ROOT=$root; TRIBUNAL_COLLECTOR="$root/scripts/collect-review-evidence.sh"
}

tribunal_collection_path() {
  printf '%s/tribunal-%s-%s\n' "$issue_dir" "$DELIVERY_ID" "$1"
}

verify_tribunal_collection() {
  local role=$1 pr=$2 head=$3 collection manifest manifest_sha result
  collection=$(tribunal_collection_path "$role"); manifest="$collection/manifest.json"
  [ -d "$collection" ] && [ ! -L "$collection" ] && [ "$(dirname -- "$collection")" = "$issue_dir" ] \
    && [ -f "$manifest" ] && [ ! -L "$manifest" ] || die "tribunal collection is missing or unsafe"
  manifest_sha=$(file_digest "$manifest")
  result=$(tribunal_bash 5s 180s "$TRIBUNAL_COLLECTOR" \
    verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha") \
    || die "tribunal collection failed fresh verification"
  jq -e --arg path "$collection" --arg sha "$manifest_sha" \
    'type == "object" and keys == ["collection","manifest_sha256","status"]
     and .collection == $path and .manifest_sha256 == $sha and .status == "valid"' \
    <<<"$result" >/dev/null || die "tribunal collection verifier returned an invalid result"
  jq -e --argjson pr "$pr" --arg head "$head" \
    '.pull_request.number == $pr and .pull_request.head_oid == $head' "$manifest" >/dev/null \
    || die "tribunal collection is not bound to the delivery PR head"
  printf '%s\n' "$manifest_sha"
}

verify_tribunal_proof() {
  local proof=$1 role collection manifest_sha proof_sha result
  role=$(jq -r .role "$proof"); collection=$(tribunal_collection_path "$role")
  manifest_sha=$(jq -r .manifest_digest "$proof"); proof_sha=$(jq -r .proof_digest "$proof")
  valid_digest "$manifest_sha" && valid_digest "$proof_sha" || die "tribunal proof digests are invalid"
  [ -f "$collection/proof.json" ] && [ ! -L "$collection/proof.json" ] \
    && [ "$(file_digest "$collection/proof.json")" = "$proof_sha" ] \
    || die "retained tribunal proof differs from its receipt"
  result=$(tribunal_bash 5s 180s "$TRIBUNAL_COLLECTOR" \
    verify-proof --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --expected-proof-sha256 "$proof_sha") \
    || die "tribunal proof failed fresh verification"
  jq -e --arg path "$collection" --arg sha "$proof_sha" \
    'type == "object" and keys == ["collection","proof_sha256","status"]
     and .collection == $path and .proof_sha256 == $sha and .status == "valid"' \
    <<<"$result" >/dev/null || die "tribunal proof verifier returned an invalid result"
}

tracked_command() {
  local target=$1 input=$2 absolute rel entry mode blob actual
  [ -n "$input" ] || die "proof command is missing or unsafe"
  case "$input" in /*) absolute=$input ;; *) absolute="$ROOT/$input" ;; esac
  case "/${absolute#/}/" in */./*|*/../*) die "proof command path is not canonical" ;; esac
  [ -f "$absolute" ] && [ ! -L "$absolute" ] \
    || die "proof command is missing or unsafe"
  path_has_no_symlink "$ROOT" "$absolute" || die "proof command must have safe repository ancestry"
  rel=${absolute#"$ROOT"/}
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$target" ] \
    || die "proof command must run from the exact receipt commit"
  entry=$(git -C "$ROOT" ls-tree "$target" -- "$rel") || die "cannot inspect proof command"
  [ -n "$entry" ] || die "proof command must be tracked at the receipt commit"
  mode=${entry%% *}; entry=${entry#* }; [ "${entry%% *}" = blob ] \
    || die "proof command is not a tracked blob"
  case "$mode" in 100644|100755) : ;; *) die "proof command has an unsafe Git mode" ;; esac
  blob=${entry#* }; blob=${blob%%$'\t'*}; valid_sha "$blob" || die "proof command blob is invalid"
  actual=$(git -C "$ROOT" hash-object --no-filters -- "$rel") || die "cannot hash proof command"
  [ "$actual" = "$blob" ] || die "proof command differs from the receipt commit"
  printf '%s\t%s\t%s\n' "$absolute" "$rel" "$blob"
}

PROOF_PASS_ARGS=()
build_proof_pass_args() {
  local kind=$1 names="" name
  local -a proof_names=()
  PROOF_PASS_ARGS=(
    --pass-env MAINTAIN_PROOF_KIND
    --pass-env MAINTAIN_ISSUE_NUMBER
    --pass-env MAINTAIN_PR_NUMBER
    --pass-env MAINTAIN_HEAD_SHA
    --pass-env MAINTAIN_MERGE_SHA
    --pass-env MAINTAIN_DEPLOY_RUN_ID
    --pass-env MAINTAIN_LIVE_TARGET_SOURCE
    --pass-env MONITOR_SINCE
    --pass-env MONITOR_SINCE_MINUTES
  )
  case "$kind" in
    qa) names=${SAAS_MAINTAIN_QA_PROOF_ENV:-} ;;
    live) names=${SAAS_MAINTAIN_LIVE_PROOF_ENV:-} ;;
    *) die "proof environment kind is invalid" ;;
  esac
  case "$names" in *$'\n'*|*$'\r'*|*$'\t'*) die "proof environment configuration is invalid" ;; esac
  read -r -a proof_names <<<"$names" || true
  for name in "${proof_names[@]}"; do
    [[ "$name" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || die "proof environment name is invalid"
    case "$name" in
      GH_*|GITHUB_*|GIT_*|SSH_*|DOCKER_*|CODEX_*|CLAUDE_*|OPENAI_*|ANTHROPIC_*|GEMINI_*|GOOGLE_*|OPENROUTER_*|QWEN_*|DASHSCOPE_*|DEEPSEEK_*|OPENCODE_*|AWS_*|AZURE_*|KUBE*|CI_*|NPM_*|PYPI_*)
        die "proof environment configuration requested an infrastructure authority variable" ;;
    esac
    [ "${!name+x}" = x ] || die "proof command requires unset environment variable $name"
    PROOF_PASS_ARGS+=(--pass-env "$name")
    [ "${#PROOF_PASS_ARGS[@]}" -le 41 ] || die "proof environment allowlist is too large"
  done
}

require_configured_monitor_hook() {
  local target=$1 command_rel=$2 config_info config_abs line trimmed value="" count=0
  config_info=$(tracked_command "$target" .claude/saas-startup-team.local.md) \
    || die "monitor-hook proof requires tracked local plugin configuration"
  config_abs=${config_info%%$'\t'*}
  while IFS= read -r line; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in
      custom_checks:*)
        count=$((count + 1)); value=${trimmed#custom_checks:}
        value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
        ;;
    esac
  done < "$config_abs"
  [ "$count" -eq 1 ] && [ -n "$value" ] || die "monitor custom_checks binding is missing or ambiguous"
  case "$value" in /*|./*|../*|*/../*|*/./*|*$'\n'*|*$'\r'*) die "monitor custom_checks path is unsafe" ;; esac
  [ "$command_rel" = "$value" ] || die "live monitor hook does not match configured custom_checks"
}

monitor_jsonl_count() {
  local file=$1 raw count=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    [ -n "$raw" ] || continue
    jq -e '
      type == "object"
      and (.pattern_key|type == "string" and test("^[a-z0-9][a-z0-9:_-]*$"))
      and (.severity == "high" or .severity == "medium" or .severity == "low")
      and has("entity") and (.entity == null or ((.entity|type == "string") and ((.entity|test("[\\n`]"))|not)))
      and (.title|type == "string") and (.body|type == "string")
      and ((has("summary")|not) or (.summary|type == "string"))
    ' <<<"$raw" >/dev/null || return 1
    count=$((count + 1))
  done < "$file"
  printf '%s\n' "$count"
}

proof_path() { printf '%s/proof-%s-%s-%s.json\n' "$issue_dir" "$DELIVERY_ID" "$1" "$2"; }
proof_output_path() { printf '%s/proof-%s-%s-%s-output.json\n' "$issue_dir" "$DELIVERY_ID" "$1" "$2"; }

proof_valid() {
  local file=$1
  jq -e '
    def sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def id: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$");
    type == "object" and .schema_version == 1 and (.delivery_id|id)
    and (.issue_number|type == "number" and . >= 1 and floor == .)
    and (.role == "normal" or .role == "rollback") and (.kind == "qa" or .kind == "tribunal" or .kind == "live")
    and (.command_path|type == "string" and length > 0) and (.command_blob|sha)
    and (.output_path|type == "string" and test("^proof-[A-Za-z0-9_.-]+-(normal|rollback)-(qa|tribunal|live)-output(-[A-Za-z0-9_.-]+)?\\.json$"))
    and (.output_digest|digest) and (.evidence_id|id) and (.recorded_at|stamp)
    and (.status == "passed" or (.kind == "qa" and .status == "not_applicable"))
    and (if .kind == "qa" then
      keys == ["command_blob","command_path","delivery_id","evidence_id","head_sha","issue_number","kind","output_digest","output_path","pr_number","reason_code","recorded_at","role","schema_version","status"]
      and (.head_sha|sha) and (.pr_number|type == "number" and . >= 1 and floor == .) and (.reason_code|id)
    elif .kind == "tribunal" then
      keys == ["command_blob","command_path","delivery_id","evidence_id","head_sha","issue_number","kind","manifest_digest","output_digest","output_path","pr_number","proof_digest","recorded_at","role","runner_bundle_digest","schema_version","status"]
      and (.head_sha|sha) and (.pr_number|type == "number" and . >= 1 and floor == .)
      and (.manifest_digest|digest) and (.proof_digest|digest) and (.runner_bundle_digest|digest)
    else
      keys == ["command_blob","command_path","delivery_id","deploy_run_id","evidence_id","issue_number","kind","merge_sha","observed_at","output_digest","output_path","recorded_at","role","schema_version","status","target_source"]
      and (.deploy_run_id|id) and (.merge_sha|sha) and (.target_source|id) and (.observed_at|stamp)
    end)
  ' "$file" >/dev/null 2>&1
}

load_proof() {
  local role=$1 kind=$2 expected_path output_path expected_digest actual_digest
  expected_path=$(proof_path "$role" "$kind")
  [ -f "$expected_path" ] && [ ! -L "$expected_path" ] && [ "$(dirname -- "$expected_path")" = "$issue_dir" ] \
    && proof_valid "$expected_path" || die "$kind proof is missing, unsafe, or malformed"
  output_path="$issue_dir/$(jq -r .output_path "$expected_path")"
  [ -f "$output_path" ] && [ ! -L "$output_path" ] && [ "$(dirname -- "$output_path")" = "$issue_dir" ] \
    || die "$kind proof output is missing or unsafe"
  expected_digest=$(jq -r .output_digest "$expected_path"); actual_digest=$(file_digest "$output_path")
  [ "$actual_digest" = "$expected_digest" ] || die "$kind proof output changed after capture"
  printf '%s\n' "$expected_path"
}

verify_proof_producer() {
  local proof=$1 target=$2 path blob entry current_blob root
  path=$(jq -r .command_path "$proof"); blob=$(jq -r .command_blob "$proof")
  case "$path" in
    plugin:qa-diff-classifier)
      [ "$blob" = "$(qa_classifier_digest)" ] \
        || die "plugin proof validator changed after capture"
      ;;
    */scripts/collect-review-evidence.sh)
      [ "$blob" = "$TRIBUNAL_BUNDLE_SHA256" ] \
        && [ "$(jq -r .runner_bundle_digest "$proof")" = "$TRIBUNAL_BUNDLE_SHA256" ] \
        || die "tribunal-review runner bundle differs from the required release"
      root=${path%/scripts/collect-review-evidence.sh}
      validate_tribunal_plugin "$root"
      [ "$TRIBUNAL_COLLECTOR" = "$path" ] || die "tribunal proof producer path is invalid"
      verify_tribunal_proof "$proof"
      ;;
    plugin:*) die "unknown plugin proof producer" ;;
    *)
      entry=$(git -C "$PRIMARY" ls-tree "$target" -- "$path") || die "cannot revalidate proof producer"
      [ -n "$entry" ] && [ "${entry#* }" != "$entry" ] || die "proof producer is absent from the receipt commit"
      entry=${entry#* }; [ "${entry%% *}" = blob ] || die "proof producer is not a blob"
      current_blob=${entry#* }; current_blob=${current_blob%%$'\t'*}
      [ "$current_blob" = "$blob" ] || die "proof producer does not match the captured commit blob"
      ;;
  esac
}

validate_proof_output() {
  local kind=$1 file=$2 role=$3 pr=$4 target=$5 run=${6:-} source=${7:-} now state_time
  now=$(now_iso); state_time=${8:-0000-01-01T00:00:00Z}
  case "$kind" in
    qa)
      jq -e --argjson issue "$ISSUE" --argjson pr "$pr" --arg head "$target" \
        --arg earliest "$state_time" --arg now "$now" '
        def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        def id: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$");
        def digest: type == "string" and test("^[0-9a-f]{64}$");
        type == "object"
        and keys == ["assertions","head_sha","issue_number","kind","observed_at","pr_number","reason_code","schema_version","status"]
        and .schema_version == 1 and .kind == "qa" and .issue_number == $issue and .pr_number == $pr and .head_sha == $head
        and (.status == "passed" or .status == "not_applicable") and (.reason_code|id)
        and (.observed_at|stamp) and .observed_at >= $earliest and .observed_at <= $now
        and (.assertions|type == "array" and length > 0)
        and all(.assertions[]; type == "object" and keys == ["detail_digest","id","status"]
          and (.id|id) and .status == "passed" and (.detail_digest|digest))
      ' "$file" >/dev/null || die "QA command did not emit concrete head-bound evidence"
      ;;
    tribunal)
      jq -e --argjson issue "$ISSUE" --argjson pr "$pr" --arg head "$target" \
        --arg earliest "$state_time" --arg now "$now" '
        def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        def digest: type == "string" and test("^[0-9a-f]{64}$");
        type == "object"
        and keys == ["arbitration","finalized_at","manifest_sha256","pull_request","schema"]
        and .schema == "tribunal-proof/v1" and (.finalized_at|stamp)
        and .finalized_at >= $earliest and .finalized_at <= $now and (.manifest_sha256|digest)
        and (.pull_request|type == "object"
          and keys == ["body_sha256","diff_sha256","head_oid","number"]
          and .number == $pr and .head_oid == $head
          and (.body_sha256|digest) and (.diff_sha256|digest))
        and (.arbitration|type == "object"
          and keys == ["confidence","critical_count","decision","high_count","path","sha256"]
          and .path == "arbitration.json" and (.sha256|digest) and .decision == "APPROVE"
          and (.confidence|type == "number" and . >= 0 and . <= 1)
          and .critical_count == 0 and .high_count == 0)
      ' "$file" >/dev/null || die "tribunal collector did not emit an approving current-head proof"
      ;;
    live)
      jq -e --argjson issue "$ISSUE" --arg merge "$target" --arg run "$run" --arg source "$source" \
        --arg earliest "$state_time" --arg now "$now" '
        def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        def id: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$");
        def digest: type == "string" and test("^[0-9a-f]{64}$");
        type == "object"
        and (keys == ["assertions","deploy_run_id","issue_number","kind","merge_sha","observed_at","schema_version","status","target_source"]
          or keys == ["assertions","capture","deploy_run_id","issue_number","kind","merge_sha","observed_at","schema_version","status","target_source"])
        and .schema_version == 1 and .kind == "live" and .issue_number == $issue
        and .merge_sha == $merge and .deploy_run_id == $run and .target_source == $source and .status == "passed"
        and (.target_source|id) and (.observed_at|stamp) and .observed_at >= $earliest and .observed_at <= $now
        and (.assertions|type == "array" and length > 0)
        and all(.assertions[]; type == "object" and keys == ["detail_digest","id","status"]
          and (.id|id) and .status == "passed" and (.detail_digest|digest))
        and (if has("capture") then
          (.capture|type == "object"
            and keys == ["contract","finding_count","stderr_bytes","stderr_digest","stdout_bytes","stdout_digest"]
            and .contract == "monitor-hook"
            and (.finding_count|type == "number" and . >= 0 and floor == .)
            and (.stdout_bytes|type == "number" and . >= 0 and . <= 1048576 and floor == .)
            and (.stderr_bytes|type == "number" and . >= 0 and . <= 1048576 and floor == .)
            and (.stdout_digest|digest) and (.stderr_digest|digest))
        else true end)
      ' "$file" >/dev/null || die "live proof has no concrete merge-bound assertions"
      ;;
  esac
}

fresh_pr_snapshot() {
  local role=$1 destination=$2 pr
  ensure_gh_bin
  pr=$(jq -r "$(role_key "$role").pr_number" "$current"); valid_uint "$pr" || die "bound PR number is missing"
  (cd "$PRIMARY" && trusted_repo_gh pr view "$pr" --json number,state,headRefName,headRefOid,baseRefName,body,mergeCommit,title,files > "$destination") \
    || die "cannot refresh bound PR"
  verify_pr "$role" "$destination"
}

deploy_workflow_identity() {
  local target=$1 inventory path lower count=0 selected="" workflow_file line name="" blob
  inventory=$(mktemp "$STATE_ROOT/.deploy-workflows.XXXXXX") || die "cannot create workflow inventory"
  if ! git -C "$ROOT" ls-tree -r --name-only "$target" -- .github/workflows > "$inventory"; then
    rm -f -- "$inventory"; die "cannot inspect deployment workflows"
  fi
  while IFS= read -r path; do
    lower=${path##*/}; lower=${lower,,}
    case "$lower" in *deploy*.yml|*deploy*.yaml) count=$((count + 1)); selected=$path ;; esac
  done < "$inventory"
  rm -f -- "$inventory"
  [ "$count" -eq 1 ] || die "repository must have exactly one deploy-named workflow"
  workflow_file=$(mktemp "$STATE_ROOT/.deploy-workflow.XXXXXX") || die "cannot create workflow snapshot"
  if ! git -C "$ROOT" show "$target:$selected" > "$workflow_file"; then
    rm -f -- "$workflow_file"; die "cannot read deployment workflow"
  fi
  [ "$(wc -c < "$workflow_file")" -le 1048576 ] \
    || { rm -f -- "$workflow_file"; die "deployment workflow exceeds its byte budget"; }
  while IFS= read -r line; do
    case "$line" in name:*) name=${line#name:}; break ;; esac
  done < "$workflow_file"
  rm -f -- "$workflow_file"
  name=${name#"${name%%[![:space:]]*}"}; name=${name%"${name##*[![:space:]]}"}
  case "$name" in \"*\") name=${name#\"}; name=${name%\"} ;; \'*\') name=${name#\'}; name=${name%\'} ;; esac
  [ -n "$name" ] && [ "${#name}" -le 256 ] || die "deployment workflow has no bounded top-level name"
  blob=$(git -C "$ROOT" rev-parse "$target:$selected") || die "cannot bind deployment workflow blob"
  valid_sha "$blob" || die "deployment workflow blob is invalid"
  printf '%s\t%s\t%s\n' "$name" "$selected" "$blob"
}

FRESH_WORKFLOW_NAME=""; FRESH_WORKFLOW_PATH=""; FRESH_WORKFLOW_BLOB=""
fresh_run_snapshot() {
  local run=$1 expected_sha=$2 destination=$3 workflow identity rest workflow_path workflow_blob
  ensure_gh_bin
  identity=$(deploy_workflow_identity "$expected_sha")
  workflow=${identity%%$'\t'*}; rest=${identity#*$'\t'}
  workflow_path=${rest%%$'\t'*}; workflow_blob=${rest#*$'\t'}
  (cd "$PRIMARY" && trusted_repo_gh run view "$run" --json databaseId,headSha,status,conclusion,updatedAt,name,workflowName,event > "$destination") \
    || die "cannot refresh deploy run"
  jq -e --arg run "$run" --arg sha "$expected_sha" --arg workflow "$workflow" '
    def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    type == "object" and keys == ["conclusion","databaseId","event","headSha","name","status","updatedAt","workflowName"]
    and ((.databaseId|tostring) == $run) and .headSha == $sha and .workflowName == $workflow
    and (.event == "push" or .event == "workflow_run" or .event == "workflow_dispatch" or .event == "release")
    and .status == "completed" and .conclusion == "success" and (.updatedAt|stamp)
  ' "$destination" >/dev/null || die "deploy run is not a successful exact-merge run"
  FRESH_WORKFLOW_NAME=$workflow; FRESH_WORKFLOW_PATH=$workflow_path; FRESH_WORKFLOW_BLOB=$workflow_blob
}

verify_exact_rollback() {
  local base=$1 head=$2 target=$3 parent index expected_tree actual_tree count
  git -C "$PRIMARY" merge-base --is-ancestor "$target" "$base" \
    || die "rollback base does not contain the target merge"
  parent=$(git -C "$PRIMARY" rev-parse "$target^1" 2>/dev/null) \
    || die "rollback target has no first parent"
  count=$(git -C "$PRIMARY" rev-list --count "$base..$head") \
    || die "cannot inspect rollback commits"
  [ "$count" = 1 ] && [ "$(git -C "$PRIMARY" rev-parse "$head^1")" = "$base" ] \
    || die "rollback head must be exactly one commit on its recorded base"
  index=$(mktemp "$STATE_ROOT/.rollback-index.XXXXXX") \
    || die "cannot create rollback verification index"
  rm -f -- "$index"
  if ! GIT_INDEX_FILE="$index" git -C "$PRIMARY" read-tree "$base^{tree}" \
    || ! git -C "$PRIMARY" diff-tree --binary --full-index -p "$parent" "$target" \
      | GIT_INDEX_FILE="$index" git -C "$PRIMARY" apply --cached --reverse --3way - \
    || ! expected_tree=$(GIT_INDEX_FILE="$index" git -C "$PRIMARY" write-tree); then
    rm -f -- "$index"
    die "rollback target cannot be reversed cleanly from the recorded base"
  fi
  rm -f -- "$index"
  actual_tree=$(git -C "$PRIMARY" rev-parse "$head^{tree}") \
    || die "cannot inspect rollback tree"
  [ "$actual_tree" = "$expected_tree" ] \
    || die "rollback head is not the exact inverse of the target merge"
}

if [ "$ACTION" = plan-pr ]; then
  [ -n "$BRANCH" ] && valid_sha "$BASE_SHA" && valid_sha "$HEAD_SHA" || usage
  git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || die "invalid PR branch" 2
  git -C "$PRIMARY" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null \
    && git -C "$PRIMARY" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null \
    && git -C "$PRIMARY" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" \
    || die "planned PR commits are missing or not descendant"
  action_id="$DELIVERY_ID-$ROLE"; [ "$ROLE" = normal ] || action_id="$DELIVERY_ID-rollback-1"
  valid_id "$action_id" || die "delivery id is too long for a PR action"
  if [ "$ROLE" = normal ]; then expected=claimed; next=normal_planned; target=null
  else expected=post_merge; next=rollback_planned; target="\"$(jq -r .normal.merge.sha "$current")\""; fi
  if [ "$TOP_STATE" = "$next" ]; then
    obj=$(role_object "$ROLE")
    [ "$(jq -r .branch <<<"$obj")" = "$BRANCH" ] \
      && [ "$(jq -r .base_sha <<<"$obj")" = "$BASE_SHA" ] \
      && [ "$(jq -r .head_sha <<<"$obj")" = "$HEAD_SHA" ] \
      || die "conflicting repeated PR plan"
    printf '%s\n' "$current"; exit 0
  fi
  [ "$TOP_STATE" = "$expected" ] || die "cannot plan $ROLE PR from $TOP_STATE"
  if [ "$ROLE" = rollback ]; then
    target_sha=$(jq -r .normal.merge.sha "$current"); valid_sha "$target_sha" || die "normal merge is missing"
    verify_exact_rollback "$BASE_SHA" "$HEAD_SHA" "$target_sha"
  fi
  updated=$(now_iso); key=$(role_key "$ROLE")
  if [ "$ROLE" = normal ]; then
    atomic_update "$key = {action_id:\$action,branch:\$branch,base_sha:\$base,head_sha:\$head,
      base_branch:null,body_digest:null,pr_number:null,state:\"planned\",premerge:null,merge:null,merge_method:null}
      | .state = \$state | .updated_at = \$now" \
      --arg action "$action_id" --arg branch "$BRANCH" --arg base "$BASE_SHA" --arg head "$HEAD_SHA" \
      --arg state "$next" --arg now "$updated"
  else
    atomic_update "$key = {action_id:\$action,branch:\$branch,base_sha:\$base,head_sha:\$head,
      base_branch:null,body_digest:null,pr_number:null,state:\"planned\",premerge:null,merge:null,merge_method:null,target_merge_sha:\$target}
      | .state = \$state | .updated_at = \$now" \
      --arg action "$action_id" --arg branch "$BRANCH" --arg base "$BASE_SHA" --arg head "$HEAD_SHA" \
      --arg target "$target_sha" --arg state "$next" --arg now "$updated"
  fi
  printf '%s\n' "$current"; exit 0
fi

if [ "$ACTION" = match-pr ]; then
  terminal_state "$TOP_STATE" && die "terminal delivery history cannot authorize a PR resume"
  verify_pr "$ROLE" "$PR_JSON"
  jq -n --arg role "$ROLE" --argjson number "$(jq -r .number "$PR_JSON")" \
    --arg state "$(jq -r .state "$PR_JSON")" '{match:true,role:$role,number:$number,state:$state}'
  exit 0
fi

if [ "$ACTION" = bind-pr ]; then
  verify_pr "$ROLE" "$PR_JSON"
  [ "$(jq -r .state "$PR_JSON")" = OPEN ] || die "only an open PR can be bound"
  if [ "$ROLE" = normal ]; then expected=normal_planned; next=normal_open
  else expected=rollback_planned; next=rollback_open; fi
  obj=$(role_object "$ROLE"); number=$(jq -r .number "$PR_JSON"); base_branch=$(jq -r .baseRefName "$PR_JSON")
  body_digest=$(content_digest "$(jq -r .body "$PR_JSON")")
  if [ "$TOP_STATE" = "$next" ]; then
    [ "$(jq -r .pr_number <<<"$obj")" = "$number" ] || die "conflicting repeated PR binding"
    printf '%s\n' "$current"; exit 0
  fi
  [ "$TOP_STATE" = "$expected" ] || die "cannot bind $ROLE PR from $TOP_STATE"
  updated=$(now_iso); key=$(role_key "$ROLE")
  atomic_update "$key.pr_number = \$pr | $key.base_branch = \$base | $key.body_digest = \$body_digest | $key.state = \"open\"
    | .state = \$state | .updated_at = \$now" \
    --argjson pr "$number" --arg base "$base_branch" --arg body_digest "$body_digest" \
    --arg state "$next" --arg now "$updated"
  printf '%s\n' "$current"; exit 0
fi

if [ "$ACTION" = collect-tribunal ]; then
  [ -n "$TRIBUNAL_PLUGIN_ROOT" ] && [ -z "$KIND$COMMAND_FILE$ARTIFACT$DEPLOY_RUN_ID$LIVE_TARGET_SOURCE" ] \
    && [ "$NOT_APPLICABLE" -eq 0 ] || usage
  if [ "$ROLE" = normal ]; then expected=normal_open; else expected=rollback_open; fi
  [ "$TOP_STATE" = "$expected" ] || die "cannot collect $ROLE tribunal evidence from $TOP_STATE"
  obj=$(role_object "$ROLE"); pr=$(jq -r .pr_number <<<"$obj"); target=$(jq -r .head_sha <<<"$obj")
  valid_uint "$pr" && valid_sha "$target" || die "bound PR review identity is incomplete"
  validate_tribunal_plugin "$TRIBUNAL_PLUGIN_ROOT"
  collection=$(tribunal_collection_path "$ROLE")
  if [ ! -e "$collection" ] && [ ! -L "$collection" ]; then
    require_active_controller "$(jq -r .origin_run_id "$current")" 1
    collection_result=$(tribunal_hold 60 1900 10s 1800s "$TRIBUNAL_COLLECTOR" \
      collect --repo-root "$ROOT" --pr "$pr" --output "$collection") \
      || die "tribunal evidence collection failed"
    jq -e --arg path "$collection" --arg head "$target" --arg bundle "$TRIBUNAL_BUNDLE_SHA256" '
      type == "object" and keys == ["collection","head_oid","manifest_sha256","runner_bundle_sha256"]
      and .collection == $path and .head_oid == $head and .runner_bundle_sha256 == $bundle
      and (.manifest_sha256|type == "string" and test("^[0-9a-f]{64}$"))
    ' <<<"$collection_result" >/dev/null || die "tribunal collector returned an invalid binding"
  fi
  manifest_sha=$(verify_tribunal_collection "$ROLE" "$pr" "$target")
  jq -nc --arg collection "$collection" --arg manifest_sha256 "$manifest_sha" \
    --arg runner_bundle_sha256 "$TRIBUNAL_BUNDLE_SHA256" --arg head_oid "$target" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,
      runner_bundle_sha256:$runner_bundle_sha256,head_oid:$head_oid}'
  exit 0
fi

if [ "$ACTION" = record-proof ]; then
  case "$KIND" in qa|tribunal|live) : ;; *) usage ;; esac
  obj=$(role_object "$ROLE"); [ "$obj" != null ] || die "proof role is not planned"
  if [ "$KIND" = live ]; then
    [ -n "$COMMAND_FILE" ] || usage
    case "$LIVE_COMMAND_CONTRACT" in structured|monitor-hook) : ;; *) usage ;; esac
    [ -z "$ARTIFACT$TRIBUNAL_PLUGIN_ROOT" ] && [ "$NOT_APPLICABLE" -eq 0 ] || usage
    valid_uint "$DEPLOY_RUN_ID" && valid_id "$LIVE_TARGET_SOURCE" || usage
    if [ "$ROLE" = normal ]; then expected=post_merge; merge_path=.normal.merge.sha
    else expected=rollback_merged; merge_path=.rollback.merge.sha; fi
    [ "$TOP_STATE" = "$expected" ] \
      || { [ "$ROLE" = normal ] && [ "$TOP_STATE" = release_verified ]; } \
      || die "cannot record $ROLE live proof from $TOP_STATE"
    target=$(jq -r "$merge_path" "$current"); valid_sha "$target" || die "recorded merge is missing"
    pr=$(jq -r '.pr_number' <<<"$obj")
  else
    [ -z "$DEPLOY_RUN_ID$LIVE_TARGET_SOURCE" ] && [ "$LIVE_COMMAND_CONTRACT" = structured ] || usage
    if [ "$ROLE" = normal ]; then expected=normal_open
    else expected=rollback_open; fi
    [ "$TOP_STATE" = "$expected" ] || die "cannot record $ROLE $KIND proof from $TOP_STATE"
    target=$(jq -r .head_sha <<<"$obj"); pr=$(jq -r .pr_number <<<"$obj")
    valid_sha "$target" && valid_uint "$pr" || die "bound PR proof identity is incomplete"
    if [ "$KIND" = qa ]; then
      [ -z "$ARTIFACT$TRIBUNAL_PLUGIN_ROOT" ] || usage
      if [ "$NOT_APPLICABLE" -eq 1 ]; then [ -z "$COMMAND_FILE" ] || usage
      else [ -n "$COMMAND_FILE" ] || usage; fi
    else
      [ -z "$COMMAND_FILE" ] && [ "$NOT_APPLICABLE" -eq 0 ] && [ -n "$ARTIFACT" ] \
        && [ -n "$TRIBUNAL_PLUGIN_ROOT" ] || usage
    fi
  fi
  live_run_updated=""
  if [ "$KIND" = live ]; then
    run_tmp=$(mktemp "$STATE_ROOT/.deploy-run.XXXXXX") || die "cannot create run snapshot"
    if ! fresh_run_snapshot "$DEPLOY_RUN_ID" "$target" "$run_tmp"; then rm -f -- "$run_tmp"; exit 1; fi
    live_run_updated=$(jq -r .updatedAt "$run_tmp"); rm -f -- "$run_tmp"
    live_info=$(tracked_command "$target" "$COMMAND_FILE") || die "cannot authenticate live proof command"
    requested_abs=${live_info%%$'\t'*}; requested_rest=${live_info#*$'\t'}
    requested_rel=${requested_rest%%$'\t'*}; requested_blob=${requested_rest#*$'\t'}
    if [ "$LIVE_COMMAND_CONTRACT" = monitor-hook ]; then require_configured_monitor_hook "$target" "$requested_rel"; fi
  fi
  proof=$(proof_path "$ROLE" "$KIND"); output=$(proof_output_path "$ROLE" "$KIND"); old_output=""
  if [ -e "$proof" ] || [ -L "$proof" ]; then
    existing=$(load_proof "$ROLE" "$KIND")
    if [ "$KIND" = live ]; then
      jq -e --arg merge "$target" --arg run "$DEPLOY_RUN_ID" --arg source "$LIVE_TARGET_SOURCE" \
        --arg command "$requested_rel" --arg blob "$requested_blob" \
        '.merge_sha == $merge and .deploy_run_id == $run and .target_source == $source
          and .command_path == $command and .command_blob == $blob' "$existing" >/dev/null \
        || die "conflicting repeated live proof"
      existing_output="$issue_dir/$(jq -r .output_path "$existing")"
      if [ "$LIVE_COMMAND_CONTRACT" = monitor-hook ]; then
        jq -e '.capture.contract == "monitor-hook"' "$existing_output" >/dev/null \
          || die "existing live proof uses another command contract"
      else
        jq -e 'has("capture") | not' "$existing_output" >/dev/null \
          || die "existing live proof uses another command contract"
      fi
      verify_proof_producer "$existing" "$target"
      validate_proof_output live "$existing_output" "$ROLE" "$pr" "$target" \
        "$DEPLOY_RUN_ID" "$LIVE_TARGET_SOURCE" "$(jq -r .updated_at "$current")"
      if stamp_is_fresh "$(jq -r .observed_at "$existing")" 600; then
        printf '%s\n' "$existing"; exit 0
      fi
      old_output=$existing_output
    else
      jq -e --arg head "$target" --argjson pr "$pr" '.head_sha == $head and .pr_number == $pr' "$existing" >/dev/null \
        || die "conflicting repeated premerge proof"
      if [ "$KIND" = tribunal ]; then
        validate_tribunal_plugin "$TRIBUNAL_PLUGIN_ROOT"
        [ "$(jq -r .command_path "$existing")" = "$TRIBUNAL_COLLECTOR" ] \
          || die "conflicting repeated tribunal-review release"
        ARTIFACT=$(safe_json_artifact "$ARTIFACT")
        canonical_arbitration=$(mktemp "$STATE_ROOT/.tribunal-arbitration.XXXXXX") \
          || die "cannot canonicalize repeated tribunal arbitration"
        jq -S . "$ARTIFACT" > "$canonical_arbitration" \
          && cmp -s -- "$canonical_arbitration" "$(tribunal_collection_path "$ROLE")/arbitration.json" \
          || { rm -f -- "$canonical_arbitration"; die "conflicting repeated tribunal arbitration"; }
        rm -f -- "$canonical_arbitration"
        verify_proof_producer "$existing" "$target"
      fi
      printf '%s\n' "$existing"; exit 0
    fi
  fi
  if [ "$KIND" != live ] && { [ -e "$output" ] || [ -L "$output" ]; }; then
    [ -f "$output" ] && [ ! -L "$output" ] && [ "$(dirname -- "$output")" = "$issue_dir" ] \
      || die "orphaned proof output is unsafe"
    rm -f -- "$output" || die "cannot clear orphaned proof output"
  fi
  tmp_out=$(mktemp "$STATE_ROOT/.proof-output.XXXXXX") || die "cannot create proof output"
  if [ "$KIND" = qa ] && [ "$NOT_APPLICABLE" -eq 1 ]; then
    classification=""
    base=$(jq -r .base_sha <<<"$obj"); valid_sha "$base" || { rm -f -- "$tmp_out"; die "QA diff base is missing"; }
    diff_names=$(mktemp "$STATE_ROOT/.qa-diff.XXXXXX") || { rm -f -- "$tmp_out"; die "cannot create QA diff"; }
    git -C "$PRIMARY" diff --name-only -z "$base..$target" > "$diff_names" \
      || { rm -f -- "$tmp_out" "$diff_names"; die "cannot inspect QA applicability diff"; }
    classification=$(cd -- "$PRIMARY" && bash "$SCRIPT_DIR/ui-touch.sh" --range "$base..$target") \
      || { rm -f -- "$tmp_out" "$diff_names"; die "cannot classify QA applicability diff"; }
    case "$classification" in
      ui) rm -f -- "$tmp_out" "$diff_names"; die "browser-visible diff cannot use QA not-applicable" ;;
      no-ui) : ;;
      *) rm -f -- "$tmp_out" "$diff_names"; die "browser applicability classifier returned an ambiguous result" ;;
    esac
    if git -C "$PRIMARY" diff --numstat "$base..$target" | grep -Eq '^-[[:space:]]+-[[:space:]]+' \
      || git -C "$PRIMARY" diff --unified=0 "$base..$target" \
        | grep -Eiq '^[+-][^+-].*(browser|playwright|selenium|html|css|dom|react|vue|svelte|template|render|route|endpoint|http|viewport|responsive|accessibility)'; then
      rm -f -- "$tmp_out" "$diff_names"; die "browser applicability is ambiguous; run concrete QA"
    fi
    detail=$(file_digest "$diff_names"); rm -f -- "$diff_names"; observed=$(now_iso)
    jq -n --argjson issue "$ISSUE" --argjson pr "$pr" --arg head "$target" \
      --arg observed "$observed" --arg detail "$detail" \
      '{schema_version:1,kind:"qa",issue_number:$issue,pr_number:$pr,head_sha:$head,
        status:"not_applicable",reason_code:"no-browser-surface",observed_at:$observed,
        assertions:[{id:"bound-diff-has-no-browser-surface",status:"passed",detail_digest:$detail}]}' > "$tmp_out"
    command_rel='plugin:qa-diff-classifier'; command_blob=$(qa_classifier_digest)
  elif [ "$KIND" = tribunal ]; then
    ARTIFACT=$(safe_json_artifact "$ARTIFACT")
    [ "$(wc -c < "$ARTIFACT")" -le 2097152 ] || { rm -f -- "$tmp_out"; die "tribunal artifact exceeds its byte budget"; }
    validate_tribunal_plugin "$TRIBUNAL_PLUGIN_ROOT"
    collection=$(tribunal_collection_path "$ROLE")
    manifest_digest=$(verify_tribunal_collection "$ROLE" "$pr" "$target")
    require_active_controller "$(jq -r .origin_run_id "$current")" 1
    finalize_result=$(tribunal_hold 60 300 10s 240s "$TRIBUNAL_COLLECTOR" \
      finalize --collection "$collection" \
        --expected-manifest-sha256 "$manifest_digest" --arbitration "$ARTIFACT") \
      || { rm -f -- "$tmp_out"; die "tribunal arbitration failed collector validation"; }
    jq -e --arg path "$collection" --arg manifest "$manifest_digest" '
      type == "object" and keys == ["arbitration_sha256","collection","manifest_sha256","proof_sha256"]
      and .collection == $path and .manifest_sha256 == $manifest
      and (.proof_sha256|type == "string" and test("^[0-9a-f]{64}$"))
      and (.arbitration_sha256|type == "string" and test("^[0-9a-f]{64}$"))
    ' <<<"$finalize_result" >/dev/null \
      || { rm -f -- "$tmp_out"; die "tribunal finalizer returned an invalid result"; }
    proof_digest=$(jq -r .proof_sha256 <<<"$finalize_result")
    verify_result=$(tribunal_bash 5s 180s "$TRIBUNAL_COLLECTOR" \
      verify-proof --collection "$collection" \
        --expected-manifest-sha256 "$manifest_digest" --expected-proof-sha256 "$proof_digest") \
      || { rm -f -- "$tmp_out"; die "tribunal proof failed collector verification"; }
    jq -e --arg path "$collection" --arg proof "$proof_digest" '
      type == "object" and keys == ["collection","proof_sha256","status"]
      and .collection == $path and .proof_sha256 == $proof and .status == "valid"
    ' <<<"$verify_result" >/dev/null \
      || { rm -f -- "$tmp_out"; die "tribunal proof verifier returned an invalid result"; }
    [ -f "$collection/proof.json" ] && [ ! -L "$collection/proof.json" ] \
      && [ "$(file_digest "$collection/proof.json")" = "$proof_digest" ] \
      && cp -- "$collection/proof.json" "$tmp_out" \
      || { rm -f -- "$tmp_out"; die "cannot retain tribunal proof"; }
    command_rel=$TRIBUNAL_COLLECTOR; command_blob=$TRIBUNAL_BUNDLE_SHA256
  else
    if [ "$KIND" = live ]; then
      command_abs=$requested_abs; command_rel=$requested_rel; command_blob=$requested_blob
    else
      info=$(tracked_command "$target" "$COMMAND_FILE") || { rm -f -- "$tmp_out"; die "cannot authenticate proof command"; }
      command_abs=${info%%$'\t'*}; rest=${info#*$'\t'}; command_rel=${rest%%$'\t'*}; command_blob=${rest#*$'\t'}
    fi
    git -C "$ROOT" diff --quiet -- && git -C "$ROOT" diff --cached --quiet -- \
      || { rm -f -- "$tmp_out"; die "proof command requires an unchanged tracked tree"; }
    proof_work=$(mktemp -d "$STATE_ROOT/.proof-work.XXXXXX") \
      || { rm -f -- "$tmp_out"; die "cannot create disposable proof tree"; }
    proof_scratch=$(mktemp -d "$STATE_ROOT/.proof-scratch.XXXXXX") \
      || { rm -f -- "$tmp_out"; rm -rf -- "$proof_work"; die "cannot create proof scratch"; }
    chmod 700 "$proof_work" "$proof_scratch" \
      || { rm -f -- "$tmp_out"; rm -rf -- "$proof_work" "$proof_scratch"; die "cannot protect proof roots"; }
    register_temp "$proof_work"; register_temp "$proof_scratch"
    if ! git -C "$ROOT" archive --format=tar "$target" | /usr/bin/tar -xf - -C "$proof_work"; then
      rm -f -- "$tmp_out"; die "cannot materialize exact proof commit"
    fi
    archive_command="$proof_work/$command_rel"
    [ -f "$archive_command" ] && [ ! -L "$archive_command" ] \
      || { rm -f -- "$tmp_out"; die "proof command is absent from the disposable commit"; }
    chmod 700 "$archive_command" || { rm -f -- "$tmp_out"; die "cannot make proof command executable"; }
    build_proof_pass_args "$KIND"
    tmp_err="$proof_scratch/stderr"; sandbox_out="$proof_scratch/stdout"
    require_active_controller "$(jq -r .origin_run_id "$current")" 1
    if ! (ulimit -f 1024 && \
        export MAINTAIN_PROOF_KIND="$KIND" MAINTAIN_ISSUE_NUMBER="$ISSUE" MAINTAIN_PR_NUMBER="$pr" \
          MAINTAIN_HEAD_SHA="$target" MAINTAIN_MERGE_SHA="$target" MAINTAIN_DEPLOY_RUN_ID="$DEPLOY_RUN_ID" \
          MAINTAIN_LIVE_TARGET_SOURCE="$LIVE_TARGET_SOURCE" MONITOR_SINCE="$live_run_updated" \
          MONITOR_SINCE_MINUTES=1 && \
        proof_hold --work-root "$proof_work" --scratch-root "$proof_scratch" \
          "${PROOF_PASS_ARGS[@]}" -- "$archive_command") \
        >"$sandbox_out" 2>"$tmp_err"; then
      tail -c 4096 -- "$tmp_err" >&2 || true; rm -f -- "$tmp_out"; die "$KIND proof command failed"
    fi
    if [ "$(wc -c < "$sandbox_out")" -gt 1048576 ] || [ "$(wc -c < "$tmp_err")" -gt 1048576 ]; then
      rm -f -- "$tmp_out"; die "$KIND proof output exceeded its byte budget"
    fi
    mv -T -- "$sandbox_out" "$tmp_out" || { rm -f -- "$tmp_out"; die "cannot retain proof output"; }
    if [ "$KIND" = live ] && [ "$LIVE_COMMAND_CONTRACT" = monitor-hook ]; then
      finding_count=$(monitor_jsonl_count "$tmp_out") \
        || { rm -f -- "$tmp_out"; die "monitor hook emitted malformed findings JSONL"; }
      stdout_bytes=$(wc -c < "$tmp_out"); stderr_bytes=$(wc -c < "$tmp_err")
      stdout_digest=$(file_digest "$tmp_out"); stderr_digest=$(file_digest "$tmp_err")
      if [ "$finding_count" -ne 0 ]; then
        rm -f -- "$tmp_out"
        die "monitor hook reported $finding_count finding(s); stdout digest $stdout_digest"
      fi
      observed=$(now_iso)
      capture=$(jq -cn --arg stdout_digest "$stdout_digest" --arg stderr_digest "$stderr_digest" \
        --argjson stdout_bytes "$stdout_bytes" --argjson stderr_bytes "$stderr_bytes" \
        --argjson finding_count "$finding_count" \
        '{contract:"monitor-hook",stdout_bytes:$stdout_bytes,stdout_digest:$stdout_digest,
          stderr_bytes:$stderr_bytes,stderr_digest:$stderr_digest,finding_count:$finding_count}') \
        || { rm -f -- "$tmp_out"; die "cannot bind monitor hook capture"; }
      detail=$(content_digest "$capture") \
        || { rm -f -- "$tmp_out"; die "cannot digest monitor hook capture"; }
      sealed=$(mktemp "$STATE_ROOT/.monitor-proof.XXXXXX") \
        || { rm -f -- "$tmp_out"; die "cannot create monitor proof output"; }
      if ! jq -n --argjson issue "$ISSUE" --arg merge "$target" --arg run "$DEPLOY_RUN_ID" \
          --arg source "$LIVE_TARGET_SOURCE" --arg observed "$observed" --arg detail "$detail" \
          --argjson capture "$capture" \
          '{schema_version:1,kind:"live",issue_number:$issue,merge_sha:$merge,deploy_run_id:$run,
            target_source:$source,status:"passed",observed_at:$observed,capture:$capture,
            assertions:[{id:"configured-monitor-hook-exit-zero",status:"passed",detail_digest:$detail}]}' \
          > "$sealed"; then
        rm -f -- "$tmp_out" "$sealed"; die "cannot seal monitor hook proof"
      fi
      mv -T -- "$sealed" "$tmp_out" \
        || { rm -f -- "$tmp_out" "$sealed"; die "cannot publish monitor hook proof"; }
    fi
    rm -rf -- "$proof_work" "$proof_scratch"
    forget_temp "$proof_work"; forget_temp "$proof_scratch"
    git -C "$ROOT" diff --quiet -- && git -C "$ROOT" diff --cached --quiet -- \
      && [ "$(git -C "$ROOT" rev-parse HEAD)" = "$target" ] \
      || { rm -f -- "$tmp_out"; die "$KIND proof command changed the tracked candidate"; }
  fi
  [ "$(wc -c < "$tmp_out")" -le 8388608 ] \
    || { rm -f -- "$tmp_out"; die "$KIND proof bundle exceeded its byte budget"; }
  [ -s "$tmp_out" ] && jq -e . "$tmp_out" >/dev/null 2>&1 \
    || { rm -f -- "$tmp_out"; die "$KIND proof command returned no valid JSON"; }
  validate_proof_output "$KIND" "$tmp_out" "$ROLE" "$pr" "$target" "$DEPLOY_RUN_ID" "$LIVE_TARGET_SOURCE" \
    "$(jq -r .updated_at "$current")"
  if [ "$KIND" = live ]; then
    observed=$(jq -r .observed_at "$tmp_out")
    [[ "$observed" < "$live_run_updated" ]] \
      && { rm -f -- "$tmp_out"; die "live proof predates the successful deploy run"; }
  fi
  output_digest=$(file_digest "$tmp_out"); evidence_id="$KIND-${output_digest:0:24}"
  if [ "$KIND" = live ]; then
    output="$issue_dir/proof-$DELIVERY_ID-$ROLE-live-output-$evidence_id.json"
    [ ! -e "$output" ] && [ ! -L "$output" ] || die "live proof output identity already exists"
  fi
  recorded=$(now_iso); output_name=${output##*/}
  case "$KIND" in
    qa)
      status=$(jq -r .status "$tmp_out"); reason=$(jq -r .reason_code "$tmp_out")
      proof_json=$(jq -cn --arg delivery "$DELIVERY_ID" --argjson issue "$ISSUE" --arg role "$ROLE" \
        --argjson pr "$pr" --arg head "$target" --arg status "$status" --arg reason "$reason" \
        --arg command "$command_rel" --arg blob "$command_blob" --arg output "$output_name" \
        --arg digest "$output_digest" --arg evidence "$evidence_id" --arg now "$recorded" \
        '{schema_version:1,delivery_id:$delivery,issue_number:$issue,role:$role,kind:"qa",pr_number:$pr,
          head_sha:$head,status:$status,reason_code:$reason,evidence_id:$evidence,command_path:$command,
          command_blob:$blob,output_path:$output,output_digest:$digest,recorded_at:$now}')
      ;;
    tribunal)
      proof_json=$(jq -cn --arg delivery "$DELIVERY_ID" --argjson issue "$ISSUE" --arg role "$ROLE" \
        --argjson pr "$pr" --arg head "$target" --arg command "$command_rel" --arg blob "$command_blob" \
        --arg output "$output_name" --arg digest "$output_digest" --arg manifest "$manifest_digest" \
        --arg proof "$proof_digest" --arg bundle "$TRIBUNAL_BUNDLE_SHA256" \
        --arg evidence "$evidence_id" --arg now "$recorded" \
        '{schema_version:1,delivery_id:$delivery,issue_number:$issue,role:$role,kind:"tribunal",pr_number:$pr,
          head_sha:$head,status:"passed",evidence_id:$evidence,manifest_digest:$manifest,proof_digest:$proof,
          runner_bundle_digest:$bundle,command_path:$command,command_blob:$blob,
          output_path:$output,output_digest:$digest,recorded_at:$now}')
      ;;
    live)
      observed=$(jq -r .observed_at "$tmp_out")
      proof_json=$(jq -cn --arg delivery "$DELIVERY_ID" --argjson issue "$ISSUE" --arg role "$ROLE" \
        --arg merge "$target" --arg run "$DEPLOY_RUN_ID" --arg source "$LIVE_TARGET_SOURCE" \
        --arg observed "$observed" --arg command "$command_rel" --arg blob "$command_blob" \
        --arg output "$output_name" --arg digest "$output_digest" --arg evidence "$evidence_id" --arg now "$recorded" \
        '{schema_version:1,delivery_id:$delivery,issue_number:$issue,role:$role,kind:"live",merge_sha:$merge,
          deploy_run_id:$run,target_source:$source,observed_at:$observed,status:"passed",evidence_id:$evidence,
          command_path:$command,command_blob:$blob,output_path:$output,output_digest:$digest,recorded_at:$now}')
      ;;
  esac
  proof_tmp=$(mktemp "$proof.tmp.XXXXXX") || { rm -f -- "$tmp_out"; die "cannot create proof receipt"; }
  printf '%s\n' "$proof_json" > "$proof_tmp"
  proof_valid "$proof_tmp" || { rm -f -- "$tmp_out" "$proof_tmp"; die "cannot build proof receipt"; }
  chmod 600 "$tmp_out" "$proof_tmp" \
    && mv -T -- "$tmp_out" "$output" && mv -T -- "$proof_tmp" "$proof" \
    || { rm -f -- "$tmp_out" "$proof_tmp"; die "cannot persist proof receipt"; }
  if [ -n "$old_output" ] && [ "$old_output" != "$output" ]; then rm -f -- "$old_output" || true; fi
  printf '%s\n' "$proof"; exit 0
fi

if [ "$ACTION" = authorize-merge ]; then
  if [ "$ROLE" = normal ]; then expected=normal_open; next=normal_merge_authorized
  else expected=rollback_open; next=rollback_merge_authorized; fi
  obj=$(role_object "$ROLE")
  [ "$TOP_STATE" = "$expected" ] || [ "$TOP_STATE" = "$next" ] \
    || die "cannot authorize $ROLE merge from $TOP_STATE"
  pr_number=$(jq -r .pr_number <<<"$obj"); head_sha=$(jq -r .head_sha <<<"$obj"); base_branch=$(jq -r .base_branch <<<"$obj")
  valid_uint "$pr_number" && valid_sha "$head_sha" && [ -n "$base_branch" ] || die "bound PR identity is incomplete"
  qa_proof=$(load_proof "$ROLE" qa); tribunal_proof=$(load_proof "$ROLE" tribunal)
  jq -e --arg delivery "$DELIVERY_ID" --argjson issue "$ISSUE" --arg role "$ROLE" --argjson pr "$pr_number" --arg head "$head_sha" \
    '.delivery_id == $delivery and .issue_number == $issue and .role == $role and .pr_number == $pr and .head_sha == $head' \
    "$qa_proof" >/dev/null || die "QA proof identity does not match the delivery"
  jq -e --arg delivery "$DELIVERY_ID" --argjson issue "$ISSUE" --arg role "$ROLE" --argjson pr "$pr_number" --arg head "$head_sha" \
    '.delivery_id == $delivery and .issue_number == $issue and .role == $role and .pr_number == $pr and .head_sha == $head' \
    "$tribunal_proof" >/dev/null || die "tribunal proof identity does not match the delivery"
  verify_proof_producer "$qa_proof" "$head_sha"; verify_proof_producer "$tribunal_proof" "$head_sha"
  qa_output="$issue_dir/$(jq -r .output_path "$qa_proof")"
  tribunal_output="$issue_dir/$(jq -r .output_path "$tribunal_proof")"
  validate_proof_output qa "$qa_output" "$ROLE" "$pr_number" "$head_sha"
  validate_proof_output tribunal "$tribunal_output" "$ROLE" "$pr_number" "$head_sha"
  ensure_gh_bin
  pr_before=$(mktemp "$STATE_ROOT/.premerge-pr.XXXXXX") || die "cannot create PR snapshot"
  pr_after=$(mktemp "$STATE_ROOT/.premerge-pr.XXXXXX") || { rm -f -- "$pr_before"; die "cannot create PR snapshot"; }
  checks_tmp=$(mktemp "$STATE_ROOT/.premerge-checks.XXXXXX") || { rm -f -- "$pr_before" "$pr_after"; die "cannot create checks snapshot"; }
  fresh_pr_snapshot "$ROLE" "$pr_before"; [ "$(jq -r .state "$pr_before")" = OPEN ] \
    || { rm -f -- "$pr_before" "$pr_after" "$checks_tmp"; die "merge authorization requires an open PR"; }
  if ! (cd "$PRIMARY" && trusted_repo_gh pr checks "$pr_number" --json name,bucket,link > "$checks_tmp"); then
    rm -f -- "$pr_before" "$pr_after" "$checks_tmp"; die "cannot query current PR checks"
  fi
  jq -e '
    type == "array" and length > 0
    and all(.[]; type == "object" and (.name|type == "string" and length > 0)
      and (.bucket == "pass" or .bucket == "skipping") and (.link == null or (.link|type == "string")))
    and any(.[]; .bucket == "pass")
  ' "$checks_tmp" >/dev/null \
    || { rm -f -- "$pr_before" "$pr_after" "$checks_tmp"; die "current PR checks are absent, incomplete, or not green"; }
  fresh_pr_snapshot "$ROLE" "$pr_after"
  jq -e --slurpfile before "$pr_before" '
    .number == $before[0].number and .state == "OPEN" and .headRefName == $before[0].headRefName
    and .headRefOid == $before[0].headRefOid and .baseRefName == $before[0].baseRefName and .body == $before[0].body
  ' "$pr_after" >/dev/null \
    || { rm -f -- "$pr_before" "$pr_after" "$checks_tmp"; die "PR identity changed while checks were inspected"; }
  checks_json=$(jq -cS 'sort_by(.name,.link)' "$checks_tmp") \
    || { rm -f -- "$pr_before" "$pr_after" "$checks_tmp"; die "cannot bind current PR checks"; }
  checks_digest=$(content_digest "$checks_json") \
    || { rm -f -- "$pr_before" "$pr_after" "$checks_tmp"; die "cannot digest current PR checks"; }
  checks_id="checks-${checks_digest:0:24}"
  rm -f -- "$checks_tmp"
  git -C "$PRIMARY" fetch --quiet origin "$base_branch" \
    || { rm -f -- "$pr_before" "$pr_after"; die "cannot fetch the exact default branch"; }
  default_sha=$(git -C "$PRIMARY" rev-parse "refs/remotes/origin/$base_branch") \
    || { rm -f -- "$pr_before" "$pr_after"; die "cannot resolve fetched default branch"; }
  valid_sha "$default_sha" && git -C "$PRIMARY" merge-base --is-ancestor "$default_sha" "$head_sha" \
    || { rm -f -- "$pr_before" "$pr_after"; die "premerge default ancestry is not proven"; }
  trusted_path="$(dirname -- "$GH_BIN"):/usr/bin:/bin"
  if ! (cd "$PRIMARY" && PATH="$trusted_path" bash "$SCRIPT_DIR/issue-closure-audit.sh" \
      --pr "$pr_number" --audit-issue "$ISSUE") >/dev/null; then
    rm -f -- "$pr_before" "$pr_after"; die "prospective closure audit failed"
  fi
  fresh_pr_snapshot "$ROLE" "$pr_after"; [ "$(jq -r .state "$pr_after")" = OPEN ] \
    || { rm -f -- "$pr_before" "$pr_after"; die "PR changed during prospective closure audit"; }
  rm -f -- "$pr_before" "$pr_after"
  authorized=$(now_iso)
  qa_status=$(jq -r .status "$qa_proof"); qa_reason=$(jq -r .reason_code "$qa_proof"); qa_id=$(jq -r .evidence_id "$qa_proof")
  tribunal_id=$(jq -r .evidence_id "$tribunal_proof")
  evidence=$(jq -cn --argjson pr "$pr_number" --arg head "$head_sha" --arg base "$base_branch" \
    --arg default "$default_sha" --arg now "$authorized" --arg checks "$checks_id" \
    --arg qa_status "$qa_status" --arg qa_reason "$qa_reason" --arg qa "$qa_id" --arg tribunal "$tribunal_id" '
    {authorized_at:$now,base_branch:$base,checks:{evidence_id:$checks,head_sha:$head,status:"passed"},
     closure_audit:{status:"passed",head_sha:$head},default_sha:$default,head_sha:$head,pr_number:$pr,
     qa:{evidence_id:$qa,head_sha:$head,reason_code:$qa_reason,status:$qa_status},
     tribunal:{evidence_id:$tribunal,head_sha:$head,status:"passed"}}')
  if [ "$TOP_STATE" = "$next" ]; then
    jq -e --argjson evidence "$evidence" "$(role_key "$ROLE").premerge
      | .base_branch == \$evidence.base_branch and .default_sha == \$evidence.default_sha
      and .head_sha == \$evidence.head_sha and .pr_number == \$evidence.pr_number
      and .checks == \$evidence.checks and .closure_audit == \$evidence.closure_audit
      and .qa == \$evidence.qa and .tribunal == \$evidence.tribunal" "$current" >/dev/null \
      || die "current evidence conflicts with repeated premerge authorization"
    printf '%s\n' "$current"; exit 0
  fi
  updated=$authorized; key=$(role_key "$ROLE")
  atomic_update "$key.premerge = \$evidence | $key.state = \"merge_authorized\"
    | .state = \$state | .updated_at = \$now" \
    --argjson evidence "$evidence" --arg state "$next" --arg now "$updated"
  printf '%s\n' "$current"; exit 0
fi

if [ "$ACTION" = merge-pr ]; then
  case "$MERGE_METHOD" in merge|squash) : ;; *) usage ;; esac
  [ -z "$PR_JSON" ] || usage
  ensure_gh_bin
  if [ "$ROLE" = normal ]; then expected=normal_merge_authorized
  else expected=rollback_merge_authorized; fi
  [ "$TOP_STATE" = "$expected" ] || die "cannot merge $ROLE PR from $TOP_STATE"
  key=$(role_key "$ROLE"); pr_number=$(jq -r "$key.pr_number" "$current"); head_sha=$(jq -r "$key.head_sha" "$current")
  base_branch=$(jq -r "$key.base_branch" "$current"); authorized_default=$(jq -r "$key.premerge.default_sha" "$current")
  pr_snapshot=$(mktemp "$STATE_ROOT/.merge-pr.XXXXXX") || die "cannot create merge PR snapshot"
  checks_tmp=$(mktemp "$STATE_ROOT/.merge-checks.XXXXXX") || { rm -f -- "$pr_snapshot"; die "cannot create merge checks snapshot"; }
  fresh_pr_snapshot "$ROLE" "$pr_snapshot"; [ "$(jq -r .state "$pr_snapshot")" = OPEN ] \
    || { rm -f -- "$pr_snapshot" "$checks_tmp"; die "only the exact open bound PR can be merged"; }
  if ! (cd "$PRIMARY" && trusted_repo_gh pr checks "$pr_number" --json name,bucket,link > "$checks_tmp") \
    || ! jq -e 'type == "array" and length > 0
      and all(.[]; type == "object" and (.name|type == "string" and length > 0)
        and (.bucket == "pass" or .bucket == "skipping")) and any(.[]; .bucket == "pass")' \
      "$checks_tmp" >/dev/null; then
    rm -f -- "$pr_snapshot" "$checks_tmp"; die "merge-time PR checks are absent, incomplete, or not green"
  fi
  rm -f -- "$checks_tmp"
  git -C "$PRIMARY" fetch --quiet origin "$base_branch" \
    || { rm -f -- "$pr_snapshot"; die "cannot refresh default before merge"; }
  current_default=$(git -C "$PRIMARY" rev-parse "refs/remotes/origin/$base_branch") \
    || { rm -f -- "$pr_snapshot"; die "cannot resolve merge-time default"; }
  [ "$current_default" = "$authorized_default" ] && git -C "$PRIMARY" merge-base --is-ancestor "$current_default" "$head_sha" \
    || { rm -f -- "$pr_snapshot"; die "default changed after merge authorization"; }
  rm -f -- "$pr_snapshot"
  existing_method=$(jq -r "$key.merge_method // \"\"" "$current")
  if [ -n "$existing_method" ] && [ "$existing_method" != "$MERGE_METHOD" ]; then
    die "conflicting repeated merge method"
  fi
  if [ -z "$existing_method" ]; then
    updated=$(now_iso)
    atomic_update "$key.merge_method = \$method | .updated_at = \$now" \
      --arg method "$MERGE_METHOD" --arg now "$updated"
  fi
  load_run_ledger "$(jq -r .origin_run_id "$current")"
  merge_budget=$(jq -r .merge_budget "$RUN_LEDGER")
  normal_merge_count=$(jq -r .normal_merge_count "$RUN_LEDGER")
  if [ "$ROLE" = normal ]; then
    [ "$normal_merge_count" -lt "$merge_budget" ] \
      || die "run-wide forward merge budget is exhausted"
  else
    jq -e --arg delivery "$DELIVERY_ID" --arg sha "$(jq -r .normal.merge.sha "$current")" '
      any(.events[]; .delivery_id == $delivery and .role == "normal" and .sha == $sha)
    ' "$RUN_LEDGER" >/dev/null || die "rollback lacks its run-ledger normal merge"
  fi
  require_active_controller "$(jq -r .origin_run_id "$current")" 1
  if ! (cd "$PRIMARY" && trusted_repo_gh pr merge "$pr_number" --match-head-commit "$head_sha" "--$MERGE_METHOD"); then
    die "head-pinned PR merge failed"
  fi
  printf '%s\n' "$current"; exit 0
fi

if [ "$ACTION" = record-merge ]; then
  [ -z "$PR_JSON" ] || usage
  ensure_gh_bin
  pr_snapshot=$(mktemp "$STATE_ROOT/.record-merge-pr.XXXXXX") || die "cannot create merged PR snapshot"
  fresh_pr_snapshot "$ROLE" "$pr_snapshot"
  [ "$(jq -r .state "$pr_snapshot")" = MERGED ] || { rm -f -- "$pr_snapshot"; die "PR is not merged"; }
  merge_sha=$(jq -r '.mergeCommit.oid // ""' "$pr_snapshot"); rm -f -- "$pr_snapshot"
  valid_sha "$merge_sha" || die "merged PR has no concrete merge SHA"
  base_branch=$(jq -r "$(role_key "$ROLE").base_branch" "$current")
  git -C "$PRIMARY" fetch --quiet origin "$base_branch" || die "cannot refresh merged default branch"
  default_sha=$(git -C "$PRIMARY" rev-parse "refs/remotes/origin/$base_branch") || die "cannot resolve merged default branch"
  git -C "$PRIMARY" cat-file -e "$default_sha^{commit}" 2>/dev/null \
    && git -C "$PRIMARY" cat-file -e "$merge_sha^{commit}" 2>/dev/null \
    && git -C "$PRIMARY" merge-base --is-ancestor "$merge_sha" "$default_sha" \
    || die "merged PR is not proven on the default branch"
  if [ "$ROLE" = normal ]; then expected=normal_merge_authorized; next=post_merge
  else expected=rollback_merge_authorized; next=rollback_merged; fi
  load_run_ledger "$(jq -r .origin_run_id "$current")"
  MERGE_BUDGET=$(jq -r .merge_budget "$RUN_LEDGER")
  ledger_event=$(jq -c --arg delivery "$DELIVERY_ID" --arg role "$ROLE" '
    [.events[]|select(.delivery_id == $delivery and .role == $role)] | if length == 1 then .[0] else null end
  ' "$RUN_LEDGER") || die "cannot inspect run merge ledger"
  [ "$ledger_event" = null ] || [ "$(jq -r .sha <<<"$ledger_event")" = "$merge_sha" ] \
    || die "run merge ledger conflicts with the merged PR"
  if [ "$TOP_STATE" = "$next" ]; then
    [ "$ledger_event" != null ] || die "recorded merge is absent from the run ledger"
    MERGE_COUNT=$(jq -r "$(role_key "$ROLE").merge.merge_count" "$current")
    jq -e --arg merge "$merge_sha" --arg default "$default_sha" \
      --argjson count "$MERGE_COUNT" --argjson budget "$MERGE_BUDGET" \
      "$(role_key "$ROLE").merge | .sha == \$merge and .default_sha == \$default
        and .merge_count == \$count and .merge_budget == \$budget" "$current" >/dev/null \
      || die "conflicting repeated merge observation"
    printf '%s\n' "$current"; exit 0
  fi
  [ "$TOP_STATE" = "$expected" ] || die "cannot record $ROLE merge from $TOP_STATE"
  observed=$(now_iso)
  if [ "$ledger_event" = null ]; then
    normal_count=$(jq -r .normal_merge_count "$RUN_LEDGER")
    if [ "$ROLE" = normal ]; then
      MERGE_COUNT=$((normal_count + 1))
      [ "$MERGE_COUNT" -le "$MERGE_BUDGET" ] || die "run-wide forward merge budget is exhausted"
      ledger_filter='.normal_merge_count += 1 | .events += [$event]'
    else
      jq -e --arg delivery "$DELIVERY_ID" --arg sha "$(jq -r .normal.merge.sha "$current")" '
        any(.events[]; .delivery_id == $delivery and .role == "normal" and .sha == $sha)
      ' "$RUN_LEDGER" >/dev/null || die "rollback lacks its run-ledger normal merge"
      MERGE_COUNT=$((normal_count + 1))
      [ "$MERGE_COUNT" -le $((MERGE_BUDGET + 1)) ] \
        || die "rollback exceeds the single emergency overage"
      ledger_filter='.events += [$event]'
    fi
    event=$(jq -cn --arg delivery "$DELIVERY_ID" --argjson issue "$ISSUE" --arg role "$ROLE" \
      --arg sha "$merge_sha" --arg observed "$observed" \
      '{delivery_id:$delivery,issue_number:$issue,role:$role,sha:$sha,observed_at:$observed}')
    atomic_update_run_ledger "$ledger_filter" --argjson event "$event"
  else
    normal_count=$(jq -r .normal_merge_count "$RUN_LEDGER")
    if [ "$ROLE" = normal ]; then MERGE_COUNT=$normal_count; else MERGE_COUNT=$((normal_count + 1)); fi
  fi
  key=$(role_key "$ROLE")
  atomic_update "$key.merge = {sha:\$merge,default_sha:\$default,merge_count:\$count,merge_budget:\$budget,observed_at:\$now}
    | $key.state = \"merged\" | .state = \$state | .updated_at = \$now" \
    --arg merge "$merge_sha" --arg default "$default_sha" --argjson count "$MERGE_COUNT" \
    --argjson budget "$MERGE_BUDGET" --arg state "$next" --arg now "$observed"
  printf '%s\n' "$current"; exit 0
fi

if [ "$ACTION" = record-release ]; then
  valid_uint "$DEPLOY_RUN_ID" && valid_id "$LIVE_TARGET_SOURCE" || usage
  if [ "$ROLE" = normal ]; then expected=post_merge; next=release_verified; merge_path=.normal.merge.sha
  else expected=rollback_merged; next=rollback_release_verified; merge_path=.rollback.merge.sha; fi
  merge_sha=$(jq -r "$merge_path" "$current"); valid_sha "$merge_sha" || die "recorded merge is missing"
  live_proof=$(load_proof "$ROLE" live)
  jq -e --arg delivery "$DELIVERY_ID" --argjson issue "$ISSUE" --arg role "$ROLE" --arg merge "$merge_sha" \
    --arg run "$DEPLOY_RUN_ID" --arg source "$LIVE_TARGET_SOURCE" '
    .delivery_id == $delivery and .issue_number == $issue and .role == $role and .merge_sha == $merge
    and .deploy_run_id == $run and .target_source == $source and .status == "passed"
  ' "$live_proof" >/dev/null || die "live proof identity does not match the release"
  verify_proof_producer "$live_proof" "$merge_sha"
  live_output="$issue_dir/$(jq -r .output_path "$live_proof")"
  validate_proof_output live "$live_output" "$ROLE" "$(jq -r "$(role_key "$ROLE").pr_number" "$current")" \
    "$merge_sha" "$DEPLOY_RUN_ID" "$LIVE_TARGET_SOURCE"
  run_tmp=$(mktemp "$STATE_ROOT/.release-run.XXXXXX") || die "cannot create release run snapshot"
  fresh_run_snapshot "$DEPLOY_RUN_ID" "$merge_sha" "$run_tmp"
  run_updated=$(jq -r .updatedAt "$run_tmp"); rm -f -- "$run_tmp"
  observed=$(jq -r .observed_at "$live_proof"); [[ "$observed" < "$run_updated" ]] \
    && die "live proof predates the successful deploy run"
  stamp_is_fresh "$observed" 600 || die "live proof is stale; refresh it before release"
  live_digest=$(jq -r .output_digest "$live_proof")
  verified=$(now_iso)
  if [ "$TOP_STATE" = "$next" ]; then
    if jq -e --arg run "$DEPLOY_RUN_ID" --arg sha "$merge_sha" --arg source "$LIVE_TARGET_SOURCE" \
      --arg digest "$live_digest" '
        .release.deploy_run_id == $run and .release.sha == $sha
        and .release.live_target_source == $source and .release.live_evidence_digest == $digest
      ' "$current" >/dev/null; then
      printf '%s\n' "$current"; exit 0
    fi
    [ "$ROLE" = normal ] || die "conflicting repeated release proof"
    atomic_update '.release = {deploy_run_id:$run,sha:$sha,live_target_source:$source,live_evidence_digest:$digest,verified_at:$now}
      | .updated_at = $now' \
      --arg run "$DEPLOY_RUN_ID" --arg sha "$merge_sha" --arg source "$LIVE_TARGET_SOURCE" \
      --arg digest "$live_digest" --arg now "$verified"
    printf '%s\n' "$current"; exit 0
  fi
  [ "$TOP_STATE" = "$expected" ] || die "cannot record $ROLE release from $TOP_STATE"
  if [ "$ROLE" = normal ]; then
    atomic_update '.release = {deploy_run_id:$run,sha:$sha,live_target_source:$source,live_evidence_digest:$digest,verified_at:$now}
      | .state = "release_verified" | .updated_at = $now' \
      --arg run "$DEPLOY_RUN_ID" --arg sha "$merge_sha" --arg source "$LIVE_TARGET_SOURCE" \
      --arg digest "$live_digest" --arg now "$verified"
  else
    atomic_update '.release = {deploy_run_id:$run,sha:$sha,live_target_source:$source,live_evidence_digest:$digest,verified_at:$now}
      | .state = "rollback_release_verified" | .updated_at = $now' \
      --arg run "$DEPLOY_RUN_ID" --arg sha "$merge_sha" --arg source "$LIVE_TARGET_SOURCE" \
      --arg digest "$live_digest" --arg now "$verified"
  fi
  printf '%s\n' "$current"; exit 0
fi

issue_snapshot_valid() {
  jq -e --argjson issue "$ISSUE" '
    def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    type == "object" and .number == $issue and (.state == "OPEN" or .state == "CLOSED")
    and (.updatedAt|stamp) and (.title|type == "string") and (.body|type == "string")
    and (.labels|type == "array")
    and all(.labels[]; type == "object" and (.name|type == "string"))
    and (.comments|type == "array")
    and all(.comments[]; type == "object" and (.id|type == "string" and length > 0)
      and (.body|type == "string") and (.createdAt|stamp)
      and (.updatedAt == null or (.updatedAt|stamp)))
    and (.closedAt == null or (.closedAt|stamp))
  ' "$1" >/dev/null 2>&1
}

issue_content_digest() {
  local canonical
  canonical=$(jq -cS '{number,title,body,
      labels:([.labels[].name] | sort),
      comments:[.comments[] | {id,body,createdAt,updatedAt:(.updatedAt // null)}]}' "$1") \
    || die "cannot bind issue content"
  content_digest "$canonical"
}

issue_scope_digest() {
  local canonical
  canonical=$(jq -cS '{number,title,body}' "$1") || die "cannot bind issue scope"
  content_digest "$canonical"
}

verify_close_snapshot() {
  local file=$1 expected_updated expected_digest actual_digest
  issue_snapshot_valid "$file" || { printf 'maintain-delivery: issue snapshot is malformed\n' >&2; return 1; }
  [ "$(jq -r .state "$file")" = OPEN ] \
    || { printf 'maintain-delivery: close requires an open issue\n' >&2; return 1; }
  jq -e 'all(.labels[]; .name != "maintain:claimed")' "$file" >/dev/null \
    || { printf 'maintain-delivery: claim label must remain absent before close\n' >&2; return 1; }
  expected_updated=$(jq -r .close.issue_updated_at "$current")
  [ "$(jq -r .updatedAt "$file")" = "$expected_updated" ] \
    || { printf 'maintain-delivery: issue changed after close intent\n' >&2; return 1; }
  expected_digest=$(jq -r .close.issue_digest "$current")
  actual_digest=$(issue_content_digest "$file")
  [ "$actual_digest" = "$expected_digest" ] \
    || { printf 'maintain-delivery: issue content changed after close intent\n' >&2; return 1; }
}

verify_closed_snapshot() {
  local file=$1 closed prepared expected_digest actual_digest
  issue_snapshot_valid "$file" \
    || { printf 'maintain-delivery: closed issue snapshot is malformed\n' >&2; return 1; }
  [ "$(jq -r .state "$file")" = CLOSED ] \
    || { printf 'maintain-delivery: issue is not closed\n' >&2; return 1; }
  jq -e 'all(.labels[]; .name != "maintain:claimed")' "$file" >/dev/null \
    || { printf 'maintain-delivery: closed issue still has the claim label\n' >&2; return 1; }
  closed=$(jq -r '.closedAt // ""' "$file")
  valid_time "$closed" \
    || { printf 'maintain-delivery: closed issue has no concrete closedAt\n' >&2; return 1; }
  [ "$(jq -r .updatedAt "$file")" = "$closed" ] \
    || { printf 'maintain-delivery: closed issue changed after its close event\n' >&2; return 1; }
  expected_digest=$(jq -r .close.issue_digest "$current")
  actual_digest=$(issue_content_digest "$file")
  [ "$actual_digest" = "$expected_digest" ] \
    || { printf 'maintain-delivery: closed issue content does not match the close intent\n' >&2; return 1; }
  prepared=$(jq -r .close.prepared_at "$current")
  [[ "$closed" < "$prepared" ]] \
    && { printf 'maintain-delivery: observed close predates the close intent\n' >&2; return 1; }
  return 0
}

if [ "$ACTION" = close-intent ]; then
  [ -z "$PR_JSON" ] || usage
  [ "$TOP_STATE" = release_verified ] || [ "$TOP_STATE" = close_intent ] \
    || die "cannot prepare issue close from $TOP_STATE"
  if [ "$TOP_STATE" = release_verified ]; then
    stamp_is_fresh "$(jq -r .release.verified_at "$current")" 1800 \
      || die "release verification is stale; refresh live proof before close intent"
  fi
  ensure_gh_bin
  pr_number=$(jq -r .normal.pr_number "$current"); merge_sha=$(jq -r .normal.merge.sha "$current")
  pr_snapshot=$(mktemp "$STATE_ROOT/.close-pr.XXXXXX") || die "cannot create close PR snapshot"
  issue_before=$(mktemp "$STATE_ROOT/.close-issue.XXXXXX") || { rm -f -- "$pr_snapshot"; die "cannot create issue snapshot"; }
  issue_after=$(mktemp "$STATE_ROOT/.close-issue.XXXXXX") || { rm -f -- "$pr_snapshot" "$issue_before"; die "cannot create issue snapshot"; }
  fresh_pr_snapshot normal "$pr_snapshot"
  [ "$(jq -r .state "$pr_snapshot")" = MERGED ] \
    && [ "$(jq -r '.mergeCommit.oid // ""' "$pr_snapshot")" = "$merge_sha" ] \
    || { rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"; die "normal PR merge does not match the receipt"; }
  if ! (cd "$PRIMARY" && trusted_repo_gh issue view "$ISSUE" \
      --json number,state,updatedAt,closedAt,title,body,labels,comments > "$issue_before"); then
    rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"; die "cannot refresh issue for close intent"
  fi
  issue_snapshot_valid "$issue_before" && [ "$(jq -r .state "$issue_before")" = OPEN ] \
    || { rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"; die "close intent requires a valid open issue"; }
  [ "$(issue_scope_digest "$issue_before")" = "$(jq -r .origin_issue_digest "$current")" ] \
    || { rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"; die "issue scope changed after delivery began"; }
  jq -e 'all(.labels[]; .name != "maintain:claimed")' "$issue_before" >/dev/null \
    || { rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"; die "claim label must be removed before close intent"; }
  trusted_path="$(dirname -- "$GH_BIN"):/usr/bin:/bin"
  if ! (cd "$PRIMARY" && PATH="$trusted_path" bash "$SCRIPT_DIR/issue-closure-audit.sh" \
      --pr "$pr_number" --audit-issue "$ISSUE") >/dev/null; then
    rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"; die "fresh close audit failed"
  fi
  fresh_pr_snapshot normal "$pr_snapshot"
  if ! (cd "$PRIMARY" && trusted_repo_gh issue view "$ISSUE" \
      --json number,state,updatedAt,closedAt,title,body,labels,comments > "$issue_after"); then
    rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"; die "cannot recheck issue after close audit"
  fi
  issue_snapshot_valid "$issue_after" && [ "$(jq -r .state "$issue_after")" = OPEN ] \
    && [ "$(issue_scope_digest "$issue_after")" = "$(jq -r .origin_issue_digest "$current")" ] \
    && [ "$(jq -r .updatedAt "$issue_after")" = "$(jq -r .updatedAt "$issue_before")" ] \
    && [ "$(issue_content_digest "$issue_after")" = "$(issue_content_digest "$issue_before")" ] \
    && [ "$(jq -r .state "$pr_snapshot")" = MERGED ] \
    && [ "$(jq -r '.mergeCommit.oid // ""' "$pr_snapshot")" = "$merge_sha" ] \
    || { rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"; die "PR or issue changed during close audit"; }
  issue_updated=$(jq -r .updatedAt "$issue_after"); issue_digest=$(issue_content_digest "$issue_after")
  rm -f -- "$pr_snapshot" "$issue_before" "$issue_after"
  audited=$(now_iso)
  audit=$(jq -cn --arg at "$audited" --argjson issue "$ISSUE" --argjson pr "$pr_number" \
    --arg merge "$merge_sha" --arg updated "$issue_updated" --arg digest "$issue_digest" \
    '{audited_at:$at,issue_number:$issue,merge_sha:$merge,pr_number:$pr,status:"passed",
      issue_updated_at:$updated,issue_digest:$digest}')
  prepared=$(now_iso)
  if [ "$TOP_STATE" = close_intent ]; then
    if [ "$(jq -r .close.issue_updated_at "$current")" = "$issue_updated" ] \
      && [ "$(jq -r .close.issue_digest "$current")" = "$issue_digest" ]; then
      printf '%s\n' "$current"; exit 0
    fi
    die "conflicting repeated close intent"
  fi
  atomic_update '.close = {status:"ready_to_close",issue_updated_at:$updated,issue_digest:$digest,prepared_at:$now,
      audit:$audit,claim_label_removed:true,closed_at:null}
    | .state = "close_intent" | .updated_at = $now' \
    --arg updated "$issue_updated" --arg digest "$issue_digest" --arg now "$prepared" --argjson audit "$audit"
  printf '%s\n' "$current"; exit 0
fi

if [ "$ACTION" = close-issue ]; then
  [ "$TOP_STATE" = close_intent ] || die "cannot close issue from $TOP_STATE"
  ensure_gh_bin
  snapshot=$(mktemp "$STATE_ROOT/.close-snapshot.XXXXXX") || die "cannot create close snapshot"
  if ! (cd "$PRIMARY" && trusted_repo_gh issue view "$ISSUE" \
      --json number,state,updatedAt,closedAt,title,body,labels,comments > "$snapshot"); then
    rm -f -- "$snapshot"; die "cannot refresh issue before close"
  fi
  if ! verify_close_snapshot "$snapshot"; then
    rm -f -- "$snapshot"; die "fresh issue does not match the close intent"
  fi
  rm -f -- "$snapshot"
  if ! (cd "$PRIMARY" && trusted_repo_gh issue close "$ISSUE" --reason completed); then
    die "issue close failed"
  fi
  snapshot=$(mktemp "$STATE_ROOT/.closed-snapshot.XXXXXX") || die "cannot create closed snapshot"
  if ! (cd "$PRIMARY" && trusted_repo_gh issue view "$ISSUE" \
      --json number,state,updatedAt,closedAt,title,body,labels,comments > "$snapshot"); then
    rm -f -- "$snapshot"; die "cannot refresh issue after close"
  fi
  if ! verify_closed_snapshot "$snapshot"; then
    rm -f -- "$snapshot"; die "post-close issue does not match the close intent"
  fi
  closed=$(jq -r .closedAt "$snapshot"); rm -f -- "$snapshot"; observed=$(now_iso)
  atomic_update '.close.status = "closed" | .close.closed_at = $closed
    | .state = "closed_observed" | .updated_at = $now' \
    --arg closed "$closed" --arg now "$observed"
  printf '%s\n' "$current"; exit 0
fi

if [ "$ACTION" = observe-closed ]; then
  [ "$TOP_STATE" = close_intent ] || [ "$TOP_STATE" = closed_observed ] \
    || die "cannot observe issue close from $TOP_STATE"
  ensure_gh_bin
  snapshot=$(mktemp "$STATE_ROOT/.observe-closed.XXXXXX") || die "cannot create closed issue snapshot"
  if ! (cd "$PRIMARY" && trusted_repo_gh issue view "$ISSUE" \
      --json number,state,updatedAt,closedAt,title,body,labels,comments > "$snapshot"); then
    rm -f -- "$snapshot"; die "cannot refresh closed issue"
  fi
  issue_snapshot_valid "$snapshot" || { rm -f -- "$snapshot"; die "issue snapshot is malformed"; }
  jq -e 'all(.labels[]; .name != "maintain:claimed")' "$snapshot" >/dev/null \
    || die "closed issue still has the claim label"
  verify_closed_snapshot "$snapshot" || { rm -f -- "$snapshot"; die "closed issue does not match the close intent"; }
  closed=$(jq -r .closedAt "$snapshot"); rm -f -- "$snapshot"
  prepared=$(jq -r .close.prepared_at "$current"); [[ "$closed" < "$prepared" ]] \
    && die "observed close predates the close intent"
  if [ "$TOP_STATE" = closed_observed ]; then
    [ "$(jq -r .close.closed_at "$current")" = "$closed" ] || die "conflicting repeated close observation"
    printf '%s\n' "$current"; exit 0
  fi
  observed=$(now_iso)
  atomic_update '.close.status = "closed" | .close.closed_at = $closed
    | .state = "closed_observed" | .updated_at = $now' --arg closed "$closed" --arg now "$observed"
  printf '%s\n' "$current"; exit 0
fi

render_result() {
  case "$(jq -r .state "$current")" in
    closed_observed|finalized_success)
      jq -e '
        def ready_pr:
          . != null and .state == "merged" and .premerge != null and .merge != null
          and (.merge_method == "merge" or .merge_method == "squash")
          and .pr_number == .premerge.pr_number and .head_sha == .premerge.head_sha
          and .base_branch == .premerge.base_branch;
        . as $r
        | ($r.normal|ready_pr) and $r.rollback == null
          and $r.release != null and $r.release.sha == $r.normal.merge.sha
          and $r.close != null and $r.close.status == "closed" and $r.close.closed_at != null
          and (($r.state == "closed_observed" and $r.final == null)
            or ($r.state == "finalized_success" and $r.final.outcome == "success"))
      ' "$current" >/dev/null || die "success receipt facts are incomplete or contradictory"
      jq -r '[
        "fixed:PR#\(.normal.pr_number)",
        "pr_number:\(.normal.pr_number)",
        "pr_head_sha:\(.normal.head_sha)",
        "merge_sha:\(.normal.merge.sha)",
        "default_sha:\(.normal.merge.default_sha)",
        "default_ancestry:passed",
        "checks:passed",
        "checks_evidence_id:\(.normal.premerge.checks.evidence_id)",
        "checks_head_sha:\(.normal.premerge.checks.head_sha)",
        "qa:\(.normal.premerge.qa.status)",
        "qa_evidence_id:\(.normal.premerge.qa.evidence_id)",
        "qa_reason_code:\(.normal.premerge.qa.reason_code)",
        "qa_head_sha:\(.normal.premerge.qa.head_sha)",
        "tribunal:passed",
        "tribunal_evidence_id:\(.normal.premerge.tribunal.evidence_id)",
        "tribunal_head_sha:\(.normal.premerge.tribunal.head_sha)",
        "pr:merged",
        "merge:merged",
        "merge_count:\(.normal.merge.merge_count)",
        "merge_budget:\(.normal.merge.merge_budget)",
        "deployment:passed",
        "deploy_run_id:\(.release.deploy_run_id)",
        "deploy_head_sha:\(.release.sha)",
        "live_qa:passed",
        "live_target_source:\(.release.live_target_source)",
        "live_evidence_digest:\(.release.live_evidence_digest)",
        "live_verified_at:\(.release.verified_at)",
        "ready_to_close:validated",
        "close_issue_number:\(.close.audit.issue_number)",
        "close_pr_number:\(.close.audit.pr_number)",
        "close_merge_sha:\(.close.audit.merge_sha)",
        "close_audited_at:\(.close.audit.audited_at)",
        "close_issue_updated_at:\(.close.issue_updated_at)",
        "close_issue_digest:\(.close.issue_digest)",
        "claim_label:removed",
        "issue:closed",
        "issue_closed_at:\(.close.closed_at)",
        "rollback:not_run",
        "outcome:success"
      ] | .[]' "$current"
      ;;
    rollback_release_verified|finalized_rolled_back)
      jq -e '
        def ready_pr:
          . != null and .state == "merged" and .premerge != null and .merge != null
          and (.merge_method == "merge" or .merge_method == "squash")
          and .pr_number == .premerge.pr_number and .head_sha == .premerge.head_sha
          and .base_branch == .premerge.base_branch;
        . as $r
        | ($r.normal|ready_pr) and ($r.rollback|ready_pr)
          and $r.rollback.target_merge_sha == $r.normal.merge.sha
          and $r.release != null and $r.release.sha == $r.rollback.merge.sha
          and $r.close == null
          and (($r.state == "rollback_release_verified" and $r.final == null)
            or ($r.state == "finalized_rolled_back" and $r.final.outcome == "rolled_back"))
      ' "$current" >/dev/null || die "rollback receipt facts are incomplete or contradictory"
      jq -r '([
        "pr_number:\(.normal.pr_number)",
        "pr_head_sha:\(.normal.head_sha)",
        "merge_sha:\(.normal.merge.sha)",
        "rollback_target_merge_sha:\(.rollback.target_merge_sha)",
        "rollback_pr_number:\(.rollback.pr_number)",
        "rollback_pr_head_sha:\(.rollback.head_sha)",
        "rollback_merge_sha:\(.rollback.merge.sha)",
        "default_sha:\(.rollback.merge.default_sha)",
        "default_ancestry:passed",
        "checks:passed",
        "checks_evidence_id:\(.rollback.premerge.checks.evidence_id)",
        "checks_head_sha:\(.rollback.premerge.checks.head_sha)",
        "qa:\(.rollback.premerge.qa.status)",
        "qa_evidence_id:\(.rollback.premerge.qa.evidence_id)",
        "qa_reason_code:\(.rollback.premerge.qa.reason_code)",
        "qa_head_sha:\(.rollback.premerge.qa.head_sha)",
        "tribunal:passed",
        "tribunal_evidence_id:\(.rollback.premerge.tribunal.evidence_id)",
        "tribunal_head_sha:\(.rollback.premerge.tribunal.head_sha)",
        "pr:merged",
        "merge:merged",
        "rollback_pr:merged",
        "rollback_merge:merged",
        "merge_count:\(.rollback.merge.merge_count)",
        "merge_budget:\(.rollback.merge.merge_budget)",
        "deployment:passed",
        "deploy_run_id:\(.release.deploy_run_id)",
        "deploy_head_sha:\(.release.sha)",
        "live_qa:passed",
        "live_target_source:\(.release.live_target_source)",
        "live_evidence_digest:\(.release.live_evidence_digest)",
        "live_verified_at:\(.release.verified_at)",
        "ready_to_close:not_run",
        "issue:not_closed",
        "rollback:rolled_back",
        "outcome:rolled_back"
      ] + (if .rollback.merge.merge_count > .rollback.merge.merge_budget
        then ["merge_budget_overage:rollback"] else [] end)) | .[]' "$current"
      ;;
    *) die "delivery state cannot render a terminal result" ;;
  esac
}

if [ "$ACTION" = render-result ]; then
  render_result
  exit 0
fi

if [ "$ACTION" = finalize ]; then
  case "$PROFILE" in mechanical|light|standard|deep) : ;; *) usage ;; esac
  case "$TOP_STATE" in
    closed_observed|finalized_success) final_outcome=success; event_outcome=success; event_rollback=not_run; proof_role=normal ;;
    rollback_release_verified|finalized_rolled_back) final_outcome=rolled_back; event_outcome=failure; event_rollback=rolled_back; proof_role=rollback ;;
    *) die "cannot finalize delivery from $TOP_STATE" ;;
  esac
  [ -n "$RESULT_SOURCE" ] && [ -f "$RESULT_SOURCE" ] && [ ! -L "$RESULT_SOURCE" ] \
    || die "result source is missing or unsafe"
  pr_number=$(jq -r .normal.pr_number "$current"); normal_merge=$(jq -r .normal.merge.sha "$current")
  if [ "$final_outcome" = success ]; then
    merge_sha=$normal_merge
  else
    merge_sha=$(jq -r .rollback.merge.sha "$current")
  fi
  canonical=$(mktemp "$STATE_ROOT/.result.XXXXXX") || die "cannot create canonical result"
  if ! render_result > "$canonical" || ! chmod 600 "$canonical"; then
    rm -f -- "$canonical"; die "cannot render canonical result"
  fi
  cmp -s -- "$RESULT_SOURCE" "$canonical" \
    || { rm -f -- "$canonical"; die "result source omits or contradicts canonical receipt facts"; }
  for part in .startup maintain-loop runs "$(jq -r .origin_run_id "$current")"; do
    parent=${target_parent:-$PRIMARY}; ensure_child_dir "$parent" "$part" \
      || { rm -f -- "$canonical"; die "result directory is unsafe"; }
    target_parent="$parent/$part"
  done
  target="$target_parent/issue-$ISSUE.md"
  [ ! -L "$target" ] && { [ ! -e "$target" ] || [ -f "$target" ]; } \
    || { rm -f -- "$canonical"; die "result target is unsafe"; }
  if [ -e "$target" ]; then
    cmp -s -- "$canonical" "$target" \
      || { rm -f -- "$canonical"; die "existing result conflicts with finalization"; }
    rm -f -- "$canonical"
  else
    tmp=$(mktemp "$target.tmp.XXXXXX") || { rm -f -- "$canonical"; die "cannot create result"; }
    cp -- "$canonical" "$tmp" && chmod 600 "$tmp" && mv -- "$tmp" "$target" \
      || { rm -f -- "$tmp" "$canonical"; die "cannot persist result"; }
    rm -f -- "$canonical"
  fi
  events_parent="$PRIMARY/.startup/runs"; ensure_child_dir "$PRIMARY/.startup" runs || die "event directory is unsafe"
  events="$events_parent/agent-events.jsonl"
  qa=$(jq -r ".$proof_role.premerge.qa.status" "$current"); base=$(jq -r .normal.base_sha "$current")
  (cd "$PRIMARY" && bash "$SCRIPT_DIR/agent-events.sh" append --once \
    --events "$events" --run-id "$DELIVERY_ID" --command maintain-loop --phase issue-outcome \
    --surface script --profile "$PROFILE" --writer-id "$DELIVERY_ID" --attempt 1 \
    --event-type completed --base-sha "$base" --result-sha "$merge_sha" \
    --checks passed --qa "$qa" --tribunal passed --pr merged --merge merged \
    --deployment passed --rollback "$event_rollback" --outcome "$event_outcome") >/dev/null \
    || die "cannot append the exactly-once issue outcome"
  finalized=$(now_iso); relative=${target#"$PRIMARY/"}
  if [ "$TOP_STATE" = closed_observed ] || [ "$TOP_STATE" = rollback_release_verified ]; then
    terminal_state=finalized_success; [ "$final_outcome" = success ] || terminal_state=finalized_rolled_back
    atomic_update '.final = {outcome:$outcome,result_path:$path,event_identity:.delivery_id,finalized_at:$now}
      | .state = $state | .updated_at = $now' --arg outcome "$final_outcome" --arg state "$terminal_state" \
      --arg path "$relative" --arg now "$finalized"
  fi
  printf '%s\n' "$current"; exit 0
fi

die "unhandled action" 2
