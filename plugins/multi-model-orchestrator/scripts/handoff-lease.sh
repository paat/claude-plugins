#!/usr/bin/env bash
# handoff-lease.sh — one orchestrator per handoff directory.
#
#   handoff-lease.sh claim OWNER [--ttl SECONDS] [--dir DIR]   take or renew the lease
#   handoff-lease.sh release OWNER [--dir DIR]                 drop it when the run ends
#
# The lease is DIR/.lease holding "OWNER EXPIRES_EPOCH". claim succeeds when there is no
# lease, when it is OWNER's, or when it has expired, and then holds it for --ttl seconds
# (default 3600). A crashed session cannot release, so a lease blocks only until it expires:
# renew it before every dispatch with a ttl that covers the leg.
# DIR defaults to ${MMO_HANDOFF_DIR:-.claude/handoffs} under the checkout's root, beside the
# handoffs it guards: a linked worktree is a separate run with its own lease.
#
# Exit codes: 0 held by OWNER (claim) or not held by OWNER any more (release); 2 usage;
# 75 held by another owner — that owner and its expiry go to stderr.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: handoff-lease.sh claim|release OWNER [--ttl SECONDS] [--dir DIR]'
}

action="${1:-}"
owner="${2:-}"
case "$action" in claim|release) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
[[ "$owner" =~ ^[A-Za-z0-9._:-]+$ ]] || { printf 'handoff-lease: OWNER must match [A-Za-z0-9._:-]+\n' >&2; usage >&2; exit 2; }
shift 2
ttl=3600
dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ttl) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; ttl="$2"; shift 2 ;;
    --dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; dir="$2"; shift 2 ;;
    *) printf 'handoff-lease: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$ttl" =~ ^[1-9][0-9]*$ ]] || { printf 'handoff-lease: ttl must be a positive integer\n' >&2; exit 2; }
if [ -z "$dir" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf 'handoff-lease: not in a git repository; pass --dir\n' >&2; exit 2; }
  dir="$root/${MMO_HANDOFF_DIR:-.claude/handoffs}"
fi
mkdir -p "$dir"
lease="$dir/.lease"

exec 9> "$lease.lock"
flock 9
now="$(date +%s)"
held_owner=""
held_until=0
[ ! -f "$lease" ] || read -r held_owner held_until _ < "$lease" || true
[[ "$held_until" =~ ^[0-9]+$ ]] || held_until=0

if [ "$action" = release ]; then
  [ "$held_owner" != "$owner" ] || rm -f -- "$lease"
  exit 0
fi
if [ -n "$held_owner" ] && [ "$held_owner" != "$owner" ] && [ "$held_until" -gt "$now" ]; then
  printf 'handoff-lease: exit=75 held by %s until %s\n' "$held_owner" "$(date -u -d "@$held_until" +%Y-%m-%dT%H:%M:%SZ)" >&2
  exit 75
fi
printf '%s %s\n' "$owner" "$((now + ttl))" > "$lease"
