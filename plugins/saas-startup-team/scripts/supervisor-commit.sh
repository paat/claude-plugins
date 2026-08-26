#!/usr/bin/env bash
# Run the product check and optionally stage and commit product changes.
set -euo pipefail

die() { echo "supervisor-commit: $1" >&2; exit "${2:-1}"; }

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
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "invalid repository root"
case "$CHECK" in
  /*) CHECK_PATH=$CHECK ;;
  *) CHECK_PATH="$ROOT/${CHECK#./}" ;;
esac
[ -f "$CHECK_PATH" ] && [ ! -L "$CHECK_PATH" ] || die "check must be a regular file"

(cd "$ROOT" && bash "$CHECK_PATH")
[ "$CHECK_ONLY" -eq 0 ] || exit 0
[ -n "$MESSAGE" ] || usage

git -C "$ROOT" add -A -- . ':(exclude).startup' ':(exclude).startup/**'
git -C "$ROOT" diff --cached --quiet --exit-code && {
  die "no product changes to commit"
}

if [ -n "$FIREWALL" ]; then
  case "$FIREWALL" in
    /*) FIREWALL_PATH=$FIREWALL ;;
    *) FIREWALL_PATH="$ROOT/${FIREWALL#./}" ;;
  esac
  [ -f "$FIREWALL_PATH" ] && [ ! -L "$FIREWALL_PATH" ] || die "firewall script must be a regular file"
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
