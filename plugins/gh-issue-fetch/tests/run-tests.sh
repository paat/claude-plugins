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
set +e  # sourced script enabled errexit; keep the runner resilient
got_count="$(extract_asset_urls < "$FIX/body-urls.md" | wc -l | tr -d ' ')"
check "extracts 7 unique urls" 7 "$got_count"
first="$(extract_asset_urls < "$FIX/body-urls.md" | head -1)"
check "first url clean (no paren/title)" \
  "https://github.com/user-attachments/assets/11111111-1111-1111-1111-111111111111" "$first"
has_cdn="$(extract_asset_urls < "$FIX/body-urls.md" | grep -c 'user-images.githubusercontent.com')"
check "includes legacy cdn" 2 "$has_cdn"
no_example="$(extract_asset_urls < "$FIX/body-urls.md" | grep -c 'example.com' || true)"
check "excludes non-asset link" 0 "$no_example"
check "strips trailing dot" 1 "$(extract_asset_urls < "$FIX/body-urls.md" | grep -c '/punct-test.png$')"

# --- Task 3: sanitize_component + ext_for_mime ---
check "sanitize slashes" "r-53-ou-aruannik" "$(sanitize_component 'r-53-ou/aruannik')"
check "sanitize dots ok"  "a.b_c-d"          "$(sanitize_component 'a.b_c-d')"
check "sanitize traversal" "..-..-etc-passwd" "$(sanitize_component '../../etc/passwd')"
check "mime png" "png" "$(ext_for_mime image/png)"
check "mime jpeg" "jpg" "$(ext_for_mime image/jpeg)"
check "mime pdf"  "pdf" "$(ext_for_mime application/pdf)"
check "mime unknown" "bin" "$(ext_for_mime application/octet-stream)"

# --- Task 4: parse_task_list ---
total="$(parse_task_list < "$FIX/epic-body.md" | wc -l | tr -d ' ')"
check "parses 4 children" 4 "$total"
checked="$(parse_task_list < "$FIX/epic-body.md" | grep -c '^checked')"
check "2 checked" 2 "$checked"
nums="$(parse_task_list < "$FIX/epic-body.md" | awk '{print $2}' | paste -sd, -)"
check "child numbers in order" "101,102,103,104" "$nums"
line1="$(parse_task_list < "$FIX/epic-body.md" | head -1)"
IFS=$'\t' read -r st_tab num_tab <<< "$line1"
check "tab-split state" "unchecked" "$st_tab"
check "tab-split number" "101" "$num_tab"

# --- Task 5: wrappers ---
# download_url builds the right curl invocation: stub curl, capture args.
stubdir="$(mktemp -d)"
cat > "$stubdir/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GHIF_CURL_ARGS_OUT"
# emulate -w output for the -o success path
printf '200\timage/png\t1234'
STUB
chmod +x "$stubdir/curl"
cat > "$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "auth token" ] && { echo "gho_TESTTOKEN"; exit 0; }
exit 0
STUB
chmod +x "$stubdir/gh"
export GHIF_CURL_ARGS_OUT="$stubdir/args.txt"
out="$(PATH="$stubdir:$PATH" bash -c 'source "'"$SCRIPT"'"; download_url https://github.com/user-attachments/assets/x "'"$stubdir"'/o.png"')"
check "download_url prints status line" "200	image/png	1234" "$out"
args="$(cat "$stubdir/args.txt")"
check "no --location-trusted" 0 "$(echo "$args" | grep -c -- '--location-trusted' || true)"
check "sends auth header" 1 "$(echo "$args" | grep -c 'Authorization: token gho_TESTTOKEN')"
rm -rf "$stubdir"

# download_url returns 1 on HTTP>=400, and does not abort the runner
sd2="$(mktemp -d)"
cat > "$sd2/curl" <<'STUB'
#!/usr/bin/env bash
printf '404\ttext/plain\t9'
STUB
chmod +x "$sd2/curl"
cat > "$sd2/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "auth token" ] && { echo "gho_TESTTOKEN"; exit 0; }
exit 0
STUB
chmod +x "$sd2/gh"
rc40x="$(PATH="$sd2:$PATH" bash -c 'set -euo pipefail; source "'"$SCRIPT"'"; if download_url https://github.com/user-attachments/assets/x "'"$sd2"'/o" >/dev/null; then echo 0; else echo 1; fi; echo SURVIVED')"
check "download_url returns 1 on 404" "1
SURVIVED" "$rc40x"
rm -rf "$sd2"

nokids="$(printf 'just text\nno checklist here\n' | bash -c 'set -euo pipefail; source "'"$SCRIPT"'"; parse_task_list; echo "RC=$?"')"
check "parse_task_list empty+ok on no children" "RC=0" "$nokids"

sd3="$(mktemp -d)"
cat > "$sd3/curl" <<'STUB'
#!/usr/bin/env bash
printf '000\t\t0'; exit 7
STUB
chmod +x "$sd3/curl"
cat > "$sd3/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "auth token" ] && { echo gho_T; exit 0; }
exit 0
STUB
chmod +x "$sd3/gh"
rctf="$(PATH="$sd3:$PATH" bash -c 'set -euo pipefail; source "'"$SCRIPT"'"; if download_url https://x "'"$sd3"'/o" >/dev/null; then echo 0; else echo 1; fi; echo SURVIVED')"
check "download_url returns 1 on transport failure" "1
SURVIVED" "$rctf"
rm -rf "$sd3"

[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "SOME RED"
exit "$fail"
