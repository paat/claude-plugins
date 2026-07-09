#!/usr/bin/env bash
# ui-touch.sh — classify a changeset as UI-touching or not.
# Usage:
#   ui-touch.sh --range <git-range>   # e.g. main...HEAD; changed files via git
#   ui-touch.sh --files               # newline-separated paths on stdin
# Prints "ui" or "no-ui" (exit 0). Usage error → exit 2.
# Fails toward "ui" only on real signal; empty input prints "no-ui".
set -euo pipefail

usage() { echo "usage: ui-touch.sh --range <git-range> | --files (paths on stdin)" >&2; exit 2; }

case "${1:-}" in
  --range) range="${2:-}"; [ -n "$range" ] || usage
           files=$(git diff --name-only "$range" 2>/dev/null) || usage ;;
  --files) files=$(cat) ;;
  *) usage ;;
esac

# UI-touching file patterns — single source of truth. One ERE branch per line.
PATTERNS='\.(css|scss|sass|less)$
\.(tsx|jsx|vue|svelte)$
(^|/)[^/]*(tailwind|theme)[^/]*\.(js|ts|cjs|mjs|json)$
(^|/)(components?|layouts?|pages|views|templates|partials)/.*\.(ts|js|html|erb|blade\.php|razor|cshtml)$
(^|/)(locales?|i18n|lang|translations?)/
\.(po|pot)$
(^|/)public/.*\.(svg|png|ico)$'

if [ -n "$files" ] && printf '%s\n' "$files" | grep -Eq "$(printf '%s' "$PATTERNS" | paste -sd'|' -)"; then
  echo ui
else
  echo no-ui
fi
