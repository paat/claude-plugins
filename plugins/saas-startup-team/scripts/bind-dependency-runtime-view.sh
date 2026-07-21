#!/usr/bin/env bash
# Materialize a private dependency-runtime view for a disposable tree.
# Never creates a symlink (or bind mount) into the primary checkout — always a
# private copy — so verification writes cannot mutate the sealed primary runtime.
set -euo pipefail

usage() {
  echo "usage: bind-dependency-runtime-view.sh --primary-root DIR --target-root DIR --runtime REL" >&2
  echo "       bind-dependency-runtime-view.sh --primary-root DIR --digest REL" >&2
  exit 2
}

need_value() { [ "$#" -ge 2 ] || usage; }

PRIMARY=
TARGET=
RUNTIME=
ACTION=bind

while [ "$#" -gt 0 ]; do
  case "$1" in
    --primary-root) need_value "$@"; PRIMARY=$2; shift 2 ;;
    --target-root) need_value "$@"; TARGET=$2; shift 2 ;;
    --runtime) need_value "$@"; RUNTIME=${2%/}; shift 2 ;;
    --digest) need_value "$@"; ACTION=digest; RUNTIME=${2%/}; shift 2 ;;
    -h|--help) usage ;;
    *) echo "bind-dependency-runtime-view: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$PRIMARY" ] && [ -n "$RUNTIME" ] || usage
case "$RUNTIME" in
  ''|.|/*|../*|*/../*|*/..|*..*) echo "bind-dependency-runtime-view: invalid runtime path" >&2; exit 2 ;;
esac
case "${RUNTIME##*/}" in
  node_modules|venv|.venv) : ;;
  *) echo "bind-dependency-runtime-view: unsupported runtime class: $RUNTIME" >&2; exit 2 ;;
esac

PRIMARY=$(cd -- "$PRIMARY" && pwd -P) || {
  echo "bind-dependency-runtime-view: primary root is unreadable" >&2; exit 1; }
source="$PRIMARY/$RUNTIME"
[ -d "$source" ] && [ ! -L "$source" ] || {
  echo "bind-dependency-runtime-view: primary runtime must be a real directory" >&2; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
digest_runtime() {
  python3 "$SCRIPT_DIR/runtime-tree-digest.py" "$1" "$2"
}

if [ "$ACTION" = digest ]; then
  digest_runtime "$source" "$RUNTIME"
  exit 0
fi

[ -n "$TARGET" ] || usage
if [ -d "$TARGET" ]; then
  TARGET=$(cd -- "$TARGET" && pwd -P) || {
    echo "bind-dependency-runtime-view: target root is unreadable" >&2; exit 1; }
else
  # Allow a not-yet-created target dir whose parent exists.
  target_parent=$(dirname -- "$TARGET")
  target_base=$(basename -- "$TARGET")
  target_parent=$(cd -- "$target_parent" && pwd -P) || {
    echo "bind-dependency-runtime-view: target parent is unreadable" >&2; exit 1; }
  TARGET="$target_parent/$target_base"
fi
[ "$TARGET" != "$PRIMARY" ] || {
  echo "bind-dependency-runtime-view: target root must differ from primary" >&2; exit 1; }
# Fail closed if either root is nested inside the other — never write a view
# under the sealed primary tree (or reverse).
case "$TARGET" in
  "$PRIMARY"/*)
    echo "bind-dependency-runtime-view: target root must not nest under primary" >&2
    exit 1
    ;;
esac
case "$PRIMARY" in
  "$TARGET"/*)
    echo "bind-dependency-runtime-view: primary root must not nest under target" >&2
    exit 1
    ;;
esac

dest="$TARGET/$RUNTIME"
[ ! -e "$dest" ] && [ ! -L "$dest" ] || {
  echo "bind-dependency-runtime-view: target runtime path already exists" >&2; exit 1; }

parent=$(dirname -- "$dest")
mkdir -p -- "$parent"
# Private copy only — no symlink, no bind mount into primary.
if ! cp -a -- "$source" "$dest"; then
  rm -rf -- "$dest"
  echo "bind-dependency-runtime-view: could not copy runtime view" >&2; exit 1
fi
if [ ! -d "$dest" ] || [ -L "$dest" ]; then
  rm -rf -- "$dest"
  echo "bind-dependency-runtime-view: copied runtime is unsafe" >&2; exit 1
fi

# Prove the primary tree was not rewritten by the materialization itself.
primary_digest=$(digest_runtime "$source" "$RUNTIME") || {
  rm -rf -- "$dest"; exit 1; }
view_digest=$(digest_runtime "$dest" "$RUNTIME") || {
  rm -rf -- "$dest"; exit 1; }
if [ "$primary_digest" != "$view_digest" ]; then
  rm -rf -- "$dest"
  echo "bind-dependency-runtime-view: copy digest mismatch" >&2; exit 1
fi
printf '%s\n' "$dest"
