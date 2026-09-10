#!/usr/bin/env bash
# Exercise the successful and unavailable checks against the same captured range.
set -euo pipefail
lib="${1:?library path required}"
scenario="${2:?healthy or pruned required}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q -b main
git -C "$work" config user.email test@example.com
git -C "$work" config user.name 'Test User'
printf 'base\n' > "$work/file.txt"
printf 'outside\n' > "$work/outside.txt"
git -C "$work" add file.txt outside.txt
git -C "$work" commit -qm base
base="$(git -C "$work" rev-parse HEAD)"
printf 'one\ntwo\nthree\n' > "$work/file.txt"
git -C "$work" commit -qam reviewed
cd "$work"
. "$lib"
TRIBUNAL_BASE_REF="$base" tribunal_prepare_diff "$work/review.diff"
stat="$(tribunal_take_diff_stat "$work/review.diff")"
head="$(printf '%s' "$stat" | jq -r .head_oid)"
cat > "$work/input.json" <<'JSON'
{"provider":"codex","findings":[{"file":"file.txt","line":3},{"file":"file.txt","line":999},{"file":"outside.txt","line":1},{"file":"outside.txt"},{"file":"file.txt"},{"file":"file.txt","line":0},{"line":2},{"title":"no position"}],"summary":{"total_findings":8}}
JSON
case "$scenario" in
  healthy)
    jq -c '.findings[1].line_check = "line out of bounds: file has 3 lines"
      | .findings[2].line_check = "file not in reviewed diff"
      | .findings[3].line_check = "file not in reviewed diff"
      | .findings[5].line_check = "invalid line number"
      | .findings[6].line_check = "malformed finding coordinates"
      | .findings[7].line_check = "malformed finding coordinates"' \
      "$work/input.json" > "$work/expected.json"
    ;;
  pruned)
    git reset -q --hard "$base"
    git reflog expire --expire=now --all
    git gc --prune=now
    git cat-file -e "$base"
    if git cat-file -e "$head" 2>/dev/null; then
      echo 'fixture failed to prune reviewed head' >&2
      exit 1
    fi
    jq -c '.findings[0].line_check = "position check unavailable"
      | .findings[1].line_check = "position check unavailable"
      | .findings[2].line_check = "position check unavailable"
      | .findings[3].line_check = "position check unavailable"
      | .findings[4].line_check = "position check unavailable"
      | .findings[5].line_check = "position check unavailable"
      | .findings[6].line_check = "malformed finding coordinates"
      | .findings[7].line_check = "malformed finding coordinates"' \
      "$work/input.json" > "$work/expected.json"
    ;;
  *) exit 2 ;;
esac
tribunal_line_check "$work" "$stat" < "$work/input.json" > "$work/actual.json"
tribunal_stamp_diff_stat "$stat" < "$work/actual.json" > "$work/stamped.json"
jq -e --argjson stat "$stat" '.diff_stat == $stat and .error == null' "$work/stamped.json" >/dev/null
if ! cmp -s "$work/expected.json" "$work/actual.json"; then
  printf 'FAIL %s line check: actual marks (diff_stat remains valid):\n' "$scenario" >&2
  jq -c '[.findings[] | .line_check // "UNMARKED"]' "$work/stamped.json" >&2
  exit 1
fi
printf 'PASS %s line check: output matches expected bytes; diff_stat remains valid\n' "$scenario"
if [ "$scenario" = pruned ]; then
  printf '%s\n' '{"provider":"x","findings":[{"file":"a.txt","line":9},"stray note"],"summary":{}}' \
    | tribunal_line_check "$work" "$stat" > "$work/scalar.json"
  jq -e '. == {"provider":"x","findings":[{"file":"a.txt","line":9,"line_check":"position check unavailable"},"stray note"],"summary":{}}' \
    "$work/scalar.json" >/dev/null
  printf 'PASS pruned line check: stray scalar survives: '
  cat "$work/scalar.json"
fi
