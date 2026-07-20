#!/usr/bin/env bash
# Snapshot and verify the complete product working state around a review-only QA phase.
set -euo pipefail

unset GIT_CONFIG_PARAMETERS
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.hooksPath
export GIT_CONFIG_VALUE_1=/dev/null

ACTION=""; SNAPSHOT=""; ROOT=""; AUTH_TOKEN=""; AUTH_STDIN=0
ORIGIN_URL=""; ORIGIN_FETCH_REFSPEC=""; VERIFIED_ORIGIN_REFS_JSON=""
VERIFIED_REFS_FINGERPRINT=""; ALLOW=()
declare -A IGNORED_BASELINE=()
declare -A ORIGIN_REF_OID=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  echo "usage: delivery-mutation-guard.sh (--snapshot FILE|--verify FILE) --auth-stdin [--allow PATH] [--repo-root DIR]" >&2
}
need_value() { [ "$#" -ge 2 ] || { usage; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot) need_value "$@"; ACTION="snapshot"; SNAPSHOT="$2"; shift 2 ;;
    --verify) need_value "$@"; ACTION="verify"; SNAPSHOT="$2"; shift 2 ;;
    --auth-stdin) AUTH_STDIN=1; shift ;;
    --allow) need_value "$@"; ALLOW+=("${2%/}"); shift 2 ;;
    --repo-root) need_value "$@"; ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "delivery-mutation-guard: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$ACTION" ] && [ -n "$SNAPSHOT" ] || { usage; exit 2; }
