#!/usr/bin/env bash
# Snapshot trusted commit hooks before a worker, then check and commit in isolation.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_NO_REPLACE_OBJECTS=1
export GIT_LITERAL_PATHSPECS=1
unset GIT_CONFIG_PARAMETERS
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.hooksPath
export GIT_CONFIG_VALUE_1=/dev/null
unset GIT_EXTERNAL_DIFF

ACTION=commit
CHECK_ONLY=0
MESSAGE=""
CHECK="./check.sh"
ROOT=""
TRUST_RECEIPT=""
AUTH_TOKEN=""
AUTH_STDIN=0
REQUIRE_APPROVED_DIFF=0
FIREWALL_SCRIPT=""
CHECK_LOG_RETENTION_FILES=50
CHECK_TIMEOUT_SECONDS=${SAAS_SUPERVISOR_CHECK_TIMEOUT_SECONDS:-1800}
CHECK_LOG_MAX_BYTES=${SAAS_SUPERVISOR_CHECK_LOG_MAX_BYTES:-8388608}
CHECK_LOG_RETENTION_BYTES=${SAAS_SUPERVISOR_CHECK_LOG_RETENTION_BYTES:-67108864}
ALLOW=()

usage() {
  echo "usage: supervisor-commit.sh --snapshot-trust FILE --auth-stdin --allow PATH... [--require-approved-diff --firewall-script FILE] [--repo-root DIR]" >&2
  echo "       supervisor-commit.sh --snapshot-trust FILE --check-only --auth-stdin [--check PATH] [--repo-root DIR]" >&2
  echo "       supervisor-commit.sh --rebind-check-environment FILE --auth-stdin [--repo-root DIR]" >&2
  echo "       supervisor-commit.sh --message TEXT --trust-receipt FILE --auth-stdin [--check PATH] [--repo-root DIR]" >&2
  echo "       supervisor-commit.sh --check-only --trust-receipt FILE --auth-stdin [--check PATH] [--repo-root DIR]" >&2
  exit 2
}
need_value() { [ "$#" -ge 2 ] || usage; }
valid_git_oid() { [[ "$1" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot-trust) need_value "$@"; ACTION=snapshot; TRUST_RECEIPT=$2; shift 2 ;;
    --rebind-check-environment) need_value "$@"; ACTION=rebind-env; TRUST_RECEIPT=$2; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --trust-receipt) need_value "$@"; TRUST_RECEIPT=$2; shift 2 ;;
    --auth-stdin) AUTH_STDIN=1; shift ;;
    --allow) need_value "$@"; ALLOW+=("${2%/}"); shift 2 ;;
    --require-approved-diff) REQUIRE_APPROVED_DIFF=1; shift ;;
    --firewall-script) need_value "$@"; FIREWALL_SCRIPT=$2; shift 2 ;;
    --message) need_value "$@"; MESSAGE=$2; shift 2 ;;
    --check) need_value "$@"; CHECK=$2; shift 2 ;;
    --repo-root) need_value "$@"; ROOT=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "supervisor-commit: unknown argument: $1" >&2; usage ;;
  esac
done

[[ "$CHECK_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{0,3}$ ]] \
  && [ "$CHECK_TIMEOUT_SECONDS" -le 7200 ] || {
  echo "supervisor-commit: invalid check timeout (maximum 7200 seconds)" >&2; exit 2; }
[[ "$CHECK_LOG_MAX_BYTES" =~ ^[1-9][0-9]{0,8}$ ]] \
  && [ "$CHECK_LOG_MAX_BYTES" -ge 512 ] \
  && [ "$CHECK_LOG_MAX_BYTES" -le 8388608 ] || {
  echo "supervisor-commit: invalid check-log byte budget" >&2; exit 2; }
[[ "$CHECK_LOG_RETENTION_BYTES" =~ ^[1-9][0-9]{0,8}$ ]] \
  && [ "$CHECK_LOG_RETENTION_BYTES" -le 67108864 ] \
  && [ "$CHECK_LOG_RETENTION_BYTES" -ge "$CHECK_LOG_MAX_BYTES" ] || {
  echo "supervisor-commit: invalid retained check-log byte budget" >&2; exit 2; }

[ "$AUTH_STDIN" -eq 1 ] || usage
IFS= read -r AUTH_TOKEN || { echo "supervisor-commit: authentication token missing on stdin" >&2; exit 2; }

[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "supervisor-commit: not in a git repository" >&2; exit 2; }
ROOT=$(cd "$ROOT" && pwd)
cd "$ROOT"
REAL_GIT=$(command -v git)
COMMON_DIR=$($REAL_GIT rev-parse --git-common-dir)
case "$COMMON_DIR" in /*) : ;; *) COMMON_DIR="$ROOT/$COMMON_DIR" ;; esac
COMMON_DIR=$(cd "$COMMON_DIR" && pwd -P)
GIT_DIR=$($REAL_GIT rev-parse --absolute-git-dir)
GIT_DIR=$(cd "$GIT_DIR" && pwd -P)
TRUST_DIR="$GIT_DIR/saas-startup-team"

trusted_git() {
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
    "$REAL_GIT" "$@"
}

checked_inventory() {
  local target="$1"; shift
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  "$@" > "$target"
}

valid_auth_token() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

canonical_receipt() {
  jq -cS 'del(.auth_tag)' "$1"
}

auth_tag() {
  local file="$1"
  canonical_receipt "$file" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$AUTH_TOKEN" \
    | awk '{print $NF}'
}

sign_receipt() {
  local file="$1" tag tmp
  tag=$(auth_tag "$file")
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  jq --arg tag "$tag" '.auth_tag=$tag' "$file" > "$tmp"
  chmod 400 "$tmp"
  mv -f -- "$tmp" "$file"
}

verify_receipt_auth() {
  local file="$1" expected actual
  expected=$(jq -r '.auth_tag // empty' "$file")
  [ -n "$expected" ] || return 1
  actual=$(auth_tag "$file")
  [ "$actual" = "$expected" ]
}

head_ref() {
  $REAL_GIT symbolic-ref -q HEAD 2>/dev/null || true
}

strict_refs_fingerprint() {
  local result
  result=$($REAL_GIT for-each-ref --format='%(refname)%00%(objectname)%00%(symref)' \
    | $REAL_GIT hash-object --stdin) || return 1
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

receipt_refs_intact() {
  local current expected
  [ "$RECEIPT_CHECK_ONLY" != true ] || return 0
  current=$(strict_refs_fingerprint) || return 1
  expected=$(jq -er .refs_fingerprint "$TRUST_RECEIPT") || return 1
  valid_git_oid "$expected" || return 1
  [ "$current" = "$expected" ]
}

primary_boundary_fingerprint() {
  local result
  result=$({
    $REAL_GIT rev-parse HEAD
    [ "$CHECK_ONLY" -eq 1 ] \
      || $REAL_GIT for-each-ref --format='%(refname)%00%(objectname)%00%(symref)'
    $REAL_GIT config --local --list
  } | $REAL_GIT hash-object --stdin) || return 1
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

hooks_fingerprint() {
  local dir="$1" tmp path rel mode oid result failed=0 old_shopt
  tmp=$(mktemp) || return 1
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    old_shopt=$(shopt -p dotglob nullglob globstar || true)
    shopt -s dotglob nullglob globstar
    for path in "$dir"/**; do
      rel=${path#"$dir"/}
      if [ -d "$path" ] && [ ! -L "$path" ]; then continue
      elif [ -f "$path" ] && [ ! -L "$path" ]; then
        if [ -x "$path" ]; then mode=100755; else mode=100644; fi
        if ! oid=$($REAL_GIT hash-object --no-filters -- "$path" 2>/dev/null) \
          || ! valid_git_oid "$oid"; then
          failed=1; break
        fi
      else
        failed=1; break
      fi
      printf '%s\0%s\0%s\0' "$rel" "$mode" "$oid" >> "$tmp" || {
        failed=1; break; }
    done
    eval "$old_shopt"
    [ "$failed" -eq 0 ] || { rm -f "$tmp"; return 1; }
  elif [ -e "$dir" ] || [ -L "$dir" ]; then
    rm -f "$tmp"; return 1
  fi
  result=$($REAL_GIT hash-object --no-filters "$tmp") \
    && valid_git_oid "$result" || { rm -f -- "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$result" || return 1
}

config_fingerprint() {
  local result
  result=$(trusted_git config --null --list --show-origin --show-scope \
    | $REAL_GIT hash-object --stdin) || return 1
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

metadata_fingerprint() {
  local tmp entry kind key path mode oid result
  tmp=$(mktemp) || return 1
  for entry in attributes:info/attributes exclude:info/exclude \
    commondir:commondir gitdir:gitdir head:HEAD config-worktree:config.worktree; do
    kind=${entry%%:*}; key=${entry#*:}
    path=$($REAL_GIT rev-parse --git-path "$key") || { rm -f -- "$tmp"; return 1; }
    case "$path" in /*) : ;; *) path="$ROOT/$path" ;; esac
    if [ -L "$path" ]; then rm -f "$tmp"; return 1
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      oid=$($REAL_GIT hash-object --no-filters -- "$path") \
        && valid_git_oid "$oid" || { rm -f -- "$tmp"; return 1; }
    elif [ -e "$path" ]; then rm -f "$tmp"; return 1
    else mode=missing; oid=missing
    fi
    printf '%s\0%s\0%s\0' "$kind" "$mode" "$oid" >> "$tmp" \
      || { rm -f -- "$tmp"; return 1; }
  done
  result=$($REAL_GIT hash-object --no-filters "$tmp") \
    && valid_git_oid "$result" || { rm -f -- "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$result" || return 1
}

resolve_hook_source() {
  local configured source parent base config_rc=0
  configured=$(trusted_git config --path core.hooksPath 2>/dev/null) || config_rc=$?
  case "$config_rc" in
    0)
      [ -n "$configured" ] || return 1
      case "$configured" in /*) source=$configured ;; *) source="$ROOT/$configured" ;; esac
      ;;
    1)
      source=$(trusted_git rev-parse --git-path hooks) || return 1
      case "$source" in /*) : ;; *) source="$ROOT/$source" ;; esac
      ;;
    *) return 1 ;;
  esac
  parent=$(dirname -- "$source"); base=$(basename -- "$source")
  [ -d "$parent" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
  parent=$(cd "$parent" && pwd -P); source="$parent/$base"
  [ ! -L "$source" ] || return 1
  if [ -e "$source" ] && [ ! -d "$source" ]; then return 1; fi
  if [ -d "$source" ] && find "$source" -type l -print -quit | grep -q .; then return 1; fi
  printf '%s\n' "$source" || return 1
}

receipt_path() {
  local supplied="$1" resolved parent base
  case "$supplied" in /*) resolved=$supplied ;; *) resolved="$ROOT/$supplied" ;; esac
  case "$resolved" in *$'\n'*|*$'\r'*|*$'\t'*|*/../*|*/./*)
    echo "supervisor-commit: invalid trust receipt path" >&2; return 1 ;;
  esac
  parent=$(dirname -- "$resolved"); base=$(basename -- "$resolved")
  [ "$parent" = "$TRUST_DIR" ] && [ "$base" != . ] && [ "$base" != .. ] || {
    echo "supervisor-commit: trust receipt must use the dedicated Git trust directory" >&2; return 1; }
  if [ ! -e "$TRUST_DIR" ] && [ ! -L "$TRUST_DIR" ]; then mkdir -m 700 -- "$TRUST_DIR"; fi
  [ -d "$TRUST_DIR" ] && [ ! -L "$TRUST_DIR" ] || {
    echo "supervisor-commit: Git trust directory is unsafe" >&2; return 1; }
  [ "$(cd "$TRUST_DIR" && pwd -P)" = "$TRUST_DIR" ] || {
    echo "supervisor-commit: Git trust directory changed identity" >&2; return 1; }
  printf '%s\n' "$TRUST_DIR/$base"
}

valid_repo_path() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  case "/$1/" in */../*|*/./*|*//*) return 1 ;; esac
  case "$1" in /*|.|'') return 1 ;; esac
  return 0
}

runtime_tree_digest() {
  python3 "$SCRIPT_DIR/runtime-tree-digest.py" "$1" "$2"
}

manifest_json_for_tree() {
  local repo="$1" tree="$2" target="$3" parent path manifest_dir scope_dir in_scope
  local oid inventory item result count failed=0
  local -a manifests=()
  local -a ancestor_dirs=()
  parent=${target%/*}
  [ "$parent" != "$target" ] || parent=.
  scope_dir=$parent
  while [ "$scope_dir" != . ]; do
    case "$scope_dir" in */*) scope_dir=${scope_dir%/*} ;; *) scope_dir=. ;; esac
    ancestor_dirs+=("$scope_dir")
  done
  inventory=$(mktemp) || return 1
  checked_inventory "$inventory" "$REAL_GIT" -C "$repo" \
    ls-tree -r --name-only -z "$tree" || { rm -f -- "$inventory"; return 1; }
  while IFS= read -r -d '' path; do
    if [ "$parent" != . ]; then
      case "$path" in
        "$parent"/*) : ;;
        *)
          manifest_dir=${path%/*}
          [ "$manifest_dir" != "$path" ] || manifest_dir=.
          in_scope=false
          for scope_dir in "${ancestor_dirs[@]}"; do
            if [ "$manifest_dir" = "$scope_dir" ]; then in_scope=true; break; fi
          done
          $in_scope || continue
          ;;
      esac
    fi
    case "${target##*/}" in
      node_modules)
        case "$path" in
          package.json|*/package.json|package-lock.json|*/package-lock.json|\
          npm-shrinkwrap.json|*/npm-shrinkwrap.json|pnpm-lock.yaml|*/pnpm-lock.yaml|\
          pnpm-workspace.yaml|*/pnpm-workspace.yaml|.npmrc|*/.npmrc|\
          yarn.lock|*/yarn.lock|bun.lock|*/bun.lock|bun.lockb|*/bun.lockb) : ;;
          *) continue ;;
        esac
        ;;
      venv|.venv)
        case "$path" in
          pyproject.toml|*/pyproject.toml|uv.lock|*/uv.lock|poetry.lock|*/poetry.lock|\
          Pipfile|*/Pipfile|Pipfile.lock|*/Pipfile.lock|setup.py|*/setup.py|\
          setup.cfg|*/setup.cfg|requirements*.txt|*/requirements*.txt|\
          requirements/*.txt|*/requirements/*.txt) : ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    oid=$($REAL_GIT -C "$repo" rev-parse "$tree:$path") || { failed=1; break; }
    valid_git_oid "$oid" || { failed=1; break; }
    item=$(jq -cen --arg path "$path" --arg oid "$oid" \
      '{path:$path,oid:$oid}') || { failed=1; break; }
    manifests+=("$item") || { failed=1; break; }
  done < "$inventory"
  rm -f -- "$inventory"
  [ "$failed" -eq 0 ] || return 1
  if [ "${#manifests[@]}" -eq 0 ]; then printf '[]\n' || return 1; return; fi
  result=$(printf '%s\n' "${manifests[@]}" | jq -ces 'sort_by(.path)') || return 1
  count=$(jq -er 'length' <<<"$result") || return 1
  [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -eq "${#manifests[@]}" ] || return 1
  printf '%s\n' "$result" || return 1
}

discover_primary_checkout() {
  # Single-worktree contract: this ROOT is the primary checkout. Runtime deps
  # (node_modules/venv) are discovered here or not at all. Prove identity
  # without assuming the common dir lives at $ROOT/.git (separate-git-dir ok);
  # reject linked worktrees (GIT_DIR != COMMON_DIR, or any sibling in the list).
  local top abs_git
  top=$($REAL_GIT -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd -- "$top" && pwd -P) || return 1
  [ "$top" = "$ROOT" ] || return 1
  abs_git=$($REAL_GIT -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  abs_git=$(cd -- "$abs_git" && pwd -P) || return 1
  [ "$abs_git" = "$GIT_DIR" ] || return 1
  [ "$GIT_DIR" = "$COMMON_DIR" ] || return 1
  # Fail closed if any linked worktree exists (sibling or this root is linked).
  bash "$SCRIPT_DIR/maintain-leases.sh" assert-primary-only --repo-root "$ROOT" >/dev/null 2>&1 \
    || return 1
  PRIMARY_CHECKOUT=$ROOT
}

safe_runtime_source() {
  local root="$1" relative="$2" current part
  current=$root
  while [[ "$relative" == */* ]]; do
    part=${relative%%/*}; relative=${relative#*/}; current="$current/$part"
    [ -d "$current" ] && [ ! -L "$current" ] || return 1
  done
  current="$current/$relative"
  [ -d "$current" ] && [ ! -L "$current" ] || return 1
  RUNTIME_SOURCE=$(cd "$current" && pwd -P) || return 1
  [ "$RUNTIME_SOURCE" = "$current" ]
}

