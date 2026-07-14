#!/usr/bin/env bash
# Validate a campaign path before any workflow reads from or writes to it.
set -euo pipefail

require_current=0
if [ "${1:-}" = "--require-current" ]; then require_current=1; shift; fi
campaign_dir="${1:-}"
[ "$#" -eq 1 ] && [ -n "$campaign_dir" ] || {
  echo "usage: check-campaign-path.sh [--require-current] docs/ads/<campaign>" >&2
  exit 2
}
case "$campaign_dir" in
  docs/ads/*) campaign_slug="${campaign_dir#docs/ads/}" ;;
  *) echo "ads campaign path: campaign must be under docs/ads/" >&2; exit 2 ;;
esac
case "$campaign_slug" in
  ""|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
    echo "ads campaign path: invalid campaign slug" >&2
    exit 2
    ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ads campaign path: not inside a Git worktree" >&2
  exit 3
}
[ -d "$repo_root/docs/ads" ] || { echo "ads campaign path: missing docs/ads" >&2; exit 3; }
[ ! -L "$repo_root/docs" ] && [ ! -L "$repo_root/docs/ads" ] || {
  echo "ads campaign path: docs/ads cannot be symlinked" >&2
  exit 3
}
[ -d "$campaign_dir" ] && [ ! -L "$campaign_dir" ] || {
  echo "ads campaign path: campaign directory is missing or symlinked" >&2
  exit 3
}

ads_root="$(cd "$repo_root/docs/ads" && pwd -P)"
campaign_real="$(cd "$campaign_dir" && pwd -P)"
[ "$campaign_real" = "$ads_root/$campaign_slug" ] || {
  echo "ads campaign path: campaign escapes docs/ads" >&2
  exit 3
}

for path in "$campaign_dir/brief.md" "$campaign_dir/launched_at" "$campaign_dir/current/applied_at"; do
  [ ! -L "$path" ] || { echo "ads campaign path: ${path#"$campaign_dir/"} cannot be symlinked" >&2; exit 3; }
done
unexpected_links="$(find "$campaign_dir" -type l ! -path "$campaign_dir/current" -print)"
[ -z "$unexpected_links" ] || {
  echo "ads campaign path: campaign content contains an unexpected symlink" >&2
  exit 3
}
if [ -e "$campaign_dir/current" ] || [ -L "$campaign_dir/current" ]; then
  [ -d "$campaign_dir/current" ] || { echo "ads campaign path: current is not a directory" >&2; exit 3; }
  current_real="$(cd "$campaign_dir/current" && pwd -P)"
  case "$current_real" in
    "$campaign_real"/iterations/*) : ;;
    *) echo "ads campaign path: current escapes campaign iterations" >&2; exit 3 ;;
  esac
fi
if [ "$require_current" -eq 1 ]; then
  [ -d "$campaign_dir/current" ] && [ -f "$campaign_dir/current/spec.md" ] && [ ! -L "$campaign_dir/current/spec.md" ] || {
    echo "ads campaign path: current iteration/spec.md is missing or symlinked" >&2
    exit 3
  }
fi

printf 'ads campaign path: ok\n'
