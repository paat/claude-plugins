#!/usr/bin/env bash
# Snapshot trusted commit hooks before a worker, then check and commit in isolation.
set -euo pipefail

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
MESSAGE=""
CHECK="./check.sh"
ROOT=""
TRUST_RECEIPT=""
AUTH_TOKEN=""
AUTH_STDIN=0
REQUIRE_APPROVED_DIFF=0
FIREWALL_SCRIPT=""
ALLOW=()

usage() {
  echo "usage: supervisor-commit.sh --snapshot-trust FILE --auth-stdin --allow PATH... [--require-approved-diff --firewall-script FILE] [--repo-root DIR]" >&2
  echo "       supervisor-commit.sh --message TEXT --trust-receipt FILE --auth-stdin [--check PATH] [--repo-root DIR]" >&2
  exit 2
}
need_value() { [ "$#" -ge 2 ] || usage; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot-trust) need_value "$@"; ACTION=snapshot; TRUST_RECEIPT=$2; shift 2 ;;
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

refs_fingerprint() {
  $REAL_GIT for-each-ref --format='%(refname)%00%(objectname)%00%(symref)' \
    | $REAL_GIT hash-object --stdin
}

head_ref() {
  $REAL_GIT symbolic-ref -q HEAD 2>/dev/null || true
}

