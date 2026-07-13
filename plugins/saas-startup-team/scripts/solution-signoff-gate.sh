#!/usr/bin/env bash
# Validate the solution signoff, optionally refreshing it into a linked worktree.
set -euo pipefail

SIGNOFF_PATH=.startup/go-live/solution-signoff.md
SOURCE_ROOT=
TARGET_ROOT=

usage() {
  echo "usage: solution-signoff-gate.sh --source-root DIR [--target-root DIR]" >&2
}

die() {
  echo "solution-signoff-gate: $*" >&2
  exit 1
}

need_value() {
  [ "$#" -ge 2 ] || { usage; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-root) need_value "$@"; SOURCE_ROOT="$2"; shift 2 ;;
    --target-root) need_value "$@"; TARGET_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "solution-signoff-gate: unsupported argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$SOURCE_ROOT" ] || { usage; exit 2; }

repo_root() {
  local root
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) ||
    die "not a Git worktree: $1"
  (cd "$root" && pwd -P) || die "cannot resolve Git worktree: $1"
}

common_dir() {
  local root="$1" raw
  raw=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) ||
    die "cannot resolve Git common directory: $root"
  case "$raw" in
    /*) (cd "$raw" && pwd -P) ;;
    *) (cd "$root/$raw" && pwd -P) ;;
  esac || die "cannot resolve Git common directory: $root"
}

fingerprint() {
  git hash-object --stdin < "$1"
}

source_is_regular() {
  [ ! -L "$SOURCE_ROOT/.startup" ] &&
    [ ! -L "$SOURCE_ROOT/.startup/go-live" ] &&
    [ -f "$SOURCE_FILE" ] &&
    [ ! -L "$SOURCE_FILE" ]
}

target_is_clean() {
  local status
  status=$(git -C "$TARGET_ROOT" status --porcelain --untracked-files=all 2>/dev/null) ||
    die "cannot inspect target worktree: $TARGET_ROOT"
  [ -z "$status" ]
}

remove_stale_target() {
  if [ -e "$TARGET_FILE" ] || [ -L "$TARGET_FILE" ]; then
    if [ -d "$TARGET_FILE" ] && [ ! -L "$TARGET_FILE" ]; then
      die "target signoff path is a directory: $TARGET_FILE"
    fi
    rm -f "$TARGET_FILE" || die "cannot remove stale target signoff: $TARGET_FILE"
  fi
  target_is_clean || die "target worktree is not clean after stale signoff removal: $TARGET_ROOT"
}

invalidate_target() {
  local reason="$1"
  remove_stale_target
  die "$reason"
}

SOURCE_ROOT=$(repo_root "$SOURCE_ROOT")
SOURCE_FILE="$SOURCE_ROOT/$SIGNOFF_PATH"

if [ -z "$TARGET_ROOT" ]; then
  source_is_regular || die "source signoff is missing, non-regular, or symlinked: $SOURCE_FILE"
  SOURCE_HASH=$(fingerprint "$SOURCE_FILE") || die "cannot read source signoff: $SOURCE_FILE"
  source_is_regular && [ "$(fingerprint "$SOURCE_FILE")" = "$SOURCE_HASH" ] ||
    die "source signoff changed during validation"
  printf '%s\n' "$SOURCE_FILE"
  exit 0
fi

TARGET_ROOT=$(repo_root "$TARGET_ROOT")
TARGET_FILE="$TARGET_ROOT/$SIGNOFF_PATH"
[ "$SOURCE_ROOT" != "$TARGET_ROOT" ] ||
  die "copy mode requires a distinct target worktree"
SOURCE_COMMON=$(common_dir "$SOURCE_ROOT") || die "cannot inspect source Git common directory"
TARGET_COMMON=$(common_dir "$TARGET_ROOT") || die "cannot inspect target Git common directory"
[ "$SOURCE_COMMON" = "$TARGET_COMMON" ] ||
  die "source and target do not share a Git common directory"
target_is_clean || die "target worktree is not clean: $TARGET_ROOT"
git -C "$TARGET_ROOT" check-ignore -q -- "$SIGNOFF_PATH" ||
  die "target signoff path is not ignored: $TARGET_FILE"
[ ! -L "$TARGET_ROOT/.startup" ] && [ ! -L "$TARGET_ROOT/.startup/go-live" ] ||
  die "target signoff parent is symlinked: $TARGET_FILE"

if ! source_is_regular; then
  invalidate_target "source signoff is missing, non-regular, or symlinked: $SOURCE_FILE"
fi

SOURCE_HASH=$(fingerprint "$SOURCE_FILE") ||
  invalidate_target "cannot read source signoff: $SOURCE_FILE"
mkdir -p "$(dirname "$TARGET_FILE")" ||
  invalidate_target "cannot create target signoff directory"
if [ -L "$TARGET_FILE" ]; then
  rm -f "$TARGET_FILE" || die "cannot remove stale target signoff: $TARGET_FILE"
elif [ -e "$TARGET_FILE" ] && [ ! -f "$TARGET_FILE" ]; then
  die "target signoff path is not a regular file: $TARGET_FILE"
fi
TMP_FILE="$TARGET_FILE.tmp.$$.$RANDOM"
cleanup() { rm -f "$TMP_FILE" "$TARGET_FILE"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
(umask 077; set -o noclobber; : > "$TMP_FILE") 2>/dev/null ||
  invalidate_target "cannot create temporary target signoff"
cp "$SOURCE_FILE" "$TMP_FILE" || invalidate_target "cannot copy source signoff"

[ "$(fingerprint "$TMP_FILE")" = "$SOURCE_HASH" ] ||
  invalidate_target "copied signoff failed validation"
source_is_regular || invalidate_target "source signoff changed type during copy"
[ "$(fingerprint "$SOURCE_FILE")" = "$SOURCE_HASH" ] ||
  invalidate_target "source signoff changed during copy"
if [ -L "$TARGET_FILE" ]; then
  rm -f "$TARGET_FILE" || die "cannot remove stale target signoff: $TARGET_FILE"
elif [ -e "$TARGET_FILE" ] && [ ! -f "$TARGET_FILE" ]; then
  die "target signoff path is not a regular file: $TARGET_FILE"
fi
mv -f "$TMP_FILE" "$TARGET_FILE" ||
  invalidate_target "cannot atomically replace target signoff"
trap - EXIT INT TERM HUP

if ! source_is_regular || [ "$(fingerprint "$SOURCE_FILE")" != "$SOURCE_HASH" ]; then
  rm -f "$TARGET_FILE"
  die "source signoff changed during copy"
fi
[ -f "$TARGET_FILE" ] && [ ! -L "$TARGET_FILE" ] &&
  [ "$(fingerprint "$TARGET_FILE")" = "$SOURCE_HASH" ] || {
    rm -f "$TARGET_FILE"
    die "target signoff failed validation"
  }
target_is_clean || die "target worktree became dirty while refreshing signoff: $TARGET_ROOT"

printf '%s\n' "$TARGET_FILE"