[ "$AUTH_STDIN" -eq 1 ] || { usage; exit 2; }
IFS= read -r AUTH_TOKEN || {
  echo "delivery-mutation-guard: authentication token missing on stdin" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 2
ROOT="$(cd "$ROOT" && pwd -P)"; cd "$ROOT"
REAL_GIT="$(command -v git)"
case "$REAL_GIT" in /*) [ -x "$REAL_GIT" ] ;; *) false ;; esac || {
  echo "delivery-mutation-guard: trusted Git executable is unavailable" >&2; exit 2; }
GIT_DIR="$($REAL_GIT rev-parse --absolute-git-dir)"
GIT_DIR="$(cd "$GIT_DIR" && pwd -P)"
GUARD_DIR="$GIT_DIR/saas-startup-team"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_NO_REPLACE_OBJECTS=1
unset GIT_EXTERNAL_DIFF

trusted_git() {
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
    "$REAL_GIT" "$@"
}

valid_git_oid() { [[ "$1" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; }

resolve_snapshot_path() {
  local supplied="$1" resolved parent base
  case "$supplied" in /*) resolved="$supplied" ;; *) resolved="$ROOT/$supplied" ;; esac
  case "$resolved" in *$'\n'*|*$'\r'*|*$'\t'*|*/../*|*/./*) return 1 ;; esac
  parent="$(dirname -- "$resolved")"; base="$(basename -- "$resolved")"
  [ "$parent" = "$GUARD_DIR" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
  if [ ! -e "$GUARD_DIR" ] && [ ! -L "$GUARD_DIR" ]; then mkdir -m 700 -- "$GUARD_DIR"; fi
  [ -d "$GUARD_DIR" ] && [ ! -L "$GUARD_DIR" ] \
    && [ "$(cd "$GUARD_DIR" && pwd -P)" = "$GUARD_DIR" ] || return 1
  printf '%s\n' "$GUARD_DIR/$base"
}

SNAPSHOT="$(resolve_snapshot_path "$SNAPSHOT")" || {
  echo "delivery-mutation-guard: snapshot must use the dedicated Git guard directory" >&2
  exit 2
}

[[ "$AUTH_TOKEN" =~ ^[0-9a-f]{64}$ ]] || {
  echo "delivery-mutation-guard: invalid authentication token" >&2; exit 2; }

auth_tag() {
  jq -cS 'del(.auth_tag)' "$1" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$AUTH_TOKEN" \
    | awk '{print $NF}'
}

sign_snapshot() {
  local file="$1" tag tmp
  tag="$(auth_tag "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  jq --arg tag "$tag" '.auth_tag=$tag' "$file" > "$tmp"
  chmod 400 "$tmp"
  mv -f -- "$tmp" "$file"
}

head_ref() {
  git symbolic-ref -q HEAD 2>/dev/null || true
}

valid_live_origin_url() {
  local url="$1" lower
  [[ "$url" != *[[:space:]]* && "$url" != *[[:cntrl:]]* ]] || return 1
  lower=${url,,}
  [[ ! "$lower" =~ %([01][0-9a-f]|7f) ]] || return 1
  case "$url" in -*|*::*) return 1 ;; esac
  case "$url" in
    https://*) [[ "$url" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/.+ ]] ;;
    ssh://*) [[ "$url" =~ ^ssh://([A-Za-z0-9][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/.+ ]] ;;
    *:* ) [[ "$url" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*:.+ ]] ;;
    *) return 1 ;;
  esac
}

origin_tracking_ref() {
  local ref="$1" symref="$2"
  case "$ref" in refs/remotes/origin/*) : ;; *) return 1 ;; esac
  [ "$ref" != refs/remotes/origin/HEAD ] && [ -z "$symref" ]
}

origin_refs_json() {
  local raw entries ref oid symref result
  raw="$(mktemp)" || return 1
  entries="$(mktemp)" || { rm -f -- "$raw"; return 1; }
  git for-each-ref --format='%(refname)%09%(objectname)%09%(symref)' \
    refs/remotes/origin > "$raw" || { rm -f "$raw" "$entries"; return 1; }
  while IFS=$'\t' read -r ref oid symref; do
    origin_tracking_ref "$ref" "$symref" || continue
    jq -cn --arg ref "$ref" --arg oid "$oid" '{ref:$ref,oid:$oid}' >> "$entries" \
      || { rm -f -- "$raw" "$entries"; return 1; }
  done < "$raw"
  rm -f "$raw"
  result="$(jq -cs '
    sort_by(.ref)
    | select((map(.ref)|unique|length) == length)
    | select(all(.[];
        (.ref|type == "string" and startswith("refs/remotes/origin/") and . != "refs/remotes/origin/HEAD") and
        (.oid|type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))))' "$entries")" || {
    rm -f "$entries"; return 1; }
  rm -f "$entries"
  [ -n "$result" ] || return 1
  printf '%s\n' "$result" || return 1
}

load_origin_refs() {
  local json="$1" count i ref oid
  ORIGIN_REF_OID=()
  count="$(jq 'length' <<<"$json")" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  for ((i=0; i<count; i++)); do
    ref="$(jq -er ".[${i}].ref" <<<"$json")" || return 1
    oid="$(jq -er ".[${i}].oid" <<<"$json")" || return 1
    case "$ref" in refs/remotes/origin/*) : ;; *) return 1 ;; esac
    [ "$ref" != refs/remotes/origin/HEAD ] || return 1
    [[ "$oid" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
    [ -z "${ORIGIN_REF_OID[$ref]+present}" ] || return 1
    ORIGIN_REF_OID["$ref"]=$oid
  done
}

origin_refs_intact() {
  local current_json current_after count i ref oid live_file head line
  local -A current=() changed=() live=()
  current_json="$(origin_refs_json)" || return 1
  count="$(jq 'length' <<<"$current_json")" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  for ((i=0; i<count; i++)); do
    ref="$(jq -er ".[${i}].ref" <<<"$current_json")" || return 1
    oid="$(jq -er ".[${i}].oid" <<<"$current_json")" || return 1
    current["$ref"]=$oid
    [ -n "${ORIGIN_REF_OID[$ref]+present}" ] || return 1
    if [ "${ORIGIN_REF_OID[$ref]}" != "$oid" ]; then
      changed["$ref"]=$oid
    fi
  done
  for ref in "${!ORIGIN_REF_OID[@]}"; do
    [ -n "${current[$ref]+present}" ] || return 1
  done
  if [ "${#changed[@]}" -eq 0 ]; then
    VERIFIED_ORIGIN_REFS_JSON="$current_json"
    return 0
  fi
  [ "$ORIGIN_FETCH_REFSPEC" = '+refs/heads/*:refs/remotes/origin/*' ] || return 1
  valid_live_origin_url "$ORIGIN_URL" || return 1
  live_file="$(mktemp)" || return 1
  (unset GIT_DIR GIT_WORK_TREE GIT_EXEC_PATH GIT_PROXY_COMMAND GIT_SSH GIT_SSH_COMMAND \
      GIT_SSH_VARIANT GIT_ASKPASS SSH_ASKPASS SSH_ASKPASS_REQUIRE \
      GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
      GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
    cd /
    env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_TERMINAL_PROMPT=0 \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      timeout -k 5 30 "$REAL_GIT" -c protocol.ext.allow=never ls-remote --refs -- \
        "$ORIGIN_URL" 'refs/heads/*') > "$live_file" 2>/dev/null || {
    rm -f "$live_file"; return 1; }
  while IFS= read -r line; do
    oid=${line%%$'\t'*}; head=${line#*$'\t'}
    [[ "$oid" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] && [ "$head" != "$line" ] || {
      rm -f "$live_file"; return 1; }
    case "$head" in refs/heads/*) : ;; *) rm -f "$live_file"; return 1 ;; esac
    [ -z "${live[$head]+present}" ] || { rm -f "$live_file"; return 1; }
    live["$head"]=$oid
  done < "$live_file"
  for ref in "${!changed[@]}"; do
    head="refs/heads/${ref#refs/remotes/origin/}"
    [ -n "${live[$head]+present}" ] && [ "${live[$head]}" = "${changed[$ref]}" ] \
      || { rm -f "$live_file"; return 1; }
  done
  rm -f "$live_file"
  current_after="$(origin_refs_json)" || return 1
  [ "$current_after" = "$current_json" ] || return 1
  VERIFIED_ORIGIN_REFS_JSON="$current_after"
}

other_refs_fingerprint() {
  local active="$1" ref oid symref result
  result="$("$REAL_GIT" for-each-ref --format='%(refname)%09%(objectname)%09%(symref)' \
    | while IFS=$'\t' read -r ref oid symref; do
        [ "$ref" = "$active" ] && continue
        origin_tracking_ref "$ref" "$symref" && continue
        printf '%s\0%s\0%s\0' "$ref" "$oid" "$symref" || exit 1
      done \
    | "$REAL_GIT" hash-object --stdin)" || return 1
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

strict_refs_fingerprint() {
  local result
  result="$("$REAL_GIT" for-each-ref --format='%(refname)%00%(objectname)%00%(symref)' \
    | "$REAL_GIT" hash-object --stdin)" || return 1
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

ref_boundary_intact() {
  local active="$1" expected="$2" current strict origin_json
  current="$(other_refs_fingerprint "$active")" || return 1
  [ "$current" = "$expected" ] || return 1
  origin_refs_intact || return 1
  current="$(other_refs_fingerprint "$active")" || return 1
  [ "$current" = "$expected" ] || return 1
  strict="$(strict_refs_fingerprint)" || return 1
  origin_json="$(origin_refs_json)" || return 1
  [ "$origin_json" = "$VERIFIED_ORIGIN_REFS_JSON" ] || return 1
  current="$(strict_refs_fingerprint)" || return 1
  [ "$current" = "$strict" ] || return 1
  VERIFIED_REFS_FINGERPRINT="$strict"
}

hooks_fingerprint() {
  local dir="$1" tmp path rel mode oid result failed=0 old_shopt
  tmp="$(mktemp)" || return 1
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    old_shopt="$(shopt -p dotglob nullglob globstar || true)"
    shopt -s dotglob nullglob globstar
    for path in "$dir"/**; do
      rel="${path#"$dir"/}"
      if [ -d "$path" ] && [ ! -L "$path" ]; then continue
      elif [ -f "$path" ] && [ ! -L "$path" ]; then
        if [ -x "$path" ]; then mode=100755; else mode=100644; fi
        if ! oid=$(git hash-object --no-filters -- "$path" 2>/dev/null) \
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
  result="$(git hash-object --no-filters "$tmp")" \
    && valid_git_oid "$result" || { rm -f -- "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$result" || return 1
}

resolve_hook_source() {
  local configured source parent base config_rc=0
  configured="$(trusted_git config --path core.hooksPath 2>/dev/null)" || config_rc=$?
  case "$config_rc" in
    0)
      [ -n "$configured" ] || return 1
      case "$configured" in /*) source="$configured" ;; *) source="$ROOT/$configured" ;; esac
      ;;
    1)
      source="$(trusted_git rev-parse --git-path hooks)" || return 1
      case "$source" in /*) : ;; *) source="$ROOT/$source" ;; esac
      ;;
    *) return 1 ;;
  esac
  parent="$(dirname -- "$source")"; base="$(basename -- "$source")"
  [ -d "$parent" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
  parent="$(cd "$parent" && pwd -P)"; source="$parent/$base"
  [ ! -L "$source" ] || return 1
  if [ -e "$source" ] && [ ! -d "$source" ]; then return 1; fi
  printf '%s\n' "$source" || return 1
}

git_control_fingerprint() {
  local tmp key path mode oid result
  tmp="$(mktemp)" || return 1
  for key in info/attributes objects/info/alternates shallow grafts commondir gitdir \
    HEAD config.worktree MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD BISECT_LOG; do
    path="$(git rev-parse --git-path "$key")" || { rm -f -- "$tmp"; return 1; }
    case "$path" in /*) : ;; *) path="$ROOT/$path" ;; esac
    if [ -L "$path" ]; then rm -f "$tmp"; return 1
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      oid="$(git hash-object --no-filters -- "$path")" \
        && valid_git_oid "$oid" || { rm -f -- "$tmp"; return 1; }
    elif [ -e "$path" ]; then rm -f "$tmp"; return 1
    else mode=missing; oid=missing
    fi
    printf '%s\0%s\0%s\0' "$key" "$mode" "$oid" >> "$tmp" \
      || { rm -f -- "$tmp"; return 1; }
  done
  result="$(git hash-object --no-filters "$tmp")" \
    && valid_git_oid "$result" || { rm -f -- "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$result" || return 1
}

index_metadata_fingerprint() {
  local result
  result="$(git -c core.fsmonitor=false ls-files --stage -v -z \
    | git hash-object --stdin)" || return 1
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

allowed_path() {
  local path="$1" prefix
  for prefix in "${ALLOW[@]}"; do
    if [ "$path" = "$prefix" ] || [ "${path#"$prefix"/}" != "$path" ]; then return 0; fi
  done
  return 1
}

valid_allowed_path() {
  case "$1" in ''|.|/*|:*|*$'\n'*|*$'\r'*|*$'\t'*|../*|*/../*|*/..|./*|*/./*|*/.) return 1 ;; esac
  return 0
}

safe_allow_slot() {
  local relative="$1" current="$ROOT" component next canonical
  while [[ "$relative" == */* ]]; do
    component="${relative%%/*}"
    relative="${relative#*/}"
    next="$current/$component"
    [ ! -L "$next" ] || return 1
    if [ ! -e "$next" ]; then return 0; fi
    [ -d "$next" ] || return 1
    canonical="$(cd "$next" && pwd -P)" || return 1
    case "$canonical/" in "$ROOT/"*) : ;; *) return 1 ;; esac
    current="$canonical"
  done
  next="$current/$relative"
  [ ! -L "$next" ] || return 1
  [ ! -e "$next" ] || [ -f "$next" ]
}

