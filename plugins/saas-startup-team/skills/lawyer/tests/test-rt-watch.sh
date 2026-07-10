#!/usr/bin/env bash
set -euo pipefail

# Test: future-effective-date watch in lawyer-check.sh. /changes/feed cannot see a
# postponement of a not-yet-in-force act's effective date; this watch polls
# Riigi Teataja directly for entries carrying expected_effective_date. Invokes
# the real script (not an inlined mirror) so the assertions exercise the actual
# implementation.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
CHECK_SCRIPT="$PLUGIN_ROOT/scripts/lawyer-check.sh"

# Mock curl: /changes/feed and /citation (the pre-existing feed + lifecycle
# passes) get neutral "nothing to see" responses so only the future-effective
# watch pass is under test. blob-html is driven by $BLOB_HTML / $BLOB_FAIL.
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCKCURL'
#!/usr/bin/env bash
url="${@: -1}"
emit_code=0
for a in "$@"; do [ "$a" = "-w" ] && emit_code=1; done
case "$url" in
  *blob-html*)
    [ -n "${BLOB_URL_LOG:-}" ] && printf '%s\n' "$url" >> "$BLOB_URL_LOG"
    [ "${BLOB_FAIL:-0}" = "1" ] && exit 1
    printf '%s' "$BLOB_HTML"
    exit 0
    ;;
  *changes/feed*) body='{"items":[],"total":0}' ;;
  *citation*)     body='{"status":"valid","in_force":true,"text":"x","url":"https://www.riigiteataja.ee/akt/1","redaktsioon_date":"2026-01-01"}' ;;
  *)              body='{}' ;;
esac
if [ "$emit_code" = 1 ]; then printf '%s\n200' "$body"; else printf '%s' "$body"; fi
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key
export DATALAKE_URL=https://datalake.r-53.com
export RT_PUBLIC_API=https://rt-test.example/public-api/api/v1

# entry() writes a one-entry registry with the given expected_effective_date
# (pass the literal string "null" for no watch).
seed_registry() {
  local work="$1" expected_json="$2"
  mkdir -p "$work/.startup/laws"
  jq -n --argjson exp "$expected_json" '{
    version: 2,
    last_feed_check_at: "2026-04-23T10:00:00Z",
    entries: {
      "future-act": {
        act_id: 30099, rt_id: "1099999", redaktsioon_id: "106032026099",
        redaktsioon_date: "2026-01-01", status: "valid",
        expected_effective_date: $exp,
        act_title: "Test Act", act_type: "seadus", citation: "§ 1",
        citation_parts: {paragraph: "1", paragraph_qualifier: "", section: "", section_qualifier: "", point: "", point_qualifier: ""},
        rt_url: "https://www.riigiteataja.ee/akt/106032026099",
        registered_at: "2026-04-01T00:00:00Z", verified_at: "2026-04-01T00:00:00Z",
        registered_by: "lawyer", purpose: "test",
        needs_review: false, change_detected_at: null, change: null, gh_issue_url: null
      }
    }
  }' > "$work/.startup/law-registry.json"
}

run_check() {
  local work="$1"
  (cd "$work" && bash "$CHECK_SCRIPT")
}

# ---- Case 1: postponed date -> flagged with type=postponement ----
WORK=$(mktemp -d)
seed_registry "$WORK" '"2026-08-01"'
export BLOB_HTML='<div>Jõustumise kp: 01.09.2026</div>'
unset BLOB_FAIL
run_check "$WORK" >/dev/null
needs_review=$(jq -r '.entries["future-act"].needs_review' "$WORK/.startup/law-registry.json")
[ "$needs_review" = "true" ] || { echo "FAIL: case1 expected needs_review=true, got $needs_review"; exit 1; }
change_type=$(jq -r '.entries["future-act"].change.type' "$WORK/.startup/law-registry.json")
[ "$change_type" = "postponement" ] || { echo "FAIL: case1 expected change.type=postponement, got $change_type"; exit 1; }
change_effdate=$(jq -r '.entries["future-act"].change.effective_date' "$WORK/.startup/law-registry.json")
[ "$change_effdate" = "2026-09-01" ] || { echo "FAIL: case1 expected change.effective_date=2026-09-01, got $change_effdate"; exit 1; }
summary=$(jq -r '.entries["future-act"].change.summary' "$WORK/.startup/law-registry.json")
[[ "$summary" == *"2026-08-01"* && "$summary" == *"2026-09-01"* ]] || { echo "FAIL: case1 summary missing old/new dates: $summary"; exit 1; }
rm -rf "$WORK"

# ---- Case 2: unchanged date -> not flagged ----
WORK=$(mktemp -d)
seed_registry "$WORK" '"2099-01-01"'
export BLOB_HTML='<div>Jõustumise kp: 01.01.2099</div>'
unset BLOB_FAIL
run_check "$WORK" >/dev/null
needs_review=$(jq -r '.entries["future-act"].needs_review' "$WORK/.startup/law-registry.json")
[ "$needs_review" = "false" ] || { echo "FAIL: case2 expected needs_review=false, got $needs_review"; exit 1; }
change=$(jq -r '.entries["future-act"].change' "$WORK/.startup/law-registry.json")
[ "$change" = "null" ] || { echo "FAIL: case2 expected change=null, got $change"; exit 1; }
expected=$(jq -r '.entries["future-act"].expected_effective_date' "$WORK/.startup/law-registry.json")
[ "$expected" = "2099-01-01" ] || { echo "FAIL: case2 expected_effective_date should be untouched (still future), got $expected"; exit 1; }
rm -rf "$WORK"

# ---- Case 3: date passed + matches -> expected_effective_date cleared ----
WORK=$(mktemp -d)
seed_registry "$WORK" '"2020-01-01"'
export BLOB_HTML='<div>Jõustumise kp: 01.01.2020</div>'
unset BLOB_FAIL
run_check "$WORK" >/dev/null
needs_review=$(jq -r '.entries["future-act"].needs_review' "$WORK/.startup/law-registry.json")
[ "$needs_review" = "false" ] || { echo "FAIL: case3 expected needs_review=false, got $needs_review"; exit 1; }
expected=$(jq -r '.entries["future-act"].expected_effective_date' "$WORK/.startup/law-registry.json")
[ "$expected" = "null" ] || { echo "FAIL: case3 expected expected_effective_date cleared to null, got $expected"; exit 1; }
rm -rf "$WORK"

# ---- Case 4: curl failure -> entry untouched, exit 0 ----
WORK=$(mktemp -d)
seed_registry "$WORK" '"2026-08-01"'
export BLOB_HTML=''
export BLOB_FAIL=1
ec=0
(cd "$WORK" && bash "$CHECK_SCRIPT") >/dev/null 2>&1 || ec=$?
[ "$ec" = "0" ] || { echo "FAIL: case4 expected exit 0 on curl failure, got $ec"; exit 1; }
needs_review=$(jq -r '.entries["future-act"].needs_review' "$WORK/.startup/law-registry.json")
[ "$needs_review" = "false" ] || { echo "FAIL: case4 expected needs_review untouched (false), got $needs_review"; exit 1; }
expected=$(jq -r '.entries["future-act"].expected_effective_date' "$WORK/.startup/law-registry.json")
[ "$expected" = "2026-08-01" ] || { echo "FAIL: case4 expected expected_effective_date untouched, got $expected"; exit 1; }
unset BLOB_FAIL
rm -rf "$WORK"

echo "PASS: test-rt-watch"
