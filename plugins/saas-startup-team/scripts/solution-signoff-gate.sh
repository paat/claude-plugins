#!/usr/bin/env bash
# Validate the solution signoff on the primary checkout (no second trees).
set -euo pipefail

SIGNOFF_PATH=.startup/go-live/solution-signoff.md
SOURCE_ROOT=
TARGET_ROOT=

usage() {
  echo "usage: solution-signoff-gate.sh --source-root DIR [--target-root DIR]" >&2
  echo "  target must be omitted or identical to source (primary-only)." >&2
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

fingerprint() {
  git hash-object --stdin < "$1"
}

source_is_regular() {
  [ ! -L "$SOURCE_ROOT/.startup" ] &&
    [ ! -L "$SOURCE_ROOT/.startup/go-live" ] &&
    [ -f "$SOURCE_FILE" ] &&
    [ ! -L "$SOURCE_FILE" ]
}

SOURCE_ROOT=$(repo_root "$SOURCE_ROOT")
SOURCE_FILE="$SOURCE_ROOT/$SIGNOFF_PATH"

if [ -n "$TARGET_ROOT" ]; then
  TARGET_ROOT=$(repo_root "$TARGET_ROOT")
  [ "$TARGET_ROOT" = "$SOURCE_ROOT" ] ||
    die "primary-only: --target-root must equal --source-root (no second trees)"
fi

source_is_regular || die "source signoff is missing, non-regular, or symlinked: $SOURCE_FILE"
SOURCE_HASH=$(fingerprint "$SOURCE_FILE") || die "cannot read source signoff: $SOURCE_FILE"
source_is_regular && [ "$(fingerprint "$SOURCE_FILE")" = "$SOURCE_HASH" ] ||
  die "source signoff changed during validation"
printf '%s\n' "$SOURCE_FILE"
