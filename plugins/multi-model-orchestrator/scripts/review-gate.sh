#!/usr/bin/env bash
# review-gate.sh — combine review legs into one verdict and enforce that an
# advisory-only engine is never the sole reviewer.
#
# The local Qwen leg reads the diff and has no shell, so it cannot verify by
# execution. It is a decorrelated extra lens, never the review itself. That rule
# used to live in prose; this script enforces it.
#
# Usage:
#   review-gate.sh --leg <provider>=<final-message-file> [--leg ...]
#
# Providers whose name is `qwen-local` (or starts with `qwen-local-`) are
# advisory. Any other provider counts as an independent reviewer.
#
# Exit codes:
#   0  APPROVE     — every leg approved and at least one independent leg did
#   1  NEEDS_WORK  — at least one leg asked for work
#   2  usage, unreadable leg, or a leg without a terminal verdict
#   3  advisory-only review set: no independent reviewer present
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"

usage() {
  printf '%s\n' 'Usage: review-gate.sh --leg <provider>=<final-message-file> [--leg ...]'
}

legs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --leg) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; legs+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'review-gate: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "${#legs[@]}" -gt 0 ] || { printf 'review-gate: no --leg given\n' >&2; usage >&2; exit 2; }

mmo_is_advisory_provider() {
  case "$1" in
    qwen-local|qwen-local-*) return 0 ;;
    *) return 1 ;;
  esac
}

independent=0
needs_work=0

for leg in "${legs[@]}"; do
  provider="${leg%%=*}"
  file="${leg#*=}"
  if [ -z "$provider" ] || [ "$provider" = "$leg" ] || [ -z "$file" ]; then
    printf 'review-gate: --leg must be <provider>=<file>, got: %s\n' "$leg" >&2
    exit 2
  fi
  if [ ! -r "$file" ]; then
    printf 'review-gate: cannot read %s leg: %s\n' "$provider" "$file" >&2
    exit 2
  fi
  if ! mmo_has_review_verdict "$file"; then
    printf 'review-gate: %s leg has no terminal APPROVE/NEEDS_WORK: %s\n' "$provider" "$file" >&2
    exit 2
  fi
  if mmo_verdict_is_needs_work "$file"; then
    needs_work=1
  fi
  mmo_is_advisory_provider "$provider" || independent=1
done

if [ "$independent" -eq 0 ]; then
  printf 'review-gate: advisory-only review set — the local engine reads the diff and cannot run probes, so it may not be the only reviewer; add an independent provider\n' >&2
  exit 3
fi

if [ "$needs_work" -eq 1 ]; then
  printf 'NEEDS_WORK\n'
  exit 1
fi

printf 'APPROVE\n'
exit 0
