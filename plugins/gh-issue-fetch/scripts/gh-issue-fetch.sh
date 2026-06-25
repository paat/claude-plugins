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
  { grep -oE '(https://github\.com/user-attachments/assets/[A-Za-z0-9-]+|https://[A-Za-z0-9.-]*githubusercontent\.com/[^][:space:]"'"'"'<>)]+)' || true; } \
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
  { grep -oE '^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+#[0-9]+' || true; } \
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
  local url="$1" dest="$2" maxbytes="${GHIF_MAX_BYTES:-52428800}" line status rc=0
  line="$(curl -sSL \
      -H "Authorization: token $(gh auth token)" \
      --max-filesize "$maxbytes" \
      -w '%{http_code}\t%{content_type}\t%{size_download}' \
      -o "$dest" "$url" 2>/dev/null)" || rc=$?
  printf '%s' "$line"
  status="${line%%$'\t'*}"
  if [ "$rc" -eq 0 ] && [ -n "$status" ] && [ "$status" -lt 400 ] 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

repo_from_flag_or_remote() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "-R" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  gh repo view --json nameWithOwner -q .nameWithOwner
}

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
  # Guard: when manifest_items is empty, pass an empty string to jq via process
  # substitution so it reads no lines instead of a blank line (which is invalid JSON).
  if [ "${#manifest_items[@]}" -eq 0 ]; then
    jq -sc \
      --arg repo "$repo" --argjson issue "$issue" \
      '{repo:$repo, issue:$issue, assets: map(select(. != null))}' \
      < /dev/null \
      > "$outdir/manifest.json"
  else
    printf '%s\n' "${manifest_items[@]}" | jq -sc \
      --arg repo "$repo" --argjson issue "$issue" \
      '{repo:$repo, issue:$issue, assets: map(select(. != null))}' \
      > "$outdir/manifest.json"
  fi

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

cmd_epic()  { echo "not yet implemented" >&2; exit 1; }
cmd_epics() { echo "not yet implemented" >&2; exit 1; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
