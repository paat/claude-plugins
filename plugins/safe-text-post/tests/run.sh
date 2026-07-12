#!/usr/bin/env bash
# safe-text-post tests: exercise the real helper against a mock gh that stores
# and echoes bodies like the GitHub API. Exit non-zero on any mismatch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
SP="$PLUGIN/scripts/safe-post.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT
mkdir -p "$WD/bin"

# Mock gh api: POST/PATCH with -F body=@file stores the file; GET returns the
# stored body via --jq .body (or id via --jq .id). GH_MOCK_MUTATE simulates a
# server that stores corrupted content.
cat > "$WD/bin/gh" <<'SH'
#!/usr/bin/env bash
store="${GH_STORE:?}"
body_file=""; jqf=""; method="GET"
for ((i=1; i<=$#; i++)); do
  a="${!i}"
  case "$a" in
    -X) j=$((i+1)); method="${!j}" ;;
    -F) j=$((i+1)); v="${!j}"; body_file="${v#body=@}" ;;
    --jq) j=$((i+1)); jqf="${!j}" ;;
  esac
done
if [ -n "$body_file" ]; then
  cp "$body_file" "$store"
  [ -z "${GH_MOCK_MUTATE:-}" ] || printf '%s' "$GH_MOCK_MUTATE" >> "$store"
  case "$jqf" in .id) echo 12345 ;; .number) echo 42 ;; esac
  exit 0
fi
case "$jqf" in
  .body) cat "$store" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$WD/bin/gh"
run() { PATH="$WD/bin:$PATH" GH_STORE="$WD/store" bash "$SP" "$@"; }

# Lint
printf 'tere\n' > "$WD/ok.md"
t "lint: clean file passes" run lint "$WD/ok.md"
printf '   \n\n' > "$WD/empty.md"
lint_empty() { run lint "$WD/empty.md"; [ $? -eq 4 ]; }
t "lint: whitespace-only payload is the empty-post class (exit 4)" lint_empty
printf 'zero\xe2\x80\x8bwidth\n' > "$WD/zw.md"
lint_zw() { run lint "$WD/zw.md"; [ $? -eq 4 ]; }
t "lint: zero-width char rejected (exit 4)" lint_zw
printf '\xE2\x80\x9Ctere\xE2\x80\x9D \xC3\xB5\xC3\xA4\xC3\xB6\xC3\xBC\n' > "$WD/est.md"
t "lint: curly quotes and Estonian letters are legitimate content" run lint "$WD/est.md"

# Post + read-back verification round-trip (curly quotes survive)
post_roundtrip() { run post --via issue-comment --repo o/r --number 1 --file "$WD/est.md" | grep -q "verified"; }
t "post: comment round-trip verifies curly quotes survived" post_roundtrip
post_body() { run post --via pr-body --repo o/r --number 7 --file "$WD/est.md" | grep -q "verified"; }
t "post: pr-body round-trip verifies" post_body

# Corrupted storage → verification fails loudly (exit 6)
post_corrupted() {
  GH_MOCK_MUTATE="CORRUPTION" PATH="$WD/bin:$PATH" GH_STORE="$WD/store" \
    bash "$SP" post --via issue-comment --repo o/r --number 1 --file "$WD/est.md"
  [ $? -eq 6 ]
}
t "post: mutated stored content fails verification (exit 6)" post_corrupted

# Zero-width payload never leaves the machine
post_zw_blocked() {
  rm -f "$WD/store"
  run post --via issue-comment --repo o/r --number 1 --file "$WD/zw.md"
  rc=$?
  [ "$rc" -eq 4 ] && [ ! -e "$WD/store" ]
}
t "post: lint hazard blocks before any network call" post_zw_blocked

# Large payload (beyond typical inline argv comfort) round-trips file-based
head -c 300000 /dev/zero | tr '\0' 'a' > "$WD/big.md"; echo >> "$WD/big.md"
post_big() { run post --via issue-body --repo o/r --number 42 --file "$WD/big.md" | grep -q "verified"; }
t "post: 300KB payload round-trips (ARG_MAX by construction)" post_big

# Standalone verify: match and mismatch
verify_match() { run verify --via issue-body --repo o/r --number 42 --file "$WD/big.md" | grep -q "verified"; }
t "verify: standalone match" verify_match
verify_mismatch() {
  run verify --via issue-body --repo o/r --number 42 --file "$WD/est.md"
  [ $? -eq 6 ]
}
t "verify: standalone mismatch exits 6" verify_mismatch

# Trailing-newline symmetry: extra EOF newlines on either side still verify.
printf 'body\n\n\n' > "$WD/multinl.md"
run post --via issue-body --repo o/r --number 42 --file "$WD/multinl.md" >/dev/null
printf 'body' > "$WD/singlenl.md"
trailing_nl_symmetric() { run verify --via issue-body --repo o/r --number 42 --file "$WD/singlenl.md" | grep -q verified; }
t "verify: EOF-newline differences tolerated symmetrically" trailing_nl_symmetric

# Embedded carriage returns are real content: a difference must fail.
printf 'line1\r\nline2\n' > "$WD/crlf.md"
run post --via issue-body --repo o/r --number 42 --file "$WD/crlf.md" >/dev/null
printf 'line1\nline2\n' > "$WD/lf.md"
embedded_cr_detected() { run verify --via issue-body --repo o/r --number 42 --file "$WD/lf.md"; [ $? -eq 6 ]; }
t "verify: embedded CR difference detected (exit 6)" embedded_cr_detected

# Fetch failure is UNKNOWN state (exit 5), not a mismatch.
fetch_failure() {
  rm -f "$WD/store"
  run verify --via issue-body --repo o/r --number 42 --file "$WD/lf.md"
  [ $? -eq 5 ]
}
t "verify: read-back fetch failure exits 5 (state unknown)" fetch_failure

# Usage errors
usage_bad_adapter() { run post --via nope --repo o/r --number 1 --file "$WD/ok.md"; [ $? -eq 2 ]; }
t "unknown adapter exits 2" usage_bad_adapter
usage_missing_file() { run post --via issue-body --repo o/r --number 1 --file "$WD/nope.md"; [ $? -eq 2 ]; }
t "missing file exits 2" usage_missing_file
usage_missing_comment_id() { run verify --via issue-comment --repo o/r --number 1 --file "$WD/ok.md"; [ $? -eq 2 ]; }
t "verify comment without --comment-id exits 2" usage_missing_comment_id
usage_dangling_value() { run post --via issue-body --repo o/r --number 1 --file; [ $? -eq 2 ]; }
t "dangling option value exits 2" usage_dangling_value

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
