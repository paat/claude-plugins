#!/usr/bin/env bash
# ui-touch.sh — classify a changeset as UI-touching or not.
# Usage:
#   ui-touch.sh --range <git-range>   # e.g. main...HEAD; changed files via git
#   ui-touch.sh --files               # newline-separated paths on stdin
# Prints "ui" or "no-ui" (exit 0). Usage error → exit 2.
# Fails toward "ui" only on real signal; empty input prints "no-ui".
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_EXTERNAL_DIFF

usage() { echo "usage: ui-touch.sh --range <git-range> | --files (paths on stdin)" >&2; exit 2; }

case "${1:-}" in
  --range) range="${2:-}"; [ -n "$range" ] || usage
           # a failing git range must not skip the review gate: classify ui
           files=$(git -c core.fsmonitor=false diff --no-ext-diff --no-textconv --name-only "$range" 2>/dev/null) \
             || { echo "ui-touch: git diff failed for '$range' — classifying ui (fail-closed)" >&2; echo ui; exit 0; } ;;
  --files) files=$(cat) ;;
  *) usage ;;
esac

# UI-touching file patterns — single source of truth. One ERE branch per line.
PATTERNS='\.(css|scss|sass|less)$
\.(tsx|jsx|vue|svelte|html?|mdx)$
\.(svg|png|jpe?g|gif|webp|ico)$
(^|/)(public|static|assets)/
(^|/)[^/]*(tailwind|theme)[^/]*\.(js|ts|cjs|mjs|json)$
(^|/)(components?|layouts?|pages|views|templates|partials)/.*\.(ts|js|erb|blade\.php|razor|cshtml)$
(^|/)(locales?|i18n|lang|translations?)/
\.(po|pot)$'

if [ -n "$files" ] && printf '%s\n' "$files" | grep -Eq "$(printf '%s' "$PATTERNS" | paste -sd'|' -)"; then
  echo ui
else
  echo no-ui
fi