runtime_target_is_ignored() {
  env -u GIT_LITERAL_PATHSPECS "$REAL_GIT" -C "$ROOT" \
    -c core.fsmonitor=false check-ignore --no-index -q -- "$1/"
}

discover_check_runtimes() {
  local path rel source marker identity digest manifests manifest_count inventory tracked item result count
  local -a runtimes=()
  declare -A seen=()
  # Identity failure must fail closed — never translate to an empty runtime list
  # (empty list is only valid when primary is proven and has no sealable deps).
  discover_primary_checkout || return 1
  inventory=$(mktemp) || return 1
  checked_inventory "$inventory" "$REAL_GIT" -C "$PRIMARY_CHECKOUT" \
    ls-files --others --ignored --exclude-standard --directory -z || {
    rm -f -- "$inventory"; return 1; }
  while IFS= read -r -d '' path; do
    rel=${path%/}
    valid_repo_path "$rel" || continue
    [ "${seen[$rel]+present}" = present ] && continue
    case "${rel##*/}" in
      node_modules) marker=.bin ;;
      venv|.venv) marker=bin/python ;;
      *) continue ;;
    esac
    source="$PRIMARY_CHECKOUT/$rel"
    safe_runtime_source "$PRIMARY_CHECKOUT" "$rel" || continue
    [ "$RUNTIME_SOURCE" = "$source" ] || continue
    if [ "$marker" = .bin ]; then
      [ -d "$source/.bin" ] && [ ! -L "$source/.bin" ] || continue
    else
      [ -d "$source/bin" ] && [ ! -L "$source/bin" ] \
        && [ -e "$source/bin/python" ] && [ -x "$source/bin/python" ] || continue
    fi
    runtime_target_is_ignored "$rel" || continue
    tracked=$($REAL_GIT -C "$ROOT" ls-files -- "$rel") || {
      rm -f -- "$inventory"; return 1; }
    [ -z "$tracked" ] || continue
    manifests=$(manifest_json_for_tree "$ROOT" HEAD "$rel") || {
      rm -f -- "$inventory"; return 1; }
    manifest_count=$(jq -er 'length' <<<"$manifests") || {
      rm -f -- "$inventory"; return 1; }
    [[ "$manifest_count" =~ ^[0-9]+$ ]] || { rm -f -- "$inventory"; return 1; }
    [ "$manifest_count" -gt 0 ] || continue
    identity=$(stat -Lc '%d:%i' -- "$source") || { rm -f -- "$inventory"; return 1; }
    digest=$(runtime_tree_digest "$source" "$rel") || { rm -f -- "$inventory"; return 1; }
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { rm -f -- "$inventory"; return 1; }
    item=$(jq -cen --arg source "$source" --arg target "$rel" \
      --arg identity "$identity" --arg digest "$digest" --argjson manifests "$manifests" \
      '{source:$source,target:$target,identity:$identity,digest:$digest,manifests:$manifests}') \
      || { rm -f -- "$inventory"; return 1; }
    runtimes+=("$item") || { rm -f -- "$inventory"; return 1; }
    seen["$rel"]=1
  done < "$inventory"
  rm -f -- "$inventory"
  if [ "${#runtimes[@]}" -eq 0 ]; then printf '[]\n' || return 1; return; fi
  result=$(printf '%s\n' "${runtimes[@]}" | jq -ces 'sort_by(.target)') || return 1
  count=$(jq -er 'length' <<<"$result") || return 1
  [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -eq "${#runtimes[@]}" ] || return 1
  printf '%s\n' "$result" || return 1
}

