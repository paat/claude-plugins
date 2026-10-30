#!/usr/bin/env bash
# Collect and seal merge-gate tribunal evidence. Provider output is advisory;
# this runner owns provider identity, repository/PR binding, and artifact hashes.
set -euo pipefail
umask 077
export LC_ALL=C GIT_NO_REPLACE_OBJECTS=1
unset BASH_ENV ENV CDPATH GLOBIGNORE
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_SSH_COMMAND

for command_name in git gh jq sha256sum awk sed wc date mktemp chmod mkdir mv rm rmdir cat dirname basename tr pwd env bash printf timeout head cp cmp stat setsid unshare ps kill codex agy dsh qwen grok muse claude; do
  unset -f "$command_name" 2>/dev/null || true
done
unset command_name

# Also covers library helpers and traps; never exported to reviewer shells.
git() {
  check_git_surface || die "git surface validation failed"
  local target="$PWD" i
  local -a args=("$@")
  for ((i=0; i<${#args[@]}; i+=2)); do
    case "${args[$i]}" in
      -C) target="${args[$((i+1))]}" ;;
      -c) ;;
      *) break ;;
    esac
  done
  if [ "$SURFACE_PINNED" -eq 1 ] && [ "$target" = "$SURFACE_ROOT" ]; then
    local -x GIT_DIR="$SURFACE_GITDIR" GIT_COMMON_DIR="$SURFACE_COMMON" GIT_WORK_TREE="$SURFACE_ROOT"
  fi
  hardened_git "$@"
}

hardened_git() {
  local arg upload_pack=""
  local -a options=() invocation protections upload_invocation
  # Ignore external config and worktree attributes, including '=' driver names.
  invocation=(env GIT_NO_LAZY_FETCH=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_COUNT="$SAFE_DIRECTORY_COUNT" "${SAFE_DIRECTORY_ENV[@]+"${SAFE_DIRECTORY_ENV[@]}"}"
    git --attr-source=4b825dc642cb6eb9a060e54bf8d69288fbee4904)
  protections=(-c core.attributesFile=/dev/null -c core.fsmonitor=false -c core.hooksPath=/dev/null)
  while [ "${1:-}" = -c ] || [ "${1:-}" = -C ]; do
    options+=("$1" "$2"); shift 2
  done
  if [ "${1:-}" = clone ]; then
    shift
    # Local clone drops command-scope config in its upload-pack child.
    # Reapply the same pinned environment there, quoted for Git's POSIX shell.
    upload_invocation=(env)
    if [ -n "${GIT_DIR:-}" ]; then
      upload_invocation+=("GIT_DIR=$GIT_DIR" "GIT_COMMON_DIR=$GIT_COMMON_DIR")
    fi
    for arg in "${upload_invocation[@]}" "${invocation[@]}" "${protections[@]}" upload-pack; do
      upload_pack+="'${arg//\'/\'\\\'\'}' "
    done
    set -- clone "--upload-pack=$upload_pack" "$@"
    # The clone destination must not inherit the source repository's pins.
    invocation=(env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE "${invocation[@]}")
  fi
  "${invocation[@]}" "${options[@]+"${options[@]}"}" "${protections[@]}" "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
. "$SCRIPT_DIR/lib.sh"

SCHEMA_COLLECTION="tribunal-collection/v1"
SCHEMA_PROOF="tribunal-proof/v1"
PROVIDERS="codex gemini deepseek qwen grok muse claude"
STAGING=""
REVIEW_SOURCE=""
REVIEW_WORKTREES=()
REVIEW_PIDS=()
REVIEW_NAMES=()
CONTAINMENT=session
declare -A LEG_CONTAINMENT=() NAMESPACE_PIDS=()
CONFIG_FILE=""
CONFIG_SNAPSHOT=""
SAFE_DIRECTORY_COUNT=0
SAFE_DIRECTORY_ENV=()
SURFACE_ROOT=""
SURFACE_GITDIR=""
SURFACE_COMMON=""
SURFACE_ID=""
SURFACE_KIND=""
SURFACE_GITDIR_ID=""
SURFACE_COMMON_ID=""
SURFACE_STATE=""
SURFACE_SNAPSHOTS=""
SURFACE_FAILED=0
SURFACE_PINNED=0
VERIFIED_COLLECTION=""
FINAL_TMP1=""
FINAL_TMP2=""

die() { printf 'tribunal evidence: %s\n' "$*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha_file() { sha256sum -- "$1" | awk '{print $1}'; }
bytes_file() { wc -c < "$1" | tr -d ' '; }

kill_leg() {
  local pid="$1" group child children
  if [ "${NAMESPACE_PIDS[$pid]:-}" = yes ]; then
    # Leave unshare alive to wait for PID 1: its wait completes only after the
    # kernel has killed and reaped the namespace, including detached sessions.
    children="$(ps -o pid= --ppid "$pid")" || children=""
    if [ -n "$children" ]; then
      for child in $children; do kill -KILL "$child" 2>/dev/null || true; done
      wait "$pid" 2>/dev/null || true
      unset 'NAMESPACE_PIDS[$pid]'
      return 0
    fi
    # The launcher has finished or has not forked yet; --kill-child covers death
    # during startup. No reviewer can run before that parent-death guard is set.
  fi
  # timeout may create nested groups. Kill every group in the wrapper's session;
  # SIGKILL has no handler/grace period and we never wait for orphan descendants.
  kill -KILL "$pid" 2>/dev/null || true
  while read -r group; do
    kill -KILL -- "-$group" 2>/dev/null || true
  done < <(ps -eo sid=,pgid= | awk -v sid="$pid" '$1 == sid && !seen[$2]++ { print $2 }')
  wait "$pid" 2>/dev/null || true
  unset 'NAMESPACE_PIDS[$pid]'
}

probe_containment() {
  local reason help
  CONTAINMENT=session
  if ! command -v unshare >/dev/null 2>&1; then
    reason="unshare is unavailable"
  elif help="$(unshare --help 2>&1)" && [[ "$help" = *--map-current-user* ]]; then
    if reason="$(timeout -k 1 5 unshare --user --map-current-user --pid --fork --kill-child true 2>&1)"; then
      CONTAINMENT=pid-namespace
      return
    fi
    reason="user/PID namespace probe failed: ${reason%%$'\n'*}"
  else
    reason="unshare lacks --map-current-user (util-linux 2.38+ required)"
  fi
  printf 'tribunal evidence: containment degraded: %s\n' "$reason" >&2
}

reject_uncontained_config() {
  local enabled rc entries
  entries="$(config_entries "$CONFIG_SNAPSHOT")" || die "cannot parse common repository config"
  printf '%s' "$entries" | jq -e 'keys | all(.[]; test("^(include|includeif)\\.") | not)' >/dev/null \
    || die "sealed collection does not support repository config include/includeIf directives; use a clone without them"
  enabled="$(git -C "$1" config --type=bool --get extensions.worktreeConfig)" || {
    rc=$?
    [ "$rc" -eq 1 ] || die "cannot read extensions.worktreeConfig"
  }
  [ "$enabled" != true ] || die "sealed collection does not support extensions.worktreeConfig (per-worktree config cannot be contained); disable it or run tribunal from a clone without it"
}

load_safe_directories() {
  local scope values value rc
  if [ "$SURFACE_PINNED" -eq 1 ]; then
    local -x GIT_DIR="$SURFACE_GITDIR" GIT_COMMON_DIR="$SURFACE_COMMON"
  fi
  # Read only the operator's protected scopes, before any reviewer can change them.
  for scope in system global; do
    values="$(command git -C "$SURFACE_ROOT" config --"$scope" --includes --null --get-all safe.directory \
      | jq -Rs 'split("\u0000")[:-1]')" || {
      rc=$?
      [ "$rc" -eq 1 ] || die "cannot read protected safe.directory ($scope)"
    }
    while IFS= read -r -d '' value; do
      SAFE_DIRECTORY_ENV+=("GIT_CONFIG_KEY_$SAFE_DIRECTORY_COUNT=safe.directory"
        "GIT_CONFIG_VALUE_$SAFE_DIRECTORY_COUNT=$value")
      SAFE_DIRECTORY_COUNT=$((SAFE_DIRECTORY_COUNT + 1))
    done < <(printf '%s' "$values" | jq -j '.[] | ., "\u0000"')
  done
}

copy_surface_file() {
  # Bound even the open: a live sibling can replace a checked path with a FIFO.
  # Check the opened fd before reading, and expose only a private regular copy.
  timeout -k 1 2 bash -c '
    [ -f "$1" ] && [ ! -L "$1" ] || exit 1
    exec 3< "$1"
    [ -f /proc/self/fd/3 ] || exit 1
    cat <&3
  ' _ "$1" > "$2"
}

config_entries() {
  local copy rc=0
  copy="$(mktemp)" || return 1
  if copy_surface_file "$1" "$copy"; then
    # Parse only the private copy; bypass the recursive surface guard.
    GIT_DIR="$SURFACE_GITDIR" GIT_COMMON_DIR="$SURFACE_COMMON" hardened_git config --file "$copy" --list --no-includes --null 2>/dev/null \
      | jq -Rs 'split("\u0000")[:-1] | group_by(split("\n")[0])
        | map({key:(.[0] | split("\n")[0]), value:.}) | from_entries' || rc=$?
  else rc=1; fi
  rm -f -- "$copy"
  return "$rc"
}

changed_config_keys() {
  local before after
  before="$(config_entries "$CONFIG_SNAPSHOT")" || return 1
  after="$(config_entries "$1")" || return 1
  printf '%s\n%s\n' "$before" "$after" | jq -s '
    .[0] as $before | .[1] as $after
    | [($before + $after | keys[]) | select($before[.] != $after[.])]'
}

pin_git_surface() {
  local root_git="$SURFACE_ROOT/.git" kind common
  [ ! -L "$root_git" ] || die "symbolic root git path: $root_git"
  if [ -d "$root_git" ]; then kind=directory
  elif [ -f "$root_git" ]; then kind=file
  else die "root git path is not a directory or gitfile: $root_git"; fi
  # Resolve only before legs launch; subsequent resolution checks use no Git.
  SURFACE_GITDIR="$(real_dir "$(hardened_git -C "$SURFACE_ROOT" rev-parse --absolute-git-dir)")"
  common="$(hardened_git -C "$SURFACE_ROOT" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$SURFACE_ROOT/$common" ;; esac
  SURFACE_COMMON="$(real_dir "$common")"
  SURFACE_SNAPSHOTS="$(mktemp -d)"
  if [ "$kind" = file ]; then snapshot_surface_file "$root_git" root.git; fi
  if [ -e "$SURFACE_GITDIR/commondir" ] || [ -L "$SURFACE_GITDIR/commondir" ]; then
    snapshot_surface_file "$SURFACE_GITDIR/commondir" commondir
  fi
  CONFIG_FILE="$SURFACE_COMMON/config"
  snapshot_surface_file "$CONFIG_FILE" config
  CONFIG_SNAPSHOT="$SURFACE_SNAPSHOTS/config"
  SURFACE_STATE="$(jq -nc --arg kind "$kind" --arg root_id "$(stat -c '%d:%i' -- "$root_git")" \
    --arg git_dir "$SURFACE_GITDIR" --arg git_id "$(stat -c '%d:%i' -- "$SURFACE_GITDIR")" \
    --arg common_dir "$SURFACE_COMMON" --arg common_id "$(stat -c '%d:%i' -- "$SURFACE_COMMON")" \
    --argjson root_file "$(surface_file_metadata root.git)" \
    --argjson commondir "$(surface_file_metadata commondir)" \
    --argjson config "$(surface_file_metadata config)" \
    '{schema:"tribunal-git-surface/v2",root_git:{kind:$kind,identity:$root_id,file:$root_file},
      git_dir:$git_dir,git_dir_identity:$git_id,common_dir:$common_dir,common_dir_identity:$common_id,
      commondir:$commondir,config:$config}')"
  set_surface_identities
  SURFACE_PINNED=1
  check_git_surface || die "cannot pin git surface"
}

snapshot_surface_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || die "git surface is not a regular file: $1"
  cp -p -- "$1" "$SURFACE_SNAPSHOTS/$2"
}

