#!/usr/bin/env bash
# Resolve the repository default branch without guessing a conventional name.

set -euo pipefail

repo=""
root=""
usage() {
  echo "usage: default-branch.sh [--repo OWNER/REPO] [--repo-root DIR]" >&2
  exit 2
}
need_value() { [ "$#" -ge 2 ] || usage; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; repo="$2"; shift 2 ;;
    --repo-root) need_value "$@"; root="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [ -n "$root" ]; then
  [ -d "$root" ] || { echo "default-branch: repository root is not a directory: $root" >&2; exit 2; }
  root="$(cd "$root" && pwd)"
else
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

valid_branch() {
  [ -n "$1" ] && [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" -eq 1 ] \
    && git check-ref-format --branch "$1" >/dev/null 2>&1
}

candidate=""
if command -v gh >/dev/null 2>&1; then
  gh_args=(repo view)
  [ -z "$repo" ] || gh_args+=("$repo")
  gh_args+=(--json defaultBranchRef -q .defaultBranchRef.name)
  candidate="$(cd "$root" && gh "${gh_args[@]}" 2>/dev/null || true)"
  if valid_branch "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
fi

repo_slug() {
  local value="$1" path
  local -a parts=()
  value="${value%/}"
  value="${value%.git}"
  case "$value" in
    *://*) path="${value#*://}"; path="${path#*/}" ;;
    *@*:*) path="${value#*:}" ;;
    *) path="$value" ;;
  esac
  path="${path#/}"
  IFS=/ read -r -a parts <<< "$path"
  [ "${#parts[@]}" -ge 2 ] || return 1
  printf '%s/%s\n' "${parts[${#parts[@]}-2]}" "${parts[${#parts[@]}-1]}"
}

if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$repo" ]; then
    requested_slug="$(repo_slug "$repo" 2>/dev/null || true)"
    origin_url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
    origin_slug="$(repo_slug "$origin_url" 2>/dev/null || true)"
    if [ -z "$requested_slug" ] || [ "${requested_slug,,}" != "${origin_slug,,}" ]; then
      echo "default-branch: origin does not match requested repository $repo" >&2
      exit 1
    fi
  fi

  origin_head="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  case "$origin_head" in
    origin/*) candidate="${origin_head#origin/}" ;;
    *) candidate="" ;;
  esac
  if valid_branch "$candidate" \
    && git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/${candidate}^{commit}" >/dev/null; then
    printf '%s\n' "$candidate"
    exit 0
  fi
fi

echo "default-branch: could not resolve the default branch from GitHub or verified origin/HEAD" >&2
exit 1