check_driver_path() {
  local path product_root=
  path=${SAAS_SUPERVISOR_CHECK_DRIVER:-$SCRIPT_DIR/supervisor-check-container.sh}
  path=$(readlink -f -- "$path") || return 1
  [ -f "$path" ] && [ -x "$path" ] && [ ! -L "$path" ] || return 1
  case "$path" in "$ROOT"|"$ROOT"/*) return 1 ;; esac
  if [ "$(basename -- "$COMMON_DIR")" = .git ]; then
    product_root=$(dirname -- "$COMMON_DIR") || return 1
    case "$path" in "$product_root"|"$product_root"/*) return 1 ;; esac
  fi
  printf '%s\n' "$path"
}

# Fail closed before the expensive writer/commit path when the sealed image
# lacks tools the product check needs (e.g. pdftotext). Empty list = no probe.
probe_required_check_tools() {
  local path tools image_id list
  tools=${SAAS_SUPERVISOR_CHECK_REQUIRED_TOOLS:-}
  [ -n "$tools" ] || return 0
  path=$(check_driver_path) || return 1
  list=${tools// /,}
  image_id=${1:-}
  if [ -n "$image_id" ]; then
    timeout -k 5 60 "$path" --probe-tools "$list" --image-id "$image_id" >/dev/null || {
      echo "supervisor-commit: sealed-check image fails required tool parity" >&2
      return 1
    }
  else
    timeout -k 5 60 "$path" --probe-tools "$list" >/dev/null || {
      echo "supervisor-commit: sealed-check image fails required tool parity" >&2
      return 1
    }
  fi
  return 0
}

check_driver_metadata() {
  local path identity mode digest backend image_id
  path=$(check_driver_path) || return 1
  identity=$(stat -Lc '%d:%i' -- "$path") || return 1
  mode=$(stat -Lc '%a' -- "$path") || return 1
  digest=$(sha256sum -- "$path" | awk '{print $1}') || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  backend=$(timeout -k 5 30 "$path" --metadata) || return 1
  jq -e 'type == "object" and
    (.docker|type == "object") and
    (.docker.path|type == "string" and length > 0) and
    (.docker.identity|type == "string" and test("^[0-9]+:[0-9]+$")) and
    (.docker.mode|type == "string" and test("^[0-7]+$")) and
    (.docker.sha256|type == "string" and test("^[0-9a-f]{64}$")) and
    (.daemon_id|type == "string" and length > 0) and
    (.image_id|type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.container_id|type == "string" and length > 0)' <<<"$backend" >/dev/null || return 1
  image_id=$(jq -er .image_id <<<"$backend") || return 1
  # Cheap fail-fast: missing tools never start a writer/containment cycle.
  probe_required_check_tools "$image_id" || return 1
  jq -cn --arg path "$path" --arg identity "$identity" --arg mode "$mode" \
    --arg digest "$digest" --argjson backend "$backend" \
    '{path:$path,identity:$identity,mode:$mode,sha256:$digest,backend:$backend}'
}

is_local_only() {
  case "$1" in
    .startup/state.json|.startup/leases|.startup/leases/*|.startup/runs|.startup/runs/*|\
    .startup/evaluation|.startup/evaluation/*|.startup/maintain|.startup/maintain/*|\
    .startup/maintain-loop|.startup/maintain-loop/*|.startup/operate|.startup/operate/*|\
    .startup/demand|.startup/demand/*|.startup/lessons-deliver|.startup/lessons-deliver/*|\
    .startup/memory-gc|.startup/memory-gc/*|.startup/*.probe-findings|\
    .supervisor-check.*) return 0 ;;
  esac
  return 1
}

workspace_is_clean_base() {
  local path inventory clean=1
  trusted_git diff --quiet -- . && trusted_git diff --cached --quiet -- . || return 1
  inventory=$(mktemp) || return 1
  checked_inventory "$inventory" trusted_git \
    ls-files --others --exclude-standard -z -- . || {
    rm -f -- "$inventory"
    echo "supervisor-commit: could not inventory untracked base paths" >&2
    return 1
  }
  while IFS= read -r -d '' path; do
    is_local_only "$path" || { clean=0; break; }
  done < "$inventory"
  rm -f -- "$inventory"
  [ "$clean" -eq 1 ]
}

snapshot_trust() {
  local receipt hooks_copy firewall_copy source base hash source_hash firewall_hash=null config_hash metadata_hash
  local source_rel=null old_umask="" ref refs_hash allow_json path receipt_tmp="" firewall_parent firewall_source
  local check_driver_json runtimes_json purpose=commit snapshot_complete=0
  [ -n "$TRUST_RECEIPT" ] && [ -z "$MESSAGE" ] || usage
  valid_auth_token "$AUTH_TOKEN" || { echo "supervisor-commit: invalid authentication token" >&2; exit 2; }
  if [ "$CHECK_ONLY" -eq 1 ]; then
    purpose=check-only
    [ "${#ALLOW[@]}" -eq 0 ] && [ "$REQUIRE_APPROVED_DIFF" -eq 0 ] \
      && [ -z "$FIREWALL_SCRIPT" ] || usage
    workspace_is_clean_base || {
      echo "supervisor-commit: check-only requires a clean base worktree" >&2; exit 1; }
  fi
  if [ "$REQUIRE_APPROVED_DIFF" -eq 1 ]; then
    [ -n "$FIREWALL_SCRIPT" ] || { echo "supervisor-commit: required diff approval needs --firewall-script" >&2; exit 2; }
  elif [ -n "$FIREWALL_SCRIPT" ]; then
    echo "supervisor-commit: --firewall-script requires --require-approved-diff" >&2; exit 2
  fi
  [ "$CHECK_ONLY" -eq 1 ] || [ "${#ALLOW[@]}" -gt 0 ] || {
    echo "supervisor-commit: at least one exact --allow path is required" >&2; exit 2; }
  for path in "${ALLOW[@]}"; do
    valid_repo_path "$path" || { printf 'supervisor-commit: invalid allowed path: %q\n' "$path" >&2; exit 2; }
    is_local_only "$path" && { printf 'supervisor-commit: local runtime state cannot be allowed: %q\n' "$path" >&2; exit 2; }
  done
  check_driver_json=$(check_driver_metadata) || {
    echo "supervisor-commit: trusted private-container check runtime is unavailable" >&2; exit 1; }
  runtimes_json=$(discover_check_runtimes) || {
    echo "supervisor-commit: could not seal primary-checkout check runtimes" >&2; exit 1; }
  receipt=$(receipt_path "$TRUST_RECEIPT") || exit 2
  hooks_copy="${receipt}.hooks"
  firewall_copy="${receipt}.firewall"
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] \
    && [ ! -e "$hooks_copy" ] && [ ! -L "$hooks_copy" ] \
    && [ ! -e "$firewall_copy" ] && [ ! -L "$firewall_copy" ] || {
    echo "supervisor-commit: trust receipt already exists" >&2; exit 1; }
  cleanup_trust_snapshot() {
    [ "$snapshot_complete" -eq 0 ] || return 0
    [ -z "$receipt_tmp" ] || rm -f -- "$receipt_tmp"
    rm -f -- "$receipt"
    rm -rf -- "$hooks_copy" "$firewall_copy"
    [ -z "$old_umask" ] || umask "$old_umask"
  }
  trap cleanup_trust_snapshot EXIT
  source=$(resolve_hook_source) || {
    echo "supervisor-commit: configured hook source is unsafe" >&2; exit 1; }
  mkdir -p "$(dirname -- "$receipt")" "$hooks_copy"
  [ ! -d "$source" ] || cp -pPR "$source/." "$hooks_copy/"
  chmod -R go-w "$hooks_copy"
  hash=$(hooks_fingerprint "$hooks_copy") || {
    echo "supervisor-commit: could not fingerprint trusted hooks" >&2; exit 1; }
  source_hash=$(hooks_fingerprint "$source") || {
    echo "supervisor-commit: could not fingerprint hook source" >&2; exit 1; }
  if [ "$REQUIRE_APPROVED_DIFF" -eq 1 ]; then
    case "$FIREWALL_SCRIPT" in /*) firewall_source=$FIREWALL_SCRIPT ;; *) firewall_source="$ROOT/$FIREWALL_SCRIPT" ;; esac
    firewall_parent=$(dirname -- "$firewall_source")
    [ -d "$firewall_parent" ] && [ ! -L "$firewall_parent" ] || {
      echo "supervisor-commit: firewall parent is unsafe" >&2; exit 1; }
    firewall_parent=$(cd "$firewall_parent" && pwd -P)
    firewall_source="$firewall_parent/$(basename -- "$firewall_source")"
    [ -f "$firewall_source" ] && [ ! -L "$firewall_source" ] || {
      echo "supervisor-commit: firewall must be a regular file" >&2; exit 1; }
    mkdir -m 700 -- "$firewall_copy"
    cp -p -- "$firewall_source" "$firewall_copy/run.sh"
    if [ -e "$firewall_parent/pii-gate.sh" ] || [ -L "$firewall_parent/pii-gate.sh" ]; then
      [ -f "$firewall_parent/pii-gate.sh" ] && [ ! -L "$firewall_parent/pii-gate.sh" ] || {
        echo "supervisor-commit: firewall PII gate is unsafe" >&2; exit 1; }
      cp -p -- "$firewall_parent/pii-gate.sh" "$firewall_copy/pii-gate.sh"
    fi
    chmod -R go-w "$firewall_copy"
    firewall_hash=$(hooks_fingerprint "$firewall_copy") || {
      echo "supervisor-commit: could not fingerprint frozen firewall" >&2; exit 1; }
    firewall_hash=$(jq -Rn --arg value "$firewall_hash" '$value')
  fi
  config_hash=$(config_fingerprint)
  metadata_hash=$(metadata_fingerprint) || {
    echo "supervisor-commit: unsafe Git metadata path" >&2; exit 1; }
  case "$source" in "$ROOT"/*) source_rel=$(jq -Rn --arg p "${source#"$ROOT"/}" '$p') ;; esac
  base=$($REAL_GIT rev-parse HEAD)
  ref=$(head_ref)
  refs_hash=$(strict_refs_fingerprint)
  if [ "${#ALLOW[@]}" -eq 0 ]; then allow_json='[]'
  else allow_json=$(printf '%s\n' "${ALLOW[@]}" | LC_ALL=C sort -u | jq -R . | jq -s .)
  fi
  old_umask=$(umask); umask 077
  receipt_tmp=$(mktemp "${receipt}.unsigned.XXXXXX")
  jq -n --arg base "$base" --arg hash "$hash" --arg config_hash "$config_hash" \
    --arg metadata_hash "$metadata_hash" --argjson source_rel "$source_rel" \
    --arg head_ref "$ref" --arg refs "$refs_hash" \
    --argjson allow "$allow_json" \
    --argjson require_approved "$REQUIRE_APPROVED_DIFF" --argjson firewall_hash "$firewall_hash" \
    --arg source_hash "$source_hash" --argjson check_driver "$check_driver_json" \
    --argjson check_runtimes "$runtimes_json" \
    --arg purpose "$purpose" \
    '({schema_version:(if $purpose == "check-only" then 5 else 4 end),base_head:$base,head_ref:$head_ref,refs_fingerprint:$refs,
      hooks_fingerprint:$hash,hook_source_fingerprint:$source_hash,
      config_fingerprint:$config_hash,metadata_fingerprint:$metadata_hash,
      hook_source_rel:$source_rel,allow:$allow,
      require_approved_diff:($require_approved == 1),firewall_fingerprint:$firewall_hash,
      check_driver:$check_driver,check_runtimes:$check_runtimes,
      auth_tag:null} + if $purpose == "check-only" then {purpose:$purpose} else {} end)' > "$receipt_tmp"
  mv -- "$receipt_tmp" "$receipt"
  receipt_tmp=""
  sign_receipt "$receipt"
  umask "$old_umask"
  old_umask=""
  snapshot_complete=1
  trap - EXIT
  printf '%s\n' "$receipt"
}

# Environment-only rebind: refresh sealed check_driver backend on an existing
# receipt when candidate identity (base, refs, hooks, allow, runtime digests)
# is unchanged. Does not rehash the candidate boundary or require a new writer.
rebind_check_environment() {
  local receipt hooks_copy check_driver_json tmp
  local runtimes_json current_runtimes
  [ -n "$TRUST_RECEIPT" ] && [ -z "$MESSAGE" ] && [ "$CHECK_ONLY" -eq 0 ] \
    && [ "${#ALLOW[@]}" -eq 0 ] && [ "$REQUIRE_APPROVED_DIFF" -eq 0 ] \
    && [ -z "$FIREWALL_SCRIPT" ] || usage
  valid_auth_token "$AUTH_TOKEN" || {
    echo "supervisor-commit: invalid authentication token" >&2; exit 2; }
  receipt=$(receipt_path "$TRUST_RECEIPT") || exit 2
  hooks_copy="${receipt}.hooks"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ -d "$hooks_copy" ] && [ ! -L "$hooks_copy" ] || {
    echo "supervisor-commit: trusted hook receipt is missing" >&2; exit 1; }
  jq -e '((.schema_version == 4 and (has("purpose")|not) and (.allow|length > 0)) or
    (.schema_version == 5 and .purpose == "check-only" and (.allow|length == 0))) and
    (.auth_tag|type == "string")' "$receipt" >/dev/null || {
    echo "supervisor-commit: malformed trust receipt" >&2; exit 1; }
  verify_receipt_auth "$receipt" || {
    echo "supervisor-commit: trust receipt authentication failed" >&2; exit 1; }
  [ "$($REAL_GIT rev-parse HEAD)" = "$(jq -r .base_head "$receipt")" ] || {
    echo "supervisor-commit: trust receipt base no longer matches HEAD" >&2; exit 1; }
  [ "$(head_ref)" = "$(jq -r .head_ref "$receipt")" ] || {
    echo "supervisor-commit: active branch changed after trust snapshot" >&2; exit 1; }
  TRUST_RECEIPT=$receipt
  RECEIPT_CHECK_ONLY=$(jq -r '(.schema_version == 5 and .purpose == "check-only")' "$receipt")
  receipt_refs_intact || {
    echo "supervisor-commit: Git refs changed after trust snapshot" >&2; exit 1; }
  [ "$(hooks_fingerprint "$hooks_copy")" = "$(jq -r .hooks_fingerprint "$receipt")" ] || {
    echo "supervisor-commit: trusted hook receipt changed" >&2; exit 1; }
  [ "$(hooks_fingerprint "$(resolve_hook_source)")" = "$(jq -r .hook_source_fingerprint "$receipt")" ] || {
    echo "supervisor-commit: configured hook source changed after trust snapshot" >&2; exit 1; }
  [ "$(config_fingerprint)" = "$(jq -r .config_fingerprint "$receipt")" ] || {
    echo "supervisor-commit: Git configuration changed after trust snapshot" >&2; exit 1; }
  [ "$(metadata_fingerprint)" = "$(jq -r .metadata_fingerprint "$receipt")" ] || {
    echo "supervisor-commit: Git metadata changed after trust snapshot" >&2; exit 1; }
  # Candidate dependency runtimes must still match the sealed digests — only the
  # check-image / docker binding may change on this path.
  runtimes_json=$(jq -cS '.check_runtimes' "$receipt") || exit 1
  current_runtimes=$(discover_check_runtimes) || {
    echo "supervisor-commit: could not re-seal primary-checkout check runtimes" >&2; exit 1; }
  [ "$(jq -cS . <<<"$current_runtimes")" = "$runtimes_json" ] || {
    # Identity+digest may stay equal while order is fixed by discover; compare
    # digests/targets explicitly if full JSON differs only by path presentation.
    if ! jq -en --argjson a "$runtimes_json" --argjson b "$current_runtimes" '
      ($a|length) == ($b|length) and
      ([ $a[] | {target,identity,digest,manifests} ] | sort_by(.target)) ==
      ([ $b[] | {target,identity,digest,manifests} ] | sort_by(.target))
    '; then
      echo "supervisor-commit: candidate check runtimes changed; rebind refused" >&2
      exit 1
    fi
  }
  check_driver_json=$(check_driver_metadata) || {
    echo "supervisor-commit: trusted private-container check runtime is unavailable" >&2; exit 1; }
  # Build and sign a temp receipt first so a failed re-sign cannot destroy the
  # previously authenticated binding.
  tmp=$(mktemp "${receipt}.rebind.XXXXXX") || exit 1
  if ! jq --argjson driver "$check_driver_json" \
    'del(.auth_tag) | .check_driver=$driver | .auth_tag=null' \
    "$receipt" > "$tmp"; then
    rm -f -- "$tmp"
    echo "supervisor-commit: could not rewrite check environment binding" >&2
    exit 1
  fi
  sign_receipt "$tmp" || {
    rm -f -- "$tmp"
    echo "supervisor-commit: could not re-sign rebound receipt" >&2; exit 1; }
  mv -f -- "$tmp" "$receipt" || {
    rm -f -- "$tmp"
    echo "supervisor-commit: could not publish rebound receipt" >&2
    exit 1
  }
  printf '%s\n' "$receipt"
}

if [ "$ACTION" = snapshot ]; then snapshot_trust; exit; fi
if [ "$ACTION" = rebind-env ]; then rebind_check_environment; exit; fi
[ "$ACTION" = commit ] && [ -n "$TRUST_RECEIPT" ] \
  && [ "${#ALLOW[@]}" -eq 0 ] && [ "$REQUIRE_APPROVED_DIFF" -eq 0 ] \
  && [ -z "$FIREWALL_SCRIPT" ] || usage
if [ "$CHECK_ONLY" -eq 1 ]; then [ -z "$MESSAGE" ] || usage
else [ -n "$MESSAGE" ] || usage
fi
valid_auth_token "$AUTH_TOKEN" || { echo "supervisor-commit: invalid authentication token" >&2; exit 2; }
TRUST_RECEIPT=$(receipt_path "$TRUST_RECEIPT") || exit 2
TRUST_HOOKS="${TRUST_RECEIPT}.hooks"
TRUST_FIREWALL="${TRUST_RECEIPT}.firewall"
[ -f "$TRUST_RECEIPT" ] && [ ! -L "$TRUST_RECEIPT" ] && [ -d "$TRUST_HOOKS" ] && [ ! -L "$TRUST_HOOKS" ] || {
  echo "supervisor-commit: trusted hook receipt is missing" >&2; exit 1; }
jq -e '((.schema_version == 4 and (has("purpose")|not) and (.allow|length > 0)) or
  (.schema_version == 5 and .purpose == "check-only" and (.allow|length == 0))) and
  (.base_head|type == "string") and
  (.head_ref|type == "string") and (.refs_fingerprint|type == "string") and
  (.hooks_fingerprint|type == "string") and (.hook_source_fingerprint|type == "string") and
  (.config_fingerprint|type == "string") and (.metadata_fingerprint|type == "string") and
  (.hook_source_rel == null or (.hook_source_rel|type == "string")) and
  (.allow|type == "array" and all(.[]; type == "string")) and
  (.require_approved_diff|type == "boolean") and
  (.firewall_fingerprint == null or (.firewall_fingerprint|type == "string")) and
  ((.require_approved_diff == true and (.firewall_fingerprint|type == "string")) or
   (.require_approved_diff == false and .firewall_fingerprint == null)) and
  (.check_driver|type == "object") and
  (.check_driver.path|type == "string" and length > 0) and
  (.check_driver.identity|type == "string" and test("^[0-9]+:[0-9]+$")) and
  (.check_driver.mode|type == "string" and test("^[0-7]+$")) and
  (.check_driver.sha256|type == "string" and test("^[0-9a-f]{64}$")) and
  (.check_driver.backend|type == "object") and
  (.check_driver.backend.docker|type == "object") and
  (.check_driver.backend.docker.path|type == "string" and length > 0) and
  (.check_driver.backend.docker.identity|type == "string" and test("^[0-9]+:[0-9]+$")) and
  (.check_driver.backend.docker.mode|type == "string" and test("^[0-7]+$")) and
  (.check_driver.backend.docker.sha256|type == "string" and test("^[0-9a-f]{64}$")) and
  (.check_driver.backend.daemon_id|type == "string" and length > 0) and
  (.check_driver.backend.image_id|type == "string" and test("^sha256:[0-9a-f]{64}$")) and
  (.check_driver.backend.container_id|type == "string" and length > 0) and
  (.check_runtimes|type == "array" and all(.[];
    (type == "object") and (.source|type == "string" and length > 0) and
    (.target|type == "string" and length > 0) and
    (.identity|type == "string" and test("^[0-9]+:[0-9]+$")) and
    (.digest|type == "string" and test("^[0-9a-f]{64}$")) and
    (.manifests|type == "array" and length > 0 and all(.[];
      (.path|type == "string" and length > 0) and
      (.oid|type == "string" and test("^[0-9a-f]{40,64}$")))))) and
  (.auth_tag|type == "string")' "$TRUST_RECEIPT" >/dev/null || {
  echo "supervisor-commit: malformed trust receipt" >&2; exit 1; }
verify_receipt_auth "$TRUST_RECEIPT" || {
  echo "supervisor-commit: trust receipt authentication failed" >&2; exit 1; }
RECEIPT_CHECK_ONLY=$(jq -r '(.schema_version == 5 and .purpose == "check-only")' "$TRUST_RECEIPT")
if [ "$CHECK_ONLY" -eq 1 ]; then
  [ "$RECEIPT_CHECK_ONLY" = true ] || {
    echo "supervisor-commit: trust receipt is not authenticated for check-only" >&2; exit 1; }
else
  [ "$RECEIPT_CHECK_ONLY" = false ] || {
    echo "supervisor-commit: check-only trust receipt cannot authorize a commit" >&2; exit 1; }
fi
BASE_HEAD=$(jq -r .base_head "$TRUST_RECEIPT")
[ "$($REAL_GIT rev-parse HEAD)" = "$BASE_HEAD" ] || {
  echo "supervisor-commit: trust receipt base no longer matches HEAD" >&2; exit 1; }
ACTIVE_REF=$(jq -r .head_ref "$TRUST_RECEIPT")
[ "$(head_ref)" = "$ACTIVE_REF" ] || {
  echo "supervisor-commit: active branch changed after trust snapshot" >&2; exit 1; }
receipt_refs_intact || {
  echo "supervisor-commit: Git refs changed after trust snapshot" >&2; exit 1; }
[ "$(hooks_fingerprint "$TRUST_HOOKS")" = "$(jq -r .hooks_fingerprint "$TRUST_RECEIPT")" ] || {
  echo "supervisor-commit: trusted hook receipt changed" >&2; exit 1; }
if [ "$(jq -r .require_approved_diff "$TRUST_RECEIPT")" = true ]; then
  [ -d "$TRUST_FIREWALL" ] && [ ! -L "$TRUST_FIREWALL" ] \
    && [ -f "$TRUST_FIREWALL/run.sh" ] && [ ! -L "$TRUST_FIREWALL/run.sh" ] \
    && [ "$(hooks_fingerprint "$TRUST_FIREWALL")" = "$(jq -r .firewall_fingerprint "$TRUST_RECEIPT")" ] || {
      echo "supervisor-commit: frozen firewall receipt changed" >&2; exit 1; }
fi
CURRENT_HOOK_SOURCE=$(resolve_hook_source) || {
  echo "supervisor-commit: configured hook source became unsafe" >&2; exit 1; }
[ "$(hooks_fingerprint "$CURRENT_HOOK_SOURCE")" = "$(jq -r .hook_source_fingerprint "$TRUST_RECEIPT")" ] || {
  echo "supervisor-commit: configured hook source changed after trust snapshot" >&2; exit 1; }
[ "$(config_fingerprint)" = "$(jq -r .config_fingerprint "$TRUST_RECEIPT")" ] || {
  echo "supervisor-commit: Git configuration changed after trust snapshot" >&2; exit 1; }
[ "$(metadata_fingerprint)" = "$(jq -r .metadata_fingerprint "$TRUST_RECEIPT")" ] || {
  echo "supervisor-commit: Git metadata changed after trust snapshot" >&2; exit 1; }
[ "$CHECK_ONLY" -eq 0 ] || workspace_is_clean_base || {
  echo "supervisor-commit: check-only requires a clean base worktree" >&2; exit 1; }

exec 9<"$COMMON_DIR" || {
  echo "supervisor-commit: cannot open the repository lock directory" >&2; exit 1; }
flock -n 9 || { echo "supervisor-commit: another supervisor commit is active" >&2; exit 1; }

ALLOW_INVENTORY=$(mktemp) || exit 1
if ! jq -r '.allow[]' "$TRUST_RECEIPT" > "$ALLOW_INVENTORY"; then
  rm -f -- "$ALLOW_INVENTORY"
  echo "supervisor-commit: cannot materialize authenticated allowlist" >&2
  exit 1
fi
mapfile -t ALLOW < "$ALLOW_INVENTORY"
ALLOW_COUNT=$(jq -er '.allow | length' "$TRUST_RECEIPT") || {
  rm -f -- "$ALLOW_INVENTORY"
  echo "supervisor-commit: cannot count authenticated allowlist" >&2
  exit 1
}
rm -f -- "$ALLOW_INVENTORY"
[ "${#ALLOW[@]}" -eq "$ALLOW_COUNT" ] || {
  echo "supervisor-commit: authenticated allowlist is incomplete" >&2
  exit 1
}
for path in "${ALLOW[@]}"; do
  valid_repo_path "$path" && ! is_local_only "$path" || {
    echo "supervisor-commit: authenticated allowlist is invalid" >&2; exit 1; }
done
allowed_path() {
  local candidate="$1" prefix
  for prefix in "${ALLOW[@]}"; do
    [ "$candidate" = "$prefix" ] || [ "${candidate#"$prefix"/}" != "$candidate" ] && return 0
  done
  return 1
}

CHECK_DRIVER_PATH=$(jq -r '.check_driver.path' "$TRUST_RECEIPT")
CHECK_DRIVER_IDENTITY=$(jq -r '.check_driver.identity' "$TRUST_RECEIPT")
CHECK_DRIVER_MODE=$(jq -r '.check_driver.mode' "$TRUST_RECEIPT")
CHECK_DRIVER_SHA256=$(jq -r '.check_driver.sha256' "$TRUST_RECEIPT")
CHECK_BACKEND=$(jq -cS '.check_driver.backend' "$TRUST_RECEIPT")

verify_check_driver_receipt() {
  local canonical identity mode digest backend
  [ -f "$CHECK_DRIVER_PATH" ] && [ -x "$CHECK_DRIVER_PATH" ] \
    && [ ! -L "$CHECK_DRIVER_PATH" ] || return 1
  canonical=$(readlink -f -- "$CHECK_DRIVER_PATH") || return 1
  [ "$canonical" = "$CHECK_DRIVER_PATH" ] || return 1
  case "$canonical" in "$ROOT"|"$ROOT"/*) return 1 ;; esac
  identity=$(stat -Lc '%d:%i' -- "$CHECK_DRIVER_PATH") || return 1
  mode=$(stat -Lc '%a' -- "$CHECK_DRIVER_PATH") || return 1
  digest=$(sha256sum -- "$CHECK_DRIVER_PATH" | awk '{print $1}') || return 1
  [ "$identity" = "$CHECK_DRIVER_IDENTITY" ] && [ "$mode" = "$CHECK_DRIVER_MODE" ] \
    && [ "$digest" = "$CHECK_DRIVER_SHA256" ] || return 1
  backend=$(timeout -k 5 30 "$CHECK_DRIVER_PATH" --metadata) || return 1
  [ "$(jq -cS . <<<"$backend")" = "$CHECK_BACKEND" ]
}

declare -a CHECK_RUNTIME_SOURCES=() CHECK_RUNTIME_TARGETS=() CHECK_RUNTIME_IDENTITIES=()
declare -a CHECK_RUNTIME_DIGESTS=() CHECK_RUNTIME_MANIFESTS=()
load_check_runtime_receipt() {
  local count i item source target identity digest manifests expected expected_canonical
  local previous= inventory runtime_inventory
  local -a runtime_items=()
  runtime_inventory=$(mktemp) || return 1
  if ! jq -c '.check_runtimes[]' "$TRUST_RECEIPT" > "$runtime_inventory"; then
    rm -f -- "$runtime_inventory"
    echo "supervisor-commit: cannot materialize authenticated check runtimes" >&2
    return 1
  fi
  mapfile -t runtime_items < "$runtime_inventory" || {
    rm -f -- "$runtime_inventory"
    echo "supervisor-commit: cannot read authenticated check runtimes" >&2
    return 1
  }
  count=$(jq -er '.check_runtimes|length' "$TRUST_RECEIPT") || {
    rm -f -- "$runtime_inventory"
    echo "supervisor-commit: cannot count authenticated check runtimes" >&2
    return 1
  }
  [[ "$count" =~ ^[0-9]+$ ]] && [ "${#runtime_items[@]}" -eq "$count" ] || {
    rm -f -- "$runtime_inventory"
    echo "supervisor-commit: authenticated check runtime inventory is incomplete" >&2
    return 1
  }
  rm -f -- "$runtime_inventory"
  # Always re-prove primary identity on reload — including empty runtime receipts
  # so a deps-blind linked-root snapshot cannot commit later from the primary.
  discover_primary_checkout || {
    echo "supervisor-commit: primary-checkout runtime source is no longer available" >&2; return 1; }
  for ((i=0; i<count; i++)); do
    item=${runtime_items[$i]}
    source=$(jq -er '.source | select(type == "string" and length > 0)' <<<"$item") || {
      echo "supervisor-commit: authenticated runtime source is unreadable" >&2; return 1; }
    target=$(jq -er '.target | select(type == "string" and length > 0)' <<<"$item") || {
      echo "supervisor-commit: authenticated runtime target is unreadable" >&2; return 1; }
    identity=$(jq -er '.identity | select(type == "string")' <<<"$item") || {
      echo "supervisor-commit: authenticated runtime identity is unreadable" >&2; return 1; }
    digest=$(jq -er '.digest | select(type == "string")' <<<"$item") || {
      echo "supervisor-commit: authenticated runtime digest is unreadable" >&2; return 1; }
    manifests=$(jq -ceS '.manifests | select(type == "array" and length > 0)' \
      <<<"$item") || {
      echo "supervisor-commit: authenticated runtime manifests are unreadable" >&2; return 1; }
    [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
      echo "supervisor-commit: authenticated runtime metadata is invalid" >&2; return 1; }
    valid_repo_path "$target" || {
      echo "supervisor-commit: authenticated runtime target is invalid" >&2; return 1; }
    case "${target##*/}" in node_modules|venv|.venv) : ;; *)
      echo "supervisor-commit: authenticated runtime class is invalid" >&2; return 1 ;; esac
    [ -z "$previous" ] || [[ "$previous" < "$target" ]] || {
      echo "supervisor-commit: authenticated runtime targets are not unique" >&2; return 1; }
    previous=$target
    [ "$source" = "$PRIMARY_CHECKOUT/$target" ] || {
      echo "supervisor-commit: authenticated runtime source left the primary checkout" >&2; return 1; }
    safe_runtime_source "$PRIMARY_CHECKOUT" "$target" && [ "$RUNTIME_SOURCE" = "$source" ] || {
      echo "supervisor-commit: authenticated runtime source became unsafe" >&2; return 1; }
    if [ "${target##*/}" = node_modules ]; then
      [ -d "$source/.bin" ] && [ ! -L "$source/.bin" ] || {
        echo "supervisor-commit: authenticated Node runtime marker is missing" >&2; return 1; }
    else
      [ -d "$source/bin" ] && [ ! -L "$source/bin" ] \
        && [ -e "$source/bin/python" ] && [ -x "$source/bin/python" ] || {
          echo "supervisor-commit: authenticated Python runtime marker is missing" >&2; return 1; }
    fi
    inventory=$(mktemp) || return 1
    checked_inventory "$inventory" "$REAL_GIT" -C "$ROOT" \
      ls-tree -r --name-only -z "$BASE_HEAD" -- "$target" || {
      rm -f -- "$inventory"; return 1; }
    runtime_target_is_ignored "$target" && [ ! -s "$inventory" ] || {
        rm -f -- "$inventory"
        echo "supervisor-commit: authenticated runtime target is not ignored and untracked" >&2; return 1; }
    rm -f -- "$inventory"
    expected=$(manifest_json_for_tree "$ROOT" "$BASE_HEAD" "$target") || return 1
    expected_canonical=$(jq -ceS . <<<"$expected") || return 1
    [ "$expected_canonical" = "$manifests" ] || {
      echo "supervisor-commit: authenticated runtime manifests do not match the base" >&2; return 1; }
    CHECK_RUNTIME_SOURCES+=("$source") || return 1
    CHECK_RUNTIME_TARGETS+=("$target") || return 1
    CHECK_RUNTIME_IDENTITIES+=("$identity") || return 1
    CHECK_RUNTIME_DIGESTS+=("$digest") || return 1
    CHECK_RUNTIME_MANIFESTS+=("$manifests") || return 1
  done
}

