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

# --- Task 6: cmd_issue ---
t6="$(mktemp -d)"
GHIF_OUTDIR="$t6" bash -c '
  source "'"$SCRIPT"'"
  gh_json() {
    case "$*" in
      *"issue view"*) cat "'"$FIX"'/issue-view.json" ;;
      *"issues/"*"/comments"*) cat "'"$FIX"'/comments.json" ;;
      *) echo "{}" ;;
    esac
  }
  download_url() { cp "'"$FIX"'/pixel.png" "$2"; printf "200\timage/png\t70"; }
  cmd_issue 7 -R o/r
' >/dev/null 2>&1
check "issue.md created" 1 "$( [ -f "$t6/issue.md" ] && echo 1 || echo 0 )"
check "two assets downloaded" 2 "$(ls "$t6/assets" 2>/dev/null | wc -l | tr -d ' ')"
check "assets are png by sniff" 2 "$(ls "$t6/assets"/*.png 2>/dev/null | wc -l | tr -d ' ')"
check "body url rewritten to relative" 1 "$(grep -c 'assets/001.png' "$t6/issue.md")"
check "no raw asset url remains" 0 "$(grep -c 'user-attachments/assets' "$t6/issue.md" || true)"
check "manifest valid json" 0 "$(jq -e '.assets|length==2' "$t6/manifest.json" >/dev/null 2>&1; echo $?)"
rm -rf "$t6"

# --- Task 6: no-image edge case ---
t6b="$(mktemp -d)"
GHIF_OUTDIR="$t6b" bash -c '
  source "'"$SCRIPT"'"
  gh_json() {
    case "$*" in
      *"issue view"*) cat "'"$FIX"'/issue-no-images.json" ;;
      *"issues/"*"/comments"*) echo "[]" ;;
      *) echo "{}" ;;
    esac
  }
  download_url() { cp "'"$FIX"'/pixel.png" "$2"; printf "200\timage/png\t70"; }
  cmd_issue 9 -R o/r
' >/dev/null 2>&1
check "no-image issue.md created" 1 "$( [ -f "$t6b/issue.md" ] && echo 1 || echo 0 )"
check "no-image manifest has empty assets" 0 "$(jq -e '.assets|length==0' "$t6b/manifest.json" >/dev/null 2>&1; echo $?)"
rm -rf "$t6b"

# --- Task 6: escape_glob exact-string rewrite ---
md_t='see https://x/y.png?z=* twice: https://x/y.png?z=*'
url_t='https://x/y.png?z=*'
url_pat_t="$(escape_glob "$url_t")"
out_t="${md_t//$url_pat_t/LOCAL}"
check "escape_glob literal rewrite" "see LOCAL twice: LOCAL" "$out_t"

# --- Task 6: arg parser — flag-before-number does not steal the issue number ---
t6c="$(mktemp -d)"
GHIF_OUTDIR="$t6c" bash -c '
  source "'"$SCRIPT"'"
  gh_json() {
    case "$*" in
      *"issue view"*) cat "'"$FIX"'/issue-view.json" ;;
      *"issues/"*"/comments"*) cat "'"$FIX"'/comments.json" ;;
      *) echo "{}" ;;
    esac
  }
  download_url() { cp "'"$FIX"'/pixel.png" "$2"; printf "200\timage/png\t70"; }
  cmd_issue --max-assets 5 7 -R o/r
' >/dev/null 2>&1
check "flag-before-number: issue.md created" 1 "$( [ -f "$t6c/issue.md" ] && echo 1 || echo 0 )"
check "flag-before-number: issue 7 used (not 5)" 1 "$(grep -c '(#7)' "$t6c/issue.md" 2>/dev/null || echo 0)"
rm -rf "$t6c"

# --- Task 6: paginated comments (two concatenated JSON arrays) ---
t6d="$(mktemp -d)"
GHIF_OUTDIR="$t6d" bash -c '
  source "'"$SCRIPT"'"
  gh_json() {
    case "$*" in
      *"issue view"*) printf '\''%s'\'' '\''{"number":7,"title":"Paginated test","state":"OPEN","url":"https://github.com/o/r/issues/7","author":{"login":"alice"},"labels":[],"body":""}'\'' ;;
      *"issues/"*"/comments"*) printf '\''%s'\'' '\''[{"id":1,"user":{"login":"u1"},"body":"![a](https://github.com/user-attachments/assets/cccccccc-cccc-cccc-cccc-cccccccccccc)"}][{"id":2,"user":{"login":"u2"},"body":"![b](https://github.com/user-attachments/assets/dddddddd-dddd-dddd-dddd-dddddddddddd)"}]'\'' ;;
      *) echo "{}" ;;
    esac
  }
  download_url() { cp "'"$FIX"'/pixel.png" "$2"; printf "200\timage/png\t70"; }
  cmd_issue 7 -R o/r
' >/dev/null 2>&1
check "paginated comments render" 1 "$(grep -c '## Comments' "$t6d/issue.md")"
check "both paginated comment images downloaded" 2 "$(ls "$t6d/assets" | wc -l | tr -d ' ')"
rm -rf "$t6d"

# --- Task 7: cmd_epic roll-up ---
t7="$(mktemp -d)"
GHIF_OUTDIR="$t7" bash -c '
  source "'"$SCRIPT"'"
  gh_json() {
    case "$*" in
      *"issue view 9"*) jq -n "{number:9,title:\"Epic\",state:\"OPEN\",url:\"u\",author:{login:\"a\"},labels:[{name:\"epic\"}],body:(\"- [ ] #101 a\n- [x] #102 b\n\")}" ;;
      *"issues/9/comments"*) echo "[]" ;;
      *"issue view 101"*) jq -n "{number:101,state:\"OPEN\",title:\"child a\",labels:[]}" ;;
      *"issue view 102"*) jq -n "{number:102,state:\"CLOSED\",title:\"child b\",labels:[]}" ;;
      *) echo "{}" ;;
    esac
  }
  download_url() { return 0; }
  cmd_epic 9 -R o/r
