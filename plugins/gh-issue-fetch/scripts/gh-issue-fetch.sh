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

# Read text on stdin, print unique attachment URLs (first-seen order).
extract_asset_urls() {
  grep -oE '(https://github\.com/user-attachments/assets/[A-Za-z0-9-]+|https://[A-Za-z0-9.-]*githubusercontent\.com/[^][:space:]"'"'"'<>)]+)' \
    | sed -E 's/[")'"'"'>.,\]]+$//' \
    | awk '!seen[$0]++'
}

# Sanitize a path component: replace non-alphanumeric (except . _ -) with -.
sanitize_component() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]/-/g'
}

# Map mime type to file extension; default "bin" for unknown.
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

# stdin: issue body. stdout: "checked\t<num>" / "unchecked\t<num>" per child.
parse_task_list() {
  grep -oE '^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+#[0-9]+' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+\[([ xX])\][[:space:]]+#([0-9]+)/\1:\2/' \
    | awk -F: '{ st=($1=="x"||$1=="X")?"checked":"unchecked"; print st"\t"$2 }'
}

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

# Stub subcommands (filled in later tasks).
cmd_issue() { echo "not yet implemented" >&2; exit 1; }
cmd_epic()  { echo "not yet implemented" >&2; exit 1; }
cmd_epics() { echo "not yet implemented" >&2; exit 1; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