load_check_runtime_receipt || exit 1

workspace_fingerprint() {
  local tmp inventory path mode oid result
  tmp=$(mktemp) || return 1
  inventory=$(mktemp) || { rm -f -- "$tmp"; return 1; }
  checked_inventory "$inventory" "$REAL_GIT" -c core.fsmonitor=false \
    ls-files --cached --others --exclude-standard -z -- . || {
    rm -f -- "$tmp" "$inventory"; return 1; }
  while IFS= read -r -d '' path; do
    is_local_only "$path" && continue
    if [ -L "$path" ]; then
      mode=120000; oid=$(readlink "$path" | $REAL_GIT hash-object --stdin) || {
        rm -f -- "$tmp" "$inventory"; return 1; }
      valid_git_oid "$oid" || { rm -f -- "$tmp" "$inventory"; return 1; }
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      oid=$($REAL_GIT hash-object --no-filters -- "$path" 2>/dev/null) || {
        rm -f -- "$tmp" "$inventory"; return 1; }
      valid_git_oid "$oid" || { rm -f -- "$tmp" "$inventory"; return 1; }
    elif [ -d "$path" ]; then mode=040000; oid=directory
    elif [ -e "$path" ]; then
      rm -f -- "$tmp" "$inventory"; return 1
    else mode=missing; oid=missing
    fi
    printf '%s\0%s\0%s\0' "$path" "$mode" "$oid" >> "$tmp" || {
      rm -f -- "$tmp" "$inventory"; return 1; }
  done < "$inventory"
  result=$($REAL_GIT hash-object --no-filters "$tmp") || {
    rm -f -- "$tmp" "$inventory"; return 1; }
  valid_git_oid "$result" || { rm -f -- "$tmp" "$inventory"; return 1; }
  rm -f -- "$tmp" "$inventory"
  printf '%s\n' "$result" || return 1
}