fingerprint_entry() {
  local path="$1"
  if [ -L "$path" ]; then
    ENTRY_MODE=120000
    ENTRY_OID="$(readlink "$path" | git hash-object --stdin)" || return 1
    valid_git_oid "$ENTRY_OID" || return 1
  elif [ -f "$path" ]; then
    if [ -x "$path" ]; then ENTRY_MODE=100755; else ENTRY_MODE=100644; fi
    ENTRY_OID="$(git hash-object --no-filters -- "$path" 2>/dev/null)" || return 1
    valid_git_oid "$ENTRY_OID" || return 1
  elif [ -d "$path" ]; then
    ENTRY_MODE=040000; ENTRY_OID=directory
  elif [ -e "$path" ]; then
    return 1
  else
    ENTRY_MODE=missing; ENTRY_OID=missing
  fi
}

diff_fingerprint() {
  local kind="$1" base="$2" prefix result
  local pathspec=(.)
  for prefix in "${ALLOW[@]}"; do
    pathspec+=(":(exclude,literal)$prefix")
  done
  case "$kind" in
    index)
      result="$(git -c core.fsmonitor=false diff --binary --no-ext-diff --no-textconv \
        --cached "$base" -- "${pathspec[@]}" | git hash-object --stdin)" || return 1
      ;;
    worktree)
      result="$(git -c core.fsmonitor=false diff --binary --no-ext-diff --no-textconv \
        -- "${pathspec[@]}" | git hash-object --stdin)" || return 1
      ;;
    *) return 2 ;;
  esac
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

status_outside_allow() {
  local prefix pathspec=(.)
  for prefix in "${ALLOW[@]}"; do
    pathspec+=(":(exclude,literal)$prefix")
  done
  git -c core.fsmonitor=false status --short -- "${pathspec[@]}"
}

untracked_fingerprint() {
  fingerprint_other_files untracked --others --exclude-standard
}

always_exempt_ignored_path() {
  local path="${1%/}"
  [ ! -L "$path" ] || return 1
  # Maintain runtime temps under .startup must not fail investor seals.
  case "$path" in
    .startup/maintain-loop|.startup/maintain-loop/*) return 0 ;;
  esac
  # Large dependency / build / test / runtime-data trees. These are either
  # sealed via check_runtimes (node_modules, venv) or are regenerated product
  # caches/PII dumps that must not force O(n) fingerprinting on every
  # mutation-guard snapshot (seen hanging at 50k+ paths on aruannik).
  case "/$path/" in
    */node_modules/*|*/.pnpm-store/*|*/.pnpm/*|*/bower_components/*|\
    */.yarn/cache/*|*/.yarn/unplugged/*|\
    */venv/*|*/.venv/*|*/site-packages/*|\
    */.next/*|*/dist/*|*/build/*|*/coverage/*|*/htmlcov/*|*/.turbo/*|*/.cache/*|\
    */__pycache__/*|*/.pytest_cache/*|*/.mypy_cache/*|*/.ruff_cache/*|*/.tox/*|*/.eggs/*|\
    */.playwright-mcp/*|*/playwright-report/*|*/test-results/*|\
    */data/reports/*|*/data/orders/*|*/data/payments/*|*/data/analytics/*|\
    */data/ecb-rates-cache/*|*/data/listmonk-backups/*|*/data/listmonk-backups-*/*|\
    */logs/*|*/.startup/runs/*|*/.startup/handoffs/*|*/.startup/digests/*|\
    */.startup/maintain/*|*/.monitor/*|*/.replay-shots/*|*/.replay-tmp/*) return 0 ;;
  esac
  return 1
}

mutable_python_cache_path() {
  local path="$1"
  case "/$path/" in */__pycache__/*|*/.pytest_cache/*) return 0 ;; esac
  case "${path##*/}" in *.pyc|*.pyo) return 0 ;; esac
  return 1
}

mutable_control_ignored_path() {
  local path="$1" rest lease
  case "$path" in
    .startup/maintain-loop|.startup/maintain-loop/*) return 0 ;;
    .startup/leases/*/heartbeat|.startup/leases/*/audit.log) : ;;
    *) return 1 ;;
  esac
  rest=${path#.startup/leases/}
  lease=${rest%/*}
  case "$lease" in ''|*/*) return 1 ;; *) return 0 ;; esac
}

materialize_git_ls_files() {
  local output="$1" path="$2"
  shift 2
  : > "$output" || return 1
  git -c core.fsmonitor=false ls-files -z "$@" -- "$path" > "$output"
}

materialize_ignored_paths() {
  # Single bulk `git ls-files` of all ignored paths, then filter in one process.
  # The previous top-level `--directory` + per-dir expand was O(ignored-dirs)
  # git spawns and hung for minutes on product checkouts with ~1k+ ignored
  # directory entries and 50k+ files under data dumps / venv / .next.
  local output="$1" all
  all="$(mktemp)" || return 1
  : > "$output" || { rm -f -- "$all"; return 1; }
  materialize_git_ls_files "$all" . --others --ignored --exclude-standard || {
    rm -f -- "$all"
    return 1
  }
  if command -v python3 >/dev/null 2>&1; then
    # Keep filter rules in sync with always_exempt_ignored_path / allowed_path
    # prefix exemptions. allowed_path is path-shape only for absolute/escape;
    # here we only drop always-exempt heavy trees and directory placeholders.
    python3 - "$all" "$output" <<'PY' || { rm -f -- "$all"; return 1; }
import re, sys
src, dst = sys.argv[1], sys.argv[2]
exempt = re.compile(
    r"(?:^|/)"
    r"(?:"
    r"node_modules|\.pnpm-store|\.pnpm|bower_components|"
    r"\.yarn/cache|\.yarn/unplugged|"
    r"venv|\.venv|site-packages|"
    r"\.next|dist|build|coverage|htmlcov|\.turbo|\.cache|"
    r"__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.tox|\.eggs|"
    r"\.playwright-mcp|playwright-report|test-results|"
    r"data/reports|data/orders|data/payments|data/analytics|"
    r"data/ecb-rates-cache|data/listmonk-backups(?:-[^/]*)?|"
    r"logs|"
    r"\.startup/runs|\.startup/handoffs|\.startup/digests|"
    r"\.startup/maintain|\.startup/maintain-loop|"
    r"\.monitor|\.replay-shots|\.replay-tmp"
    r")"
    r"(?:/|$)"
)
maintain_loop = re.compile(r"^\.startup/maintain-loop(?:/|$)")  # kept for clarity; covered above
with open(src, "rb") as fh, open(dst, "wb") as out:
    for raw in fh.read().split(b"\0"):
        if not raw or raw.endswith(b"/"):
            continue
        try:
            path = raw.decode()
        except UnicodeDecodeError:
            continue
        if maintain_loop.match(path):
            continue
        if exempt.search(path):
            continue
        out.write(raw + b"\0")
PY
  else
    local path
    while IFS= read -r -d '' path; do
      [[ "$path" == */ ]] && continue
      allowed_path "$path" && continue
      always_exempt_ignored_path "$path" && continue
      printf '%s\0' "$path" >> "$output" || { rm -f -- "$all"; return 1; }
    done < "$all"
  fi
  rm -f -- "$all"
}

