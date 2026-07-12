#!/usr/bin/env bash
# fleet-targets.sh — enumerate propagation targets from the fleet manifest.
# Output: one target per line, tab-separated: NAME<TAB>KIND<TAB>EXEC
#   KIND: host | container | file
#   EXEC: for containers, the docker exec prefix to reach a shell in it;
#         for file targets, the path; for host, "-".
#
# Usage: fleet-targets.sh list [--manifest F]
# Manifest (default ~/.config/fleet-propagate/fleet.json):
#   { "docker_cmd": "docker",
#     "docker_exec_user": "dev",
#     "container_filters": ["name=webtop", "name=devbox"],
#     "exclude_containers": ["webtop-old"],
#     "init_scripts": ["~/containers/init/*.sh"],
#     "creator_skills": ["~/.claude/skills/container-creator/SKILL.md"] }
# Exit: 0 ok; 1 docker unreachable while filters configured; 2 usage/manifest.
set -uo pipefail

MODE="${1:-}"; [ "$#" -gt 0 ] && shift || { echo "fleet-targets: mode required (list)" >&2; exit 2; }
[ "$MODE" = "list" ] || { echo "fleet-targets: unknown mode: $MODE" >&2; exit 2; }
MANIFEST="${HOME:-/nonexistent}/.config/fleet-propagate/fleet.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest) [ "$#" -ge 2 ] || { echo "fleet-targets: --manifest needs a value" >&2; exit 2; }; MANIFEST="$2"; shift 2 ;;
    *) echo "fleet-targets: unknown arg: $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "fleet-targets: jq required" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "fleet-targets: manifest not found: $MANIFEST" >&2; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { echo "fleet-targets: malformed manifest: $MANIFEST" >&2; exit 2; }

DOCKER_CMD="$(jq -r '.docker_cmd // "docker"' "$MANIFEST")"
EXEC_USER="$(jq -r '.docker_exec_user // empty' "$MANIFEST")"
case "$EXEC_USER" in *[!A-Za-z0-9_:.-]*) echo "fleet-targets: invalid docker_exec_user" >&2; exit 2 ;; esac
USER_OPT=""; [ -n "$EXEC_USER" ] && USER_OPT=" -u $EXEC_USER"

printf 'host\thost\t-\n'

filters="$(jq -r '(.container_filters // [])[]' "$MANIFEST")"
if [ -n "$filters" ]; then
  seen="$(mktemp)"; trap 'rm -f "$seen"' EXIT
  fail=0
  while IFS= read -r flt; do
    [ -n "$flt" ] || continue
    if ! out="$($DOCKER_CMD ps --filter "$flt" --format '{{.Names}}' 2>/dev/null)"; then
      fail=1; continue
    fi
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      grep -qxF -- "$c" "$seen" && continue
      jq -e --arg c "$c" '(.exclude_containers // []) | index($c) != null' "$MANIFEST" >/dev/null && continue
      printf '%s\n' "$c" >> "$seen"
      printf '%s\tcontainer\t%s exec%s -i %s\n' "$c" "$DOCKER_CMD" "$USER_OPT" "$c"
    done <<< "$out"
  done <<< "$filters"
  if [ "$fail" -eq 1 ]; then
    echo "fleet-targets: docker unreachable via '$DOCKER_CMD' — container targets incomplete" >&2
    exit 1
  fi
fi

while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  case "$pat" in "~/"*) pat="${HOME:-/nonexistent}/${pat#\~/}" ;; esac
  for f in $pat; do
    [ -e "$f" ] || continue
    printf '%s\tfile\t%s\n' "$(basename "$f")" "$f"
  done
done < <(jq -r '((.init_scripts // []) + (.creator_skills // []))[]' "$MANIFEST")
exit 0
