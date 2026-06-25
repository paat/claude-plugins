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

# --- Task 2: extract_asset_urls ---
source "$SCRIPT"
got_count="$(extract_asset_urls < "$FIX/body-urls.md" | wc -l | tr -d ' ')"
check "extracts 6 unique urls" 6 "$got_count"
first="$(extract_asset_urls < "$FIX/body-urls.md" | head -1)"
check "first url clean (no paren/title)" \
  "https://github.com/user-attachments/assets/11111111-1111-1111-1111-111111111111" "$first"
has_cdn="$(extract_asset_urls < "$FIX/body-urls.md" | grep -c 'user-images.githubusercontent.com')"
check "includes legacy cdn" 1 "$has_cdn"
no_example="$(extract_asset_urls < "$FIX/body-urls.md" | grep -c 'example.com' || true)"
check "excludes non-asset link" 0 "$no_example"

[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "SOME RED"
exit "$fail"
