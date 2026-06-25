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
  grep -oiE '^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+#[0-9]+' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+\[([ xX])\][[:space:]]+#([0-9]+).*/\1\t\2/' \
    | awk -F'\t' '{ st=($1=="x"||$1=="X")?"checked":"unchecked"; print st"\t"$2 }'
}

# Stub subcommands (filled in later tasks).
cmd_issue() { echo "not yet implemented" >&2; exit 1; }
cmd_epic()  { echo "not yet implemented" >&2; exit 1; }
cmd_epics() { echo "not yet implemented" >&2; exit 1; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