hooks_fingerprint() {
  local dir="$1" tmp path rel mode oid result failed=0 old_shopt
  tmp=$(mktemp)
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    old_shopt=$(shopt -p dotglob nullglob globstar || true)
    shopt -s dotglob nullglob globstar
    for path in "$dir"/**; do
      rel=${path#"$dir"/}
      if [ -d "$path" ] && [ ! -L "$path" ]; then continue
      elif [ -f "$path" ] && [ ! -L "$path" ]; then
        if [ -x "$path" ]; then mode=100755; else mode=100644; fi
        oid=$($REAL_GIT hash-object --no-filters -- "$path" 2>/dev/null || echo unreadable)
      else
        failed=1; break
      fi
      printf '%s\0%s\0%s\0' "$rel" "$mode" "$oid" >> "$tmp"
    done
    eval "$old_shopt"
    [ "$failed" -eq 0 ] || { rm -f "$tmp"; return 1; }
  elif [ -e "$dir" ] || [ -L "$dir" ]; then
    rm -f "$tmp"; return 1
  fi
  result=$($REAL_GIT hash-object --no-filters "$tmp")
  rm -f "$tmp"
  printf '%s\n' "$result"
}

config_fingerprint() {
  trusted_git config --null --list --show-origin --show-scope | $REAL_GIT hash-object --stdin
}

metadata_fingerprint() {
  local tmp entry kind key path mode oid result
  tmp=$(mktemp)
  for entry in attributes:info/attributes exclude:info/exclude \
    commondir:commondir gitdir:gitdir head:HEAD config-worktree:config.worktree; do
    kind=${entry%%:*}; key=${entry#*:}
    path=$($REAL_GIT rev-parse --git-path "$key")
    case "$path" in /*) : ;; *) path="$ROOT/$path" ;; esac
    if [ -L "$path" ]; then rm -f "$tmp"; return 1
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      oid=$($REAL_GIT hash-object --no-filters -- "$path")
    elif [ -e "$path" ]; then rm -f "$tmp"; return 1
    else mode=missing; oid=missing
    fi
    printf '%s\0%s\0%s\0' "$kind" "$mode" "$oid" >> "$tmp"
  done
  result=$($REAL_GIT hash-object --no-filters "$tmp")
  rm -f "$tmp"
  printf '%s\n' "$result"
}

resolve_hook_source() {
  local configured source parent base
  configured=$(trusted_git config --path core.hooksPath 2>/dev/null || true)
  if [ -n "$configured" ]; then
    case "$configured" in /*) source=$configured ;; *) source="$ROOT/$configured" ;; esac
  else
    source=$(trusted_git rev-parse --git-path hooks)
    case "$source" in /*) : ;; *) source="$ROOT/$source" ;; esac
  fi
  parent=$(dirname -- "$source"); base=$(basename -- "$source")
  [ -d "$parent" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
  parent=$(cd "$parent" && pwd -P); source="$parent/$base"
  [ ! -L "$source" ] || return 1
  if [ -e "$source" ] && [ ! -d "$source" ]; then return 1; fi
  if [ -d "$source" ] && find "$source" -type l -print -quit | grep -q .; then return 1; fi
  printf '%s\n' "$source"
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

snapshot_trust() {
  local receipt hooks_copy firewall_copy source base hash source_hash firewall_hash=null config_hash metadata_hash
  local source_rel=null old_umask ref refs_hash allow_json path receipt_tmp firewall_parent firewall_source
  [ -n "$TRUST_RECEIPT" ] && [ -z "$MESSAGE" ] || usage
  valid_auth_token "$AUTH_TOKEN" || { echo "supervisor-commit: invalid authentication token" >&2; exit 2; }
  if [ "$REQUIRE_APPROVED_DIFF" -eq 1 ]; then
    [ -n "$FIREWALL_SCRIPT" ] || { echo "supervisor-commit: required diff approval needs --firewall-script" >&2; exit 2; }
  elif [ -n "$FIREWALL_SCRIPT" ]; then
    echo "supervisor-commit: --firewall-script requires --require-approved-diff" >&2; exit 2
  fi
  [ "${#ALLOW[@]}" -gt 0 ] || { echo "supervisor-commit: at least one exact --allow path is required" >&2; exit 2; }
  for path in "${ALLOW[@]}"; do
    valid_repo_path "$path" || { printf 'supervisor-commit: invalid allowed path: %q\n' "$path" >&2; exit 2; }
    is_local_only "$path" && { printf 'supervisor-commit: local runtime state cannot be allowed: %q\n' "$path" >&2; exit 2; }
  done
  receipt=$(receipt_path "$TRUST_RECEIPT") || exit 2
  hooks_copy="${receipt}.hooks"
  firewall_copy="${receipt}.firewall"
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] \
    && [ ! -e "$hooks_copy" ] && [ ! -L "$hooks_copy" ] \
    && [ ! -e "$firewall_copy" ] && [ ! -L "$firewall_copy" ] || {
    echo "supervisor-commit: trust receipt already exists" >&2; exit 1; }
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
  refs_hash=$(refs_fingerprint)
  allow_json=$(printf '%s\n' "${ALLOW[@]}" | LC_ALL=C sort -u | jq -R . | jq -s .)
  old_umask=$(umask); umask 077
  receipt_tmp=$(mktemp "${receipt}.unsigned.XXXXXX")
  jq -n --arg base "$base" --arg hash "$hash" --arg config_hash "$config_hash" \
    --arg metadata_hash "$metadata_hash" --argjson source_rel "$source_rel" \
    --arg head_ref "$ref" --arg refs "$refs_hash" --argjson allow "$allow_json" \
    --argjson require_approved "$REQUIRE_APPROVED_DIFF" --argjson firewall_hash "$firewall_hash" \
    --arg source_hash "$source_hash" \
    '{schema_version:2,base_head:$base,head_ref:$head_ref,refs_fingerprint:$refs,
      hooks_fingerprint:$hash,hook_source_fingerprint:$source_hash,
      config_fingerprint:$config_hash,metadata_fingerprint:$metadata_hash,
      hook_source_rel:$source_rel,allow:$allow,
      require_approved_diff:($require_approved == 1),firewall_fingerprint:$firewall_hash,
      auth_tag:null}' > "$receipt_tmp"
  mv -- "$receipt_tmp" "$receipt"
  sign_receipt "$receipt"
  umask "$old_umask"
  printf '%s\n' "$receipt"
}

if [ "$ACTION" = snapshot ]; then snapshot_trust; exit; fi
[ "$ACTION" = commit ] && [ -n "$TRUST_RECEIPT" ] && [ -n "$MESSAGE" ] \
  && [ "${#ALLOW[@]}" -eq 0 ] && [ "$REQUIRE_APPROVED_DIFF" -eq 0 ] \
  && [ -z "$FIREWALL_SCRIPT" ] || usage
valid_auth_token "$AUTH_TOKEN" || { echo "supervisor-commit: invalid authentication token" >&2; exit 2; }
TRUST_RECEIPT=$(receipt_path "$TRUST_RECEIPT") || exit 2
TRUST_HOOKS="${TRUST_RECEIPT}.hooks"
TRUST_FIREWALL="${TRUST_RECEIPT}.firewall"
[ -f "$TRUST_RECEIPT" ] && [ ! -L "$TRUST_RECEIPT" ] && [ -d "$TRUST_HOOKS" ] && [ ! -L "$TRUST_HOOKS" ] || {
  echo "supervisor-commit: trusted hook receipt is missing" >&2; exit 1; }
jq -e '.schema_version == 2 and (.base_head|type == "string") and
  (.head_ref|type == "string") and (.refs_fingerprint|type == "string") and
  (.hooks_fingerprint|type == "string") and (.hook_source_fingerprint|type == "string") and
  (.config_fingerprint|type == "string") and (.metadata_fingerprint|type == "string") and
  (.hook_source_rel == null or (.hook_source_rel|type == "string")) and
  (.allow|type == "array" and length > 0 and all(.[]; type == "string")) and
  (.require_approved_diff|type == "boolean") and
  (.firewall_fingerprint == null or (.firewall_fingerprint|type == "string")) and
  ((.require_approved_diff == true and (.firewall_fingerprint|type == "string")) or
   (.require_approved_diff == false and .firewall_fingerprint == null)) and
  (.auth_tag|type == "string")' "$TRUST_RECEIPT" >/dev/null || {
  echo "supervisor-commit: malformed trust receipt" >&2; exit 1; }
verify_receipt_auth "$TRUST_RECEIPT" || {
  echo "supervisor-commit: trust receipt authentication failed" >&2; exit 1; }
BASE_HEAD=$(jq -r .base_head "$TRUST_RECEIPT")
[ "$($REAL_GIT rev-parse HEAD)" = "$BASE_HEAD" ] || {
  echo "supervisor-commit: trust receipt base no longer matches HEAD" >&2; exit 1; }
[ "$(head_ref)" = "$(jq -r .head_ref "$TRUST_RECEIPT")" ] || {
  echo "supervisor-commit: active branch changed after trust snapshot" >&2; exit 1; }
[ "$(refs_fingerprint)" = "$(jq -r .refs_fingerprint "$TRUST_RECEIPT")" ] || {
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

LOCK_FILE="$COMMON_DIR/saas-startup-team-supervisor.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "supervisor-commit: another supervisor commit is active" >&2; exit 1; }

mapfile -t ALLOW < <(jq -r '.allow[]' "$TRUST_RECEIPT")
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

workspace_fingerprint() {
  local tmp path mode oid result
  tmp=$(mktemp)
  while IFS= read -r -d '' path; do
    is_local_only "$path" && continue
    if [ -L "$path" ]; then
      mode=120000; oid=$(readlink "$path" | $REAL_GIT hash-object --stdin)
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      oid=$($REAL_GIT hash-object --no-filters -- "$path" 2>/dev/null || echo unreadable)
    elif [ -d "$path" ]; then mode=040000; oid=directory
    elif [ -e "$path" ]; then mode=unsupported; oid=unreadable
    else mode=missing; oid=missing
    fi
    printf '%s\0%s\0%s\0' "$path" "$mode" "$oid" >> "$tmp"
  done < <($REAL_GIT -c core.fsmonitor=false ls-files --cached --others --exclude-standard -z -- .)
  result=$($REAL_GIT hash-object --no-filters "$tmp")
  rm -f "$tmp"
  printf '%s\n' "$result"
}

if [ -n "$($REAL_GIT -c core.fsmonitor=false ls-files --unmerged)" ]; then
  echo "supervisor-commit: unmerged index entries are not supported" >&2; exit 1
fi
PRIMARY_WORKSPACE_FINGERPRINT=$(workspace_fingerprint)
if [ "$($REAL_GIT config --bool core.sparseCheckout 2>/dev/null || echo false)" = true ]; then
  echo "supervisor-commit: sparse checkouts require a dedicated delivery path" >&2; exit 1
fi

consume_receipt() {
  chmod -R u+w "$TRUST_HOOKS" 2>/dev/null || true
  chmod -R u+w "$TRUST_FIREWALL" 2>/dev/null || true
  rm -rf -- "$TRUST_HOOKS"
  rm -rf -- "$TRUST_FIREWALL"
  rm -f -- "$TRUST_RECEIPT"
}

declare -A CANDIDATE_PATHS=() BASE_GITLINKS=() INDEX_GITLINKS=() INDEX_MODES=()
while IFS= read -r -d '' record; do
  meta=${record%%$'\t'*}; path=${record#*$'\t'}; mode=${meta%% *}; oid=${meta##* }
  CANDIDATE_PATHS["$path"]=1
  [ "$mode" != 160000 ] || BASE_GITLINKS["$path"]=$oid
done < <($REAL_GIT ls-tree -r -z HEAD)
while IFS= read -r -d '' record; do
  meta=${record%%$'\t'*}; path=${record#*$'\t'}; mode=${meta%% *}
  rest=${meta#* }; oid=${rest%% *}; stage=${meta##* }
  [ "$stage" = 0 ] || { echo "supervisor-commit: unmerged index entry" >&2; exit 1; }
  CANDIDATE_PATHS["$path"]=1
  INDEX_MODES["$path"]=$mode
  [ "$mode" != 160000 ] || INDEX_GITLINKS["$path"]=$oid
done < <($REAL_GIT -c core.fsmonitor=false ls-files --stage -z)
while IFS= read -r -d '' path; do
  CANDIDATE_PATHS["$path"]=1
done < <($REAL_GIT -c core.fsmonitor=false ls-files --others --exclude-standard -z)

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
SANDBOX_HOME=$(mktemp -d)
CHECK_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/saas-supervisor-check.XXXXXX")
SHADOW="$CHECK_PARENT/worktree"
FROZEN_HOOKS="$SHADOW/.git/supervisor-hooks"
cleanup() {
  rm -f "$BEFORE_STATUS" "$AFTER_STATUS" "$PACK_FILE" "$CANDIDATE_DIFF"
  chmod -R u+w "$CHECK_PARENT" 2>/dev/null || true
  rm -rf "$SANDBOX_HOME" "$CHECK_PARENT"
}
trap cleanup EXIT

$REAL_GIT clone -q --no-local "$ROOT" "$SHADOW"
$REAL_GIT -C "$SHADOW" checkout -q --detach "$BASE_HEAD"

ATTRIBUTES_FILE=$($REAL_GIT rev-parse --git-path info/attributes)
case "$ATTRIBUTES_FILE" in /*) : ;; *) ATTRIBUTES_FILE="$ROOT/$ATTRIBUTES_FILE" ;; esac
if [ -s "$ATTRIBUTES_FILE" ]; then
  echo "supervisor-commit: info/attributes requires a dedicated trusted staging path" >&2
  exit 1
fi
if [ -n "$($REAL_GIT config --path core.attributesFile 2>/dev/null || true)" ]; then
  echo "supervisor-commit: core.attributesFile requires a dedicated trusted staging path" >&2
  exit 1
fi
for staging_key in core.autocrlf core.eol core.safecrlf core.fileMode core.symlinks \
  core.ignoreCase core.precomposeUnicode; do
  if staging_value=$($REAL_GIT config --get "$staging_key" 2>/dev/null); then
    $REAL_GIT -C "$SHADOW" config "$staging_key" "$staging_value"
  else
    $REAL_GIT -C "$SHADOW" config --unset-all "$staging_key" 2>/dev/null || true
  fi
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
  if [[ -v INDEX_GITLINKS["$path"] ]] \
    || { [[ -v BASE_GITLINKS["$path"] ]] && [[ ! -v INDEX_MODES["$path"] ]]; }; then continue; fi
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
BOUNDARY_BEFORE="$({ $REAL_GIT rev-parse HEAD; $REAL_GIT for-each-ref --format='%(refname) %(objectname)'; $REAL_GIT config --local --list; } \
  | $REAL_GIT hash-object --stdin)"

CODEX_BIN=$(command -v codex 2>/dev/null) || {
  echo "supervisor-commit: Codex sandbox is required for credentialless network-off checks" >&2; exit 1; }
SANDBOX_HELP=$($CODEX_BIN sandbox --help 2>/dev/null) || {
  echo "supervisor-commit: Codex sandbox is unavailable" >&2; exit 1; }
grep -q -- '--permission-profile' <<< "$SANDBOX_HELP" \
  && grep -q -- '--sandbox-state-disable-network' <<< "$SANDBOX_HELP" || {
    echo "supervisor-commit: required Codex sandbox controls are unavailable" >&2; exit 1; }
mkdir -p "$SANDBOX_HOME/codex" "$SANDBOX_HOME/config" "$SANDBOX_HOME/data"

sandbox_exec() {
  local cwd="$1"; shift
  env -i PATH="$PATH" HOME="$SANDBOX_HOME" CODEX_HOME="$SANDBOX_HOME/codex" \
    XDG_CONFIG_HOME="$SANDBOX_HOME/config" XDG_DATA_HOME="$SANDBOX_HOME/data" \
    USER="${USER:-supervisor}" TERM="${TERM:-dumb}" CI=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=/bin/false \
    "$CODEX_BIN" sandbox --permission-profile :workspace --sandbox-state-disable-network -C "$cwd" "$@"
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
  {
    IFS= read -r -d '' attr_path || true
    IFS= read -r -d '' attr_name || true
    IFS= read -r -d '' attr_value || true
  } < <($REAL_GIT -C "$SHADOW" check-attr -z filter -- "$path")
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
  if [[ -v INDEX_GITLINKS["$path"] ]]; then
    $REAL_GIT -C "$SHADOW" update-index --add --cacheinfo "160000,${INDEX_GITLINKS[$path]},$path"
  elif [[ ! -v INDEX_MODES["$path"] ]]; then
    $REAL_GIT -C "$SHADOW" update-index --force-remove -- "$path"
  fi
done

CHECKED_TREE=$($REAL_GIT -C "$SHADOW" write-tree)
$REAL_GIT -C "$SHADOW" diff --cached --binary --no-ext-diff --no-textconv \
  "$BASE_HEAD" -- > "$CANDIDATE_DIFF"
DIFF_HASH=$(openssl dgst -sha256 "$CANDIDATE_DIFF" | awk '{print $NF}')
if [ "$CHECKED_TREE" = "$($REAL_GIT rev-parse 'HEAD^{tree}')" ]; then
  echo "supervisor-commit: no delivery diff to commit"
  consume_receipt
  exit 0
fi
if [ "$(jq -r .require_approved_diff "$TRUST_RECEIPT")" = true ]; then
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
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
(cd "$SHADOW" && bash "$SCRIPT_DIR/check-staged-size.sh")
HOOK_SOURCE_REL=$(jq -r '.hook_source_rel // empty' "$TRUST_RECEIPT")
if [ -n "$HOOK_SOURCE_REL" ] && ! $REAL_GIT -C "$SHADOW" diff --cached --quiet "$BASE_HEAD" -- "$HOOK_SOURCE_REL"; then
  echo "supervisor-commit: active hook changes require a separate trusted maintenance path" >&2
  exit 1
fi

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
rm -f -- "$CHECK_SHADOW"
$REAL_GIT -C "$SHADOW" show "$BASE_HEAD:$CHECK_REL" > "$CHECK_SHADOW"
case "$CHECK_MODE" in 100755) chmod 500 "$CHECK_SHADOW" ;; 100644) chmod 400 "$CHECK_SHADOW" ;; esac
PRE_CHECK_DIFF=$($REAL_GIT -C "$SHADOW" diff --binary --no-ext-diff --no-textconv | $REAL_GIT hash-object --stdin)
PRE_CHECK_STATUS=$($REAL_GIT -C "$SHADOW" status --porcelain=v1 --untracked-files=no | $REAL_GIT hash-object --stdin)
PRE_CHECK_BOUNDARY="$({ $REAL_GIT -C "$SHADOW" rev-parse HEAD;
  $REAL_GIT -C "$SHADOW" for-each-ref --format='%(refname) %(objectname)';
  $REAL_GIT -C "$SHADOW" config --local --list; } | $REAL_GIT hash-object --stdin)"

CHECK_RC=0
set +e
sandbox_exec "$SHADOW" /bin/bash "$CHECK_SHADOW"
CHECK_RC=$?
set -e
[ "$CHECK_RC" -eq 0 ] || { echo "supervisor-commit: deterministic checks failed" >&2; exit 1; }
[ "$($REAL_GIT -C "$SHADOW" diff --binary --no-ext-diff --no-textconv | $REAL_GIT hash-object --stdin)" = "$PRE_CHECK_DIFF" ] \
  && [ "$($REAL_GIT -C "$SHADOW" status --porcelain=v1 --untracked-files=no | $REAL_GIT hash-object --stdin)" = "$PRE_CHECK_STATUS" ] || {
    echo "supervisor-commit: checks changed the isolated candidate tree" >&2; exit 1; }
[ "$({ $REAL_GIT -C "$SHADOW" rev-parse HEAD;
  $REAL_GIT -C "$SHADOW" for-each-ref --format='%(refname) %(objectname)';
  $REAL_GIT -C "$SHADOW" config --local --list; } | $REAL_GIT hash-object --stdin)" = "$PRE_CHECK_BOUNDARY" ] || {
    echo "supervisor-commit: checks changed the isolated Git boundary" >&2; exit 1; }

validate_check_slot || { echo "supervisor-commit: checks made the check path unsafe" >&2; exit 1; }
if $REAL_GIT -C "$SHADOW" ls-files --error-unmatch "$CHECK_REL" >/dev/null 2>&1; then
  $REAL_GIT -C "$SHADOW" checkout-index -f -- "$CHECK_REL"
else
  rm -f -- "$SHADOW/$CHECK_REL"
fi
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
# The message slot is written after pre-commit so that hook never sees the
# extra untracked file. A base tree could carry a symlink at this reserved
# name; clear the slot without following it, like the check slot above.
MSG_FILE="$SHADOW/.supervisor-check.commit-msg"
rm -rf -- "$MSG_FILE"
[ ! -e "$MSG_FILE" ] && [ ! -L "$MSG_FILE" ] || {
  echo "supervisor-commit: commit message slot is unsafe" >&2; exit 1; }
printf '%s\n' "$MESSAGE" > "$MSG_FILE"
HOOK_RC=0
set +e
run_frozen_hook prepare-commit-msg .supervisor-check.commit-msg message \
  && run_frozen_hook commit-msg .supervisor-check.commit-msg
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

CURRENT_HOOK_SOURCE_AFTER=$(resolve_hook_source) || {
  echo "supervisor-commit: configured hook source became unsafe during checks" >&2; exit 1; }
[ "$CURRENT_HOOK_SOURCE_AFTER" = "$CURRENT_HOOK_SOURCE" ] || {
  echo "supervisor-commit: configured hook source changed identity" >&2; exit 1; }
if [ "$(jq -r .require_approved_diff "$TRUST_RECEIPT")" = true ]; then
  [ "$(hooks_fingerprint "$TRUST_FIREWALL")" = "$(jq -r .firewall_fingerprint "$TRUST_RECEIPT")" ] || {
    echo "supervisor-commit: frozen firewall changed during checks" >&2; exit 1; }
fi
verify_receipt_auth "$TRUST_RECEIPT" \
  && [ "$(head_ref)" = "$(jq -r .head_ref "$TRUST_RECEIPT")" ] \
  && [ "$(refs_fingerprint)" = "$(jq -r .refs_fingerprint "$TRUST_RECEIPT")" ] \
  && [ "$(config_fingerprint)" = "$(jq -r .config_fingerprint "$TRUST_RECEIPT")" ] \
  && [ "$(metadata_fingerprint)" = "$(jq -r .metadata_fingerprint "$TRUST_RECEIPT")" ] \
  && [ "$(hooks_fingerprint "$TRUST_HOOKS")" = "$(jq -r .hooks_fingerprint "$TRUST_RECEIPT")" ] \
  && [ "$(hooks_fingerprint "$CURRENT_HOOK_SOURCE_AFTER")" = "$(jq -r .hook_source_fingerprint "$TRUST_RECEIPT")" ] || {
    echo "supervisor-commit: authenticated trust boundary changed during checks" >&2
    exit 1
  }

$REAL_GIT status --porcelain=v1 --untracked-files=all > "$AFTER_STATUS"
BOUNDARY_AFTER="$({ $REAL_GIT rev-parse HEAD; $REAL_GIT for-each-ref --format='%(refname) %(objectname)'; $REAL_GIT config --local --list; } \
  | $REAL_GIT hash-object --stdin)"
cmp -s "$BEFORE_STATUS" "$AFTER_STATUS" && [ "$($REAL_GIT write-tree)" = "$PRIMARY_INDEX_TREE" ] \
  && [ "$BOUNDARY_AFTER" = "$BOUNDARY_BEFORE" ] \
  && [ "$(workspace_fingerprint)" = "$PRIMARY_WORKSPACE_FINGERPRINT" ] || {
    echo "supervisor-commit: isolated gates changed the delivery workspace" >&2; exit 1; }

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