UNMERGED_INVENTORY=$(mktemp) || exit 1
checked_inventory "$UNMERGED_INVENTORY" "$REAL_GIT" -c core.fsmonitor=false \
  ls-files --unmerged -z || {
  rm -f -- "$UNMERGED_INVENTORY"
  echo "supervisor-commit: could not inspect unmerged index entries" >&2
  exit 1
}
if [ -s "$UNMERGED_INVENTORY" ]; then
  rm -f -- "$UNMERGED_INVENTORY"
  echo "supervisor-commit: unmerged index entries are not supported" >&2; exit 1
fi
rm -f -- "$UNMERGED_INVENTORY"
PRIMARY_WORKSPACE_FINGERPRINT=$(workspace_fingerprint) || {
  echo "supervisor-commit: could not inventory the primary workspace" >&2; exit 1; }
SPARSE_CONFIG_RC=0
SPARSE_CONFIG_VALUE=$($REAL_GIT config --bool core.sparseCheckout 2>/dev/null) \
  || SPARSE_CONFIG_RC=$?
case "$SPARSE_CONFIG_RC" in
  0)
    case "$SPARSE_CONFIG_VALUE" in
      true) echo "supervisor-commit: sparse checkouts require a dedicated delivery path" >&2; exit 1 ;;
      false) : ;;
      *) echo "supervisor-commit: invalid sparse-checkout configuration" >&2; exit 1 ;;
    esac
    ;;
  1) : ;;
  *) echo "supervisor-commit: cannot inspect sparse-checkout configuration" >&2; exit 1 ;;
esac

consume_receipt() {
  chmod -R u+w "$TRUST_HOOKS" 2>/dev/null || true
  chmod -R u+w "$TRUST_FIREWALL" 2>/dev/null || true
  rm -rf -- "$TRUST_HOOKS"
  rm -rf -- "$TRUST_FIREWALL"
  rm -f -- "$TRUST_RECEIPT"
}

declare -A CANDIDATE_PATHS=() BASE_GITLINKS=() INDEX_GITLINKS=() INDEX_MODES=()
CANDIDATE_INVENTORY=$(mktemp) || exit 1
checked_inventory "$CANDIDATE_INVENTORY" "$REAL_GIT" ls-tree -r -z HEAD || {
  rm -f -- "$CANDIDATE_INVENTORY"
  echo "supervisor-commit: could not inventory the base tree" >&2; exit 1; }
while IFS= read -r -d '' record; do
  meta=${record%%$'\t'*}; path=${record#*$'\t'}; mode=${meta%% *}; oid=${meta##* }
  CANDIDATE_PATHS["$path"]=1
  [ "$mode" != 160000 ] || BASE_GITLINKS["$path"]=$oid
done < "$CANDIDATE_INVENTORY"
checked_inventory "$CANDIDATE_INVENTORY" "$REAL_GIT" -c core.fsmonitor=false \
  ls-files --stage -z || {
  rm -f -- "$CANDIDATE_INVENTORY"
  echo "supervisor-commit: could not inventory the candidate index" >&2; exit 1; }
while IFS= read -r -d '' record; do
  meta=${record%%$'\t'*}; path=${record#*$'\t'}; mode=${meta%% *}
  rest=${meta#* }; oid=${rest%% *}; stage=${meta##* }
  [ "$stage" = 0 ] || { echo "supervisor-commit: unmerged index entry" >&2; exit 1; }
  CANDIDATE_PATHS["$path"]=1
  INDEX_MODES["$path"]=$mode
  [ "$mode" != 160000 ] || INDEX_GITLINKS["$path"]=$oid
done < "$CANDIDATE_INVENTORY"
checked_inventory "$CANDIDATE_INVENTORY" "$REAL_GIT" -c core.fsmonitor=false \
  ls-files --others --exclude-standard -z || {
  rm -f -- "$CANDIDATE_INVENTORY"
  echo "supervisor-commit: could not inventory untracked candidate paths" >&2; exit 1; }
while IFS= read -r -d '' path; do
  CANDIDATE_PATHS["$path"]=1
done < "$CANDIDATE_INVENTORY"
rm -f -- "$CANDIDATE_INVENTORY"

case "$CHECK" in
  /*) case "$CHECK" in "$ROOT"/*) CHECK_REL=${CHECK#"$ROOT"/} ;;
        *) echo "supervisor-commit: check must be inside the repository" >&2; exit 1 ;; esac ;;
  *) CHECK_REL=${CHECK#./} ;;
esac
[ -n "$CHECK_REL" ] || { echo "supervisor-commit: invalid check path" >&2; exit 1; }
case "/$CHECK_REL/" in */../*|*/./*|*//*) echo "supervisor-commit: invalid check path" >&2; exit 1 ;; esac
$REAL_GIT cat-file -e "HEAD:$CHECK_REL" 2>/dev/null || {
  echo "supervisor-commit: check must exist in the recorded base commit" >&2; exit 1; }
CHECK_MODE=$($REAL_GIT ls-tree HEAD -- "$CHECK_REL" | awk 'NR == 1 {print $1}')
case "$CHECK_MODE" in 100755|100644) : ;;
  *) echo "supervisor-commit: base check must be a regular file" >&2; exit 1 ;;
esac

BEFORE_STATUS=$(mktemp)
AFTER_STATUS=$(mktemp)
PACK_FILE=$(mktemp)
CANDIDATE_DIFF=$(mktemp)
ATTR_INVENTORY=$(mktemp)
SANDBOX_HOME=$(mktemp -d)
CHECK_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/saas-supervisor-check.XXXXXX")
SHADOW="$CHECK_PARENT/worktree"
FROZEN_HOOKS="$SHADOW/.git/supervisor-hooks"
cleanup() {
  rm -f "$BEFORE_STATUS" "$AFTER_STATUS" "$PACK_FILE" "$CANDIDATE_DIFF" "$ATTR_INVENTORY"
  chmod -R u+w "$CHECK_PARENT" 2>/dev/null || true
  rm -rf "$SANDBOX_HOME" "$CHECK_PARENT"
}
trap cleanup EXIT

$REAL_GIT clone -q --no-local "$ROOT" "$SHADOW"
$REAL_GIT -C "$SHADOW" checkout -q --detach "$BASE_HEAD"

ATTRIBUTES_FILE=$($REAL_GIT rev-parse --git-path info/attributes) || {
  echo "supervisor-commit: cannot resolve Git attributes metadata" >&2; exit 1; }
case "$ATTRIBUTES_FILE" in /*) : ;; *) ATTRIBUTES_FILE="$ROOT/$ATTRIBUTES_FILE" ;; esac
if [ -s "$ATTRIBUTES_FILE" ]; then
  echo "supervisor-commit: info/attributes requires a dedicated trusted staging path" >&2
  exit 1
fi
ATTRIBUTES_CONFIG_RC=0
ATTRIBUTES_CONFIG_VALUE=$($REAL_GIT config --path core.attributesFile 2>/dev/null) \
  || ATTRIBUTES_CONFIG_RC=$?
case "$ATTRIBUTES_CONFIG_RC" in
  0)
    echo "supervisor-commit: core.attributesFile requires a dedicated trusted staging path" >&2
    exit 1
    ;;
  1) : ;;
  *) echo "supervisor-commit: cannot inspect core.attributesFile" >&2; exit 1 ;;
esac
for staging_key in core.autocrlf core.eol core.safecrlf core.fileMode core.symlinks \
  core.ignoreCase core.precomposeUnicode; do
  staging_config_rc=0
  staging_value=$($REAL_GIT config --get "$staging_key" 2>/dev/null) \
    || staging_config_rc=$?
  case "$staging_config_rc" in
    0) $REAL_GIT -C "$SHADOW" config "$staging_key" "$staging_value" ;;
    1) $REAL_GIT -C "$SHADOW" config --unset-all "$staging_key" 2>/dev/null || true ;;
    *) printf 'supervisor-commit: cannot inspect staging configuration: %s\n' \
         "$staging_key" >&2; exit 1 ;;
  esac
done

source_parent_state() {
  local relative="$1" current="$ROOT" part
  SOURCE_PARENT_EXISTS=1
  while [[ "$relative" == */* ]]; do
    part=${relative%%/*}; relative=${relative#*/}; current="$current/$part"
    [ ! -L "$current" ] || return 1
    if [ ! -d "$current" ]; then SOURCE_PARENT_EXISTS=0; return 0; fi
  done
}

