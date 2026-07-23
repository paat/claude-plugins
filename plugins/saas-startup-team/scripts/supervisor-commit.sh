#!/usr/bin/env bash
# Run the product check and optionally stage and commit product changes.
set -euo pipefail

ROOT=.
CHECK=./check.sh
MESSAGE=
CHECK_ONLY=0
FIREWALL=

usage() {
  echo "usage: supervisor-commit.sh --check-only [--check PATH] [--repo-root DIR]" >&2
  echo "       supervisor-commit.sh --message TEXT [--check PATH] [--repo-root DIR] [--firewall-script PATH]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --message) [ "$#" -ge 2 ] || usage; MESSAGE=$2; shift 2 ;;
    --check) [ "$#" -ge 2 ] || usage; CHECK=$2; shift 2 ;;
    --repo-root) [ "$#" -ge 2 ] || usage; ROOT=$2; shift 2 ;;
    --firewall-script) [ "$#" -ge 2 ] || usage; FIREWALL=$2; shift 2 ;;
    *) echo "supervisor-commit: unknown argument: $1" >&2; usage ;;
  esac
done

ROOT=$(cd -- "$ROOT" && pwd -P)
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "supervisor-commit: invalid repository root" >&2
  exit 1
}
case "$CHECK" in
  /*) CHECK_PATH=$CHECK ;;
  *) CHECK_PATH="$ROOT/${CHECK#./}" ;;
esac
[ -f "$CHECK_PATH" ] && [ ! -L "$CHECK_PATH" ] || {
  echo "supervisor-commit: check must be a regular file" >&2
  exit 1
}

(cd "$ROOT" && bash "$CHECK_PATH")
[ "$CHECK_ONLY" -eq 0 ] || exit 0
[ -n "$MESSAGE" ] || usage

git -C "$ROOT" add -A -- . ':(exclude).startup' ':(exclude).startup/**'
git -C "$ROOT" diff --cached --quiet --exit-code && {
  echo "supervisor-commit: no product changes to commit" >&2
  exit 1
}

if [ -n "$FIREWALL" ]; then
  case "$FIREWALL" in
    /*) FIREWALL_PATH=$FIREWALL ;;
    *) FIREWALL_PATH="$ROOT/${FIREWALL#./}" ;;
  esac
  [ -f "$FIREWALL_PATH" ] && [ ! -L "$FIREWALL_PATH" ] || {
    echo "supervisor-commit: firewall script must be a regular file" >&2
    exit 1
  }
  diff_file=$(mktemp) || exit 1
  # shellcheck disable=SC2064
  trap 'rm -f -- "$diff_file"' EXIT
  git -C "$ROOT" diff --cached --binary > "$diff_file" || {
    rm -f -- "$diff_file"; exit 1; }
  (cd "$ROOT" && bash "$FIREWALL_PATH" --firewall "$diff_file") || {
    ec=$?
    git -C "$ROOT" reset -q HEAD -- . || true
    rm -f -- "$diff_file"
    trap - EXIT
    exit "$ec"
  }
  rm -f -- "$diff_file"
  trap - EXIT
fi

git -C "$ROOT" commit -m "$MESSAGE"