ignored_path_key() {
  local result
  # Prefer python (no per-path process spawn). Fallback matches git blob OID.
  # Use printf (not <<<) so no trailing newline is hashed.
  if command -v python3 >/dev/null 2>&1; then
    result="$(printf '%s' "$1" | python3 -c 'import hashlib,sys
p=sys.stdin.buffer.read()
h=hashlib.sha1(); h.update(b"blob %d\0"%len(p)); h.update(p); print(h.hexdigest())')" || return 1
  else
    result="$(printf '%s' "$1" | git hash-object --stdin)" || return 1
  fi
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

materialize_ignored_baseline_keys() {
  local output="$1" paths
  paths="$(mktemp)" || return 1
  : > "$output" || { rm -f -- "$paths"; return 1; }
  materialize_ignored_paths "$paths" || { rm -f -- "$paths"; return 1; }
  # Batch-hash path strings once. Per-path `git hash-object` was O(n) process
  # spawns and hung multi-GB product checkouts for minutes under lease ptrace.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$paths" "$output" <<'PY' || { rm -f -- "$paths"; return 1; }
import hashlib, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as fh, open(dst, "w", encoding="ascii") as out:
    data = fh.read().split(b"\0")
    for path in data:
        if not path:
            continue
        h = hashlib.sha1()
        h.update(b"blob %d\0" % len(path))
        h.update(path)
        out.write(h.hexdigest() + "\n")
PY
  else
    local path key
    while IFS= read -r -d '' path; do
      key="$(ignored_path_key "$path")" || { rm -f -- "$paths"; return 1; }
      printf '%s\n' "$key" >> "$output" || { rm -f -- "$paths"; return 1; }
    done < "$paths"
  fi
  rm -f -- "$paths"
}

materialize_protected_ignored_paths() {
  local output="$1" paths path key
  paths="$(mktemp)" || return 1
  : > "$output" || { rm -f -- "$paths"; return 1; }
  materialize_ignored_paths "$paths" || { rm -f -- "$paths"; return 1; }
  while IFS= read -r -d '' path; do
    key="$(ignored_path_key "$path")" || { rm -f -- "$paths"; return 1; }
    [ -n "${IGNORED_BASELINE[$key]+present}" ] || continue
    printf '%s\0' "$path" >> "$output" || { rm -f -- "$paths"; return 1; }
  done < "$paths"
  rm -f -- "$paths"
}

materialize_new_ignored_paths() {
  local output="$1" paths path key
  declare -A seen=()
  paths="$(mktemp)" || return 1
  : > "$output" || { rm -f -- "$paths"; return 1; }
  materialize_ignored_paths "$paths" || { rm -f -- "$paths"; return 1; }
  while IFS= read -r -d '' path; do
    mutable_python_cache_path "$path" && continue
    key="$(ignored_path_key "$path")" || { rm -f -- "$paths"; return 1; }
    [ -n "${seen[$key]+present}" ] && continue
    seen["$key"]=1
    [ -z "${IGNORED_BASELINE[$key]+present}" ] || continue
    printf '%s\0' "$path" >> "$output" || { rm -f -- "$paths"; return 1; }
  done < "$paths"
  rm -f -- "$paths"
}

safe_ignored_cleanup_slot() {
  local relative="$1" current="$ROOT" component next canonical
  valid_allowed_path "$relative" || return 1
  while [[ "$relative" == */* ]]; do
    component="${relative%%/*}"
    relative="${relative#*/}"
    next="$current/$component"
    [ -d "$next" ] && [ ! -L "$next" ] || return 1
    canonical="$(cd "$next" && pwd -P)" || return 1
    case "$canonical/" in "$ROOT/"*) : ;; *) return 1 ;; esac
    current="$canonical"
  done
  CLEANUP_PATH="$current/$relative"
  [ -f "$CLEANUP_PATH" ] || [ -L "$CLEANUP_PATH" ]
}

cleanup_new_ignored_paths() {
  local path paths remaining
  paths="$(mktemp)" || return 1
  if ! materialize_new_ignored_paths "$paths"; then
    rm -f -- "$paths"
    echo "delivery-mutation-guard: cannot enumerate disposable ignored paths" >&2
    return 1
  fi
  while IFS= read -r -d '' path; do
    safe_ignored_cleanup_slot "$path" || {
      printf 'delivery-mutation-guard: unsafe disposable ignored path: %q\n' "$path" >&2
      rm -f -- "$paths"
      return 1
    }
    rm -f -- "$CLEANUP_PATH" || {
      printf 'delivery-mutation-guard: cannot remove disposable ignored path: %q\n' "$path" >&2
      rm -f -- "$paths"
      return 1
    }
  done < "$paths"
  rm -f -- "$paths"
  remaining="$(mktemp)" || return 1
  if ! materialize_new_ignored_paths "$remaining"; then
    rm -f -- "$remaining"
    echo "delivery-mutation-guard: cannot re-enumerate disposable ignored paths" >&2
    return 1
  fi
  if IFS= read -r -d '' path < "$remaining"; then
    printf 'delivery-mutation-guard: disposable ignored path survived cleanup: %q\n' "$path" >&2
    rm -f -- "$remaining"
    return 1
  fi
  rm -f -- "$remaining"
}

materialize_python_cache_paths() {
  local output="$1" raw extra path key
  declare -A seen=()
  raw="$(mktemp)" || return 1
  extra="$(mktemp)" || { rm -f -- "$raw"; return 1; }
  : > "$output" || { rm -f -- "$raw" "$extra"; return 1; }
  if ! materialize_git_ls_files "$raw" . --others --ignored --exclude-standard \
    || ! materialize_git_ls_files "$extra" . --others --exclude-standard \
    || ! cat "$extra" >> "$raw"; then
    rm -f -- "$raw" "$extra"
    return 1
  fi
  rm -f -- "$extra"
  while IFS= read -r -d '' path; do
    mutable_python_cache_path "$path" || continue
    key="$(ignored_path_key "$path")" || { rm -f -- "$raw"; return 1; }
    [ -n "${seen[$key]+present}" ] && continue
    seen["$key"]=1
    printf '%s\0' "$path" >> "$output" || { rm -f -- "$raw"; return 1; }
  done < "$raw"
  rm -f -- "$raw"
}

mutable_python_cache_directory() {
  local path="${1%/}"
  case "/$path/" in */__pycache__/*|*/.pytest_cache/*) return 0 ;; esac
  return 1
}

resolve_safe_cache_directory() {
  local relative="$1" current="$ROOT" component canonical
  valid_allowed_path "$relative" || return 1
  while [ -n "$relative" ]; do
    component=${relative%%/*}
    if [ "$relative" = "$component" ]; then relative=""; else relative=${relative#*/}; fi
    current="$current/$component"
    [ -d "$current" ] && [ ! -L "$current" ] || return 1
    canonical="$(cd "$current" && pwd -P)" || return 1
    case "$canonical/" in "$ROOT/"*) current="$canonical" ;; *) return 1 ;; esac
  done
  SAFE_CACHE_DIRECTORY="$current"
}

safe_empty_cache_directory() {
  resolve_safe_cache_directory "$1" || return 1
  rmdir -- "$SAFE_CACHE_DIRECTORY" 2>/dev/null
}