surface_file_metadata() {
  local file="$SURFACE_SNAPSHOTS/$1"
  if [ ! -f "$file" ]; then printf 'null'; return; fi
  jq -nc --arg sha256 "$(sha_file "$file")" --argjson bytes "$(bytes_file "$file")" \
    --arg mode "$(stat -c '%a' -- "$file")" '{sha256:$sha256,bytes:$bytes,mode:$mode}'
}

same_surface_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] \
    && [ "$(stat -c '%d:%i' -- "$1")" = "$2" ] && [ "$(real_dir "$1")" = "$1" ]
}

same_surface_file() {
  local copy rc=0
  copy="$(mktemp "$SURFACE_SNAPSHOTS/current.XXXXXX")" || return 1
  copy_surface_file "$1" "$copy" && cmp -s -- "$copy" "$SURFACE_SNAPSHOTS/$2" || rc=1
  rm -f -- "$copy"
  return "$rc"
}

restore_surface_file() {
  local path="$1" snapshot="$SURFACE_SNAPSHOTS/$2" mode replacement
  mode="$(printf '%s' "$SURFACE_STATE" | jq -r --arg key "$2" \
    'if $key == "root.git" then .root_git.file.mode else .[$key].mode end')"
  # Preserve the pinned gitfile inode; replace other paths without following links.
  if [ "$2" = root.git ] && [ -f "$path" ] && [ ! -L "$path" ] \
    && [ "$(stat -c '%d:%i' -- "$path")" = "$SURFACE_ID" ]; then
    chmod u+w -- "$path" && cat -- "$snapshot" > "$path" && chmod "$mode" "$path"
    return $?
  fi
  replacement="$(mktemp "$(dirname "$path")/.tribunal-restore.XXXXXX")" || return 1
  if cp -- "$snapshot" "$replacement" && chmod "$mode" "$replacement"; then
    if [ -d "$path" ] && [ ! -L "$path" ]; then rm -rf -- "$path"; fi
    if mv -fT -- "$replacement" "$path"; then return 0; fi
  fi
  rm -f -- "$replacement"
  return 1
}

check_git_surface() {
  local changes config_copy problem="" root_git git_ok=0 common_ok=0 root_bad=0 commondir_bad=0
  [ "$SURFACE_FAILED" -eq 0 ] || return 1
  [ "$SURFACE_PINNED" -eq 1 ] || return 0
  root_git="$SURFACE_ROOT/.git"
  if same_surface_dir "$SURFACE_GITDIR" "$SURFACE_GITDIR_ID"; then git_ok=1; fi
  if same_surface_dir "$SURFACE_COMMON" "$SURFACE_COMMON_ID"; then common_ok=1; fi
  if [ "$(stat -c '%d:%i' -- "$root_git" 2>/dev/null)" != "$SURFACE_ID" ] || [ -L "$root_git" ]; then
    root_bad=1
  elif [ "$SURFACE_KIND" = directory ]; then
    [ -d "$root_git" ] && [ "$(real_dir "$root_git")" = "$SURFACE_GITDIR" ] || root_bad=1
  else
    same_surface_file "$root_git" root.git || root_bad=1
  fi
  if [ "$root_bad" -eq 1 ]; then problem="$root_git (original $SURFACE_KIND changed)"
  elif [ "$git_ok" -eq 0 ]; then problem="$SURFACE_GITDIR (git-dir identity or realpath changed)"
  elif [ "$common_ok" -eq 0 ]; then problem="$SURFACE_COMMON (common-dir identity or realpath changed)"; fi
  if [ "$git_ok" -eq 1 ]; then
    if [ -f "$SURFACE_SNAPSHOTS/commondir" ]; then
      same_surface_file "$SURFACE_GITDIR/commondir" commondir || commondir_bad=1
    elif [ -e "$SURFACE_GITDIR/commondir" ] || [ -L "$SURFACE_GITDIR/commondir" ]; then commondir_bad=1; fi
    if [ "$commondir_bad" -eq 1 ]; then
      problem="${problem:+$problem; }$SURFACE_GITDIR/commondir (resolution changed)"
    fi
  fi
  if [ -n "$problem" ]; then
    SURFACE_FAILED=1
    printf 'tribunal evidence: git surface changed: %s\n' "$problem" >&2
    if [ "$root_bad" -eq 1 ] && [ "$SURFACE_KIND" = file ]; then
      restore_surface_file "$root_git" root.git || printf 'cannot restore gitfile: %s\n' "$root_git" >&2
    fi
    if [ "$commondir_bad" -eq 1 ]; then
      if [ -f "$SURFACE_SNAPSHOTS/commondir" ]; then
        restore_surface_file "$SURFACE_GITDIR/commondir" commondir \
          || printf 'cannot restore commondir: %s\n' "$SURFACE_GITDIR/commondir" >&2
      else
        rm -f -- "$SURFACE_GITDIR/commondir" || printf 'cannot remove planted commondir: %s\n' "$SURFACE_GITDIR/commondir" >&2
      fi
    fi
    return 1
  fi
  config_copy="$(mktemp "$SURFACE_SNAPSHOTS/current.XXXXXX")" || return 1
  if copy_surface_file "$CONFIG_FILE" "$config_copy"; then
    if cmp -s "$CONFIG_SNAPSHOT" "$config_copy"; then
      rm -f -- "$config_copy"
      return 0
    fi
    if changes="$(changed_config_keys "$config_copy")"; then
      rm -f -- "$config_copy"
      # Upstream tracking writes from concurrent operator sessions are legitimate.
      printf '%s' "$changes" | jq -e 'all(.[]; startswith("branch."))' >/dev/null && return 0
      changes="$(printf '%s' "$changes" | jq -r '.[:20][]')"
    else
      changes='config key names unavailable (cannot parse config)'
    fi
  else
    changes='config path is missing, symbolic, not a regular file, or cannot be read within the deadline'
  fi
  rm -f -- "$config_copy"
  restore_surface_file "$CONFIG_FILE" config \
    || { printf 'cannot restore shared git config: %s\n' "$CONFIG_FILE" >&2; return 1; }
  printf 'tribunal evidence: shared git config changed: %s (restored)\n%s\n' "$CONFIG_FILE" "$changes" >&2
  return 1
}

load_git_surface() {
  local manifest="$1" name metadata file
  SURFACE_STATE="$(jq -c .git_surface "$manifest")"
  SURFACE_ROOT="$(jq -r .repository.root "$manifest")"
  SURFACE_GITDIR="$(printf '%s' "$SURFACE_STATE" | jq -r .git_dir)"
  SURFACE_COMMON="$(printf '%s' "$SURFACE_STATE" | jq -r .common_dir)"
  # Copy authenticated snapshots to private storage so cleanup never removes evidence.
  SURFACE_SNAPSHOTS="$(mktemp -d)"
  [ -d "$(dirname "$manifest")/git-surface" ] && [ ! -L "$(dirname "$manifest")/git-surface" ] \
    || die "git surface snapshots missing or symbolic"
  for name in root.git commondir config; do
    metadata="$(printf '%s' "$SURFACE_STATE" | jq -c --arg key "$name" \
      'if $key == "root.git" then .root_git.file else .[$key] end')"
    [ "$metadata" != null ] || continue
    file="$(dirname "$manifest")/git-surface/$name"
    [ -f "$file" ] && [ ! -L "$file" ] || die "git surface snapshot missing or symbolic: $name"
    cp -- "$file" "$SURFACE_SNAPSHOTS/$name"
    [ "$(sha_file "$SURFACE_SNAPSHOTS/$name")" = "$(printf '%s' "$metadata" | jq -r .sha256)" ] \
      && [ "$(bytes_file "$SURFACE_SNAPSHOTS/$name")" = "$(printf '%s' "$metadata" | jq -r .bytes)" ] \
      || die "git surface snapshot digest/size mismatch: $name"
  done
  CONFIG_FILE="$SURFACE_COMMON/config"; CONFIG_SNAPSHOT="$SURFACE_SNAPSHOTS/config"
  set_surface_identities
  SURFACE_PINNED=1
  check_git_surface || die "git surface changed; collection rejected"
}

set_surface_identities() {
  IFS=$'\t' read -r SURFACE_KIND SURFACE_ID SURFACE_GITDIR_ID SURFACE_COMMON_ID < <(
    printf '%s' "$SURFACE_STATE" | jq -r '[.root_git.kind,.root_git.identity,.git_dir_identity,.common_dir_identity] | @tsv')
}

cleanup() {
  local rc=$? review_worktree pid leftovers=0
  for pid in ${REVIEW_PIDS[@]+"${REVIEW_PIDS[@]}"}; do kill_leg "$pid"; done
  check_git_surface || rc=1
  if [ "$SURFACE_FAILED" -eq 0 ] && [ -n "$REVIEW_SOURCE" ]; then
    for review_worktree in "${REVIEW_WORKTREES[@]}"; do
      if ! git -C "$REVIEW_SOURCE" worktree remove -f -f "$review_worktree" >/dev/null 2>&1; then
        printf 'tribunal evidence: leftover review worktree: %s\n' "$review_worktree" >&2
        leftovers=1
      fi
    done
  elif [ "$SURFACE_FAILED" -eq 1 ] && [ -n "${REVIEW_WORKTREES[0]:-}" ]; then
    for review_worktree in "${REVIEW_WORKTREES[@]}"; do
      printf 'tribunal evidence: leftover review worktree: %s\n' "$review_worktree" >&2
    done
    leftovers=1
  fi
  [ "$leftovers" -eq 0 ] || printf 'tribunal evidence: after restoring the Git surface, remove leftover worktrees and run git worktree prune\n' >&2
  [ -z "$STAGING" ] || [ ! -e "$STAGING" ] || rm -rf -- "$STAGING"
  [ -z "$FINAL_TMP1" ] || [ ! -e "$FINAL_TMP1" ] || rm -f -- "$FINAL_TMP1"
  [ -z "$FINAL_TMP2" ] || [ ! -e "$FINAL_TMP2" ] || rm -f -- "$FINAL_TMP2"
  [ -z "$SURFACE_SNAPSHOTS" ] || rm -rf -- "$SURFACE_SNAPSHOTS"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

require_tools() {
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) \
    || die "bash 4.3+ is required for wait -n"
  local tool
  for tool in git gh jq sha256sum awk sed wc date mktemp chmod cmp stat flock setsid ps timeout; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
  done
}

require_git_version() {
  local version
  version="$(command git --version)"
  [[ "$version" =~ ^git\ version\ ([0-9]+)\.([0-9]+) ]] \
    && (( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 42) )) \
    || die "git 2.42+ is required for --attr-source and cat-file -Z (found: $version)"
}

real_dir() {
  [ -d "$1" ] || die "directory not found: $1"
  (cd "$1" && pwd -P)
}