remove_shadow_path() {
  local relative="$1" current="$SHADOW" part
  while [[ "$relative" == */* ]]; do
    part=${relative%%/*}; relative=${relative#*/}; current="$current/$part"
    [ ! -L "$current" ] || return 1
    [ -d "$current" ] || return 0
  done
  rm -rf -- "${current:?}/$relative"
}

prepare_shadow_parent() {
  local relative="$1" current="$SHADOW" part
  while [[ "$relative" == */* ]]; do
    part=${relative%%/*}; relative=${relative#*/}; current="$current/$part"
    [ ! -L "$current" ] || return 1
    if [ -e "$current" ] && [ ! -d "$current" ]; then rm -f -- "$current"; fi
    [ -d "$current" ] || mkdir "$current"
  done
}

for path in "${!CANDIDATE_PATHS[@]}"; do
  valid_repo_path "$path" || { printf 'supervisor-commit: unsafe candidate path: %q\n' "$path" >&2; exit 1; }
  allowed_path "$path" || continue
  is_local_only "$path" && continue
  if [ "${INDEX_GITLINKS[$path]+present}" = present ] \
    || { [ "${BASE_GITLINKS[$path]+present}" = present ] \
      && [ "${INDEX_MODES[$path]+present}" != present ]; }; then continue; fi
  source_parent_state "$path" || {
    printf 'supervisor-commit: symlinked candidate parent: %q\n' "$path" >&2; exit 1; }
  source_path="$ROOT/$path"; shadow_path="$SHADOW/$path"
  if [ "$SOURCE_PARENT_EXISTS" -eq 0 ] || [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
    remove_shadow_path "$path" || {
      printf 'supervisor-commit: unsafe shadow parent: %q\n' "$path" >&2; exit 1; }
  elif [ -d "$source_path" ] && [ ! -L "$source_path" ]; then
    prepare_shadow_parent "$path" || {
      printf 'supervisor-commit: unsafe shadow parent: %q\n' "$path" >&2; exit 1; }
    if [ -L "$shadow_path" ] || { [ -e "$shadow_path" ] && [ ! -d "$shadow_path" ]; }; then
      rm -rf -- "$shadow_path"
    fi
    [ -d "$shadow_path" ] || mkdir "$shadow_path"
  elif [ -f "$source_path" ] || [ -L "$source_path" ]; then
    prepare_shadow_parent "$path" || {
      printf 'supervisor-commit: unsafe shadow parent: %q\n' "$path" >&2; exit 1; }
    rm -rf -- "$shadow_path"
    cp -pP "$source_path" "$shadow_path"
  else
    printf 'supervisor-commit: unsupported candidate file type: %q\n' "$path" >&2
    exit 1
  fi
done

$REAL_GIT status --porcelain=v1 --untracked-files=all > "$BEFORE_STATUS"
PRIMARY_INDEX_TREE=$($REAL_GIT write-tree)
BOUNDARY_BEFORE="$(primary_boundary_fingerprint)"

CODEX_BIN=$(command -v codex 2>/dev/null) || {
  echo "supervisor-commit: Codex sandbox is required for credentialless network-off checks" >&2; exit 1; }
SANDBOX_HELP=$($CODEX_BIN sandbox --help 2>/dev/null) || {
  echo "supervisor-commit: Codex sandbox is unavailable" >&2; exit 1; }
grep -q -- '--permission-profile' <<< "$SANDBOX_HELP" \
  && grep -q -- '--enable' <<< "$SANDBOX_HELP" || {
    echo "supervisor-commit: required Codex sandbox controls are unavailable" >&2; exit 1; }
mkdir -p "$SANDBOX_HOME/codex" "$SANDBOX_HOME/config" "$SANDBOX_HOME/data"

sandbox_exec() {
  local cwd="$1"; shift
  env -i PATH="$PATH" HOME="$SANDBOX_HOME" CODEX_HOME="$SANDBOX_HOME/codex" \
    XDG_CONFIG_HOME="$SANDBOX_HOME/config" XDG_DATA_HOME="$SANDBOX_HOME/data" \
    USER="${USER:-supervisor}" TERM="${TERM:-dumb}" CI=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=/bin/false \
    CODEX_BIN="$CODEX_BIN" /bin/bash "$SCRIPT_DIR/codex-network-off-sandbox.sh" -C "$cwd" "$@"
}

# Trusted git over the shadow clone with the same credentialless environment
# hygiene as sandbox_exec, minus the sandbox itself: Codex's :workspace profile
# denies .git writes, so Git metadata mutations cannot run inside it
# (issues #260/#261). git add/commit perform no network I/O; the scrubbed
# environment and /dev/null configs remove ambient credentials regardless.
trusted_shadow_git() {
  env -i PATH="$PATH" HOME="$SANDBOX_HOME" USER="${USER:-supervisor}" TERM="${TERM:-dumb}" CI=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_NO_REPLACE_OBJECTS=1 GIT_LITERAL_PATHSPECS=1 \
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=/bin/false \
    "$REAL_GIT" -C "$SHADOW" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

for path in "${!CANDIDATE_PATHS[@]}"; do
  allowed_path "$path" || continue
  attr_path='' attr_name='' attr_value=''
  if ! $REAL_GIT -C "$SHADOW" check-attr -z filter -- "$path" > "$ATTR_INVENTORY"; then
    printf 'supervisor-commit: could not inspect attributes for path: %q\n' "$path" >&2
    exit 1
  fi
  {
    IFS= read -r -d '' attr_path || true
    IFS= read -r -d '' attr_name || true
    IFS= read -r -d '' attr_value || true
  } < "$ATTR_INVENTORY"
  [ "$attr_path" = "$path" ] && [ "$attr_name" = filter ] || {
    printf 'supervisor-commit: could not inspect attributes for path: %q\n' "$path" >&2; exit 1; }
  case "$attr_value" in unspecified|unset) : ;;
    *) printf 'supervisor-commit: filtered path requires a dedicated trusted staging path: %q\n' "$path" >&2; exit 1 ;;
  esac
done

# Nothing untrusted executes during staging: hooks and fsmonitor are disabled,
# the attributes/filter gates above rejected any filtered path, and the
# /dev/null configs leave no filter drivers defined.
trusted_shadow_git add -A || {
  echo "supervisor-commit: isolated candidate staging failed" >&2; exit 1; }
declare -A ALL_GITLINKS=()
for path in "${!BASE_GITLINKS[@]}"; do ALL_GITLINKS["$path"]=1; done
for path in "${!INDEX_GITLINKS[@]}"; do ALL_GITLINKS["$path"]=1; done
for path in "${!ALL_GITLINKS[@]}"; do
  if [ "${INDEX_GITLINKS[$path]+present}" = present ]; then
    $REAL_GIT -C "$SHADOW" update-index --add --cacheinfo "160000,${INDEX_GITLINKS[$path]},$path"
  elif [ "${INDEX_MODES[$path]+present}" != present ]; then
    $REAL_GIT -C "$SHADOW" update-index --force-remove -- "$path"
  fi
done

CHECKED_TREE=$($REAL_GIT -C "$SHADOW" write-tree)
$REAL_GIT -C "$SHADOW" diff --cached --binary --no-ext-diff --no-textconv \
  "$BASE_HEAD" -- > "$CANDIDATE_DIFF"
DIFF_HASH=$(openssl dgst -sha256 "$CANDIDATE_DIFF" | awk '{print $NF}')
if [ "$CHECKED_TREE" = "$($REAL_GIT rev-parse 'HEAD^{tree}')" ]; then
  if [ "$CHECK_ONLY" -eq 0 ]; then
    echo "supervisor-commit: no delivery diff to commit"
    consume_receipt
    exit 0
  fi
elif [ "$CHECK_ONLY" -eq 1 ]; then
  echo "supervisor-commit: check-only candidate diverged from the clean base" >&2
  exit 1
fi
if [ "$CHECK_ONLY" -eq 0 ] && [ "$(jq -r .require_approved_diff "$TRUST_RECEIPT")" = true ]; then
  chmod 400 "$CANDIDATE_DIFF"
  FIREWALL_RC=0
  set +e
  sandbox_exec "$SHADOW" /bin/bash "$TRUST_FIREWALL/run.sh" --firewall "$CANDIDATE_DIFF"
  FIREWALL_RC=$?
  set -e
  [ "$(openssl dgst -sha256 "$CANDIDATE_DIFF" | awk '{print $NF}')" = "$DIFF_HASH" ] \
    && [ "$(hooks_fingerprint "$TRUST_FIREWALL")" = "$(jq -r .firewall_fingerprint "$TRUST_RECEIPT")" ] || {
      echo "supervisor-commit: frozen firewall transaction changed" >&2; exit 1; }
  case "$FIREWALL_RC" in
    0) : ;;
    3) echo "supervisor-commit: candidate diff firewall blocked delivery" >&2; exit 3 ;;
    *) echo "supervisor-commit: candidate diff firewall failed" >&2; exit 1 ;;
  esac
fi
if [ "$CHECK_ONLY" -eq 0 ]; then
  (cd "$SHADOW" && bash "$SCRIPT_DIR/check-staged-size.sh")
fi
HOOK_SOURCE_REL=$(jq -r '.hook_source_rel // empty' "$TRUST_RECEIPT")
if [ "$CHECK_ONLY" -eq 0 ] && [ -n "$HOOK_SOURCE_REL" ] \
  && ! $REAL_GIT -C "$SHADOW" diff --cached --quiet "$BASE_HEAD" -- "$HOOK_SOURCE_REL"; then
  echo "supervisor-commit: active hook changes require a separate trusted maintenance path" >&2
  exit 1
fi

