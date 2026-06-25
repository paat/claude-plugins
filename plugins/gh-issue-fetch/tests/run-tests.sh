#!/usr/bin/env bash
# Unit + integration proofs for gh-issue-fetch.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/gh-issue-fetch.sh"
FIX="$HERE/fixtures"
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" == "$3" ]; then echo "PASS  $1"; else
    echo "FAIL  $1: expected [$2] got [$3]"; fail=1; fi
}

# --- Task 1: dispatch ---
"$SCRIPT" --help >/dev/null 2>&1; check "help exits 0" 0 "$?"
"$SCRIPT" bogus  >/dev/null 2>&1; check "unknown subcmd exits 2" 2 "$?"

[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "SOME RED"
exit "$fail"