origin_identity() {
  local root="$1" origin host slug path
  origin="$(git -C "$root" remote get-url origin 2>/dev/null)" || die "origin remote is required"
  case "$origin" in
    https://*/*|http://*/*|ssh://*/*)
      host="$(printf '%s' "$origin" | sed -E 's#^[a-z]+://([^/@]+@)?([^/:]+)(:[0-9]+)?/.*#\2#')"
      path="$(printf '%s' "$origin" | sed -E 's#^[a-z]+://([^/@]+@)?[^/]+/##')"
      ;;
    *@*:*)
      host="${origin#*@}"; host="${host%%:*}"
      path="${origin#*:}"
      ;;
    *) die "unsupported origin URL: $origin" ;;
  esac
  path="${path#/}"; path="${path%.git}"; path="${path%/}"
  case "$host" in ''|*[!A-Za-z0-9.-]*) die "invalid origin host" ;; esac
  case "$path" in */*/*|/*|*'..'*|'') die "origin must identify one owner/repository" ;; esac
  case "$path" in *[!A-Za-z0-9_.\/-]*) die "invalid origin repository" ;; esac
  slug="$path"
  jq -nc --arg host "$host" --arg slug "$slug" '{host:$host,slug:$slug}'
}

gh_repo() {
  local host="$1" slug="$2"; shift 2
  env -u GH_REPO -u GITHUB_REPOSITORY GH_HOST="$host" GH_PROMPT_DISABLED=1 \
    GH_PAGER=cat PAGER=cat gh "$@" --repo "$slug"
}

live_binding() {
  local root="$1" pr="$2" identity host slug repo_json pr_json canonical repo_url
  identity="$(origin_identity "$root")"
  host="$(printf '%s' "$identity" | jq -r .host)"
  slug="$(printf '%s' "$identity" | jq -r .slug)"
  repo_json="$(env -u GH_REPO -u GITHUB_REPOSITORY GH_HOST="$host" GH_PROMPT_DISABLED=1 \
    GH_PAGER=cat PAGER=cat gh repo view "$slug" --json nameWithOwner,url)" \
    || die "cannot resolve canonical GitHub repository"
  printf '%s' "$repo_json" | jq -e '
    (type == "object") and (.nameWithOwner | type == "string" and length > 2)
    and (.url | type == "string" and length > 8)
  ' >/dev/null || die "invalid repository response"
  canonical="$(printf '%s' "$repo_json" | jq -r .nameWithOwner)"
  repo_url="$(printf '%s' "$repo_json" | jq -r .url)"
  [ "$(printf '%s' "$canonical" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ] \
    || die "origin and canonical GitHub repository differ"
  pr_json="$(gh_repo "$host" "$canonical" pr view "$pr" \
    --json number,url,state,baseRefName,baseRefOid,headRefName,headRefOid,body)" \
    || die "cannot resolve pull request #$pr"
  printf '%s' "$pr_json" | jq -e --argjson n "$pr" '
    (type == "object") and .number == $n and .state == "OPEN"
    and (.url | type == "string" and length > 8)
    and (.baseRefName | type == "string" and length > 0)
    and (.headRefName | type == "string" and length > 0)
    and (.baseRefOid | type == "string" and test("^[0-9a-f]{40}$"))
    and (.headRefOid | type == "string" and test("^[0-9a-f]{40}$"))
    and (.body | type == "string")
  ' >/dev/null || die "pull request is not an open, complete GitHub PR"
  jq -nc --argjson identity "$identity" --arg canonical "$canonical" \
    --arg repo_url "$repo_url" --arg root "$root" --argjson pr "$pr_json" \
    '{repository:{root:$root,host:$identity.host,name_with_owner:$canonical,
       url:$repo_url},pull_request:$pr}'
}

# $3/$4 optional authoritative base/head oids: when given, a review leg must
# have been stamped over exactly that range, so a well-formed leg for another
# revision cannot seal as ok (issue #487).
validate_provider() {
  local provider="$1" file="$2" want_base="${3:-}" want_head="${4:-}"
  jq -e --arg p "$provider" --arg want_base "$want_base" --arg want_head "$want_head" '
    def exact($allowed; $required):
      (type == "object") and ((keys - $allowed) | length == 0)
      and (($required - keys) | length == 0);
    def text: type == "string" and length > 0;
    def uint: type == "number" and . >= 0 and . == floor;
    def confidence: type == "number" and . >= 0 and . <= 1;
    def finding:
      exact(["severity","category","file","line","title","description","suggestion","confidence","line_check"];
            ["severity","category","file","line","title","description","suggestion","confidence"])
      and (.severity | IN("critical","high","medium","low"))
      and (.category | IN("logic","security","performance","quality","edge-case","architecture","testing"))
      and (.file | text and startswith("/") | not)
      and (.file | contains("../") | not)
      and (.line | type == "number" and . >= 1 and . == floor)
      and (.title | text) and (.description | text) and (.suggestion | text)
      and (.confidence | confidence)
      and ((has("line_check") | not) or (.line_check | text));
    def examined_path:
      text and (startswith("/") | not) and (contains("../") | not);
    def summary($fs):
      exact(["total_findings","critical","high","medium","low","quality_score","verdict","note"];
            ["total_findings","critical","high","medium","low","quality_score","verdict"])
      and (.total_findings | uint) and (.critical | uint) and (.high | uint)
      and (.medium | uint) and (.low | uint)
      and (.quality_score | type == "number" and . >= 0 and . <= 10)
      and (.verdict | IN("APPROVE","NEEDS_WORK","BLOCK"))
      and ((has("note") | not) or (.note | type == "string"))
      and .total_findings == ($fs | length)
      and .critical == ([$fs[] | select(.severity == "critical")] | length)
      and .high == ([$fs[] | select(.severity == "high")] | length)
      and .medium == ([$fs[] | select(.severity == "medium")] | length)
      and .low == ([$fs[] | select(.severity == "low")] | length)
      and ((.total_findings > 0) or (.verdict == "APPROVE"));
    def diff_stat:
      exact(["files_changed","insertions","deletions","base","base_oid","head_oid","truncated"];
            ["files_changed","insertions","deletions","base","base_oid","head_oid","truncated"])
      and (.files_changed | uint) and (.insertions | uint) and (.deletions | uint)
      and (.base | text) and (.truncated | type == "boolean")
      and (.base_oid | test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))
      and (.head_oid | test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))
      and ($want_base == "" or .base_oid == $want_base)
      and ($want_head == "" or .head_oid == $want_head);
    .provider == $p and (
      (exact(["provider","status","note"];["provider","status","note"])
       and .status == "disabled" and (.note | text))
      or
      (exact(["provider","error"];["provider","error"])
       and (.error | text))
      or
      (exact(["provider","model","findings","summary","diff_stat","files_examined"];
             ["provider","model","findings","summary","diff_stat","files_examined"])
       and (.model | text) and (.findings | type == "array" and all(.[]; finding))
       and (.findings as $findings | .summary | summary($findings))
       and (.diff_stat | diff_stat)
       and (.files_examined | type == "array" and all(.[]; examined_path)))
    )
  ' "$file" >/dev/null
}

validate_ignored_paths() {
  jq -e '
    type == "array" and length > 0
    and all(.[];
      type == "object" and keys == ["line","path","pattern","source"]
      and (.path | type == "string" and length > 0 and (startswith("/") | not))
      and (.path | contains("../") | not)
      and (.pattern | type == "string" and length > 0)
      and (.source | type == "string" and length > 0)
      and (.line | type == "number" and . >= 1 and . == floor))
    and ([.[].path] | length) == ([.[].path] | unique | length)
  ' "$1" >/dev/null
}

validate_deleted_paths() {
  jq -e '
    type == "array" and length > 0
    and all(.[];
      type == "object" and keys == ["glob","path"]
      and (.path | type == "string" and length > 0 and (startswith("/") | not))
      and (.path | contains("../") | not)
      and (.glob | type == "string" and length > 0))
    and ([.[].path] | length) == ([.[].path] | unique | length)
  ' "$1" >/dev/null
}

validate_mutation_gate() {
  jq -e '
    type == "array" and length > 0
    and all(.[];
      type == "object" and keys == ["command","exit_code","path","result"]
      and (.path | type == "string" and length > 0 and (startswith("/") | not))
      and (.path | contains("../") | not)
      and (.command | type == "string" and length > 0)
      and (.exit_code | type == "number" and . >= 0 and . == floor)
      and (.result | IN("RED","vacuous"))
      and ((.result == "vacuous") == (.exit_code == 0))
      and ((.result == "RED") == (.exit_code != 0)))
    and ([.[].path] | length) == ([.[].path] | unique | length)
    and . == ([.[] | .] | sort_by(.path))
  ' "$1" >/dev/null
}

provider_status() {
  jq -r 'if .status == "disabled" then "disabled" elif has("error") then "failed" else "ok" end' "$1"
}

write_failed_provider() {
  local provider="$1" message="$2" out="$3"
  jq -S -n --arg p "$provider" --arg e "$message" '{provider:$p,error:$e}' > "$out"
}

fail_mutated_providers() {
  local expected_head="$1" dir="$2" provider name worktree_var worktree artifact actual_head dirty paths message changed_paths
  local -x GIT_DIR GIT_COMMON_DIR="$SURFACE_COMMON" GIT_WORK_TREE
  # Worktree variables, review_gitdirs and mutation_errors belong to the active collect invocation.
  for provider in $PROVIDERS; do
    artifact="$dir/providers/$provider.json"
    [ "$(provider_status "$artifact")" != disabled ] || continue
    [ -z "${mutation_errors[$provider]:-}" ] || continue
    name="$provider"
    worktree_var="${name}_worktree"; worktree="${!worktree_var}"
    GIT_DIR="${review_gitdirs[$worktree]}"; GIT_WORK_TREE="$worktree"
    actual_head="$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
      || actual_head=unresolvable
    dirty="$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" \
      || dirty="git status failed"
    [ "$actual_head" != "$expected_head" ] || [ -n "$dirty" ] || continue
    message="provider mutated its review worktree"
    paths="$dirty"
    if [ "$actual_head" != "$expected_head" ]; then
      message="$message: HEAD moved from $expected_head to $actual_head"
      if [ "$actual_head" != unresolvable ]; then
        changed_paths="$(git -C "$worktree" diff --no-ext-diff --no-textconv --name-status "$expected_head" "$actual_head" 2>/dev/null)" \
          || changed_paths="git diff failed"
        paths="$paths"$'\n'"$changed_paths"
      fi
    fi
    paths="$(printf '%s\n' "$paths" | sed '/^$/d' | sed -n '1,20p')"
    [ -z "$paths" ] || message="$message: $paths"
    mutation_errors[$provider]="$message"
    write_failed_provider "$provider" "$message" "$artifact"
    printf 'tribunal evidence: %s: %s\n' "$provider" "${message//$'\n'/; }" >&2
  done
}

wrapper_exit_message() {
  if [ "$1" = 153 ]; then printf 'provider wrapper exited 153 (file size limit (SIGXFSZ))'
  else printf 'provider wrapper exited %s' "$1"; fi
}

run_wrapper() {
  local name="$1" script="$2" worktree="$3" base_oid="$4" dir="$5" pid
  local -a launch=()
  LEG_CONTAINMENT[$name]="$CONTAINMENT"
  if [ "$CONTAINMENT" = pid-namespace ]; then
    if [ "$name" = grok ] && [ "${TRIBUNAL_GROK_SANDBOX:-${GROK_SANDBOX:-none}}" = read-only ]; then
      # Grok's bwrap addresses /proc with namespace PIDs; without a private proc
      # mount that opt-in sandbox fails. Keep its sandbox and run the leg.
      LEG_CONTAINMENT[$name]=session
      printf 'tribunal evidence: containment degraded: grok: read-only sandbox requires host PID visibility\n' >&2
    else
      launch=(unshare --user --map-current-user --pid --fork --kill-child)
    fi
  fi
  printf '%s\n' "$(now)" > "$dir/$name.started"
  # With monitor mode off, $! is not a group leader: setsid execs without forking.
  (cd "$worktree" && ulimit -f 4194304 && exec setsid "${launch[@]+"${launch[@]}"}" env TRIBUNAL_BASE_REF="$base_oid" bash "$script") \
    > "$dir/$name.raw" 2> "$dir/$name.stderr" &
  pid=$!
  REVIEW_PIDS+=("$pid"); REVIEW_NAMES+=("$name")
  if [ "${LEG_CONTAINMENT[$name]}" = pid-namespace ]; then NAMESPACE_PIDS[$pid]=yes; fi
}

wait_wrappers() {
  local index pid name rc running reaped remaining="${#REVIEW_PIDS[@]}"
  while [ "$remaining" -gt 0 ]; do
    running="$(jobs -pr)"
    reaped=0
    for index in "${!REVIEW_PIDS[@]}"; do
      pid="${REVIEW_PIDS[$index]}"; name="${REVIEW_NAMES[$index]}"
      [[ $'\n'"$running"$'\n' != *$'\n'"$pid"$'\n'* ]] || continue
      rc=0
      wait "$pid" || rc=$?
      if [ "${NAMESPACE_PIDS[$pid]:-}" = yes ]; then
        # unshare waited for namespace teardown; never signal a reaped PID.
        unset 'NAMESPACE_PIDS[$pid]'
      else kill_leg "$pid"; fi
      unset 'REVIEW_PIDS[index]' 'REVIEW_NAMES[index]'
      remaining=$((remaining - 1))
      reaped=1
      check_git_surface || die "git surface changed; collection rejected"
      printf '%s\n' "$rc" > "$STAGING/wrappers/$name.exit"
      printf '%s\n' "$(now)" > "$STAGING/wrappers/$name.finished"
    done
    if [ "$remaining" -gt 0 ] && [ "$reaped" -eq 0 ]; then wait -n || true; fi
  done
  REVIEW_PIDS=(); REVIEW_NAMES=()
}

normalize_single() {
  local provider="$1" raw="$2" rc="$3" out="$4" want_base="${5:-}" want_head="${6:-}" count
  if [ "$rc" -ne 0 ]; then
    write_failed_provider "$provider" "$(wrapper_exit_message "$rc")" "$out"
    return
  fi
  count="$(jq -s 'length' "$raw" 2>/dev/null || printf 0)"
  if [ "$count" != 1 ]; then
    write_failed_provider "$provider" "provider wrapper emitted malformed JSON" "$out"
    return
  fi
  jq -S -s --arg p "$provider" '.[0] | .provider = $p' "$raw" > "$out.tmp" 2>/dev/null \
    || { rm -f "$out.tmp"; write_failed_provider "$provider" "provider wrapper emitted malformed JSON" "$out"; return; }
  if validate_provider "$provider" "$out.tmp" "$want_base" "$want_head"; then
    mv "$out.tmp" "$out"
  else
    rm -f "$out.tmp"
    write_failed_provider "$provider" "provider wrapper output failed schema validation" "$out"
  fi
}

wrapper_for_provider() {
  case "$1" in
    codex) printf '%s/run-codex-review.sh\n' "$SCRIPT_DIR" ;;
    gemini) printf '%s/run-gemini-review.sh\n' "$SCRIPT_DIR" ;;
    deepseek) printf '%s/run-deepseek-review.sh\n' "$SCRIPT_DIR" ;;
    qwen) printf '%s/run-qwen-review.sh\n' "$SCRIPT_DIR" ;;
    grok) printf '%s/run-grok-review.sh\n' "$SCRIPT_DIR" ;;
    muse) printf '%s/run-muse-review.sh\n' "$SCRIPT_DIR" ;;
    claude) printf '%s/run-claude-review.sh\n' "$SCRIPT_DIR" ;;
    *) die "unknown provider: $1" ;;
  esac
}

collect() {
  # Crashing legs must not leave core files in their sealed review worktrees.
  ulimit -c 0 || true
  set +m
  local root="" pr="" output="" started binding head_oid base_oid parent review_tmp bundle
  local wrapper name rc provider status artifact stderr wrapper_name providers_json ignored_paths_json deleted_paths_json
  local mutation_gate_json sensitive_paths sensitive_paths_sha256="" source line path content
  local codex_worktree gemini_worktree deepseek_worktree qwen_worktree grok_worktree muse_worktree claude_worktree review_worktree
  local min_ok_legs backup_legs backups backup limited
  local -A mutation_errors=() review_gitdirs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo-root) [ "$#" -ge 2 ] || die "--repo-root needs a value"; root="$2"; shift 2 ;;
      --pr) [ "$#" -ge 2 ] || die "--pr needs a value"; pr="$2"; shift 2 ;;
      --output) [ "$#" -ge 2 ] || die "--output needs a value"; output="$2"; shift 2 ;;
      *) die "unknown collect argument: $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$pr" ] && [ -n "$output" ] || die "collect requires --repo-root, --pr, and --output"
  case "$pr" in ''|*[!0-9]*|0) die "invalid PR number" ;; esac
  # Fail closed on an invalid floor before any provider leg runs (issue #519).
  min_ok_legs="$(tribunal_min_ok_legs)" || exit 1
  tribunal_risk_tier >/dev/null || exit 1
  backup_legs="$(tribunal_backup_legs)" || exit 1
  root="$(real_dir "$root")"
  SURFACE_ROOT="$root"
  load_safe_directories
  require_git_version
  [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$root" ] || die "--repo-root is not a Git worktree root"
  pin_git_surface
  reject_uncontained_config "$root"
  case "$output" in /*) ;; *) die "--output must be absolute" ;; esac
  [ ! -e "$output" ] && [ ! -L "$output" ] || die "collection output already exists"
  parent="$(dirname "$output")"; parent="$(real_dir "$parent")"
  case "$(basename "$output")" in .|..) die "invalid collection output name" ;; esac
  output="$parent/$(basename "$output")"
  [ ! -e "$output" ] && [ ! -L "$output" ] || die "collection output already exists"
  bundle="$(bash "$SCRIPT_DIR/check-runner-bundle.sh")" || die "installed tribunal runner bundle failed integrity validation"
  started="$(now)"
  binding="$(live_binding "$root" "$pr")"
  head_oid="$(printf '%s' "$binding" | jq -r .pull_request.headRefOid)"
  base_oid="$(printf '%s' "$binding" | jq -r .pull_request.baseRefOid)"
  [ "$(git -C "$root" rev-parse HEAD)" = "$head_oid" ] || die "worktree HEAD differs from PR head"
  git -C "$root" cat-file -e "$base_oid^{commit}" 2>/dev/null || die "PR base commit is not available locally"
  git -C "$root" cat-file -e "$head_oid^{commit}" 2>/dev/null || die "PR head commit is not available locally"

  STAGING="$(mktemp -d "$parent/.tribunal-collection.XXXXXX")"
  mkdir -p "$STAGING/providers" "$STAGING/wrappers"
  printf '%s' "$binding" | jq -j .pull_request.body > "$STAGING/pr-body.txt"
  git -C "$root" diff --binary --no-ext-diff --no-textconv "$base_oid...$head_oid" > "$STAGING/review.diff"
  [ -s "$STAGING/review.diff" ] || die "PR has no diff"
  ignored_paths_json="$(cd "$root" && tribunal_ignored_additions "$base_oid")"
  if [ "$(printf '%s' "$ignored_paths_json" | jq 'length')" -gt 0 ]; then
    printf '%s' "$ignored_paths_json" | jq -S . > "$STAGING/ignored-paths.json"
    validate_ignored_paths "$STAGING/ignored-paths.json" || die "internal ignored-path evidence is invalid"
    sensitive_paths="[]"
    while IFS=$'\t' read -r source line path; do
      content="$(git -C "$root" show "$head_oid:$source")" || die "cannot read ignored-path policy: $source"
      if printf '%s\n' "$content" | sed -n "1,${line}p" | awk -v line="$line" '
        NR >= line { exit }
        /^[[:space:]]*#/ {
          if (tolower($0) ~ /(^|[^[:alnum:]])(secrets?|pii|credentials?|keys?)([^[:alnum:]]|$)/ \
              || tolower($0) ~ /(^|[^[:alnum:]])never[[:space:]]+commit([^[:alnum:]]|$)/) sensitive=1
          next
        }
        /^[[:space:]]*$/ { sensitive=0 }
        END { exit !sensitive }
      '; then
        sensitive_paths="$(jq -c --arg path "$path" '. + [$path]' <<<"$sensitive_paths")"
      fi
    done < <(jq -r '.[] | [.source, (.line | tostring), .path] | @tsv' "$STAGING/ignored-paths.json")
    printf '%s' "$sensitive_paths" | jq -S . > "$STAGING/sensitive-paths.json"
    sensitive_paths_sha256="$(sha_file "$STAGING/sensitive-paths.json")"
  fi
  deleted_paths_json="$(cd "$root" && tribunal_deleted_policy_paths "$base_oid")"
  if [ "$(printf '%s' "$deleted_paths_json" | jq 'length')" -gt 0 ]; then
    printf '%s' "$deleted_paths_json" | jq -S . > "$STAGING/deleted-paths.json"
    validate_deleted_paths "$STAGING/deleted-paths.json" || die "internal deleted-path evidence is invalid"
  fi
  mutation_gate_json="$(cd "$root" && tribunal_mutation_gate "$base_oid" "$head_oid")"
  if [ "$(printf '%s' "$mutation_gate_json" | jq 'length')" -gt 0 ]; then
    printf '%s' "$mutation_gate_json" | jq -S . > "$STAGING/mutation-gate.json"
    validate_mutation_gate "$STAGING/mutation-gate.json" || die "internal mutation-gate evidence is invalid"
  fi

  REVIEW_SOURCE="$root"; REVIEW_WORKTREES=()
  for name in codex gemini deepseek qwen grok muse claude; do
    review_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tribunal-$name.XXXXXX")"; rmdir "$review_tmp"
    git -C "$root" worktree add --detach --quiet "$review_tmp" "$head_oid"
    review_tmp="$(real_dir "$review_tmp")"
    REVIEW_WORKTREES+=("$review_tmp")
    # Pin the admin directory, including its worktree id, before any reviewer runs.
    review_gitdirs["$review_tmp"]="$(real_dir "$(git -C "$review_tmp" rev-parse --absolute-git-dir)")"
    case "$name" in
      codex) codex_worktree="$review_tmp" ;;
      gemini) gemini_worktree="$review_tmp" ;;
      deepseek) deepseek_worktree="$review_tmp" ;;
      qwen) qwen_worktree="$review_tmp" ;;
      grok) grok_worktree="$review_tmp" ;;
      muse) muse_worktree="$review_tmp" ;;
      claude) claude_worktree="$review_tmp" ;;
    esac
  done

  probe_containment
  run_wrapper codex "$SCRIPT_DIR/run-codex-review.sh" "$codex_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper gemini "$SCRIPT_DIR/run-gemini-review.sh" "$gemini_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper deepseek "$SCRIPT_DIR/run-deepseek-review.sh" "$deepseek_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper qwen "$SCRIPT_DIR/run-qwen-review.sh" "$qwen_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper grok "$SCRIPT_DIR/run-grok-review.sh" "$grok_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper muse "$SCRIPT_DIR/run-muse-review.sh" "$muse_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper claude "$SCRIPT_DIR/run-claude-review.sh" "$claude_worktree" "$base_oid" "$STAGING/wrappers"
  wait_wrappers

  for name in $PROVIDERS; do
    rc="$(cat "$STAGING/wrappers/$name.exit")"
    normalize_single "$name" "$STAGING/wrappers/$name.raw" "$rc" "$STAGING/providers/$name.json" \
      "$base_oid" "$head_oid"
  done
  fail_mutated_providers "$head_oid" "$STAGING"

  # One backup leg per plan-limited leg, from TRIBUNAL_BACKUP_LEGS: an installed leg whose
  # wrapper sat idle this run. The limited leg stays failed.
  limited=0
  for provider in $PROVIDERS; do
    jq -e '(.error // "") | startswith("plan limit:")' "$STAGING/providers/$provider.json" >/dev/null \
      && limited=$((limited + 1))
  done
  backups=""
  for backup in $backup_legs; do
    [ "$limited" -gt 0 ] || break
    [ "$(provider_status "$STAGING/providers/$backup.json")" = disabled ] || continue
    tribunal_backup_installed "$backup" || continue
    backups="$backups $backup "; limited=$((limited - 1))
  done
  if [ -n "$backups" ]; then
    printf 'tribunal evidence: running backup legs for plan-limited legs:%s\n' "$backups" >&2
    case "$backups" in *" deepseek "*)
      TRIBUNAL_DEEPSEEK=on run_wrapper deepseek "$SCRIPT_DIR/run-deepseek-review.sh" "$deepseek_worktree" "$base_oid" "$STAGING/wrappers" ;;
    esac
    case "$backups" in *" gemini "*)
      TRIBUNAL_GEMINI=on run_wrapper gemini "$SCRIPT_DIR/run-gemini-review.sh" "$gemini_worktree" "$base_oid" "$STAGING/wrappers" ;;
    esac
    case "$backups" in *" qwen "*)
      TRIBUNAL_QWEN=on run_wrapper qwen "$SCRIPT_DIR/run-qwen-review.sh" "$qwen_worktree" "$base_oid" "$STAGING/wrappers" ;;
    esac
    wait_wrappers
    for backup in $backups; do
      normalize_single "$backup" "$STAGING/wrappers/$backup.raw" "$(cat "$STAGING/wrappers/$backup.exit")" \
          "$STAGING/providers/$backup.json" "$base_oid" "$head_oid"
    done
    fail_mutated_providers "$head_oid" "$STAGING"
  fi
  providers_json="$STAGING/providers.jsonl"; : > "$providers_json"
  for provider in $PROVIDERS; do
    artifact="$STAGING/providers/$provider.json"
    validate_provider "$provider" "$artifact" "$base_oid" "$head_oid" \
      || die "internal provider normalization failed: $provider"
    wrapper="$(wrapper_for_provider "$provider")"; wrapper_name="$(basename "$wrapper" .sh)"
    wrapper_name="${wrapper_name#run-}"
    name="$provider"
    status="$(provider_status "$artifact")"
    stderr="$STAGING/wrappers/$name.stderr"
    jq -nc --arg provider "$provider" --arg status "$status" --arg containment "${LEG_CONTAINMENT[$provider]}" \
      --arg wrapper_path "$wrapper" --arg wrapper_sha256 "$(sha_file "$wrapper")" \
      --arg artifact_path "providers/$provider.json" --arg artifact_sha256 "$(sha_file "$artifact")" \
      --argjson artifact_bytes "$(bytes_file "$artifact")" \
      --arg started_at "$(cat "$STAGING/wrappers/$name.started")" \
      --arg finished_at "$(cat "$STAGING/wrappers/$name.finished")" \
      --argjson exit_code "$(cat "$STAGING/wrappers/$name.exit")" \
      --arg stderr_sha256 "$(sha_file "$stderr")" --argjson stderr_bytes "$(bytes_file "$stderr")" \
      '{provider:$provider,status:$status,containment:$containment,wrapper:{path:$wrapper_path,sha256:$wrapper_sha256},
        artifact:{path:$artifact_path,sha256:$artifact_sha256,bytes:$artifact_bytes},
        started_at:$started_at,finished_at:$finished_at,exit_code:$exit_code,
        stderr:{sha256:$stderr_sha256,bytes:$stderr_bytes}}' >> "$providers_json"
  done

  rm -rf "$STAGING/wrappers"
  for review_worktree in "${REVIEW_WORKTREES[@]}"; do
    # A leg may delete its .git file; remove that disposable directory before deregistering it.
    [ -e "$review_worktree/.git" ] || rm -rf -- "$review_worktree"
    git -C "$root" worktree remove -f -f "$review_worktree" >/dev/null
    REVIEW_WORKTREES=("${REVIEW_WORKTREES[@]:1}")
  done
  REVIEW_WORKTREES=(); REVIEW_SOURCE=""
  mkdir "$STAGING/git-surface"
  cp -- "$SURFACE_SNAPSHOTS/"* "$STAGING/git-surface/"
  chmod 0400 "$STAGING/git-surface/"*
  if [ -n "$sensitive_paths_sha256" ]; then
    [ -f "$STAGING/sensitive-paths.json" ] && [ ! -L "$STAGING/sensitive-paths.json" ] \
      && [ "$(sha_file "$STAGING/sensitive-paths.json")" = "$sensitive_paths_sha256" ] \
      || die "sensitive-path evidence changed during review"
  fi
  jq -S -n --arg schema "$SCHEMA_COLLECTION" --arg started_at "$started" \
    --arg completed_at "$(now)" --argjson binding "$binding" \
    --argjson git_surface "$SURFACE_STATE" \
    --arg body_sha256 "$(sha_file "$STAGING/pr-body.txt")" \
    --argjson body_bytes "$(bytes_file "$STAGING/pr-body.txt")" \
    --arg diff_sha256 "$(sha_file "$STAGING/review.diff")" \
    --argjson diff_bytes "$(bytes_file "$STAGING/review.diff")" \
    --arg ignored_paths_sha256 "$([ ! -f "$STAGING/ignored-paths.json" ] || sha_file "$STAGING/ignored-paths.json")" \
    --argjson ignored_paths_bytes "$([ ! -f "$STAGING/ignored-paths.json" ] && printf '0' || bytes_file "$STAGING/ignored-paths.json")" \
    --arg sensitive_paths_sha256 "$sensitive_paths_sha256" \
    --argjson sensitive_paths_bytes "$([ ! -f "$STAGING/sensitive-paths.json" ] && printf '0' || bytes_file "$STAGING/sensitive-paths.json")" \
    --arg deleted_paths_sha256 "$([ ! -f "$STAGING/deleted-paths.json" ] || sha_file "$STAGING/deleted-paths.json")" \
    --argjson deleted_paths_bytes "$([ ! -f "$STAGING/deleted-paths.json" ] && printf '0' || bytes_file "$STAGING/deleted-paths.json")" \
    --arg mutation_gate_sha256 "$([ ! -f "$STAGING/mutation-gate.json" ] || sha_file "$STAGING/mutation-gate.json")" \
    --argjson mutation_gate_bytes "$([ ! -f "$STAGING/mutation-gate.json" ] && printf '0' || bytes_file "$STAGING/mutation-gate.json")" \
    --arg runner_path "$SCRIPT_DIR/collect-review-evidence.sh" \
    --arg runner_sha256 "$(sha_file "$SCRIPT_DIR/collect-review-evidence.sh")" \
    --arg library_path "$SCRIPT_DIR/lib.sh" --arg library_sha256 "$(sha_file "$SCRIPT_DIR/lib.sh")" \
    --arg bundle_manifest_path "$PLUGIN_ROOT/integrity/runner-bundle.json" \
    --arg bundle_manifest_sha256 "$(printf '%s' "$bundle" | jq -r .sha256)" \
    --argjson min_ok_legs "$min_ok_legs" \
    --slurpfile providers "$providers_json" \
    '{schema:$schema,started_at:$started_at,completed_at:$completed_at,
      repository:$binding.repository,
      git_surface:$git_surface,
      pull_request:{number:$binding.pull_request.number,url:$binding.pull_request.url,state:$binding.pull_request.state,
        base_ref:$binding.pull_request.baseRefName,base_oid:$binding.pull_request.baseRefOid,
        head_ref:$binding.pull_request.headRefName,head_oid:$binding.pull_request.headRefOid,
        body:{path:"pr-body.txt",sha256:$body_sha256,bytes:$body_bytes}},
      diff:{path:"review.diff",sha256:$diff_sha256,bytes:$diff_bytes},
      runner:{path:$runner_path,sha256:$runner_sha256,library_path:$library_path,library_sha256:$library_sha256,
        bundle_manifest_path:$bundle_manifest_path,bundle_manifest_sha256:$bundle_manifest_sha256},
      providers:$providers,
      containment:(if all($providers[]; .containment == "pid-namespace") then "pid-namespace" else "session" end),
      panel_policy:{min_ok_legs:$min_ok_legs,source:"env"}}
      + (if $ignored_paths_sha256 == "" then {} else
          {ignored_paths:{path:"ignored-paths.json",sha256:$ignored_paths_sha256,bytes:$ignored_paths_bytes},
           sensitive_paths:{path:"sensitive-paths.json",sha256:$sensitive_paths_sha256,bytes:$sensitive_paths_bytes}} end)
      + (if $deleted_paths_sha256 == "" then {} else
          {deleted_paths:{path:"deleted-paths.json",sha256:$deleted_paths_sha256,bytes:$deleted_paths_bytes}} end)
      + (if $mutation_gate_sha256 == "" then {} else
          {mutation_gate:{path:"mutation-gate.json",sha256:$mutation_gate_sha256,bytes:$mutation_gate_bytes}} end)' \
    > "$STAGING/manifest.json"
  rm -f "$providers_json"
  chmod 0444 "$STAGING/manifest.json" "$STAGING/pr-body.txt" "$STAGING/review.diff" "$STAGING/providers/"*.json
  [ ! -f "$STAGING/ignored-paths.json" ] || chmod 0444 "$STAGING/ignored-paths.json" "$STAGING/sensitive-paths.json"
  [ ! -f "$STAGING/deleted-paths.json" ] || chmod 0444 "$STAGING/deleted-paths.json"
  [ ! -f "$STAGING/mutation-gate.json" ] || chmod 0444 "$STAGING/mutation-gate.json"
  mv -T -- "$STAGING" "$output" 2>/dev/null \
    || die "collection output appeared concurrently"
  STAGING=""
  jq -nc --arg collection "$output" --arg manifest_sha256 "$(sha_file "$output/manifest.json")" \
    --arg runner_bundle_sha256 "$(printf '%s' "$bundle" | jq -r .sha256)" \
    --arg head_oid "$head_oid" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,
      runner_bundle_sha256:$runner_bundle_sha256,head_oid:$head_oid}'
}

validate_manifest_shape() {
  local manifest="$1"
  jq -e --arg schema "$SCHEMA_COLLECTION" '
    def exact($a;$r): (type=="object") and ((keys-$a)|length==0) and (($r-keys)|length==0);
    def text: type=="string" and length>0;
    def sha: type=="string" and test("^[0-9a-f]{64}$");
    def oid: type=="string" and test("^[0-9a-f]{40}$");
    def uint: type=="number" and .>=0 and .==floor;
    def identity: type=="string" and test("^[0-9]+:[0-9]+$");
    def snapshot: exact(["sha256","bytes","mode"];["sha256","bytes","mode"])
      and (.sha256|sha) and (.bytes|uint) and (.mode|type=="string" and test("^[0-7]{3,4}$"));
    def stamp: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    exact(["schema","started_at","completed_at","repository","git_surface","pull_request","diff","runner","providers","ignored_paths","sensitive_paths","deleted_paths","mutation_gate","panel_policy","containment"];
          ["schema","started_at","completed_at","repository","git_surface","pull_request","diff","runner","providers"])
    and .schema==$schema and (.started_at|stamp) and (.completed_at|stamp) and .started_at<=.completed_at
    and (if has("containment") then
      all(.providers[]; .containment|IN("pid-namespace","session"))
      and .containment == (if all(.providers[]; .containment == "pid-namespace") then "pid-namespace" else "session" end)
      else all(.providers[]; has("containment")|not) end)
    and (.git_surface | exact(["schema","root_git","git_dir","git_dir_identity","common_dir","common_dir_identity","commondir","config"];
                              ["schema","root_git","git_dir","git_dir_identity","common_dir","common_dir_identity","commondir","config"])
         and .schema=="tribunal-git-surface/v2"
         and (.git_dir|text and startswith("/")) and (.common_dir|text and startswith("/"))
         and (.git_dir_identity|identity) and (.common_dir_identity|identity)
         and (.root_git | exact(["kind","identity","file"];["kind","identity","file"])
              and (.identity|identity) and ((.kind=="directory" and .file==null) or (.kind=="file" and (.file|snapshot))))
         and (.commondir==null or (.commondir|snapshot)) and (.config|snapshot))
    and (.repository | exact(["root","host","name_with_owner","url"];
                             ["root","host","name_with_owner","url"])
         and (.root|text and startswith("/")) and (.host|test("^[A-Za-z0-9.-]+$"))
         and (.name_with_owner|test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
         and (.url|test("^https://")))
    and (.pull_request | exact(["number","url","state","base_ref","base_oid","head_ref","head_oid","body"];
                               ["number","url","state","base_ref","base_oid","head_ref","head_oid","body"])
         and (.number|uint and .>0) and (.url|test("^https://")) and .state=="OPEN" and (.base_ref|text)
         and (.base_oid|oid) and (.head_ref|text) and (.head_oid|oid)
         and (.body|exact(["path","sha256","bytes"];["path","sha256","bytes"])
              and .path=="pr-body.txt" and (.sha256|sha) and (.bytes|uint)))
    and (.diff | exact(["path","sha256","bytes"];["path","sha256","bytes"])
         and .path=="review.diff" and (.sha256|sha) and (.bytes|uint and .>0))
    and ((has("ignored_paths")|not) or
         (.ignored_paths | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="ignored-paths.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and (has("ignored_paths") == has("sensitive_paths"))
    and ((has("sensitive_paths")|not) or
         (.sensitive_paths | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="sensitive-paths.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and ((has("deleted_paths")|not) or
         (.deleted_paths | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="deleted-paths.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and ((has("mutation_gate")|not) or
         (.mutation_gate | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="mutation-gate.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and ((has("panel_policy")|not) or
         (.panel_policy | exact(["min_ok_legs","source"];["min_ok_legs","source"])
          and (.min_ok_legs|type=="number" and .>=1 and .<=7 and .==floor)
          and .source=="env"))
    and (.runner | exact(["path","sha256","library_path","library_sha256","bundle_manifest_path","bundle_manifest_sha256"];
                         ["path","sha256","library_path","library_sha256","bundle_manifest_path","bundle_manifest_sha256"])
         and (.path|text and startswith("/")) and (.sha256|sha)
         and (.library_path|text and startswith("/")) and (.library_sha256|sha)
         and (.bundle_manifest_path|text and startswith("/")) and (.bundle_manifest_sha256|sha))
    and (.providers|type=="array" and length==7
         and ([.[].provider]|sort)==(["claude","codex","deepseek","gemini","grok","muse","qwen"])
         and all(.[];
           exact(["provider","status","wrapper","artifact","started_at","finished_at","exit_code","stderr","containment"];
                 ["provider","status","wrapper","artifact","started_at","finished_at","exit_code","stderr"])
           and (.provider|IN("codex","gemini","deepseek","qwen","grok","muse","claude"))
           and (.status|IN("ok","failed","disabled"))
           and (.wrapper|exact(["path","sha256"];["path","sha256"])
                and (.path|text and startswith("/")) and (.sha256|sha))
           and (.artifact|exact(["path","sha256","bytes"];["path","sha256","bytes"])
                and (.path|test("^providers/[a-z]+\\.json$")) and (.sha256|sha) and (.bytes|uint and .>0))
           and (.started_at|stamp) and (.finished_at|stamp) and .started_at<=.finished_at and (.exit_code|uint)
           and (.stderr|exact(["sha256","bytes"];["sha256","bytes"])
                and (.sha256|sha) and (.bytes|uint))))
  ' "$manifest" >/dev/null
}

verify_live_binding() {
  local dir="$1" manifest="$2" root pr current expected body_tmp diff_tmp ignored_tmp ignored_json
  local deleted_tmp deleted_json mutation_tmp mutation_json
  root="$(jq -r .repository.root "$manifest")"; root="$(real_dir "$root")"
  pr="$(jq -r .pull_request.number "$manifest")"
  current="$(live_binding "$root" "$pr")"
  expected="$(jq -S -c '{repository,pull_request:{number:.pull_request.number,url:.pull_request.url,state:.pull_request.state,
    baseRefName:.pull_request.base_ref,baseRefOid:.pull_request.base_oid,
    headRefName:.pull_request.head_ref,headRefOid:.pull_request.head_oid}}' "$manifest")"
  [ "$(printf '%s' "$current" | jq -S -c 'del(.pull_request.body)')" = "$expected" ] \
    || die "repository or pull request drifted after collection"
  body_tmp="$(mktemp)"; diff_tmp="$(mktemp)"
  printf '%s' "$current" | jq -j .pull_request.body > "$body_tmp"
  [ "$(sha_file "$body_tmp")" = "$(jq -r .pull_request.body.sha256 "$manifest")" ] \
    || { rm -f "$body_tmp" "$diff_tmp"; die "pull request body drifted after collection"; }
  git -C "$root" diff --binary --no-ext-diff --no-textconv "$(jq -r .pull_request.base_oid "$manifest")...$(jq -r .pull_request.head_oid "$manifest")" > "$diff_tmp"
  [ "$(sha_file "$diff_tmp")" = "$(jq -r .diff.sha256 "$manifest")" ] \
    || { rm -f "$body_tmp" "$diff_tmp"; die "pull request diff drifted after collection"; }
  rm -f "$body_tmp" "$diff_tmp"
  [ "$(git -C "$root" rev-parse HEAD)" = "$(jq -r .pull_request.head_oid "$manifest")" ] \
    || die "worktree HEAD drifted after collection"
  ignored_json="$(cd "$root" && tribunal_ignored_additions "$(jq -r .pull_request.base_oid "$manifest")")"
  if jq -e 'has("ignored_paths")' "$manifest" >/dev/null; then
    ignored_tmp="$(mktemp)"; printf '%s' "$ignored_json" | jq -S . > "$ignored_tmp"
    cmp -s "$ignored_tmp" "$dir/ignored-paths.json" \
      || { rm -f "$ignored_tmp"; die "ignored-path evidence drifted after collection"; }
    rm -f "$ignored_tmp"
  else
    [ "$(printf '%s' "$ignored_json" | jq 'length')" -eq 0 ] \
      || die "ignored-path evidence appeared after collection"
  fi
  deleted_json="$(cd "$root" && tribunal_deleted_policy_paths "$(jq -r .pull_request.base_oid "$manifest")")"
  if jq -e 'has("deleted_paths")' "$manifest" >/dev/null; then
    deleted_tmp="$(mktemp)"; printf '%s' "$deleted_json" | jq -S . > "$deleted_tmp"
    cmp -s "$deleted_tmp" "$dir/deleted-paths.json" \
      || { rm -f "$deleted_tmp"; die "deleted-path evidence drifted after collection"; }
    rm -f "$deleted_tmp"
  else
    [ "$(printf '%s' "$deleted_json" | jq 'length')" -eq 0 ] \
      || die "deleted-path evidence appeared after collection"
  fi
  mutation_json="$(cd "$root" && tribunal_mutation_gate "$(jq -r .pull_request.base_oid "$manifest")" "$(jq -r .pull_request.head_oid "$manifest")")"
  if jq -e 'has("mutation_gate")' "$manifest" >/dev/null; then
    mutation_tmp="$(mktemp)"; printf '%s' "$mutation_json" | jq -S . > "$mutation_tmp"
    cmp -s "$mutation_tmp" "$dir/mutation-gate.json" \
      || { rm -f "$mutation_tmp"; die "mutation-gate evidence drifted after collection"; }
    rm -f "$mutation_tmp"
  else
    [ "$(printf '%s' "$mutation_json" | jq 'length')" -eq 0 ] \
      || die "mutation-gate evidence appeared after collection"
  fi
  [ "$(sha_file "$dir/pr-body.txt")" = "$(jq -r .pull_request.body.sha256 "$manifest")" ] \
    || die "retained PR body digest mismatch"
  [ "$(bytes_file "$dir/pr-body.txt")" = "$(jq -r .pull_request.body.bytes "$manifest")" ] \
    || die "retained PR body size mismatch"
  [ "$(sha_file "$dir/review.diff")" = "$(jq -r .diff.sha256 "$manifest")" ] \
    || die "retained diff digest mismatch"
  [ "$(bytes_file "$dir/review.diff")" = "$(jq -r .diff.bytes "$manifest")" ] \
    || die "retained diff size mismatch"
}

verify_collection_internal() {
  local dir="$1" expected_sha="$2" manifest provider path status wrapper roots
  [ ! -L "$dir" ] || die "collection directory must not be symbolic"
  dir="$(real_dir "$dir")"; manifest="$dir/manifest.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || die "collection manifest missing or symbolic"
  [ -d "$dir/providers" ] && [ ! -L "$dir/providers" ] || die "provider artifact directory missing or symbolic"
  [ -f "$dir/pr-body.txt" ] && [ ! -L "$dir/pr-body.txt" ] || die "retained PR body missing or symbolic"
  [ -f "$dir/review.diff" ] && [ ! -L "$dir/review.diff" ] || die "retained diff missing or symbolic"
  [ "$expected_sha" = "$(sha_file "$manifest")" ] || die "collection manifest digest mismatch"
  jq -e '.git_surface.schema == "tribunal-git-surface/v2"' "$manifest" >/dev/null \
    || die "collection manifest lacks git_surface identity; recollect with this runner (older manifests are unsupported)"
  validate_manifest_shape "$manifest" || die "collection manifest schema invalid"
  load_git_surface "$manifest"
  load_safe_directories
  require_git_version
  reject_uncontained_config "$SURFACE_ROOT"
  if jq -e 'has("ignored_paths")' "$manifest" >/dev/null; then
    [ -f "$dir/ignored-paths.json" ] && [ ! -L "$dir/ignored-paths.json" ] \
      || die "ignored-path artifact missing or symbolic"
    [ "$(sha_file "$dir/ignored-paths.json")" = "$(jq -r .ignored_paths.sha256 "$manifest")" ] \
      || die "ignored-path artifact digest mismatch"
    [ "$(bytes_file "$dir/ignored-paths.json")" = "$(jq -r .ignored_paths.bytes "$manifest")" ] \
      || die "ignored-path artifact size mismatch"
    validate_ignored_paths "$dir/ignored-paths.json" || die "ignored-path artifact schema invalid"
    [ -f "$dir/sensitive-paths.json" ] && [ ! -L "$dir/sensitive-paths.json" ] \
      || die "sensitive-path artifact missing or symbolic"
    [ "$(sha_file "$dir/sensitive-paths.json")" = "$(jq -r .sensitive_paths.sha256 "$manifest")" ] \
      || die "sensitive-path artifact digest mismatch"
    [ "$(bytes_file "$dir/sensitive-paths.json")" = "$(jq -r .sensitive_paths.bytes "$manifest")" ] \
      || die "sensitive-path artifact size mismatch"
    jq -e --slurpfile ignored "$dir/ignored-paths.json" '
      type == "array" and (length == (unique | length))
      and ((. - [$ignored[0][].path]) | length == 0)
    ' "$dir/sensitive-paths.json" >/dev/null || die "sensitive-path artifact schema invalid"
  else
    [ ! -e "$dir/ignored-paths.json" ] || die "unbound ignored-path artifact"
    [ ! -e "$dir/sensitive-paths.json" ] || die "unbound sensitive-path artifact"
  fi
  if jq -e 'has("deleted_paths")' "$manifest" >/dev/null; then
    [ -f "$dir/deleted-paths.json" ] && [ ! -L "$dir/deleted-paths.json" ] \
      || die "deleted-path artifact missing or symbolic"
    [ "$(sha_file "$dir/deleted-paths.json")" = "$(jq -r .deleted_paths.sha256 "$manifest")" ] \
      || die "deleted-path artifact digest mismatch"
    [ "$(bytes_file "$dir/deleted-paths.json")" = "$(jq -r .deleted_paths.bytes "$manifest")" ] \
      || die "deleted-path artifact size mismatch"
    validate_deleted_paths "$dir/deleted-paths.json" || die "deleted-path artifact schema invalid"
  else
    [ ! -e "$dir/deleted-paths.json" ] || die "unbound deleted-path artifact"
  fi
  if jq -e 'has("mutation_gate")' "$manifest" >/dev/null; then
    [ -f "$dir/mutation-gate.json" ] && [ ! -L "$dir/mutation-gate.json" ] \
      || die "mutation-gate artifact missing or symbolic"
    [ "$(sha_file "$dir/mutation-gate.json")" = "$(jq -r .mutation_gate.sha256 "$manifest")" ] \
      || die "mutation-gate artifact digest mismatch"
    [ "$(bytes_file "$dir/mutation-gate.json")" = "$(jq -r .mutation_gate.bytes "$manifest")" ] \
      || die "mutation-gate artifact size mismatch"
    validate_mutation_gate "$dir/mutation-gate.json" || die "mutation-gate artifact schema invalid"
  else
    [ ! -e "$dir/mutation-gate.json" ] || die "unbound mutation-gate artifact"
  fi
  roots="collection root=$(dirname "$(dirname "$(jq -r .runner.path "$manifest")")"); invoked root=$PLUGIN_ROOT"
  [ "$(jq -r .runner.path "$manifest")" = "$SCRIPT_DIR/collect-review-evidence.sh" ] \
    || die "collection runner path differs from installed runner ($roots)"
  [ "$(jq -r .runner.sha256 "$manifest")" = "$(sha_file "$SCRIPT_DIR/collect-review-evidence.sh")" ] \
    || die "collection runner digest differs from installed runner ($roots)"
  [ "$(jq -r .runner.library_path "$manifest")" = "$SCRIPT_DIR/lib.sh" ] \
    || die "collection library path differs from installed library ($roots)"
  [ "$(jq -r .runner.library_sha256 "$manifest")" = "$(sha_file "$SCRIPT_DIR/lib.sh")" ] \
    || die "collection library digest differs from installed library ($roots)"
  [ "$(jq -r .runner.bundle_manifest_path "$manifest")" = "$PLUGIN_ROOT/integrity/runner-bundle.json" ] \
    || die "collection runner bundle manifest path differs from installed bundle ($roots)"
  [ "$(jq -r .runner.bundle_manifest_sha256 "$manifest")" = "$(sha_file "$PLUGIN_ROOT/integrity/runner-bundle.json")" ] \
    || die "collection runner bundle manifest digest differs from installed bundle ($roots)"
  bash "$SCRIPT_DIR/check-runner-bundle.sh" \
    --expected-manifest-sha256 "$(jq -r .runner.bundle_manifest_sha256 "$manifest")" >/dev/null \
    || die "installed tribunal runner bundle failed integrity validation"
  for provider in $PROVIDERS; do
    path="$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.artifact.path' "$manifest")"
    [ "$path" = "providers/$provider.json" ] || die "unexpected artifact path for $provider"
    [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ] || die "provider artifact missing or symbolic: $provider"
    [ "$(sha_file "$dir/$path")" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.artifact.sha256' "$manifest")" ] \
      || die "provider artifact digest mismatch: $provider"
    [ "$(bytes_file "$dir/$path")" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.artifact.bytes' "$manifest")" ] \
      || die "provider artifact size mismatch: $provider"
    validate_provider "$provider" "$dir/$path" || die "provider artifact schema invalid: $provider"
    status="$(provider_status "$dir/$path")"
    [ "$status" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.status' "$manifest")" ] \
      || die "provider status mismatch: $provider"
    wrapper="$(wrapper_for_provider "$provider")"
    [ "$wrapper" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.wrapper.path' "$manifest")" ] \
      || die "provider wrapper path mismatch: $provider"
    [ "$(sha_file "$wrapper")" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.wrapper.sha256' "$manifest")" ] \
      || die "provider wrapper digest mismatch: $provider"
  done
  verify_live_binding "$dir" "$manifest"
  VERIFIED_COLLECTION="$dir"
}

validate_arbitration() {
  local arbitration="$1" manifest="$2" statuses dir evidence ignored_paths deleted_paths mutation_gate sensitive_paths
  local min_ok_legs
  statuses="$(jq -c '[.providers[]|{key:.provider,value:.status}]|from_entries' "$manifest")"
  # Sealed floor only — never re-read ambient TRIBUNAL_MIN_OK_LEGS (issue #519).
  min_ok_legs="$(jq '.panel_policy.min_ok_legs // 1' "$manifest")"
  dir="$(dirname "$manifest")"
  evidence="$(jq -nc \
    --slurpfile codex "$dir/providers/codex.json" --slurpfile gemini "$dir/providers/gemini.json" \
    --slurpfile deepseek "$dir/providers/deepseek.json" \
    --slurpfile qwen "$dir/providers/qwen.json" --slurpfile grok "$dir/providers/grok.json" \
    --slurpfile muse "$dir/providers/muse.json" \
    --slurpfile claude "$dir/providers/claude.json" \
    '{codex:$codex[0],gemini:$gemini[0],deepseek:$deepseek[0],qwen:$qwen[0],grok:$grok[0],muse:$muse[0],claude:$claude[0]}')"
  if jq -e 'has("ignored_paths")' "$manifest" >/dev/null; then
    ignored_paths="$(jq -c . "$dir/ignored-paths.json")"
  else
    ignored_paths="[]"
  fi
  if jq -e 'has("deleted_paths")' "$manifest" >/dev/null; then
    deleted_paths="$(jq -c . "$dir/deleted-paths.json")"
  else
    deleted_paths="[]"
  fi
  if jq -e 'has("mutation_gate")' "$manifest" >/dev/null; then
    mutation_gate="$(jq -c . "$dir/mutation-gate.json")"
  else
    mutation_gate="[]"
  fi
  sensitive_paths="[]"
  if jq -e 'has("ignored_paths")' "$manifest" >/dev/null; then
    sensitive_paths="$(jq -c . "$dir/sensitive-paths.json")"
  fi
  jq -e --argjson statuses "$statuses" --argjson min_ok_legs "$min_ok_legs" --argjson evidence "$evidence" \
    --argjson ignored_paths "$ignored_paths" --argjson deleted_paths "$deleted_paths" \
    --argjson mutation_gate "$mutation_gate" \
    --argjson sensitive_paths "$sensitive_paths" '
    def exact($a;$r): (type=="object") and ((keys-$a)|length==0) and (($r-keys)|length==0);
    def text: type=="string" and length>0;
    def uint: type=="number" and .>=0 and .==floor;
    def conf: type=="number" and .>=0 and .<=1;
    def finding:
      exact(["id","consensus","providers","severity","category","file","line","title","description","suggestion","confidence","blocking_proof","arbiter_notes"];
            ["id","consensus","providers","severity","category","file","line","title","description","suggestion","confidence","arbiter_notes"])
      and (.id|test("^T-[0-9]{3,}$")) and (.consensus|IN("CONSENSUS","SINGLE_PROVIDER"))
      and (. as $finding | .providers|type=="array" and length>0 and length==([.[]]|unique|length)
           and all(.[]; . as $p
             | if $p == "repository-policy" then
                 ($ignored_paths | any(.[]; .path == $finding.file))
                 or ($deleted_paths | any(.[]; .path == $finding.file))
                 or ($mutation_gate | any(.[]; .path == $finding.file))
               else
                 ($p | IN("codex","gemini","deepseek","qwen","grok","muse","claude"))
                 and $statuses[$p] == "ok"
                 and (($evidence[$p].findings // []) | any(.[]; .file == $finding.file))
               end))
      and ((.providers|length)>=2) == (.consensus=="CONSENSUS")
      and (.severity|IN("critical","high","medium","low"))
      and (.category|IN("logic","security","performance","quality","edge-case","architecture","testing"))
      and (.file|text and startswith("/")|not) and (.file|contains("../")|not)
      and (.line|type=="number" and .>=1 and .==floor)
      and (.title|text) and (.description|text) and (.suggestion|text) and (.confidence|conf)
      and (.arbiter_notes|type=="string")
      and (if (.severity|IN("critical","high")) then
        (.blocking_proof|exact(["reachable_path","material_impact","caused_by_change"];
                               ["reachable_path","material_impact","caused_by_change"])
         and all(.[];text))
        else (has("blocking_proof")|not) or
          (.blocking_proof|exact(["reachable_path","material_impact","caused_by_change"];
                                 ["reachable_path","material_impact","caused_by_change"])
           and all(.[];text)) end);
    def scope:
      exact(["id","path","why_out_of_scope","disposition","conflicting_task_text","smallest_acceptable_diff"];
            ["id","path","why_out_of_scope","disposition","conflicting_task_text","smallest_acceptable_diff"])
      and (.id|test("^S-[0-9]{3,}$")) and (.path|text)
      and (.why_out_of_scope|text) and (.disposition|IN("must-remove-before-merge","follow-up-only"))
      and (.conflicting_task_text|type=="string") and (.smallest_acceptable_diff|text);
    def assessment($p;$final):
      exact(["findings_accepted","findings_rejected","false_positives","status"];
            ["findings_accepted","findings_rejected","false_positives","status"])
      and (.findings_accepted|uint) and (.findings_rejected|uint)
      and (.false_positives|type=="array" and all(.[];type=="string"))
      and .status==$statuses[$p]
      and .findings_accepted == ([$final[] | select(.providers | index($p))] | length)
      and (.findings_accepted + .findings_rejected) <= (($evidence[$p].findings // []) | length)
      and (.false_positives | length) <= .findings_rejected;
    exact(["tribunal_verdict","findings","scope_findings","provider_assessment","conflicts_resolved","summary"];
          ["tribunal_verdict","findings","scope_findings","provider_assessment","conflicts_resolved","summary"])
    and (.tribunal_verdict|exact(["decision","confidence","rationale"];
                                ["decision","confidence","rationale"])
         and (.decision|IN("APPROVE","NEEDS_WORK","BLOCK")) and (.confidence|conf) and (.rationale|text))
    and (.findings|type=="array" and all(.[];finding) and ([.[].id]|length)==([.[].id]|unique|length))
    and (.findings as $findings | $ignored_paths | all(.[]; .path as $path
      | any($findings[]; .file == $path and (.providers | index("repository-policy")))))
    and (.findings as $findings | $deleted_paths | all(.[]; .path as $path
      | any($findings[]; .file == $path and (.providers | index("repository-policy")))))
    and (.findings as $findings | [$mutation_gate[] | select(.result == "vacuous")] | all(.[]; .path as $path
      | any($findings[]; .file == $path and (.providers | index("repository-policy")))))
    and (.findings as $findings | $sensitive_paths | all(.[]; . as $path
      | any($findings[]; .file == $path and (.providers | index("repository-policy"))
          and .severity == "high")))
    and (.scope_findings|type=="array" and all(.[];scope) and ([.[].id]|length)==([.[].id]|unique|length))
    and (.findings as $final_findings | .provider_assessment
         | exact(["codex","gemini","deepseek","qwen","grok","muse","claude"];
                 ["codex","gemini","deepseek","qwen","grok","muse","claude"])
         and (.codex|assessment("codex";$final_findings))
         and (.gemini|assessment("gemini";$final_findings))
         and (.deepseek|assessment("deepseek";$final_findings))
         and (.qwen|assessment("qwen";$final_findings)) and (.grok|assessment("grok";$final_findings))
         and (.muse|assessment("muse";$final_findings))
         and (.claude|assessment("claude";$final_findings)))
    and (.conflicts_resolved|type=="array" and all(.[];type=="string")) and (.summary|text)
    and (if .tribunal_verdict.decision=="APPROVE" then
      (([$statuses[]|select(.=="ok")]|length) >= $min_ok_legs)
      and (if ($statuses | any(.[]; .=="failed")) then
        .tribunal_verdict.confidence > 0 and .tribunal_verdict.confidence < 0.95
      else .tribunal_verdict.confidence==0.95 end)
      and ([.findings[]|select(.severity=="critical" or .severity=="high")]|length)==0
      and ([.scope_findings[]|select(.disposition=="must-remove-before-merge")]|length)==0
      else true end)
    and (if ([$statuses[]|select(.=="ok")]|length)==0
      then .tribunal_verdict.decision=="NEEDS_WORK" and .tribunal_verdict.confidence==0 else true end)
    and (if ([$statuses[]|select(.=="ok")]|length) >= $min_ok_legs
            and ($statuses | all(.[]; .=="ok" or .=="disabled"))
            and ([$evidence[]|(.findings // [])[]]|length)==0
            and ([.findings[]|select(.providers==["repository-policy"])]|length)==0
            and ([.scope_findings[]|select(.disposition=="must-remove-before-merge")]|length)==0
            and ([$mutation_gate[] | select(.result == "vacuous")] | length) == 0
      then .tribunal_verdict.decision=="APPROVE" and .tribunal_verdict.confidence==0.95 else true end)
  ' "$arbitration" >/dev/null
}

parse_collection_args() {
  COLLECTION=""; EXPECTED_MANIFEST=""; ARBITRATION=""; EXPECTED_PROOF=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --collection) [ "$#" -ge 2 ] || die "--collection needs a value"; COLLECTION="$2"; shift 2 ;;
      --expected-manifest-sha256) [ "$#" -ge 2 ] || die "--expected-manifest-sha256 needs a value"; EXPECTED_MANIFEST="$2"; shift 2 ;;
      --arbitration) [ "$#" -ge 2 ] || die "--arbitration needs a value"; ARBITRATION="$2"; shift 2 ;;
      --expected-proof-sha256) [ "$#" -ge 2 ] || die "--expected-proof-sha256 needs a value"; EXPECTED_PROOF="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$COLLECTION" ] && [ -n "$EXPECTED_MANIFEST" ] || die "--collection and --expected-manifest-sha256 are required"
  case "$COLLECTION" in /*) ;; *) die "--collection must be absolute" ;; esac
  case "$EXPECTED_MANIFEST" in *[!0-9a-f]*|'') die "invalid expected manifest digest" ;; esac
  [ "${#EXPECTED_MANIFEST}" -eq 64 ] || die "invalid expected manifest digest"
}

write_proof() {
  local manifest="$1" manifest_sha="$2" arbitration="$3" output="$4"
  jq -S -n --arg schema "$SCHEMA_PROOF" --arg finalized_at "$(now)" \
    --arg manifest_sha256 "$manifest_sha" --arg arbitration_sha256 "$(sha_file "$arbitration")" \
    --argjson pr_number "$(jq -r .pull_request.number "$manifest")" \
    --arg head_oid "$(jq -r .pull_request.head_oid "$manifest")" \
    --arg body_sha256 "$(jq -r .pull_request.body.sha256 "$manifest")" \
    --arg diff_sha256 "$(jq -r .diff.sha256 "$manifest")" \
    --arg decision "$(jq -r .tribunal_verdict.decision "$arbitration")" \
    --argjson confidence "$(jq -r .tribunal_verdict.confidence "$arbitration")" \
    --argjson critical_count "$(jq '[.findings[]|select(.severity=="critical")]|length' "$arbitration")" \
    --argjson high_count "$(jq '[.findings[]|select(.severity=="high")]|length' "$arbitration")" \
    '{schema:$schema,finalized_at:$finalized_at,manifest_sha256:$manifest_sha256,
      pull_request:{number:$pr_number,head_oid:$head_oid,body_sha256:$body_sha256,diff_sha256:$diff_sha256},
      arbitration:{path:"arbitration.json",sha256:$arbitration_sha256,decision:$decision,
        confidence:$confidence,critical_count:$critical_count,high_count:$high_count}}' > "$output"
}

proof_result() {
  local dir="$1" manifest_sha="$2"
  jq -nc --arg collection "$dir" --arg manifest_sha256 "$manifest_sha" \
    --arg proof_sha256 "$(sha_file "$dir/proof.json")" \
    --arg arbitration_sha256 "$(sha_file "$dir/arbitration.json")" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,proof_sha256:$proof_sha256,
      arbitration_sha256:$arbitration_sha256}'
}

verify_proof_internal() {
  local dir="$1" manifest_sha="$2" expected_proof="$3" manifest proof arbitration
  manifest="$dir/manifest.json"; proof="$dir/proof.json"; arbitration="$dir/arbitration.json"
  [ -f "$proof" ] && [ ! -L "$proof" ] && [ -f "$arbitration" ] && [ ! -L "$arbitration" ] \
    || die "retained tribunal proof is incomplete"
  [ "$(sha_file "$proof")" = "$expected_proof" ] || die "tribunal proof digest mismatch"
  validate_arbitration "$arbitration" "$manifest" || die "retained arbitration is invalid"
  jq -e --arg schema "$SCHEMA_PROOF" --arg manifest_sha "$manifest_sha" \
    --arg arbitration_sha "$(sha_file "$arbitration")" \
    --argjson pr "$(jq -r .pull_request.number "$manifest")" \
    --arg head "$(jq -r .pull_request.head_oid "$manifest")" \
    --arg body "$(jq -r .pull_request.body.sha256 "$manifest")" \
    --arg diff "$(jq -r .diff.sha256 "$manifest")" \
    --arg decision "$(jq -r .tribunal_verdict.decision "$arbitration")" \
    --argjson confidence "$(jq -r .tribunal_verdict.confidence "$arbitration")" \
    --argjson critical "$(jq '[.findings[]|select(.severity=="critical")]|length' "$arbitration")" \
    --argjson high "$(jq '[.findings[]|select(.severity=="high")]|length' "$arbitration")" '
      (type=="object") and ((keys-["schema","finalized_at","manifest_sha256","pull_request","arbitration"]|length)==0)
      and .schema==$schema
      and (.finalized_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and .manifest_sha256==$manifest_sha
      and .pull_request=={number:$pr,head_oid:$head,body_sha256:$body,diff_sha256:$diff}
      and .arbitration=={path:"arbitration.json",sha256:$arbitration_sha,decision:$decision,
        confidence:$confidence,critical_count:$critical,high_count:$high}
    ' "$proof" >/dev/null || die "tribunal proof schema or binding is invalid"
}

idempotent_finalize_result() {
  local dir="$1" manifest_sha="$2" canonical="$3" expected_proof
  [ -f "$dir/arbitration.json" ] && [ ! -L "$dir/arbitration.json" ] \
    && [ -f "$dir/proof.json" ] && [ ! -L "$dir/proof.json" ] \
    || die "retained tribunal proof is incomplete"
  cmp -s "$canonical" "$dir/arbitration.json" || die "conflicting arbitration for finalized collection"
  expected_proof="$(sha_file "$dir/proof.json")"
  verify_proof_internal "$dir" "$manifest_sha" "$expected_proof"
  rm -f "$canonical"; FINAL_TMP1=""
  proof_result "$dir" "$manifest_sha"
}

finalize() {
  parse_collection_args "$@"
  local dir manifest canonical retained_tmp proof_tmp lock_fd
  verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST"
  dir="$VERIFIED_COLLECTION"
  [ -n "$ARBITRATION" ] || die "finalize requires --arbitration"
  [ -f "$ARBITRATION" ] && [ ! -L "$ARBITRATION" ] || die "arbitration file missing or symbolic"
  manifest="$dir/manifest.json"
  validate_arbitration "$ARBITRATION" "$manifest" || die "arbitration schema or provider status is invalid"
  canonical="$(mktemp "${TMPDIR:-/tmp}/tribunal-arbitration.XXXXXX")"; FINAL_TMP1="$canonical"
  jq -S . "$ARBITRATION" > "$canonical"
  validate_arbitration "$canonical" "$manifest" || die "canonical arbitration validation failed"

  if [ -e "$dir/proof.json" ]; then
    idempotent_finalize_result "$dir" "$EXPECTED_MANIFEST" "$canonical"
    return
  fi
  [ ! -e "$dir/arbitration.json" ] || cmp -s "$canonical" "$dir/arbitration.json" \
    || die "conflicting arbitration retained after interrupted finalization"

  exec {lock_fd}> "$dir/.finalize.lock"
  if ! flock -n "$lock_fd"; then
    if [ -f "$dir/proof.json" ] && [ -f "$dir/arbitration.json" ]; then
      idempotent_finalize_result "$dir" "$EXPECTED_MANIFEST" "$canonical"
      return
    fi
    die "collection finalization is already in progress"
  fi
  if [ -e "$dir/proof.json" ]; then
    idempotent_finalize_result "$dir" "$EXPECTED_MANIFEST" "$canonical"
    return
  fi
  if [ -e "$dir/arbitration.json" ]; then
    cmp -s "$canonical" "$dir/arbitration.json" \
      || die "conflicting arbitration retained after interrupted finalization"
  else
    retained_tmp="$dir/.arbitration.$$.tmp"; FINAL_TMP2="$retained_tmp"
    cp "$canonical" "$retained_tmp"
    chmod 0444 "$retained_tmp"
    mv "$retained_tmp" "$dir/arbitration.json"; FINAL_TMP2=""
  fi
  rm -f "$canonical"; FINAL_TMP1=""

  proof_tmp="$dir/.proof.$$.tmp"; FINAL_TMP2="$proof_tmp"
  write_proof "$manifest" "$EXPECTED_MANIFEST" "$dir/arbitration.json" "$proof_tmp"
  chmod 0444 "$proof_tmp"
  mv "$proof_tmp" "$dir/proof.json"; FINAL_TMP2=""
  verify_proof_internal "$dir" "$EXPECTED_MANIFEST" "$(sha_file "$dir/proof.json")"
  chmod 0555 "$dir/providers" "$dir"
  proof_result "$dir" "$EXPECTED_MANIFEST"
}

verify_collection_cmd() {
  parse_collection_args "$@"
  [ -z "$ARBITRATION" ] && [ -z "$EXPECTED_PROOF" ] || die "unexpected verify-collection argument"
  local dir
  verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST"
  dir="$VERIFIED_COLLECTION"
  jq -nc --arg collection "$dir" --arg manifest_sha256 "$EXPECTED_MANIFEST" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,status:"valid"}'
}

verify_proof_cmd() {
  parse_collection_args "$@"
  [ -n "$EXPECTED_PROOF" ] || die "verify-proof requires --expected-proof-sha256"
  case "$EXPECTED_PROOF" in *[!0-9a-f]*|'') die "invalid expected proof digest" ;; esac
  [ "${#EXPECTED_PROOF}" -eq 64 ] || die "invalid expected proof digest"
  local dir
  verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST"
  dir="$VERIFIED_COLLECTION"
  verify_proof_internal "$dir" "$EXPECTED_MANIFEST" "$EXPECTED_PROOF"
  jq -nc --arg collection "$dir" --arg proof_sha256 "$EXPECTED_PROOF" \
    '{collection:$collection,proof_sha256:$proof_sha256,status:"valid"}'
}

usage() {
  cat >&2 <<'EOF'
Usage:
  collect-review-evidence.sh collect --repo-root ROOT --pr N --output ABS_DIR
  collect-review-evidence.sh verify-collection --collection DIR --expected-manifest-sha256 SHA
  collect-review-evidence.sh finalize --collection DIR --expected-manifest-sha256 SHA --arbitration FILE
  collect-review-evidence.sh verify-proof --collection DIR --expected-manifest-sha256 SHA --expected-proof-sha256 SHA
EOF
  exit 2
}

require_tools
command="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$command" in
  collect) collect "$@" ;;
  verify-collection) verify_collection_cmd "$@" ;;
  finalize) finalize "$@" ;;
  verify-proof) verify_proof_cmd "$@" ;;
  *) usage ;;
esac