cleanup_empty_cache_parents() {
  local relative="${1%/*}"
  [ "$relative" != "$1" ] || return 0
  while mutable_python_cache_directory "$relative"; do
    safe_empty_cache_directory "$relative" || break
    case "$relative" in */*) relative=${relative%/*} ;; *) break ;; esac
  done
}

materialize_python_cache_roots() {
  local output="$1" raw extra path key
  declare -A seen=()
  raw="$(mktemp)" || return 1
  extra="$(mktemp)" || { rm -f -- "$raw"; return 1; }
  : > "$output" || { rm -f -- "$raw" "$extra"; return 1; }
  if ! materialize_git_ls_files "$raw" . --others --ignored --exclude-standard --directory \
    || ! materialize_git_ls_files "$extra" . --others --exclude-standard --directory \
    || ! cat "$extra" >> "$raw"; then
    rm -f -- "$raw" "$extra"
    return 1
  fi
  rm -f -- "$extra"
  while IFS= read -r -d '' path; do
    path=${path%/}
    case "${path##*/}" in __pycache__|.pytest_cache) : ;; *) continue ;; esac
    key="$(ignored_path_key "$path")" || { rm -f -- "$raw"; return 1; }
    [ -n "${seen[$key]+present}" ] && continue
    seen["$key"]=1
    printf '%s\0' "$path" >> "$output" || { rm -f -- "$raw"; return 1; }
  done < "$raw"
  rm -f -- "$raw"
}

