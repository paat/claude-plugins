#!/usr/bin/env bash
# /lawyer marker scan (internal helper). Scans project source for `LAW:` markers
# and prints one "<slug>\t<file>:<line>" line per marker-slug pair on stdout.
# Scope: source + customer-facing content, including nested source roots in
# monorepos (e.g. frontend/src, backend/app); excludes dependency/generated
# trees (node_modules, vendor, .venv, dist, build, .git) and docs/legal/
# (lawyer output) at any depth.
set -uo pipefail

PRUNE_RE='(^|/)(node_modules|vendor|\.venv|dist|build|\.git)(/|$)'
OWN_OUTPUT_RE='(^|/)docs/legal(/|$)'
HIDDEN_DIR_RE='(^|/)\.[^/]+/'

LIST_ERR=$(mktemp)

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ALL_FILES=()
  while IFS= read -r -d '' f; do
    ALL_FILES+=("$f")
  done < <({ git ls-files -z --cached --recurse-submodules && git ls-files -z --others --exclude-standard; } 2>"$LIST_ERR")
else
  mapfile -t ALL_FILES < <(find . \
    \( -type d \( -name node_modules -o -name vendor -o -name .venv -o -name dist -o -name build -o -name .git \) -prune \) \
    -o -type f -print 2>"$LIST_ERR" | sed 's#^\./##')
fi

# A listing failure (git ls-files or find erroring out) must not pass through
# as an empty, silently-clean scan - it needs to look like the hardened
# search-step failure below, not a healthy "nothing to report" exit 0.
if [ -s "$LIST_ERR" ]; then
  cat "$LIST_ERR" >&2
  rm -f "$LIST_ERR"
  echo "lawyer-marker-scan.sh: file listing failed" >&2
  exit 1
fi
rm -f "$LIST_ERR"

SCAN_FILES=()
for f in "${ALL_FILES[@]}"; do
  [ -f "$f" ] || continue
  [[ "$f" =~ $PRUNE_RE ]] && continue
  [[ "$f" =~ $OWN_OUTPUT_RE ]] && continue
  [[ "$f" =~ $HIDDEN_DIR_RE ]] && continue
  SCAN_FILES+=("$f")
done

# Guard: with no candidate files, skip entirely rather than letting rg/grep
# fall back to an unscoped recursive scan.
if [ ${#SCAN_FILES[@]} -eq 0 ]; then
  exit 0
fi

PATTERN='(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*'
if command -v rg >/dev/null 2>&1; then
  TOOL=(rg -n -H --pcre2 --)
else
  TOOL=(grep -nH -I -E --)
fi

# Stream the file list through xargs instead of one argv: on large repos the
# full path list can exceed ARG_MAX and exec fails with E2BIG. xargs chunks
# the list to fit, invoking the search tool as many times as needed.
ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

raw=$(printf '%s\0' "${SCAN_FILES[@]}" | xargs -0 "${TOOL[@]}" "$PATTERN" 2>"$ERR_FILE")

# Exit code 1 from rg/grep just means "no matches in this batch" - normal.
# A real failure (E2BIG, missing file, tool crash, ...) writes to stderr.
if [ -s "$ERR_FILE" ]; then
  cat "$ERR_FILE" >&2
  echo "lawyer-marker-scan.sh: marker search failed" >&2
  exit 1
fi

printf '%s\n' "$raw" | awk -F: '
  {
    file=$1; line=$2
    tail=""
    for (i=3; i<=NF; i++) tail = tail (i==3?"":":") $i
    if (match(tail, /LAW:[[:space:]]*[a-z0-9,\- \t]+/) == 0) next
    slugs = substr(tail, RSTART+4)   # drop "LAW:" prefix
    gsub(/\*\/.*/, "", slugs)
    gsub(/-->.*/, "", slugs)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", slugs)
    ns = split(slugs, arr, /[[:space:]]*,[[:space:]]*/)
    for (j=1; j<=ns; j++) {
      s = arr[j]
      if (s ~ /^[a-z0-9-]+$/) print s "\t" file ":" line
    }
  }
'
