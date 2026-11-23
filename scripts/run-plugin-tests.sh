#!/usr/bin/env bash
# Run standardized plugin test entrypoints (plugins/<name>/tests/run-tests.sh).
#
# Usage:
#   scripts/run-plugin-tests.sh --all
#   scripts/run-plugin-tests.sh --changed <base-ref>
#   scripts/run-plugin-tests.sh [--list] (--all | --changed <base-ref>)
#
# In --changed mode, runs every plugin changed in <base-ref>...HEAD, or all
# plugins when .github/workflows/, scripts/, or requirements-dev.txt changed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE=""
BASE_REF=""
LIST_ONLY=0

usage() {
  cat >&2 <<'EOF'
Usage: scripts/run-plugin-tests.sh [--list] (--all | --changed <base-ref>)
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || usage
      MODE="all"
      shift
      ;;
    --changed)
      [ -z "$MODE" ] && [ "$#" -ge 2 ] || usage
      MODE="changed"
      BASE_REF="$2"
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$MODE" ] || usage

all_plugins() {
  local d
  for d in plugins/*; do
    [ -d "$d" ] || continue
    printf '%s\n' "${d#plugins/}"
  done | LC_ALL=C sort
}

SELECTED=()
REASON=""

if [ "$MODE" = "all" ]; then
  mapfile -t SELECTED < <(all_plugins)
  REASON="all plugins (--all)"
else
  CHANGED_FILES="$(git diff --name-only "${BASE_REF}...HEAD")"
  if printf '%s\n' "$CHANGED_FILES" | grep -Eq '^(\.github/workflows/|scripts/|requirements-dev\.txt$)'; then
    mapfile -t SELECTED < <(all_plugins)
    REASON="shared CI/scripts/requirements changed against ${BASE_REF}; running all plugins"
  else
    mapfile -t SELECTED < <(
      while IFS= read -r path; do
        case "$path" in
          plugins/*/*)
            name="${path#plugins/}"
            name="${name%%/*}"
            [ -d "plugins/$name" ] && printf '%s\n' "$name"
            ;;
        esac
      done <<< "$CHANGED_FILES" | LC_ALL=C sort -u
    )
    REASON="plugins changed against ${BASE_REF}"
  fi
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  if [ "${#SELECTED[@]}" -gt 0 ]; then
    printf '%s\n' "${SELECTED[@]}"
  fi
  exit 0
fi

if [ "${#SELECTED[@]}" -eq 0 ]; then
  echo "No plugins changed against ${BASE_REF}; skipping plugin test suites."
  exit 0
fi

now_ms() {
  local ms
  ms="$(date +%s%3N 2>/dev/null || true)"
  case "$ms" in
    *[!0-9]*|"") printf '%s000\n' "$(date +%s)" ;;
    *) printf '%s\n' "$ms" ;;
  esac
}

fmt_ms() {
  awk -v ms="$1" 'BEGIN { printf "%.2fs", ms / 1000 }'
}

echo "Running ${#SELECTED[@]} plugin test suite(s) (${REASON}):"
printf '  - %s\n' "${SELECTED[@]}"
echo

PASS_COUNT=0
FAIL_COUNT=0
SUMMARY_LINES=()
TOTAL_START_MS="$(now_ms)"

for name in "${SELECTED[@]}"; do
  runner="plugins/${name}/tests/run-tests.sh"
  start_ms="$(now_ms)"
  rc=0

  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::group::plugin-tests: ${name}"
  else
    echo "=== plugin-tests: ${name} ==="
  fi

  if [ ! -f "$runner" ] || [ ! -x "$runner" ]; then
    echo "ERROR: ${runner} is missing or not executable" >&2
    rc=127
  else
    "./${runner}" || rc=$?
  fi

  end_ms="$(now_ms)"
  elapsed="$(fmt_ms "$((end_ms - start_ms))")"

  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::endgroup::"
  fi

  if [ "$rc" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    SUMMARY_LINES+=("  PASS  ${name} (exit 0, ${elapsed})")
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    SUMMARY_LINES+=("  FAIL  ${name} (exit ${rc}, ${elapsed})")
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      echo "::error::Plugin test suite failed: ${name} (exit ${rc}, ${elapsed})"
    fi
  fi
done

TOTAL_END_MS="$(now_ms)"
TOTAL_ELAPSED="$(fmt_ms "$((TOTAL_END_MS - TOTAL_START_MS))")"

echo
echo "=== Plugin test summary ==="
printf '%s\n' "${SUMMARY_LINES[@]}"
echo "${PASS_COUNT} passed, ${FAIL_COUNT} failed (total: ${TOTAL_ELAPSED})"

[ "$FAIL_COUNT" -eq 0 ]