prepare_check_runtimes() {
  local i target source identity digest manifests candidate candidate_canonical shadow_target inventory
  for ((i=0; i<${#CHECK_RUNTIME_SOURCES[@]}; i++)); do
    source=${CHECK_RUNTIME_SOURCES[$i]}; target=${CHECK_RUNTIME_TARGETS[$i]}
    identity=$(stat -Lc '%d:%i' -- "$source") || return 1
    [ "$identity" = "${CHECK_RUNTIME_IDENTITIES[$i]}" ] || {
      echo "supervisor-commit: sealed check runtime changed identity" >&2; return 1; }
    digest=$(runtime_tree_digest "$source" "$target") || return 1
    [ "$digest" = "${CHECK_RUNTIME_DIGESTS[$i]}" ] || {
      echo "supervisor-commit: sealed check runtime changed after trust snapshot" >&2; return 1; }
    manifests=$(jq -ceS . <<<"${CHECK_RUNTIME_MANIFESTS[$i]}") || return 1
    candidate=$(manifest_json_for_tree "$SHADOW" "$CHECKED_TREE" "$target") || return 1
    candidate_canonical=$(jq -ceS . <<<"$candidate") || return 1
    [ "$candidate_canonical" = "$manifests" ] || {
      echo "supervisor-commit: candidate dependency manifests changed after runtime snapshot" >&2; return 1; }
    inventory=$(mktemp) || return 1
    checked_inventory "$inventory" "$REAL_GIT" -C "$SHADOW" \
      ls-tree -r --name-only -z "$CHECKED_TREE" -- "$target" || {
      rm -f -- "$inventory"; return 1; }
    [ ! -s "$inventory" ] || {
      rm -f -- "$inventory"
      echo "supervisor-commit: candidate tree contains a dependency runtime path" >&2; return 1; }
    rm -f -- "$inventory"
    prepare_shadow_parent "$target" || {
      echo "supervisor-commit: unsafe linked runtime target parent" >&2; return 1; }
    shadow_target="$SHADOW/$target"
    [ ! -e "$shadow_target" ] && [ ! -L "$shadow_target" ] || {
      echo "supervisor-commit: linked runtime target is not empty" >&2; return 1; }
    mkdir "$shadow_target"
  done
}

check_runtimes_unchanged() {
  local i source target identity digest
  for ((i=0; i<${#CHECK_RUNTIME_SOURCES[@]}; i++)); do
    source=${CHECK_RUNTIME_SOURCES[$i]}; target=${CHECK_RUNTIME_TARGETS[$i]}
    identity=$(stat -Lc '%d:%i' -- "$source") || return 1
    [ "$identity" = "${CHECK_RUNTIME_IDENTITIES[$i]}" ] || return 1
    digest=$(runtime_tree_digest "$source" "$target") || return 1
    [ "$digest" = "${CHECK_RUNTIME_DIGESTS[$i]}" ] || return 1
  done
}

prepare_check_log() {
  local log_dir="$TRUST_DIR/check-logs" name unsafe
  if [ ! -e "$log_dir" ] && [ ! -L "$log_dir" ]; then mkdir -m 700 -- "$log_dir"; fi
  [ -d "$log_dir" ] && [ ! -L "$log_dir" ] \
    && [ "$(cd "$log_dir" && pwd -P)" = "$log_dir" ] || {
      echo "supervisor-commit: check log directory is unsafe" >&2; return 1; }
  unsafe=$(find -P "$log_dir" -mindepth 1 -maxdepth 1 -name '*.check.*.log' \
    ! -type f -print -quit) || return 1
  [ -z "$unsafe" ] || {
    echo "supervisor-commit: unsafe check log retention entry" >&2; return 1; }
  name=$(basename -- "$TRUST_RECEIPT")
  CHECK_LOG=$(mktemp "$log_dir/${name}.check.XXXXXX.log") || return 1
  chmod 600 "$CHECK_LOG"
  CHECK_LOG_FD=8
  exec 8<>"$CHECK_LOG" || return 1
  CHECK_LOG_ID=$(stat -Lc '%d:%i' -- "$CHECK_LOG") || return 1
}

check_log_intact() {
  [ -f "$CHECK_LOG" ] && [ ! -L "$CHECK_LOG" ] \
    && [ "$(stat -Lc '%d:%i' -- "$CHECK_LOG")" = "$CHECK_LOG_ID" ] \
    && [ "$(stat -Lc '%d:%i' -- "/proc/self/fd/$CHECK_LOG_FD")" = "$CHECK_LOG_ID" ]
}

prune_check_logs() {
  local log_dir="$TRUST_DIR/check-logs" listing unsafe order sorted timestamp file index excess i
  local total_bytes=0 file_bytes
  local -a candidates=() old_logs=()
  listing=$(mktemp) || return 1
  unsafe=$(mktemp) || { rm -f -- "$listing"; return 1; }
  order=$(mktemp) || { rm -f -- "$listing" "$unsafe"; return 1; }
  sorted=$(mktemp) || { rm -f -- "$listing" "$unsafe" "$order"; return 1; }
  find -P "$log_dir" -mindepth 1 -maxdepth 1 -name '*.check.*.log' \
    ! -type f -print0 > "$unsafe" || {
      rm -f -- "$listing" "$unsafe" "$order" "$sorted"; return 1; }
  if [ -s "$unsafe" ]; then
    rm -f -- "$listing" "$unsafe" "$order" "$sorted"
    echo "supervisor-commit: unsafe check log retention entry" >&2
    return 1
  fi
  find -P "$log_dir" -mindepth 1 -maxdepth 1 -type f -name '*.check.*.log' \
    -printf '%T@\0%p\0' > "$listing" || {
      rm -f -- "$listing" "$unsafe" "$order" "$sorted"; return 1; }
  while IFS= read -r -d '' timestamp && IFS= read -r -d '' file; do
    [ "$file" != "$CHECK_LOG" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || {
      rm -f -- "$listing" "$unsafe" "$order" "$sorted"; return 1; }
    timestamp=${timestamp%%.*}
    [[ "$timestamp" =~ ^[0-9]+$ ]] || {
      rm -f -- "$listing" "$unsafe" "$order" "$sorted"; return 1; }
    index=${#candidates[@]}; candidates[$index]=$file
    printf '%s\t%s\n' "$timestamp" "$index" >> "$order"
  done < "$listing"
  LC_ALL=C sort -n -k1,1 -k2,2 "$order" > "$sorted" || {
    rm -f -- "$listing" "$unsafe" "$order" "$sorted"; return 1; }
  while IFS=$'\t' read -r timestamp index; do
    [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -lt "${#candidates[@]}" ] || {
      rm -f -- "$listing" "$unsafe" "$order" "$sorted"; return 1; }
    old_logs+=("${candidates[$index]}")
  done < "$sorted"
  rm -f -- "$listing" "$unsafe" "$order" "$sorted"
  file_bytes=$(stat -Lc '%s' -- "$CHECK_LOG") || return 1
  total_bytes=$file_bytes
  for file in "${old_logs[@]}"; do
    file_bytes=$(stat -Lc '%s' -- "$file") || return 1
    total_bytes=$((total_bytes + file_bytes))
  done
  excess=$((${#old_logs[@]} - CHECK_LOG_RETENTION_FILES + 1))
  [ "$excess" -gt 0 ] || excess=0
  for ((i=0; i<${#old_logs[@]}; i++)); do
    [ "$i" -lt "$excess" ] || [ "$total_bytes" -gt "$CHECK_LOG_RETENTION_BYTES" ] || break
    file=${old_logs[$i]}
    [ -f "$file" ] && [ ! -L "$file" ] \
      && [ "$(dirname -- "$file")" = "$log_dir" ] || return 1
    file_bytes=$(stat -Lc '%s' -- "$file") || return 1
    rm -f -- "$file" || return 1
    total_bytes=$((total_bytes - file_bytes))
  done
  [ "$total_bytes" -le "$CHECK_LOG_RETENTION_BYTES" ]
}

emit_bounded_check_log() {
  tail -n 80 "$CHECK_LOG" | LC_ALL=C awk -v max_bytes=8192 '
    BEGIN { bytes=0; truncated=0 }
    {
      if (bytes >= max_bytes) { truncated=1; next }
      text=$0 ORS
      remaining=max_bytes-bytes
      if (length(text) > remaining) {
        printf "%s", substr(text, 1, remaining)
        bytes=max_bytes
        truncated=1
        next
      }
      printf "%s", text
      bytes+=length(text)
    }
    END { if (truncated) print "[supervisor-commit: check output truncated]" }
  '
}

run_bounded_check() {
  local pid running=0 size i file_blocks file_limit_bytes
  CHECK_LIMIT_REASON=""
  file_blocks=$((CHECK_LOG_MAX_BYTES / 512))
  file_limit_bytes=$((file_blocks * 512))
  set +e
  (
    ulimit -f "$file_blocks" || exit 1
    exec timeout --signal=TERM --kill-after=2s "${CHECK_TIMEOUT_SECONDS}s" \
      "${CHECK_SANDBOX[@]}"
  ) >&$CHECK_LOG_FD 2>&1 &
  pid=$!
  while :; do
    running=0
    for i in $(jobs -pr); do [ "$i" = "$pid" ] && running=1; done
    [ "$running" -eq 1 ] || break
    if ! check_log_intact; then
      CHECK_LIMIT_REASON="check evidence slot became unsafe"
      break
    fi
    size=$(stat -Lc '%s' -- "/proc/self/fd/$CHECK_LOG_FD") || {
      CHECK_LIMIT_REASON="check evidence slot became unreadable"; break; }
    if [ "$size" -gt "$CHECK_LOG_MAX_BYTES" ]; then
      CHECK_LIMIT_REASON="check output exceeded the $CHECK_LOG_MAX_BYTES-byte budget"
      break
    fi
    sleep 0.05
  done
  if [ -n "$CHECK_LIMIT_REASON" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    for ((i=0; i<20; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid"
  CHECK_RC=$?
  set -e
  check_log_intact || {
    echo "supervisor-commit: check evidence slot became unsafe" >&2
    return 1
  }
  size=$(stat -Lc '%s' -- "/proc/self/fd/$CHECK_LOG_FD") || return 1
  if [ "$CHECK_RC" -ne 0 ] && [ "$size" -ge "$file_limit_bytes" ]; then
    CHECK_LIMIT_REASON="check output exceeded the $CHECK_LOG_MAX_BYTES-byte budget"
  fi
  if [ "$size" -gt "$CHECK_LOG_MAX_BYTES" ]; then
    CHECK_LIMIT_REASON="check output exceeded the $CHECK_LOG_MAX_BYTES-byte budget"
    truncate -s "$CHECK_LOG_MAX_BYTES" -- "/proc/self/fd/$CHECK_LOG_FD" || return 1
  fi
  if [ -n "$CHECK_LIMIT_REASON" ]; then
    CHECK_RC=1
  elif [ "$CHECK_RC" -eq 124 ] || [ "$CHECK_RC" -eq 137 ]; then
    CHECK_LIMIT_REASON="checks exceeded the ${CHECK_TIMEOUT_SECONDS}-second deadline"
    CHECK_RC=1
  fi
  exec 8>&-
}

prepare_check_runtimes || exit 1
verify_check_driver_receipt || {
  echo "supervisor-commit: trusted private-container check runtime changed after trust snapshot" >&2; exit 1; }

CHECK_SHADOW="$SHADOW/$CHECK_REL"
validate_check_slot() {
  local relative="$CHECK_REL" current="$SHADOW" part
  while [[ "$relative" == */* ]]; do
    part=${relative%%/*}; relative=${relative#*/}; current="$current/$part"
    [ -d "$current" ] && [ ! -L "$current" ] || return 1
  done
  [ ! -L "$current/$relative" ] && { [ ! -e "$current/$relative" ] || [ -f "$current/$relative" ]; }
}
validate_check_slot || { echo "supervisor-commit: candidate check path is unsafe" >&2; exit 1; }
CHECK_SHADOW_PARENT=$(dirname -- "$CHECK_SHADOW")
CHECK_SHADOW_TMP=$(mktemp "$CHECK_SHADOW_PARENT/.saas-check.XXXXXX") || {
  echo "supervisor-commit: could not claim the candidate check slot" >&2; exit 1; }
if ! $REAL_GIT -C "$SHADOW" show "$BASE_HEAD:$CHECK_REL" > "$CHECK_SHADOW_TMP"; then
  rm -f -- "$CHECK_SHADOW_TMP"
  echo "supervisor-commit: could not materialize the trusted check" >&2
  exit 1
fi
validate_check_slot || {
  rm -f -- "$CHECK_SHADOW_TMP"
  echo "supervisor-commit: candidate check path became unsafe" >&2
  exit 1
}
mv -fT -- "$CHECK_SHADOW_TMP" "$CHECK_SHADOW" || {
  rm -f -- "$CHECK_SHADOW_TMP"
  echo "supervisor-commit: could not publish the trusted check safely" >&2
  exit 1
}
case "$CHECK_MODE" in 100755) chmod 500 "$CHECK_SHADOW" ;; 100644) chmod 400 "$CHECK_SHADOW" ;; esac
PRE_CHECK_DIFF=$($REAL_GIT -C "$SHADOW" diff --binary --no-ext-diff --no-textconv | $REAL_GIT hash-object --stdin)
PRE_CHECK_STATUS=$($REAL_GIT -C "$SHADOW" status --porcelain=v1 --untracked-files=no | $REAL_GIT hash-object --stdin)
PRE_CHECK_BOUNDARY="$({ $REAL_GIT -C "$SHADOW" rev-parse HEAD;
  $REAL_GIT -C "$SHADOW" for-each-ref --format='%(refname) %(objectname)';
  $REAL_GIT -C "$SHADOW" config --local --list; } | $REAL_GIT hash-object --stdin)"

CHECK_RC=0
CHECKOUT_ALIAS=$ROOT
[ "${#CHECK_RUNTIME_SOURCES[@]}" -eq 0 ] || CHECKOUT_ALIAS=$PRIMARY_CHECKOUT
CHECK_SANDBOX=("$CHECK_DRIVER_PATH" -C "$SHADOW" \
  --docker-bin "$(jq -r '.docker.path' <<<"$CHECK_BACKEND")" \
  --image-id "$(jq -r '.image_id' <<<"$CHECK_BACKEND")" \
  --daemon-id "$(jq -r '.daemon_id' <<<"$CHECK_BACKEND")" \
  --checkout-alias "$CHECKOUT_ALIAS")
for ((i=0; i<${#CHECK_RUNTIME_SOURCES[@]}; i++)); do
  CHECK_SANDBOX+=(--runtime "${CHECK_RUNTIME_SOURCES[$i]}" \
    "${CHECK_RUNTIME_TARGETS[$i]}" "${CHECK_RUNTIME_DIGESTS[$i]}")
done
CHECK_SANDBOX+=(-- /bin/bash "/dev/shm/saas-check/$CHECK_REL")
prepare_check_log || exit 1
run_bounded_check || exit 1
prune_check_logs || {
  echo "supervisor-commit: check log retention failed" >&2; exit 1; }
check_runtimes_unchanged || {
  echo "supervisor-commit: sealed check runtime changed during deterministic checks" >&2; exit 1; }
verify_check_driver_receipt || {
  echo "supervisor-commit: trusted private-container check runtime changed during deterministic checks" >&2; exit 1; }
[ "$($REAL_GIT -C "$SHADOW" diff --binary --no-ext-diff --no-textconv | $REAL_GIT hash-object --stdin)" = "$PRE_CHECK_DIFF" ] \
  && [ "$($REAL_GIT -C "$SHADOW" status --porcelain=v1 --untracked-files=no | $REAL_GIT hash-object --stdin)" = "$PRE_CHECK_STATUS" ] || {
    echo "supervisor-commit: checks changed the isolated candidate tree" >&2; exit 1; }
[ "$({ $REAL_GIT -C "$SHADOW" rev-parse HEAD;
  $REAL_GIT -C "$SHADOW" for-each-ref --format='%(refname) %(objectname)';
  $REAL_GIT -C "$SHADOW" config --local --list; } | $REAL_GIT hash-object --stdin)" = "$PRE_CHECK_BOUNDARY" ] || {
    echo "supervisor-commit: checks changed the isolated Git boundary" >&2; exit 1; }
if [ "$CHECK_RC" -ne 0 ]; then
  [ -z "$CHECK_LIMIT_REASON" ] \
    || printf 'supervisor-commit: %s; retained evidence is bounded\n' "$CHECK_LIMIT_REASON" >&2
  printf 'supervisor-commit: deterministic checks failed (full log: %s)\n' "$CHECK_LOG" >&2
  if [ -s "$CHECK_LOG" ]; then
    echo "supervisor-commit: check output (tail)" >&2
    emit_bounded_check_log >&2
  fi
  exit 1
fi

validate_check_slot || { echo "supervisor-commit: checks made the check path unsafe" >&2; exit 1; }
if $REAL_GIT -C "$SHADOW" ls-files --error-unmatch "$CHECK_REL" >/dev/null 2>&1; then
  $REAL_GIT -C "$SHADOW" checkout-index -f -- "$CHECK_REL"
else
  rm -f -- "$SHADOW/$CHECK_REL"
fi
if [ "$CHECK_ONLY" -eq 0 ]; then
[ -d "$SHADOW/.git" ] && [ ! -L "$SHADOW/.git" ] || {
  echo "supervisor-commit: isolated Git directory became unsafe" >&2; exit 1; }
rm -rf -- "$FROZEN_HOOKS"
[ ! -e "$FROZEN_HOOKS" ] && [ ! -L "$FROZEN_HOOKS" ] || {
  echo "supervisor-commit: could not clear isolated hook slot" >&2; exit 1; }
mkdir -m 700 -- "$FROZEN_HOOKS"
cp -pPR "$TRUST_HOOKS/." "$FROZEN_HOOKS/"
[ "$(hooks_fingerprint "$FROZEN_HOOKS")" = "$(jq -r .hooks_fingerprint "$TRUST_RECEIPT")" ] || {
  echo "supervisor-commit: frozen hook copy mismatch" >&2; exit 1; }
$REAL_GIT -C "$SHADOW" config user.name "$( $REAL_GIT config user.name || echo 'Delivery Supervisor' )"
$REAL_GIT -C "$SHADOW" config user.email "$( $REAL_GIT config user.email || echo 'supervisor@example.invalid' )"
HOOK_BOUNDARY_BEFORE="$({ $REAL_GIT -C "$SHADOW" for-each-ref --format='%(refname) %(objectname)';
  $REAL_GIT -C "$SHADOW" config --local --list; } | $REAL_GIT hash-object --stdin)"

# The sandbox denies .git writes, so the frozen product hooks run explicitly
# inside it (credentialless, network-off, in git's commit order) while the
# trusted git binary creates the commit outside (issues #260/#261). A hook
# that needs to write Git metadata fails the delivery instead of escaping the
# sandbox; the tree checks below reject any index drift regardless.
run_frozen_hook() {
  local hook="$1"; shift
  [ -f "$FROZEN_HOOKS/$hook" ] && [ -x "$FROZEN_HOOKS/$hook" ] || return 0
  sandbox_exec "$SHADOW" /usr/bin/env GIT_DIR=.git GIT_EDITOR=: "$FROZEN_HOOKS/$hook" "$@"
}
HOOK_RC=0
set +e
run_frozen_hook pre-commit
HOOK_RC=$?
set -e
[ "$HOOK_RC" -eq 0 ] || { echo "supervisor-commit: isolated product hooks failed" >&2; exit 1; }
# The message lives in the shadow's Git metadata like git's own
# COMMIT_EDITMSG, so hooks never see an extra worktree file and no repository
# path can collide with it. The supervisor writes it outside the sandbox;
# hooks read it inside (metadata is sandbox-readable). A hook that edits the
# message needs a metadata write and fails by policy, like any other
# in-sandbox Git metadata mutation.
MSG_FILE="$SHADOW/.git/supervisor-commit-msg"
rm -rf -- "$MSG_FILE"
[ ! -e "$MSG_FILE" ] && [ ! -L "$MSG_FILE" ] || {
  echo "supervisor-commit: commit message slot is unsafe" >&2; exit 1; }
printf '%s\n' "$MESSAGE" > "$MSG_FILE"
HOOK_RC=0
set +e
run_frozen_hook prepare-commit-msg .git/supervisor-commit-msg message \
  && run_frozen_hook commit-msg .git/supervisor-commit-msg
HOOK_RC=$?
set -e
[ "$HOOK_RC" -eq 0 ] || { echo "supervisor-commit: isolated product hooks failed" >&2; exit 1; }
[ "$($REAL_GIT -C "$SHADOW" write-tree)" = "$CHECKED_TREE" ] || {
  echo "supervisor-commit: product hooks changed the staged candidate tree" >&2; exit 1; }
[ -f "$MSG_FILE" ] && [ ! -L "$MSG_FILE" ] || {
  echo "supervisor-commit: commit message slot became unsafe" >&2; exit 1; }
trusted_shadow_git commit -q -F "$MSG_FILE" || {
  echo "supervisor-commit: isolated candidate commit failed" >&2; exit 1; }
rm -f -- "$MSG_FILE"
run_frozen_hook post-commit || true
SHADOW_COMMIT=$($REAL_GIT -C "$SHADOW" rev-parse HEAD)
[ "$($REAL_GIT -C "$SHADOW" rev-parse 'HEAD^{tree}')" = "$CHECKED_TREE" ] || {
  echo "supervisor-commit: product hooks changed the checked tree" >&2; exit 1; }
PARENT_LINE=$($REAL_GIT -C "$SHADOW" rev-list --parents -n 1 "$SHADOW_COMMIT")
[ "$(wc -w <<< "$PARENT_LINE")" -eq 2 ] && [ "${PARENT_LINE#* }" = "$BASE_HEAD" ] || {
  echo "supervisor-commit: product hooks changed the commit parent" >&2; exit 1; }
[ "$({ $REAL_GIT -C "$SHADOW" for-each-ref --format='%(refname) %(objectname)';
  $REAL_GIT -C "$SHADOW" config --local --list; } | $REAL_GIT hash-object --stdin)" = "$HOOK_BOUNDARY_BEFORE" ] || {
    echo "supervisor-commit: product hooks changed the isolated Git boundary" >&2; exit 1; }
[ "$(hooks_fingerprint "$FROZEN_HOOKS")" = "$(jq -r .hooks_fingerprint "$TRUST_RECEIPT")" ] || {
  echo "supervisor-commit: product hooks changed the frozen hook set" >&2; exit 1; }

fi

CURRENT_HOOK_SOURCE_AFTER=$(resolve_hook_source) || {
  echo "supervisor-commit: configured hook source became unsafe during checks" >&2; exit 1; }
[ "$CURRENT_HOOK_SOURCE_AFTER" = "$CURRENT_HOOK_SOURCE" ] || {
  echo "supervisor-commit: configured hook source changed identity" >&2; exit 1; }
if [ "$(jq -r .require_approved_diff "$TRUST_RECEIPT")" = true ]; then
  [ "$(hooks_fingerprint "$TRUST_FIREWALL")" = "$(jq -r .firewall_fingerprint "$TRUST_RECEIPT")" ] || {
    echo "supervisor-commit: frozen firewall changed during checks" >&2; exit 1; }
fi
verify_receipt_auth "$TRUST_RECEIPT" \
  && [ "$(head_ref)" = "$ACTIVE_REF" ] \
  && receipt_refs_intact \
  && [ "$(config_fingerprint)" = "$(jq -r .config_fingerprint "$TRUST_RECEIPT")" ] \
  && [ "$(metadata_fingerprint)" = "$(jq -r .metadata_fingerprint "$TRUST_RECEIPT")" ] \
  && [ "$(hooks_fingerprint "$TRUST_HOOKS")" = "$(jq -r .hooks_fingerprint "$TRUST_RECEIPT")" ] \
  && [ "$(hooks_fingerprint "$CURRENT_HOOK_SOURCE_AFTER")" = "$(jq -r .hook_source_fingerprint "$TRUST_RECEIPT")" ] || {
    echo "supervisor-commit: authenticated trust boundary changed during checks" >&2
    exit 1
  }

$REAL_GIT status --porcelain=v1 --untracked-files=all > "$AFTER_STATUS"
BOUNDARY_AFTER="$(primary_boundary_fingerprint)"
cmp -s "$BEFORE_STATUS" "$AFTER_STATUS" && [ "$($REAL_GIT write-tree)" = "$PRIMARY_INDEX_TREE" ] \
  && [ "$BOUNDARY_AFTER" = "$BOUNDARY_BEFORE" ] \
  && [ "$(workspace_fingerprint)" = "$PRIMARY_WORKSPACE_FINGERPRINT" ] || {
    echo "supervisor-commit: isolated gates changed the delivery workspace" >&2; exit 1; }

if [ "$CHECK_ONLY" -eq 1 ]; then
  consume_receipt
  printf 'supervisor-commit: base checks passed (full log: %s)\n' "$CHECK_LOG"
  exit 0
fi

printf 'supervisor-commit: deterministic checks passed (full log: %s)\n' "$CHECK_LOG"

printf '%s\n' "$SHADOW_COMMIT" | $REAL_GIT -C "$SHADOW" pack-objects --stdout --revs > "$PACK_FILE"
$REAL_GIT index-pack --stdin < "$PACK_FILE" >/dev/null
$REAL_GIT cat-file -e "$SHADOW_COMMIT^{commit}" || {
  echo "supervisor-commit: isolated object import failed" >&2; exit 1; }
$REAL_GIT -c core.fsmonitor=false -c core.hooksPath=/dev/null \
  update-ref -m "supervisor commit" HEAD "$SHADOW_COMMIT" "$BASE_HEAD"
if ! $REAL_GIT -c core.fsmonitor=false -c core.hooksPath=/dev/null read-tree "$CHECKED_TREE"; then
  $REAL_GIT -c core.fsmonitor=false -c core.hooksPath=/dev/null \
    update-ref -m "supervisor commit rollback" HEAD "$BASE_HEAD" "$SHADOW_COMMIT" || true
  echo "supervisor-commit: could not align the primary index" >&2
  exit 1
fi
consume_receipt
echo "supervisor-commit: committed $($REAL_GIT rev-parse --short HEAD)"
