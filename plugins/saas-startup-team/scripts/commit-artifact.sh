#!/usr/bin/env bash
# Commit exactly one durable artifact without executing worker-mutable repository hooks.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_ATTR_NOSYSTEM=1
export GIT_NO_REPLACE_OBJECTS=1
unset GIT_EXTERNAL_DIFF
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
unset GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

tmpdir="$(mktemp -d)"; index="$tmpdir/index"; msgfile="$tmpdir/message"
safe_hooks="$tmpdir/hooks"
mkdir -p "$safe_hooks"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# Local config remains available for repository semantics and commit identity, but
# no Git operation in this helper may dispatch a configured program.
export GIT_CONFIG_COUNT=5
export GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1="$safe_hooks"
export GIT_CONFIG_KEY_2=commit.gpgSign GIT_CONFIG_VALUE_2=false
export GIT_CONFIG_KEY_3=gc.auto GIT_CONFIG_VALUE_3=0
export GIT_CONFIG_KEY_4=maintenance.auto GIT_CONFIG_VALUE_4=false

safe_git() { command git "$@"; }

PATH_ARG=""; MESSAGE=""
usage() { echo "usage: commit-artifact.sh --path REPO_RELATIVE_PATH --message TEXT" >&2; }
need_value() { [ "$#" -ge 2 ] || { usage; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --path) need_value "$@"; PATH_ARG="$2"; shift 2 ;;
    --message) need_value "$@"; MESSAGE="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$PATH_ARG" ] && [ -n "$MESSAGE" ] || { usage; exit 2; }
case "$PATH_ARG" in /*|../*|*/../*|*/..) echo "commit-artifact: unsafe path" >&2; exit 2 ;; esac

ROOT="$(safe_git rev-parse --show-toplevel 2>/dev/null)" || exit 2
ROOT="$(realpath -e -- "$ROOT")"; cd "$ROOT"
canonical="$(realpath -m -- "$ROOT/$PATH_ARG")"
case "$canonical" in "$ROOT"/*) : ;; *) echo "commit-artifact: path escapes repository" >&2; exit 2 ;; esac
rel="${canonical#"$ROOT"/}"
[ "$rel" = "$PATH_ARG" ] || { echo "commit-artifact: path is not canonical" >&2; exit 2; }

parent="$(safe_git rev-parse HEAD)"
printf '%s\n' "$MESSAGE" > "$msgfile"

reject_filtered_path() {
  local attr_path attr_name attr_value attrs="$tmpdir/attributes"
  safe_git check-attr -z filter -- "$rel" > "$attrs" || {
    echo "commit-artifact: cannot inspect path attributes" >&2
    exit 1
  }
  exec 3< "$attrs"
  IFS= read -r -d '' attr_path <&3 \
    && IFS= read -r -d '' attr_name <&3 \
    && IFS= read -r -d '' attr_value <&3 || {
      exec 3<&-
      echo "commit-artifact: malformed path attributes" >&2
      exit 1
    }
  if IFS= read -r -d '' _ <&3; then
    exec 3<&-
    echo "commit-artifact: ambiguous path attributes" >&2
    exit 1
  fi
  exec 3<&-
  [ "$attr_path" = "$rel" ] && [ "$attr_name" = filter ] || {
    echo "commit-artifact: unexpected path attributes" >&2
    exit 1
  }
  case "$attr_value" in
    unspecified|unset) : ;;
    *) echo "commit-artifact: filtered path is not allowed: $rel" >&2; exit 1 ;;
  esac
}

outside_fingerprint() {
  local tmp path mode oid result metadata
  local pathspec=(. ":(exclude,literal)$rel")
  tmp="$(mktemp "$tmpdir/outside.XXXXXX")"
  printf 'index\0%s\0' "$(safe_git write-tree)" > "$tmp"
  safe_git diff --binary --no-ext-diff --no-textconv -- "${pathspec[@]}" >> "$tmp"
  safe_git config --null --list --show-origin --show-scope >> "$tmp"
  for metadata in info/attributes info/exclude objects/info/alternates shallow grafts; do
    path="$(safe_git rev-parse --git-path "$metadata")"
    if [ -L "$path" ]; then mode=symlink; oid=unsafe
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      oid="$(safe_git hash-object --no-filters -- "$path")"
    elif [ -e "$path" ]; then mode=unsupported; oid=unsafe
    else mode=missing; oid=missing
    fi
    printf 'metadata\0%s\0%s\0%s\0' "$metadata" "$mode" "$oid" >> "$tmp"
  done
  while IFS= read -r -d '' path; do
    [ "$path" = "$rel" ] && continue
    if [ -L "$path" ]; then
      mode=120000; oid="$(readlink "$path" | safe_git hash-object --stdin)"
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      oid="$(safe_git hash-object --no-filters -- "$path" 2>/dev/null || echo unreadable)"
    elif [ -d "$path" ]; then mode=040000; oid=directory
    elif [ -e "$path" ]; then mode=unsupported; oid=unreadable
    else mode=missing; oid=missing
    fi
    printf 'untracked\0%s\0%s\0%s\0' "$path" "$mode" "$oid" >> "$tmp"
  done < <(safe_git ls-files -z --others --exclude-standard -- .)
  result="$(safe_git hash-object --no-filters "$tmp")"
  rm -f "$tmp"
  printf '%s\n' "$result"
}

reject_filtered_path
GIT_INDEX_FILE="$index" safe_git read-tree "$parent"
GIT_INDEX_FILE="$index" safe_git add -A -- "$rel"
GIT_INDEX_FILE="$index" safe_git diff --cached --quiet "$parent" -- "$rel" && exit 3
outside_before="$(outside_fingerprint)"
[ -s "$msgfile" ] || { echo "commit-artifact: empty commit message" >&2; exit 1; }

# Refuse concurrent changes outside the artifact before creating any Git object/ref.
[ "$(outside_fingerprint)" = "$outside_before" ] || {
  echo "commit-artifact: repository state changed outside $rel" >&2
  exit 1
}

# Rebuild the isolated index after hooks so even a hook that staged unrelated files
# into GIT_INDEX_FILE cannot expand this commit.
reject_filtered_path
GIT_INDEX_FILE="$index" safe_git read-tree "$parent"
GIT_INDEX_FILE="$index" safe_git add -A -- "$rel"
GIT_INDEX_FILE="$index" safe_git diff --cached --quiet "$parent" -- "$rel" && exit 3
tree="$(GIT_INDEX_FILE="$index" safe_git write-tree)"
count=0
while IFS= read -r -d '' changed; do
  [ "$changed" = "$rel" ] || { echo "commit-artifact: isolated tree contains $changed" >&2; exit 1; }
  count=$((count + 1))
done < <(safe_git diff-tree --no-commit-id --name-only -r -z "$parent" "$tree")
[ "$count" -eq 1 ] || { echo "commit-artifact: expected exactly one artifact change" >&2; exit 1; }

commit="$(GIT_INDEX_FILE="$index" safe_git commit-tree "$tree" -p "$parent" -F "$msgfile")"
safe_git update-ref -m "commit: artifact $rel" HEAD "$commit" "$parent"
# Preserve unrelated real-index entries while marking the artifact committed.
safe_git reset -q "$commit" -- "$rel"
printf '%s\n' "$commit"