cleanup_empty_python_cache_directories() {
  local root directory relative listing roots
  roots=$(mktemp) || return 1
  if ! materialize_python_cache_roots "$roots"; then
    rm -f -- "$roots"
    echo "delivery-mutation-guard: cannot enumerate Python cache directories" >&2
    return 1
  fi
  while IFS= read -r -d '' root; do
    if [ ! -e "$ROOT/$root" ] && [ ! -L "$ROOT/$root" ]; then continue; fi
    valid_allowed_path "$root" && [ -d "$ROOT/$root" ] && [ ! -L "$ROOT/$root" ] || {
      printf 'delivery-mutation-guard: unsafe Python cache directory: %q\n' "$root" >&2
      rm -f -- "$roots"
      return 1
    }
    listing=$(mktemp) || { rm -f -- "$roots"; return 1; }
    find "$ROOT/$root" -depth -type d -print0 > "$listing" || {
      rm -f -- "$listing" "$roots"; return 1; }
    while IFS= read -r -d '' directory; do
      relative=${directory#"$ROOT"/}
      resolve_safe_cache_directory "$relative" || {
        printf 'delivery-mutation-guard: unsafe Python cache directory: %q\n' "$relative" >&2
        rm -f -- "$listing" "$roots"
        return 1
      }
      rmdir -- "$SAFE_CACHE_DIRECTORY" 2>/dev/null || true
    done < "$listing"
    rm -f -- "$listing"
  done < "$roots"
  rm -f -- "$roots"
}

cleanup_python_cache_paths() {
  local path paths remaining
  paths=$(mktemp) || return 1
  if ! materialize_python_cache_paths "$paths"; then
    rm -f -- "$paths"
    echo "delivery-mutation-guard: cannot enumerate Python cache paths" >&2
    return 1
  fi
  while IFS= read -r -d '' path; do
    safe_ignored_cleanup_slot "$path" || {
      printf 'delivery-mutation-guard: unsafe Python cache path: %q\n' "$path" >&2
      rm -f -- "$paths"
      return 1
    }
    rm -f -- "$CLEANUP_PATH" || {
      printf 'delivery-mutation-guard: cannot remove Python cache path: %q\n' "$path" >&2
      rm -f -- "$paths"
      return 1
    }
    cleanup_empty_cache_parents "$path"
  done < "$paths"
  rm -f -- "$paths"
  cleanup_empty_python_cache_directories || return 1
  remaining=$(mktemp) || return 1
  if ! materialize_python_cache_paths "$remaining"; then
    rm -f -- "$remaining"
    echo "delivery-mutation-guard: cannot re-enumerate Python cache paths" >&2
    return 1
  fi
  if IFS= read -r -d '' path < "$remaining"; then
    printf 'delivery-mutation-guard: Python cache path survived cleanup: %q\n' "$path" >&2
    rm -f -- "$remaining"
    return 1
  fi
  rm -f -- "$remaining"
}

ignored_fingerprint() {
  local tmp paths path result
  tmp="$(mktemp)" || return 1
  paths="$(mktemp)" || { rm -f -- "$tmp"; return 1; }
  if ! materialize_protected_ignored_paths "$paths"; then
    rm -f -- "$tmp" "$paths"
    echo "delivery-mutation-guard: cannot enumerate protected ignored paths" >&2
    return 1
  fi
  while IFS= read -r -d '' path; do
    fingerprint_one ignored "$path" "$tmp" || { rm -f -- "$tmp" "$paths"; return 1; }
  done < "$paths"
  result="$(git hash-object --no-filters "$tmp")" || {
    rm -f -- "$tmp" "$paths"
    return 1
  }
  valid_git_oid "$result" || { rm -f -- "$tmp" "$paths"; return 1; }
  rm -f -- "$tmp" "$paths"
  printf '%s\n' "$result" || return 1
}

fingerprint_one() {
  local kind="$1" path="$2" tmp="$3"
  allowed_path "$path" && return 0
  if [ "$kind" = ignored ] && mutable_control_ignored_path "$path" \
    && [ -f "$path" ] && [ ! -L "$path" ]; then
    if [ -x "$path" ]; then ENTRY_MODE=100755; else ENTRY_MODE=100644; fi
    ENTRY_OID=mutable-control
  elif { [ "$kind" = ignored ] || [ "$kind" = untracked ]; } \
    && mutable_python_cache_path "$path" \
    && [ -f "$path" ] && [ ! -L "$path" ]; then
    if [ -x "$path" ]; then ENTRY_MODE=100755; else ENTRY_MODE=100644; fi
    ENTRY_OID=mutable-python-cache
  else
    fingerprint_entry "$path" || return 1
  fi
  printf '%s\0%s\0%s\0%s\0' "$kind" "$path" "$ENTRY_MODE" "$ENTRY_OID" >> "$tmp" \
    || return 1
}

special_worktree_entries_absent() {
  local inventory unsafe
  inventory="$(mktemp)" || return 1
  find -P . -path './.git' -prune -o \
    \( -type d \( -name node_modules -o -name .pnpm-store -o -name .pnpm \
      -o -name bower_components -o -name cache -path '*/.yarn/cache' \
      -o -name unplugged -path '*/.yarn/unplugged' \) \) -prune -o \
    ! -type f ! -type d ! -type l -print0 > "$inventory" || {
      rm -f -- "$inventory"; return 1; }
  if IFS= read -r -d '' unsafe < "$inventory"; then
    printf 'delivery-mutation-guard: unsupported worktree entry: %q\n' \
      "${unsafe#./}" >&2
    rm -f -- "$inventory"
    return 1
  fi
  rm -f -- "$inventory"
}

fingerprint_other_files() {
  local kind="$1" tmp paths path result
  shift
  special_worktree_entries_absent || return 1
  tmp="$(mktemp)" || return 1
  paths="$(mktemp)" || { rm -f -- "$tmp"; return 1; }
  if ! materialize_git_ls_files "$paths" . "$@"; then
    rm -f -- "$tmp" "$paths"
    printf 'delivery-mutation-guard: cannot enumerate %s files\n' "$kind" >&2
    return 1
  fi
  while IFS= read -r -d '' path; do
    fingerprint_one "$kind" "$path" "$tmp" || { rm -f -- "$tmp" "$paths"; return 1; }
  done < "$paths"
  result="$(git hash-object --no-filters "$tmp")" || {
    rm -f -- "$tmp" "$paths"
    return 1
  }
  valid_git_oid "$result" || { rm -f -- "$tmp" "$paths"; return 1; }
  rm -f -- "$tmp" "$paths"
  printf '%s\n' "$result" || return 1
}

git_exclusion_fingerprint() {
  local tmp config_rows exclude_path external raw path oid result config_rc=0
  tmp="$(mktemp)" || return 1
  config_rows="$(mktemp)" || { rm -f -- "$tmp"; return 1; }
  if ! git config --show-origin --show-scope --list > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp" "$config_rows"
    return 1
  fi
  exclude_path="$(git rev-parse --git-path info/exclude)" || {
    rm -f -- "$tmp" "$config_rows"; return 1; }
  if [ -e "$exclude_path" ] || [ -L "$exclude_path" ]; then
    fingerprint_entry "$exclude_path" || {
      rm -f -- "$tmp" "$config_rows"; return 1; }
    printf 'info-exclude\0%s\0%s\0' "$ENTRY_MODE" "$ENTRY_OID" >> "$tmp" || {
      rm -f -- "$tmp" "$config_rows"; return 1; }
  else
    printf 'info-exclude\0missing\0' >> "$tmp" || {
      rm -f -- "$tmp" "$config_rows"; return 1; }
  fi
  git config --show-origin --get-all core.excludesfile > "$config_rows" 2>/dev/null \
    || config_rc=$?
  case "$config_rc" in
    0|1) ;;
    *) rm -f -- "$tmp" "$config_rows"; return 1 ;;
  esac
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    external=${raw#*$'\t'}
    case "$external" in
      \~/*) path="${HOME:-}/${external:2}" ;;
      /*) path="$external" ;;
      *) path="$ROOT/$external" ;;
    esac
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      oid="$(git hash-object --no-filters -- "$path" 2>/dev/null)" || {
        rm -f -- "$tmp" "$config_rows"; return 1; }
      valid_git_oid "$oid" || { rm -f -- "$tmp" "$config_rows"; return 1; }
      printf 'global-exclude\0%s\0' "$oid" >> "$tmp" || {
        rm -f -- "$tmp" "$config_rows"; return 1; }
    else
      printf 'global-exclude\0missing\0' >> "$tmp" || {
        rm -f -- "$tmp" "$config_rows"; return 1; }
    fi
  done < "$config_rows"
  result="$(git hash-object --no-filters "$tmp")" || {
    rm -f -- "$tmp" "$config_rows"; return 1; }
  valid_git_oid "$result" || { rm -f -- "$tmp" "$config_rows"; return 1; }
  rm -f -- "$tmp" "$config_rows"
  printf '%s\n' "$result" || return 1
}

state_fingerprint() {
  local path=".startup/state.json" result
  if [ -e "$path" ] || [ -L "$path" ]; then
    fingerprint_entry "$path" || return 1
    result="$(printf 'present\0%s\0%s\0' "$ENTRY_MODE" "$ENTRY_OID" \
      | git hash-object --stdin)" || return 1
  else
    result="$(printf 'missing\0' | git hash-object --stdin)" || return 1
  fi
  valid_git_oid "$result" || return 1
  printf '%s\n' "$result" || return 1
}

head_boundary_intact() {
  local current
  current="$(git rev-parse HEAD)" || return 1
  valid_git_oid "$current" || return 1
  [ "$current" = "$1" ]
}

if [ "$ACTION" = "snapshot" ]; then
  [ "${#ALLOW[@]}" -gt 0 ] || {
    echo "delivery-mutation-guard: at least one exact --allow path is required" >&2
    exit 2
  }
  for allowed in "${ALLOW[@]}"; do
    valid_allowed_path "$allowed" || {
      printf 'delivery-mutation-guard: invalid allowed path: %q\n' "$allowed" >&2
      exit 2
    }
    safe_allow_slot "$allowed" || {
      printf 'delivery-mutation-guard: unsafe allowed artifact slot: %q\n' "$allowed" >&2
      exit 1
    }
  done
  base="$(git rev-parse HEAD)"
  index_fp="$(diff_fingerprint index "$base")"
  worktree_fp="$(diff_fingerprint worktree "$base")"
  untracked_fp="$(untracked_fingerprint)"
  ignored_baseline_keys=()
  ignored_baseline_file="$(mktemp)" || exit 1
  if ! materialize_ignored_baseline_keys "$ignored_baseline_file"; then
    rm -f -- "$ignored_baseline_file"
    echo "delivery-mutation-guard: cannot enumerate ignored baseline" >&2
    exit 1
  fi
  mapfile -t ignored_baseline_keys < "$ignored_baseline_file"
  rm -f -- "$ignored_baseline_file"
  for path_key in "${ignored_baseline_keys[@]}"; do
    IGNORED_BASELINE["$path_key"]=1
  done
  ignored_fp="$(ignored_fingerprint)"
  exclusion_fp="$(git_exclusion_fingerprint)"
  state_fp="$(state_fingerprint)"
  active_ref="$(head_ref)"
  ORIGIN_URL="$(trusted_git config --get remote.origin.url 2>/dev/null || true)"
  ORIGIN_FETCH_REFSPEC="$(trusted_git config --get-all remote.origin.fetch 2>/dev/null || true)"
  origin_refs="$(origin_refs_json)" || {
    echo "delivery-mutation-guard: origin ref snapshot is unsafe" >&2; exit 1; }
  load_origin_refs "$origin_refs" || {
    echo "delivery-mutation-guard: origin ref snapshot is invalid" >&2; exit 1; }
  refs_fp="$(other_refs_fingerprint "$active_ref")"
  strict_refs_fp="$(strict_refs_fingerprint)"
  hook_source="$(resolve_hook_source)" || {
    echo "delivery-mutation-guard: active hook source is unsafe" >&2; exit 1; }
  hooks_fp="$(hooks_fingerprint "$hook_source")" || {
    echo "delivery-mutation-guard: active hook set is unsafe" >&2; exit 1; }
  control_fp="$(git_control_fingerprint)" || {
    echo "delivery-mutation-guard: Git control metadata is unsafe" >&2; exit 1; }
  index_metadata_fp="$(index_metadata_fingerprint)"
  [ ! -e "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || {
    echo "delivery-mutation-guard: snapshot already exists" >&2; exit 1; }
  snapshot_tmp="$(mktemp "${SNAPSHOT}.unsigned.XXXXXX")"
  {
    for value in "${ALLOW[@]}"; do printf '%s\n' "$value"; done
    for value in "${ignored_baseline_keys[@]}"; do printf '%s\n' "$value"; done
  } \
  | jq -Rn --argjson allow_count "${#ALLOW[@]}" \
    --arg head "$base" --arg index "$index_fp" --arg worktree "$worktree_fp" \
    --arg untracked "$untracked_fp" --arg ignored "$ignored_fp" --arg exclusion "$exclusion_fp" \
    --arg state "$state_fp" --arg active_ref "$active_ref" --arg refs "$refs_fp" \
    --arg strict_refs "$strict_refs_fp" --arg origin_url "$ORIGIN_URL" \
    --arg origin_fetch_refspec "$ORIGIN_FETCH_REFSPEC" --argjson origin_refs "$origin_refs" \
    --arg hooks "$hooks_fp" --arg control "$control_fp" --arg index_metadata "$index_metadata_fp" \
    '[inputs] as $values
    | {schema_version:6,base_head:$head,head_ref:$active_ref,
      refs_fingerprint:$strict_refs,other_refs_fingerprint:$refs,
      origin_url:$origin_url,origin_fetch_refspec:$origin_fetch_refspec,origin_refs:$origin_refs,
      hooks_fingerprint:$hooks,git_control_fingerprint:$control,
      index_metadata_fingerprint:$index_metadata,
      index_fingerprint:$index,
      worktree_fingerprint:$worktree,untracked_fingerprint:$untracked,
      ignored_fingerprint:$ignored,git_exclusion_fingerprint:$exclusion,
      state_fingerprint:$state,ignored_baseline:$values[$allow_count:],
      allow:$values[:$allow_count],auth_tag:null}' > "$snapshot_tmp"
  sign_snapshot "$snapshot_tmp"
  mv -- "$snapshot_tmp" "$SNAPSHOT"
  [ ! -e "${SNAPSHOT}.active" ] && [ ! -L "${SNAPSHOT}.active" ] || {
    echo "delivery-mutation-guard: active marker already exists" >&2; exit 1; }
  (umask 077; printf 'guard-active\n' > "${SNAPSHOT}.active")
  chmod 400 "${SNAPSHOT}.active"
  echo "delivery-mutation-guard: snapshot $(git rev-parse --short HEAD)"
  exit 0
fi

[ -f "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || {
  echo "delivery-mutation-guard: snapshot not found or unsafe: $SNAPSHOT" >&2; exit 2; }
VERIFIED="${SNAPSHOT}.verified"
if [ -e "${SNAPSHOT}.active" ] || [ -L "${SNAPSHOT}.active" ]; then
  [ -f "${SNAPSHOT}.active" ] && [ ! -L "${SNAPSHOT}.active" ] || {
    echo "delivery-mutation-guard: active guard marker is unsafe" >&2; exit 1; }
elif [ ! -e "$VERIFIED" ] && [ ! -L "$VERIFIED" ]; then
  echo "delivery-mutation-guard: active guard marker is missing" >&2; exit 1
fi
jq -e '.schema_version == 6 and (.base_head|type=="string")
  and (.head_ref|type=="string") and (.refs_fingerprint|type=="string")
  and (.other_refs_fingerprint|type=="string")
  and (.origin_url|type=="string") and (.origin_fetch_refspec|type=="string")
  and (.origin_refs|type=="array")
  and (.origin_refs|all(.[];
    (.ref|type=="string" and startswith("refs/remotes/origin/") and . != "refs/remotes/origin/HEAD")
    and (.oid|type=="string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))))
  and (.origin_refs|((map(.ref)|unique|length)==length))
  and (.hooks_fingerprint|type=="string") and (.git_control_fingerprint|type=="string")
  and (.index_metadata_fingerprint|type=="string")
  and (.index_fingerprint|type=="string") and (.worktree_fingerprint|type=="string")
  and (.untracked_fingerprint|type=="string") and (.ignored_fingerprint|type=="string")
  and (.git_exclusion_fingerprint|type=="string") and (.state_fingerprint|type=="string")
  and (.ignored_baseline|type=="array")
  and (.allow|type=="array") and (.auth_tag|type=="string")' "$SNAPSHOT" >/dev/null || {
  echo "delivery-mutation-guard: malformed snapshot" >&2; exit 2; }
[ "$(auth_tag "$SNAPSHOT")" = "$(jq -r .auth_tag "$SNAPSHOT")" ] || {
  echo "delivery-mutation-guard: snapshot authentication failed" >&2; exit 1; }
retire_active_guard() { rm -f -- "${SNAPSHOT}.active"; }
CLEAN_PYTHON_CACHE=0
terminal_guard_cleanup() {
  [ "$CLEAN_PYTHON_CACHE" -eq 0 ] || cleanup_python_cache_paths >/dev/null 2>&1 || true
  retire_active_guard
}
trap terminal_guard_cleanup EXIT
base="$(jq -r '.base_head' "$SNAPSHOT")"
ORIGIN_URL="$(jq -r '.origin_url' "$SNAPSHOT")"
ORIGIN_FETCH_REFSPEC="$(jq -r '.origin_fetch_refspec' "$SNAPSHOT")"
load_origin_refs "$(jq -c '.origin_refs' "$SNAPSHOT")" || {
  echo "delivery-mutation-guard: authenticated origin refs are invalid" >&2; exit 1; }
ALLOW_INVENTORY="$(mktemp)" || exit 1
if ! jq -r '.allow[]' "$SNAPSHOT" > "$ALLOW_INVENTORY"; then
  rm -f -- "$ALLOW_INVENTORY"
  echo "delivery-mutation-guard: cannot materialize authenticated allowlist" >&2
  exit 1
fi
ALLOW_COUNT="$(jq -er '.allow|length' "$SNAPSHOT")" || {
  rm -f -- "$ALLOW_INVENTORY"
  echo "delivery-mutation-guard: cannot count authenticated allowlist" >&2
  exit 1
}
[[ "$ALLOW_COUNT" =~ ^[0-9]+$ ]] || {
  rm -f -- "$ALLOW_INVENTORY"
  echo "delivery-mutation-guard: authenticated allowlist count is invalid" >&2
  exit 1
}
mapfile -t ALLOW < "$ALLOW_INVENTORY" || {
  rm -f -- "$ALLOW_INVENTORY"
  echo "delivery-mutation-guard: cannot read authenticated allowlist" >&2
  exit 1
}
rm -f -- "$ALLOW_INVENTORY"
[ "${#ALLOW[@]}" -eq "$ALLOW_COUNT" ] || {
  echo "delivery-mutation-guard: authenticated allowlist is incomplete" >&2
  exit 1
}
for allowed in "${ALLOW[@]}"; do
  valid_allowed_path "$allowed" || {
    echo "delivery-mutation-guard: authenticated allowlist is invalid" >&2; exit 1; }
  safe_allow_slot "$allowed" || {
    printf 'delivery-mutation-guard: authenticated artifact slot became unsafe: %q\n' "$allowed" >&2
    exit 1
  }
done
IGNORED_BASELINE_INVENTORY="$(mktemp)" || exit 1
if ! jq -r '.ignored_baseline[]' "$SNAPSHOT" > "$IGNORED_BASELINE_INVENTORY"; then
  rm -f -- "$IGNORED_BASELINE_INVENTORY"
  echo "delivery-mutation-guard: cannot materialize authenticated ignored-state baseline" >&2
  exit 1
fi
IGNORED_BASELINE_COUNT="$(jq -er '.ignored_baseline|length' "$SNAPSHOT")" || {
  rm -f -- "$IGNORED_BASELINE_INVENTORY"
  echo "delivery-mutation-guard: cannot count authenticated ignored-state baseline" >&2
  exit 1
}
[[ "$IGNORED_BASELINE_COUNT" =~ ^[0-9]+$ ]] || {
  rm -f -- "$IGNORED_BASELINE_INVENTORY"
  echo "delivery-mutation-guard: authenticated ignored-state baseline count is invalid" >&2
  exit 1
}
mapfile -t ignored_baseline_keys < "$IGNORED_BASELINE_INVENTORY" || {
  rm -f -- "$IGNORED_BASELINE_INVENTORY"
  echo "delivery-mutation-guard: cannot read authenticated ignored-state baseline" >&2
  exit 1
}
rm -f -- "$IGNORED_BASELINE_INVENTORY"
[ "${#ignored_baseline_keys[@]}" -eq "$IGNORED_BASELINE_COUNT" ] || {
  echo "delivery-mutation-guard: authenticated ignored-state baseline is incomplete" >&2
  exit 1
}
for path_key in "${ignored_baseline_keys[@]}"; do
  [[ "$path_key" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || {
    echo "delivery-mutation-guard: authenticated ignored-state baseline is invalid" >&2
    exit 1
  }
  IGNORED_BASELINE["$path_key"]=1
done
CLEAN_PYTHON_CACHE=1
resume_import=0
if [ -e "$VERIFIED" ] || [ -L "$VERIFIED" ]; then
  [ -f "$VERIFIED" ] && [ ! -L "$VERIFIED" ] \
    && jq -e --arg snapshot_tag "$(jq -r .auth_tag "$SNAPSHOT")" \
      '.schema_version == 1 and .snapshot_auth_tag == $snapshot_tag and (.auth_tag|type=="string")' \
      "$VERIFIED" >/dev/null \
    && [ "$(auth_tag "$VERIFIED")" = "$(jq -r .auth_tag "$VERIFIED")" ] || {
      echo "delivery-mutation-guard: telemetry import marker authentication failed" >&2; exit 1; }
  resume_import=1
fi
[ "$resume_import" -eq 0 ] || retire_active_guard

if [ "$resume_import" -eq 0 ]; then
  hook_source="$(resolve_hook_source)" || {
    echo "delivery-mutation-guard: active hook source became unsafe" >&2; exit 1; }
  [ "$(hooks_fingerprint "$hook_source")" = "$(jq -r .hooks_fingerprint "$SNAPSHOT")" ] \
    && [ "$(git_control_fingerprint)" = "$(jq -r .git_control_fingerprint "$SNAPSHOT")" ] \
    && [ "$(index_metadata_fingerprint)" = "$(jq -r .index_metadata_fingerprint "$SNAPSHOT")" ] || {
      echo "delivery-mutation-guard: worker changed Git hooks or control metadata" >&2
      exit 1
    }
  active_ref="$(jq -r .head_ref "$SNAPSHOT")"
  [ "$(head_ref)" = "$active_ref" ] || {
    echo "delivery-mutation-guard: active Git ref changed outside the allowed phase" >&2
    exit 1
  }
  ref_boundary_intact "$active_ref" "$(jq -r .other_refs_fingerprint "$SNAPSHOT")" || {
    echo "delivery-mutation-guard: Git refs changed outside signed live origin progress" >&2
    exit 1
  }
  head_boundary_intact "$base" || {
    echo "delivery-mutation-guard: worker changed commit history; only the supervisor may commit" >&2
    exit 1
  }
  expected_index="$(jq -r '.index_fingerprint' "$SNAPSHOT")"
  expected_worktree="$(jq -r '.worktree_fingerprint' "$SNAPSHOT")"
  expected_untracked="$(jq -r '.untracked_fingerprint' "$SNAPSHOT")"
  expected_ignored="$(jq -r '.ignored_fingerprint' "$SNAPSHOT")"
  expected_exclusion="$(jq -r '.git_exclusion_fingerprint' "$SNAPSHOT")"
  expected_state="$(jq -r '.state_fingerprint' "$SNAPSHOT")"
  actual_index="$(diff_fingerprint index "$base")"
  actual_worktree="$(diff_fingerprint worktree "$base")"
  actual_untracked="$(untracked_fingerprint)"
  actual_ignored="$(ignored_fingerprint)"
  actual_exclusion="$(git_exclusion_fingerprint)"
  actual_state="$(state_fingerprint)"

  if [ "$actual_index" != "$expected_index" ] \
    || [ "$actual_worktree" != "$expected_worktree" ] \
    || [ "$actual_untracked" != "$expected_untracked" ] \
    || [ "$actual_ignored" != "$expected_ignored" ] \
    || [ "$actual_exclusion" != "$expected_exclusion" ] \
    || [ "$actual_state" != "$expected_state" ]; then
    echo "delivery-mutation-guard: guarded phase modified files outside its allowed paths" >&2
    echo "delivery-mutation-guard: changed fingerprint components:" >&2
    tracked_state_changed=0
    if [ "$actual_index" != "$expected_index" ]; then
      echo "  - tracked index" >&2; tracked_state_changed=1
    fi
    if [ "$actual_worktree" != "$expected_worktree" ]; then
      echo "  - tracked worktree" >&2; tracked_state_changed=1
    fi
    if [ "$actual_untracked" != "$expected_untracked" ]; then
      echo "  - untracked files" >&2; tracked_state_changed=1
    fi
    if [ "$actual_ignored" != "$expected_ignored" ]; then
      echo "  - protected ignored state" >&2
      echo "delivery-mutation-guard: current protected ignored paths (a removed path is absent):" >&2
      ignored_count=0; ignored_shown=0
      ignored_diagnostic="$(mktemp)" || exit 1
      if ! materialize_protected_ignored_paths "$ignored_diagnostic"; then
        rm -f -- "$ignored_diagnostic"
        echo "    (inventory unavailable)" >&2
        exit 1
      fi
      while IFS= read -r -d '' ignored_path; do
        ignored_count=$((ignored_count + 1))
        if [ "$ignored_shown" -lt 20 ]; then
          printf '    %q\n' "$ignored_path" >&2
          ignored_shown=$((ignored_shown + 1))
        fi
      done < "$ignored_diagnostic"
      rm -f -- "$ignored_diagnostic"
      if [ "$ignored_count" -eq 0 ]; then
        echo "    (none)" >&2
      elif [ "$ignored_count" -gt "$ignored_shown" ]; then
        printf '    ... and %d more\n' "$((ignored_count - ignored_shown))" >&2
      fi
    fi
    if [ "$actual_exclusion" != "$expected_exclusion" ]; then
      echo "  - Git exclusion metadata" >&2
    fi
    if [ "$actual_state" != "$expected_state" ]; then
      echo "  - .startup/state.json" >&2
    fi
    if [ "$tracked_state_changed" -eq 1 ]; then
      status_outside_allow >&2
    fi
    exit 1
  fi
fi
cleanup_new_ignored_paths || exit 1
cleanup_python_cache_paths || exit 1
if [ "$resume_import" -eq 0 ] \
  && [ "$(strict_refs_fingerprint)" != "$VERIFIED_REFS_FINGERPRINT" ]; then
  echo "delivery-mutation-guard: Git refs changed after live origin verification" >&2
  exit 1
fi
shopt -s nullglob
telemetry_receipts=("${SNAPSHOT}.telemetry-"*.json)
shopt -u nullglob
if [ "$resume_import" -eq 0 ] && [ "${#telemetry_receipts[@]}" -gt 0 ]; then
  for telemetry_receipt in "${telemetry_receipts[@]}"; do
    bash "$SCRIPT_DIR/agent-events.sh" import-guarded --check --receipt "$telemetry_receipt" >/dev/null || {
      echo "delivery-mutation-guard: guarded telemetry preflight failed" >&2
      exit 1
    }
  done
  verified_tmp="$(mktemp "${VERIFIED}.tmp.XXXXXX")"
  jq -n --arg snapshot_tag "$(jq -r .auth_tag "$SNAPSHOT")" \
    '{schema_version:1,snapshot_auth_tag:$snapshot_tag,auth_tag:null}' > "$verified_tmp"
  sign_snapshot "$verified_tmp"
  mv -- "$verified_tmp" "$VERIFIED"
  retire_active_guard
fi
for telemetry_receipt in "${telemetry_receipts[@]}"; do
  bash "$SCRIPT_DIR/agent-events.sh" import-guarded --receipt "$telemetry_receipt" >/dev/null || {
    echo "delivery-mutation-guard: guarded telemetry import failed" >&2
    exit 1
  }
done
cleanup_python_cache_paths || exit 1
if [ "$resume_import" -eq 0 ] \
  && [ "$(strict_refs_fingerprint)" != "$VERIFIED_REFS_FINGERPRINT" ]; then
  echo "delivery-mutation-guard: Git refs changed before guard completion" >&2
  exit 1
fi
CLEAN_PYTHON_CACHE=0
rm -f -- "${SNAPSHOT}.telemetry-identity-key" "$VERIFIED" "${SNAPSHOT}.active"
trap - EXIT
echo "delivery-mutation-guard: review-only boundary intact"
