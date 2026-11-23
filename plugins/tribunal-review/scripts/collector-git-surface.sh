#!/usr/bin/env bash
# Hardened git wrapper and git-surface pinning, snapshotting, validation, and restoration.
# Sourced by scripts/collect-review-evidence.sh before lib.sh and untrusted repo operations.

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