' >/dev/null 2>&1
check "epic issue.md has children table" 1 "$(grep -c '## Children' "$t7/issue.md")"
check "progress checkboxes 1/2" 1 "$(grep -c 'Progress (checkboxes): 1/2' "$t7/issue.md")"
check "closed real state 1/2" 1 "$(grep -c 'Closed (real state): 1/2' "$t7/issue.md")"
check "child 101 row present" 1 "$(grep -c '| #101 |' "$t7/issue.md")"
rm -rf "$t7"

# cmd_epics: lists labeled epics with done/total progress
out_epics="$(bash -c 'set -euo pipefail; source "'"$SCRIPT"'"
  gh_json() {
    case "$*" in
      *"issue list"*) printf "%s\n" 9 10 ;;
      *"issue view 9 "*|*"issue view 9"*) jq -n "{body:\"- [ ] #1 a\n- [x] #2 b\n\",title:\"Epic Nine\"}" ;;
      *"issue view 10 "*|*"issue view 10"*) jq -n "{body:\"no tasks here\",title:\"Epic Ten\"}" ;;
      *) echo "{}" ;;
    esac
  }
  cmd_epics -R o/r --label epic')"
check "cmd_epics epic9 progress 1/2" 1 "$(printf '%s\n' "$out_epics" | grep -c '#9  1/2  Epic Nine')"
check "cmd_epics epic10 progress 0/0" 1 "$(printf '%s\n' "$out_epics" | grep -c '#10  0/0  Epic Ten')"

# cmd_epics: zero label matches -> no output, no abort
out_zero="$(bash -c 'set -euo pipefail; source "'"$SCRIPT"'"
  gh_json() { case "$*" in *"issue list"*) printf "" ;; *) echo "{}" ;; esac; }
  cmd_epics -R o/r; echo DONE')"
check "cmd_epics zero match clean" "DONE" "$out_zero"

# --- Task 6: render_issue_md metadata lines ---
meta_t='{"number":5,"title":"T","state":"OPEN","url":"http://u","author":{"login":"alice"},"labels":[{"name":"bug"}],"body":"hi"}'
rendered="$(render_issue_md "$meta_t" '[]')"
check "render metadata state line" 1 "$(printf '%s\n' "$rendered" | grep -c '^- \*\*State:\*\* OPEN')"
check "render metadata author line" 1 "$(printf '%s\n' "$rendered" | grep -c '^- \*\*Author:\*\* alice')"
check "render metadata url line" 1 "$(printf '%s\n' "$rendered" | grep -c '^- \*\*URL:\*\* http://u')"

# --- Security: scraper CDN host allowlist ---
check "scraper rejects evil cdn host" 0 "$(printf '%s\n' '![x](https://evilgithubusercontent.com/a.png)' | extract_asset_urls | grep -c 'evilgithubusercontent' || true)"
check "scraper rejects cdn suffix-trick host" 0 "$(printf '%s\n' '![x](https://githubusercontent.com.evil.com/a.png)' | extract_asset_urls | grep -c 'evil.com' || true)"
check "scraper accepts real cdn host" 1 "$(printf '%s\n' '![x](https://user-images.githubusercontent.com/1/a.png)' | extract_asset_urls | grep -c 'user-images.githubusercontent.com')"

# --- Security: download_url host allowlist (token never sent to evil host) ---
sdh="$(mktemp -d)"
cat > "$sdh/curl" <<'STUB'
#!/usr/bin/env bash
echo CALLED > "$GHIF_CURL_CALLED"
printf '200\timage/png\t1'
STUB
chmod +x "$sdh/curl"
cat > "$sdh/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "auth token" ] && { echo gho_SECRET; exit 0; }
exit 0
STUB
chmod +x "$sdh/gh"
export GHIF_CURL_CALLED="$sdh/called"
evilres="$(PATH="$sdh:$PATH" bash -c 'set -euo pipefail; source "'"$SCRIPT"'"; if download_url https://evilgithubusercontent.com/a "'"$sdh"'/o" >/dev/null 2>&1; then echo 0; else echo 1; fi; echo SURVIVED')"
check "download_url refuses evil host (returns 1)" "1
SURVIVED" "$evilres"
check "download_url did NOT invoke curl for evil host" 0 "$( [ -f "$sdh/called" ] && echo 1 || echo 0 )"
unset GHIF_CURL_CALLED
rm -rf "$sdh"

# --- Live smoke (opt-in): GHIF_SMOKE="owner/repo:N" with a known image issue ---
if [ -n "${GHIF_SMOKE:-}" ]; then
  sr="${GHIF_SMOKE%%:*}"; sn="${GHIF_SMOKE##*:}"
  so="$("$SCRIPT" issue "$sn" -R "$sr")"; sd="${so#OUTDIR=}"
  imgs="$(ls "$sd/assets" 2>/dev/null | wc -l | tr -d ' ')"
  check "smoke downloaded >=1 asset" 1 "$( [ "${imgs:-0}" -ge 1 ] && echo 1 || echo 0 )"
  check "smoke asset is an image" 1 "$( [ "$(file --mime-type -b "$sd/assets/"* 2>/dev/null | grep -c '^image/')" -ge 1 ] && echo 1 || echo 0 )"
fi

[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "SOME RED"
exit "$fail"
