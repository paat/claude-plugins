# gh-issue-fetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a generic Claude Code plugin whose bash script downloads auth-gated GitHub issue/comment images to local disk and resolves epic→child task-lists, so Claude can `Read` screenshots and reason about epic progress.

**Architecture:** One bash script `scripts/gh-issue-fetch.sh` with three subcommands (`issue`, `epic`, `epics`). Pure logic (URL scraping, filename/extension derivation, task-list parsing, path sanitizing) lives in small sourceable functions unit-tested against string fixtures. Network access is isolated behind two thin wrappers — `gh_json` and `download_url` — which tests override with stubs, so the high-level subcommand assembly is testable without a network. The script guards its `main` dispatch with a `BASH_SOURCE`/`$0` check so the test harness can `source` it.

**Tech Stack:** bash 4+, `gh` CLI, `curl`, `jq`, `file` (mime sniff). Tests are a plain `tests/run-tests.sh` bash runner (repo house style — no bats).

## Global Constraints

- Generic / project-agnostic: **no hardcoded project names, labels, or paths**. Anything that varies is a flag with a sensible default (epic label default `epic`).
- bash 4+ and standard POSIX tools only. External deps (`gh`, `jq`, `curl`, `file`) documented in README.
- `set -euo pipefail`, every variable quoted, no `eval`, never execute anything derived from issue content.
- Read-only toward GitHub — the script never writes/uploads.
- Download auth: `curl -L -H "Authorization: token $(gh auth token)"`. **Never `--location-trusted`** (token must not follow the cross-host S3 redirect; curl drops it by default — that is the desired behavior). Signed asset URLs expire ~300s.
- Filenames sequential (`001`, `002`, …); extension from sniffed bytes (`file --mime-type`), never from URL or `Content-Type` header. No filename derived from attacker-controllable URL text.
- Output dir: `/tmp/gh-issue-<owner>-<repo>-<n>/` with owner/repo sanitized to `[A-Za-z0-9._-]`. Contains `issue.md`, `assets/`, `manifest.json`.
- Exit non-zero only on hard failures (missing tool, bad repo, bad issue number, issue JSON unfetchable). Partial asset failures exit `0` with failures recorded in manifest; `--strict` makes them non-zero.
- Version bumped in **both** `plugins/gh-issue-fetch/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` (pre-push hook enforces sync).
- README includes the standard 3-scope Installation section (Install for you / for all collaborators / for you in this repo only).

---

## File Structure

- Create: `plugins/gh-issue-fetch/.claude-plugin/plugin.json` — manifest.
- Create: `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh` — the workhorse (all logic).
- Create: `plugins/gh-issue-fetch/skills/gh-issue-fetch/SKILL.md` — when/how Claude invokes it.
- Create: `plugins/gh-issue-fetch/README.md` — usage + Installation + deps.
- Create: `plugins/gh-issue-fetch/tests/run-tests.sh` — bash test runner.
- Create: `plugins/gh-issue-fetch/tests/fixtures/` — sample bodies + a tiny real PNG.
- Modify: `.claude-plugin/marketplace.json` — add plugin entry.

---

### Task 1: Plugin scaffold + arg dispatch with sourcing guard

**Files:**
- Create: `plugins/gh-issue-fetch/.claude-plugin/plugin.json`
- Create: `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh`
- Create: `plugins/gh-issue-fetch/tests/run-tests.sh`
- Modify: `.claude-plugin/marketplace.json`

**Interfaces:**
- Produces: `main "$@"` dispatch recognizing subcommands `issue|epic|epics` and `-h|--help`; sourcing guard `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` so tests can source the file without running `main`. `usage()` prints help and the script exits `0` on `--help`, `2` on unknown subcommand.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-issue-fetch/tests/run-tests.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: FAIL (script does not exist yet / not executable).

- [ ] **Step 3: Write minimal implementation**

Create `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh`:

