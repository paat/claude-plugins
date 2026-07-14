#!/usr/bin/env bash
# ui-touch.sh — classify a changeset as UI-touching or not.
# Usage:
#   ui-touch.sh --range <git-range>   # e.g. main...HEAD; changed files via git
#   ui-touch.sh --files               # newline-separated paths on stdin
#   ui-touch.sh --files0              # NUL-separated paths on stdin
# Prints "ui" or "no-ui" (exit 0). Usage error → exit 2.
# Fails toward "ui" only on real signal; empty input prints "no-ui".
set -euo pipefail
export LC_ALL=C
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_EXTERNAL_DIFF

usage() { echo "usage: ui-touch.sh --range <git-range> | --files | --files0 (paths on stdin)" >&2; exit 2; }

# UI-touching file patterns — single source of truth. One ERE branch per line.
PATTERNS='\.(css|scss|sass|less)$
\.(tsx|jsx|vue|svelte|html?|mdx|hbs|handlebars|ejs|erb|razor|cshtml)$
\.blade\.php$
\.(svg|png|jpe?g|gif|webp|avif|bmp|ico|woff2?|ttf|otf|eot)$
(^|/)(public|static|assets)/
(^|/)[^/]*(tailwind|theme)[^/]*\.(js|ts|cjs|mjs|json)$
(^|/)(components?|layouts?|pages|views|templates|partials)/.*\.(ts|js|erb|blade\.php|razor|cshtml)$
(^|/)(locales?|i18n|lang|translations?)/
\.(po|pot)$'

classify_path() {
  local path=$1 pattern
  [[ "$path" =~ [[:cntrl:]] ]] && return 0
  path=${path,,}
  while IFS= read -r pattern; do
    [[ "$path" =~ $pattern ]] && return 0
  done <<< "$PATTERNS"
  return 1
}

classify_lines() {
  local path result=no-ui
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    if classify_path "$path"; then result=ui; break; fi
  done
  printf '%s\n' "$result"
}

classify_nul() {
  local path result=no-ui
  while IFS= read -r -d '' path; do
    if classify_path "$path"; then result=ui; break; fi
  done
  printf '%s\n' "$result"
}

case "${1:-}" in
  --range)
    range="${2:-}"; [ -n "$range" ] && [ "$#" -eq 2 ] || usage
    files=$(mktemp) || { echo "ui-touch: cannot create filename buffer — classifying ui (fail-closed)" >&2; echo ui; exit 0; }
    trap 'rm -f -- "$files"' EXIT
    git -c core.fsmonitor=false diff --no-ext-diff --no-textconv --name-only -z "$range" > "$files" 2>/dev/null \
      || { echo "ui-touch: git diff failed for '$range' — classifying ui (fail-closed)" >&2; echo ui; exit 0; }
    classify_nul < "$files"
    ;;
  --files) [ "$#" -eq 1 ] || usage; classify_lines ;;
  --files0) [ "$#" -eq 1 ] || usage; classify_nul ;;
  *) usage ;;
esac
