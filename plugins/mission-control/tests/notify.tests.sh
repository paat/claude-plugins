#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/bin"
cat > "$TD/bin/curl" <<'SH'
#!/bin/bash
echo "curl $*" >> "$CURL_CALLS"
cat >> "$CURL_CALLS"
exit "${CURL_RC:-0}"
SH
chmod +x "$TD/bin/curl"
export PATH="$TD/bin:$PATH" CURL_CALLS="$TD/curl.calls"
: > "$CURL_CALLS"

unset MC_TEST_URL || true
t "unset env var: exit 0, no curl" bash -c 'echo body | bash "$0/scripts/notify.sh" MC_TEST_URL title && [ ! -s "$CURL_CALLS" ]' "$PLUGIN"

export MC_TEST_URL="https://ntfy.example/topic"
t "set env var: curl called with URL and title" bash -c 'echo hello | bash "$0/scripts/notify.sh" MC_TEST_URL "mc: test" && grep -q "ntfy.example/topic" "$CURL_CALLS" && grep -q "mc: test" "$CURL_CALLS" && grep -q "^hello$" "$CURL_CALLS"' "$PLUGIN"

CURL_RC=22 t "curl failure still exits 0" bash -c 'echo x | bash "$0/scripts/notify.sh" MC_TEST_URL t' "$PLUGIN"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