```bash
#!/usr/bin/env bash
# gh-issue-fetch — download auth-gated GitHub issue images locally and resolve
# epic task-lists. Read-only toward GitHub. See README.md.
set -euo pipefail

usage() {
  cat <<'USAGE'
gh-issue-fetch — fetch GitHub issue details with images, resolve epics.

Usage:
  gh-issue-fetch.sh issue <n>  [-R owner/repo] [--no-images] [--max-assets N] [--max-bytes BYTES] [--strict]
  gh-issue-fetch.sh epic  <n>  [-R owner/repo] [--with-images] [--strict]
  gh-issue-fetch.sh epics      [-R owner/repo] [--label L]

Output: /tmp/gh-issue-<owner>-<repo>-<n>/ (issue.md, assets/, manifest.json)
Read-only: never writes to GitHub.
USAGE
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    -h|--help|"") usage; exit 0 ;;
    issue|epic|epics) shift; "cmd_${cmd}" "$@" ;;
    *) echo "error: unknown subcommand '$cmd'" >&2; usage >&2; exit 2 ;;
  esac
}

# Stub subcommands (filled in later tasks).
cmd_issue() { echo "not yet implemented" >&2; exit 1; }
cmd_epic()  { echo "not yet implemented" >&2; exit 1; }
cmd_epics() { echo "not yet implemented" >&2; exit 1; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Then `chmod +x plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh` and `chmod +x plugins/gh-issue-fetch/tests/run-tests.sh`.

Create `plugins/gh-issue-fetch/.claude-plugin/plugin.json`:

```json
{
  "name": "gh-issue-fetch",
  "version": "0.1.0",
  "description": "Fetch GitHub issue details with auth-gated images downloaded locally, plus epic task-list resolution — so Claude can read issue screenshots and reason about epic progress",
  "author": {
    "name": "Andre Paat"
  },
  "repository": "https://github.com/paat/claude-plugins",
  "license": "MIT",
  "keywords": [
    "github",
    "github-issues",
    "gh-cli",
    "screenshots",
    "epics",
    "productivity"
  ]
}
```

Add to `.claude-plugin/marketplace.json` `plugins` array (match the existing entry shape):

```json
    {
      "name": "gh-issue-fetch",
      "description": "Fetch GitHub issue details with auth-gated images downloaded locally, plus epic task-list resolution",
      "version": "0.1.0",
      "author": {
        "name": "Andre Paat"
      },
      "source": "./plugins/gh-issue-fetch",
      "category": "development",
      "homepage": "https://github.com/paat/claude-plugins"
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: `PASS  help exits 0`, `PASS  unknown subcmd exits 2`, `ALL GREEN`.

- [ ] **Step 5: Validate JSON**

Run: `jq -e . plugins/gh-issue-fetch/.claude-plugin/plugin.json >/dev/null && jq -e . .claude-plugin/marketplace.json >/dev/null && echo JSON-OK`
Expected: `JSON-OK`.

- [ ] **Step 6: Commit**

```bash
git add plugins/gh-issue-fetch .claude-plugin/marketplace.json
git commit -m "feat(gh-issue-fetch): scaffold plugin + arg dispatch"
```

---

### Task 2: `extract_asset_urls` — scrape attachment URLs from issue text

**Files:**
- Modify: `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh`
- Modify: `plugins/gh-issue-fetch/tests/run-tests.sh`
- Create: `plugins/gh-issue-fetch/tests/fixtures/body-urls.md`

**Interfaces:**
- Produces: `extract_asset_urls` — reads text on **stdin**, prints unique attachment URLs one per line in first-seen order. Recognizes: `![alt](url)`, `![alt](url "title")`, `<img ... src="url">`, `src='url'`, bare `https://github.com/user-attachments/assets/<uuid>`, and `https://*.githubusercontent.com/...`. Strips surrounding `<>`, trailing `)`/`"`/`'`, and any markdown title after a space.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-issue-fetch/tests/fixtures/body-urls.md`:

```markdown
Here is a screenshot:
![bug](https://github.com/user-attachments/assets/11111111-1111-1111-1111-111111111111)
And one with a title ![x](https://github.com/user-attachments/assets/22222222-2222-2222-2222-222222222222 "caption")
HTML form: <img width="400" alt="y" src="https://github.com/user-attachments/assets/33333333-3333-3333-3333-333333333333">
Single quotes: <img src='https://github.com/user-attachments/assets/44444444-4444-4444-4444-444444444444'>
Bare: https://github.com/user-attachments/assets/55555555-5555-5555-5555-555555555555
Legacy CDN: ![old](https://user-images.githubusercontent.com/123/abc-def.png)
Duplicate of first: ![dup](https://github.com/user-attachments/assets/11111111-1111-1111-1111-111111111111)
Not an asset: [a link](https://example.com/page)
```

Add to `run-tests.sh` (before the final summary):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: FAIL on the Task 2 checks (`extract_asset_urls` undefined → counts wrong).

- [ ] **Step 3: Write minimal implementation**

Add to `gh-issue-fetch.sh` (above the stub subcommands):

```bash
# Read text on stdin, print unique attachment URLs (first-seen order).
extract_asset_urls() {
  grep -oE '(https://github\.com/user-attachments/assets/[A-Za-z0-9-]+|https://[A-Za-z0-9.-]*githubusercontent\.com/[^][:space:]"'"'"'<>)]+)' \
    | sed -E 's/[")'"'"'>]+$//' \
    | awk '!seen[$0]++'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: all Task 2 checks PASS, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-issue-fetch
git commit -m "feat(gh-issue-fetch): scrape attachment URLs from issue text"
```

---

### Task 3: `sanitize_component` + `ext_for_mime` — safe paths and extensions

**Files:**
- Modify: `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh`
- Modify: `plugins/gh-issue-fetch/tests/run-tests.sh`

**Interfaces:**
- Produces: `sanitize_component <str>` → echoes the string with every char outside `[A-Za-z0-9._-]` replaced by `-`. Used for owner/repo in the output dir.
- Produces: `ext_for_mime <mimetype>` → echoes a file extension: `image/png`→`png`, `image/jpeg`→`jpg`, `image/gif`→`gif`, `image/webp`→`webp`, `image/svg+xml`→`svg`, `application/pdf`→`pdf`, anything else→`bin`.

- [ ] **Step 1: Write the failing test**

Add to `run-tests.sh`:

```bash
# --- Task 3: sanitize_component + ext_for_mime ---
check "sanitize slashes" "r-53-ou-aruannik" "$(sanitize_component 'r-53-ou/aruannik')"
check "sanitize dots ok"  "a.b_c-d"          "$(sanitize_component 'a.b_c-d')"
check "sanitize traversal" "------etc-passwd" "$(sanitize_component '../../etc/passwd')"
check "mime png" "png" "$(ext_for_mime image/png)"
check "mime jpeg" "jpg" "$(ext_for_mime image/jpeg)"
check "mime pdf"  "pdf" "$(ext_for_mime application/pdf)"
check "mime unknown" "bin" "$(ext_for_mime application/octet-stream)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: FAIL on Task 3 checks (functions undefined).

- [ ] **Step 3: Write minimal implementation**

Add to `gh-issue-fetch.sh`:

```bash
sanitize_component() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]/-/g'
}

ext_for_mime() {
  case "$1" in
    image/png)      echo png ;;
    image/jpeg)     echo jpg ;;
    image/gif)      echo gif ;;
    image/webp)     echo webp ;;
    image/svg+xml)  echo svg ;;
    application/pdf) echo pdf ;;
    *)              echo bin ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: Task 3 checks PASS, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-issue-fetch
git commit -m "feat(gh-issue-fetch): safe path sanitizer + mime->ext mapping"
```

---

### Task 4: `parse_task_list` — extract epic child issues

**Files:**
- Modify: `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh`
- Modify: `plugins/gh-issue-fetch/tests/run-tests.sh`
- Create: `plugins/gh-issue-fetch/tests/fixtures/epic-body.md`

**Interfaces:**
- Produces: `parse_task_list` — reads issue body on **stdin**, prints one line per checklist child as `state<TAB>number`, where `state` is `checked` or `unchecked`. Matches `- [ ] #12`, `- [x] #34`, `* [X] #56` (leading `-` or `*`, case-insensitive `x`). Ignores task-list items without a `#NNN` issue reference.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-issue-fetch/tests/fixtures/epic-body.md`:

```markdown
# Epic: payments

Children:
- [ ] #101 wire stripe
- [x] #102 add webhook
* [X] #103 reconcile
- [ ] no issue ref here
- [ ] #104 refunds
```

Add to `run-tests.sh`:

```bash
# --- Task 4: parse_task_list ---
total="$(parse_task_list < "$FIX/epic-body.md" | wc -l | tr -d ' ')"
check "parses 4 children" 4 "$total"
checked="$(parse_task_list < "$FIX/epic-body.md" | grep -c '^checked')"
check "2 checked" 2 "$checked"
nums="$(parse_task_list < "$FIX/epic-body.md" | awk '{print $2}' | paste -sd, -)"
check "child numbers in order" "101,102,103,104" "$nums"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: FAIL on Task 4 checks.

- [ ] **Step 3: Write minimal implementation**

Add to `gh-issue-fetch.sh`:

```bash
# stdin: issue body. stdout: "checked\t<num>" / "unchecked\t<num>" per child.
parse_task_list() {
  grep -oiE '^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+#[0-9]+' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+\[([ xX])\][[:space:]]+#([0-9]+).*/\1\t\2/' \
    | awk -F'\t' '{ st=($1=="x"||$1=="X")?"checked":"unchecked"; print st"\t"$2 }'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: Task 4 checks PASS, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-issue-fetch
git commit -m "feat(gh-issue-fetch): parse epic task-list child issues"
```

---

### Task 5: Network wrappers + `resolve_repo` + preflight

**Files:**
- Modify: `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh`
- Modify: `plugins/gh-issue-fetch/tests/run-tests.sh`

**Interfaces:**
- Produces: `require_tools` — exits `3` with a clear message if `gh`/`jq`/`curl`/`file` missing.
- Produces: `gh_json <args...>` — thin wrapper that runs `gh "$@"`. Tests override it.
- Produces: `download_url <url> <dest>` — downloads with auth; on success prints `<http_status>\t<content_type>\t<bytes>` and returns 0; on HTTP >=400 returns 1 but still prints the status line. Uses `curl -fsSL -H "Authorization: token $(gh auth token)" -w '%{http_code}\t%{content_type}\t%{size_download}' -o "$dest"`. **No `--location-trusted`.** Honors `GHIF_MAX_BYTES` via `--max-filesize`.
- Produces: `resolve_repo [-R owner/repo]` parsing helper `repo_from_flag_or_remote <args...>` → echoes `owner/repo` from an explicit `-R` value if present, else from `gh repo view --json nameWithOwner -q .nameWithOwner`.

- [ ] **Step 1: Write the failing test**

Add to `run-tests.sh`:

```bash
# --- Task 5: wrappers ---
# download_url builds the right curl invocation: stub curl, capture args.
stubdir="$(mktemp -d)"
cat > "$stubdir/curl" <<'STUB'
#!/usr/bin/env bash
echo "$@" > "$GHIF_CURL_ARGS_OUT"
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: FAIL on Task 5 checks (`download_url` undefined).

- [ ] **Step 3: Write minimal implementation**

Add to `gh-issue-fetch.sh`:

```bash
require_tools() {
  local t
  for t in gh jq curl file; do
    command -v "$t" >/dev/null 2>&1 || { echo "error: required tool '$t' not found" >&2; exit 3; }
  done
}

gh_json() { gh "$@"; }

# download_url <url> <dest>. Prints "<status>\t<ctype>\t<bytes>". 0 ok, 1 http>=400.
download_url() {
  local url="$1" dest="$2" maxbytes="${GHIF_MAX_BYTES:-52428800}" line status
  line="$(curl -sSL \
      -H "Authorization: token $(gh auth token)" \
      --max-filesize "$maxbytes" \
      -w '%{http_code}\t%{content_type}\t%{size_download}' \
      -o "$dest" "$url" 2>/dev/null)" || true
  printf '%s' "$line"
  status="${line%%$'\t'*}"
  [ -n "$status" ] && [ "$status" -lt 400 ] 2>/dev/null
}

repo_from_flag_or_remote() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "-R" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  gh repo view --json nameWithOwner -q .nameWithOwner
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: Task 5 checks PASS, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-issue-fetch
git commit -m "feat(gh-issue-fetch): network wrappers, tool preflight, repo resolution"
```

---

### Task 6: `cmd_issue` — assemble issue.md + assets + manifest

**Files:**
- Modify: `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh`
- Modify: `plugins/gh-issue-fetch/tests/run-tests.sh`
- Create: `plugins/gh-issue-fetch/tests/fixtures/issue-view.json`
- Create: `plugins/gh-issue-fetch/tests/fixtures/comments.json`

**Interfaces:**
- Consumes: `extract_asset_urls`, `sanitize_component`, `ext_for_mime`, `download_url`, `gh_json`, `repo_from_flag_or_remote`.
- Produces: `cmd_issue <n> [-R owner/repo] [--no-images] [--max-assets N] [--max-bytes BYTES] [--strict]`. Writes `$OUTDIR/issue.md`, `$OUTDIR/assets/NNN.ext`, `$OUTDIR/manifest.json`; prints `OUTDIR=<dir>`. `OUTDIR` overridable via env `GHIF_OUTDIR` for testing. Each downloaded URL is rewritten in `issue.md` (exact-string) to its relative `assets/NNN.ext`; failed ones get a `<!-- download failed: HTTP nnn -->` marker. `--max-assets` default 50.

**Testability note:** the test overrides `gh_json` and `download_url` by sourcing the script then redefining the functions before calling `cmd_issue`, and points `GHIF_OUTDIR` at a temp dir. `gh_json` stub returns the fixture JSON based on args; `download_url` stub copies the tiny fixture PNG to `$dest` and prints a `200` status line.

- [ ] **Step 1: Write the failing test**

Create `plugins/gh-issue-fetch/tests/fixtures/issue-view.json`:

```json
{
  "number": 7,
  "title": "Button overflows on mobile",
  "state": "OPEN",
  "url": "https://github.com/o/r/issues/7",
  "author": { "login": "alice" },
  "labels": [ { "name": "bug" } ],
  "body": "Repro screenshot:\n![bug](https://github.com/user-attachments/assets/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa)\n"
}
```

Create `plugins/gh-issue-fetch/tests/fixtures/comments.json`:

```json
[
  { "id": 555, "user": { "login": "bob" },
    "body": "Also here:\n![more](https://github.com/user-attachments/assets/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb)\n" }
]
```

Generate a tiny real PNG fixture (1x1) for the download stub to copy:

```bash
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
  > plugins/gh-issue-fetch/tests/fixtures/pixel.png
```

Add to `run-tests.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: FAIL on Task 6 checks (`cmd_issue` still the stub).

- [ ] **Step 3: Write minimal implementation**

Replace the `cmd_issue` stub in `gh-issue-fetch.sh` with:

```bash
cmd_issue() {
  require_tools
  local issue="" repo="" no_images=0 strict=0 max_assets=50
  local prev=""
  # first positional is the issue number; flags handled in a loop
  local args=("$@")
  local i
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
      --no-images) no_images=1 ;;
      --strict) strict=1 ;;
      --max-assets) max_assets="${args[$((i+1))]}" ;;
      --max-bytes) export GHIF_MAX_BYTES="${args[$((i+1))]}" ;;
      -R) repo="${args[$((i+1))]}" ;;
      [0-9]*) [ -z "$issue" ] && issue="${args[$i]}" ;;
    esac
  done
  [ -n "$issue" ] || { echo "error: issue number required" >&2; exit 2; }
  [ -n "$repo" ] || repo="$(repo_from_flag_or_remote "$@")"
  local owner="${repo%%/*}" name="${repo##*/}"

  local outdir="${GHIF_OUTDIR:-/tmp/gh-issue-$(sanitize_component "$owner")-$(sanitize_component "$name")-$issue}"
  mkdir -p "$outdir/assets"

  local meta body comments
  meta="$(gh_json issue view "$issue" -R "$repo" --json number,title,state,author,labels,body,url)"
  body="$(printf '%s' "$meta" | jq -r '.body // ""')"
  comments="$(gh_json api --paginate "repos/$owner/$name/issues/$issue/comments")"

  # Combined text for URL extraction + the rendered markdown we will rewrite.
  local md
  md="$(render_issue_md "$meta" "$comments")"

  # Collect URLs from body + comments.
  local urls
  urls="$( { printf '%s\n' "$body"; printf '%s' "$comments" | jq -r '.[].body // ""'; } | extract_asset_urls )"

  local manifest_items=() idx=0 had_fail=0
  if [ "$no_images" -eq 0 ] && [ -n "$urls" ]; then
    while IFS= read -r url; do
      [ -z "$url" ] && continue
      idx=$((idx+1))
      if [ "$idx" -gt "$max_assets" ]; then
        echo "note: --max-assets $max_assets reached; skipping remaining" >&2
        break
      fi
      local seq; seq="$(printf '%03d' "$idx")"
      local tmp="$outdir/assets/.$seq.dl" statusline status ctype bytes ext rel
      statusline="$(download_url "$url" "$tmp")" || had_fail=1
      status="$(printf '%s' "$statusline" | cut -f1)"
      ctype="$(printf '%s' "$statusline" | cut -f2)"
      bytes="$(printf '%s' "$statusline" | cut -f3)"
      if [ -s "$tmp" ] && [ "${status:-0}" -lt 400 ] 2>/dev/null; then
        ext="$(ext_for_mime "$(file --mime-type -b "$tmp")")"
        rel="assets/$seq.$ext"
        mv "$tmp" "$outdir/$rel"
        # exact-string rewrite in the rendered md
        md="${md//$url/$rel}"
      else
        had_fail=1
        rm -f "$tmp"
        md="${md//$url/$url <!-- download failed: HTTP ${status:-?} -->}"
        rel=""
      fi
      manifest_items+=("$(jq -nc --arg url "$url" --arg lp "$rel" \
        --argjson st "${status:-0}" --arg ct "${ctype:-}" --argjson by "${bytes:-0}" \
        '{url:$url, local_path:$lp, http_status:$st, content_type:$ct, bytes:$by}')")
    done <<< "$urls"
  fi

  printf '%s\n' "$md" > "$outdir/issue.md"
  printf '%s\n' "${manifest_items[@]:-}" | jq -sc \
    --arg repo "$repo" --argjson issue "$issue" \
    '{repo:$repo, issue:$issue, assets: map(select(. != null))}' \
    > "$outdir/manifest.json"

  echo "OUTDIR=$outdir"
  [ "$strict" -eq 1 ] && [ "$had_fail" -eq 1 ] && exit 4
  return 0
}

# render_issue_md <meta-json> <comments-json> -> markdown on stdout
render_issue_md() {
  local meta="$1" comments="$2"
  {
    printf '# %s (#%s)\n\n' "$(printf '%s' "$meta" | jq -r .title)" "$(printf '%s' "$meta" | jq -r .number)"
    printf '- **State:** %s\n' "$(printf '%s' "$meta" | jq -r .state)"
    printf '- **Author:** %s\n' "$(printf '%s' "$meta" | jq -r '.author.login // "?"')"
    printf '- **Labels:** %s\n' "$(printf '%s' "$meta" | jq -r '[.labels[].name] | join(", ")')"
    printf '- **URL:** %s\n\n' "$(printf '%s' "$meta" | jq -r .url)"
    printf '## Description\n\n%s\n\n' "$(printf '%s' "$meta" | jq -r '.body // ""')"
    local clen; clen="$(printf '%s' "$comments" | jq 'length')"
    if [ "${clen:-0}" -gt 0 ]; then
      printf '## Comments\n\n'
      printf '%s' "$comments" | jq -r '.[] | "### @\(.user.login)\n\n\(.body)\n"'
    fi
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: Task 6 checks PASS, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-issue-fetch
git commit -m "feat(gh-issue-fetch): issue subcommand — md + local images + manifest"
```

---

### Task 7: `cmd_epic` and `cmd_epics`

**Files:**
- Modify: `plugins/gh-issue-fetch/scripts/gh-issue-fetch.sh`
- Modify: `plugins/gh-issue-fetch/tests/run-tests.sh`

**Interfaces:**
- Consumes: `parse_task_list`, `gh_json`, `cmd_issue`, `repo_from_flag_or_remote`.
- Produces: `cmd_epic <n> [-R owner/repo] [--with-images] [--strict]` — runs `cmd_issue` for the epic, then appends a `## Children` table to `issue.md` with columns `# | checkbox | issue state | title`, plus a roll-up line `Progress (checkboxes): X/Y` and `Closed (real state): C/Y`. With `--with-images`, also runs `cmd_issue` for each child into its own output dir.
- Produces: `cmd_epics [-R owner/repo] [--label L]` — `--label` default `epic`; lists each labeled issue as `#<n>  <done>/<total>  <title>` where done/total come from its task-list checkbox states.

**Testability note:** test stubs `gh_json` to return the epic body fixture for the parent and minimal `{state,title}` JSON for children; asserts the roll-up math and child rows.

- [ ] **Step 1: Write the failing test**

Add to `run-tests.sh`:

```bash
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
check "child 101 row present" 1 "$(grep -c '#101' "$t7/issue.md")"
rm -rf "$t7"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: FAIL on Task 7 checks (`cmd_epic` still the stub).

- [ ] **Step 3: Write minimal implementation**

Replace the `cmd_epic` / `cmd_epics` stubs in `gh-issue-fetch.sh`:

```bash
cmd_epic() {
  local with_images=0 a repo="" issue=""
  local args=("$@") i
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
      --with-images) with_images=1 ;;
      -R) repo="${args[$((i+1))]}" ;;
      [0-9]*) [ -z "$issue" ] && issue="${args[$i]}" ;;
    esac
  done
  [ -n "$issue" ] || { echo "error: epic issue number required" >&2; exit 2; }
  [ -n "$repo" ] || repo="$(repo_from_flag_or_remote "$@")"

  # Render the epic itself (reuse issue flow, drop its own --with-images concept).
  local out; out="$(cmd_issue "$issue" -R "$repo")"
  local outdir="${out#OUTDIR=}"

  local body; body="$(gh_json issue view "$issue" -R "$repo" --json body -q .body)"
  local rows="" total=0 checked=0 closed=0
  while IFS=$'\t' read -r cbstate num; do
    [ -z "$num" ] && continue
    total=$((total+1))
    [ "$cbstate" = "checked" ] && checked=$((checked+1))
    local cj cstate ctitle
    cj="$(gh_json issue view "$num" -R "$repo" --json state,title,labels 2>/dev/null || echo '{}')"
    cstate="$(printf '%s' "$cj" | jq -r '.state // "?"')"
    ctitle="$(printf '%s' "$cj" | jq -r '.title // ""')"
    [ "$cstate" = "CLOSED" ] && closed=$((closed+1))
    rows+="| #$num | $cbstate | $cstate | $ctitle |"$'\n'
    if [ "$with_images" -eq 1 ]; then cmd_issue "$num" -R "$repo" >/dev/null || true; fi
  done < <(parse_task_list <<< "$body")

  {
    printf '\n## Children\n\n'
    printf 'Progress (checkboxes): %s/%s\n' "$checked" "$total"
    printf 'Closed (real state): %s/%s\n\n' "$closed" "$total"
    printf '| # | checkbox | issue state | title |\n|---|---|---|---|\n'
    printf '%s' "$rows"
  } >> "$outdir/issue.md"

  echo "OUTDIR=$outdir"
}

cmd_epics() {
  require_tools
  local repo="" label="epic"
  local args=("$@") i
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
      --label) label="${args[$((i+1))]}" ;;
      -R) repo="${args[$((i+1))]}" ;;
    esac
  done
  [ -n "$repo" ] || repo="$(repo_from_flag_or_remote "$@")"
  local nums
  nums="$(gh_json issue list -R "$repo" --label "$label" --state all --limit 200 --json number -q '.[].number')"
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    local body title total done_c
    body="$(gh_json issue view "$n" -R "$repo" --json body -q .body)"
    title="$(gh_json issue view "$n" -R "$repo" --json title -q .title)"
    total="$(parse_task_list <<< "$body" | wc -l | tr -d ' ')"
    done_c="$(parse_task_list <<< "$body" | grep -c '^checked' || true)"
    printf '#%s  %s/%s  %s\n' "$n" "$done_c" "$total" "$title"
  done <<< "$nums"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: Task 7 checks PASS, `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add plugins/gh-issue-fetch
git commit -m "feat(gh-issue-fetch): epic resolution + epics listing with progress"
```

---

### Task 8: SKILL.md, README, live smoke, final validation

**Files:**
- Create: `plugins/gh-issue-fetch/skills/gh-issue-fetch/SKILL.md`
- Create: `plugins/gh-issue-fetch/README.md`
- Modify: `plugins/gh-issue-fetch/tests/run-tests.sh` (add documented live-smoke, env-gated)

**Interfaces:**
- Produces: SKILL.md with triggering description; README with Installation (3 scopes) + deps + usage.

- [ ] **Step 1: Write SKILL.md**

Create `plugins/gh-issue-fetch/skills/gh-issue-fetch/SKILL.md`:

```markdown
---
name: gh-issue-fetch
description: Use when you need to SEE images/screenshots attached to a GitHub issue (they are auth-gated and 404 for normal fetches), or to resolve an epic's child task-list with progress. Triggers on "look at issue #N", "the issue has a screenshot", "what's left in epic #N". For plain issue text/listing/search, use `gh` directly instead.
---

# gh-issue-fetch

## When to use
- An issue references a screenshot you cannot open (GitHub `user-attachments` URLs 404 without auth).
- You need an epic (parent issue with a `- [ ] #NNN` checklist) resolved into child states + progress.

## When NOT to use
- Plain issue text, listing, or search — use `gh issue view`, `gh issue list`, `gh search issues` directly. This plugin deliberately does not wrap them.

## Usage
Run the script (it is read-only toward GitHub):

    "${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" issue <n> -R owner/repo
    "${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" epic  <n> -R owner/repo [--with-images]
    "${CLAUDE_PLUGIN_ROOT}/scripts/gh-issue-fetch.sh" epics      -R owner/repo [--label epic]

`-R` defaults to the current repo's remote. It prints `OUTDIR=<dir>`; then **Read** `<dir>/issue.md` and the images under `<dir>/assets/`.

## Notes
- Images download with the gh token; failures are recorded in `manifest.json` and marked inline in `issue.md` — check there if an image is missing.
- Project-specific facts (e.g. a non-default epic label) belong in the repo's project memory, passed via `--label`, not hardcoded here.
```

- [ ] **Step 2: Write README.md**

Create `plugins/gh-issue-fetch/README.md` with sections: overview, **Dependencies** (`gh` authenticated with `repo` scope, `jq`, `curl`, `file`), **Usage** (the three subcommands + flags + output layout), and the required **Installation** section:

```markdown
## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install gh-issue-fetch@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.
```

- [ ] **Step 3: Add env-gated live smoke to run-tests.sh**

Append before the summary block:

```bash
# --- Live smoke (opt-in): GHIF_SMOKE="owner/repo:N" with a known image issue ---
if [ -n "${GHIF_SMOKE:-}" ]; then
  sr="${GHIF_SMOKE%%:*}"; sn="${GHIF_SMOKE##*:}"
  so="$("$SCRIPT" issue "$sn" -R "$sr")"; sd="${so#OUTDIR=}"
  imgs="$(ls "$sd/assets" 2>/dev/null | wc -l | tr -d ' ')"
  check "smoke downloaded >=1 asset" 1 "$( [ "${imgs:-0}" -ge 1 ] && echo 1 || echo 0 )"
  check "smoke asset is an image" 1 "$(file --mime-type -b "$sd/assets/"* 2>/dev/null | grep -c '^image/' || echo 0)"
fi
```

- [ ] **Step 4: Run full test suite**

Run: `bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: `ALL GREEN`.

- [ ] **Step 5: Run the live smoke once manually**

Run: `GHIF_SMOKE="r-53-ou/aruannik:1094" bash plugins/gh-issue-fetch/tests/run-tests.sh`
Expected: `ALL GREEN` including the two smoke checks; confirm `OUTDIR` has a real image and `issue.md` links to `assets/001.<ext>`.

- [ ] **Step 6: Validate manifests + versions in sync**

Run:
```bash
jq -e . plugins/gh-issue-fetch/.claude-plugin/plugin.json >/dev/null
v1=$(jq -r .version plugins/gh-issue-fetch/.claude-plugin/plugin.json)
v2=$(jq -r '.plugins[]|select(.name=="gh-issue-fetch").version' .claude-plugin/marketplace.json)
[ "$v1" = "$v2" ] && echo "version sync OK ($v1)" || { echo "VERSION MISMATCH $v1 vs $v2"; exit 1; }
```
Expected: `version sync OK (0.1.0)`.

- [ ] **Step 7: Commit**

```bash
git add plugins/gh-issue-fetch
git commit -m "docs(gh-issue-fetch): SKILL.md, README with install, live smoke test"
```

---

## Self-Review

**Spec coverage:**
- Auth-gated image download → Tasks 5, 6. ✓
- Safe filenames / content sniff → Tasks 3, 6. ✓
- Auth-on-redirect (no `--location-trusted`) → Task 5 (asserted) + Global Constraints. ✓
- All URL forms scraped + dedupe → Task 2. ✓
- Paginated comments → Task 6 (`gh api --paginate`). ✓
- issue.md with relative rewrites + failure markers → Task 6. ✓
- Rich manifest.json → Task 6. ✓
- Caps (`--max-assets`/`--max-bytes`) + no silent truncation → Tasks 5, 6. ✓
- Partial-failure exit semantics + `--strict` → Task 6. ✓
- Epic checkbox-vs-real-state + roll-up → Task 7. ✓
- `epics` listing with progress → Task 7. ✓
- SKILL.md defers listing/search to gh → Task 8. ✓
- README Installation (3 scopes) + deps → Task 8. ✓
- Version sync both manifests → Tasks 1, 8. ✓
- Read-only, no GitHub writes → enforced throughout (no create/edit calls). ✓

**Placeholder scan:** No TBD/TODO; every code step has full code. ✓

**Type consistency:** `download_url` prints `status\tctype\tbytes` (Task 5) and Task 6 parses those three fields with `cut -f1..3`. `parse_task_list` emits `state\tnum` (Task 4) and Task 7 reads `IFS=$'\t' read -r cbstate num`. `cmd_issue` prints `OUTDIR=<dir>` (Task 6) and Task 7 strips `${out#OUTDIR=}`. Consistent. ✓
