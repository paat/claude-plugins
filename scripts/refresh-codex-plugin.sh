#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: refresh-codex-plugin.sh PLUGIN@MARKETPLACE" >&2
  exit 2
}

selector="${1:-}"
[ "$#" -eq 1 ] || usage
case "$selector" in
  *@*) ;;
  *) usage ;;
esac
plugin="${selector%@*}"
marketplace="${selector##*@}"
[[ "$plugin" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || usage
[[ "$marketplace" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || usage

codex_bin="${CODEX_BIN:-codex}"
command -v "$codex_bin" >/dev/null 2>&1 || {
  echo "refresh-codex-plugin: Codex CLI not found: $codex_bin" >&2
  exit 1
}
command -v flock >/dev/null 2>&1 || {
  echo "refresh-codex-plugin: util-linux flock is required" >&2
  exit 1
}

codex_home="${CODEX_HOME:-${HOME:?HOME is required when CODEX_HOME is unset}/.codex}"
mkdir -p "$codex_home/plugins"
codex_home="$(cd "$codex_home" && pwd -P)"
cache_parent="$codex_home/plugins/cache/$marketplace"
cache_root="$cache_parent/$plugin"
[ ! -L "$codex_home/plugins" ] && [ ! -L "$codex_home/plugins/cache" ] || {
  echo "refresh-codex-plugin: cache path must not contain a symlink" >&2
  exit 1
}
mkdir -p "$cache_parent"
[ ! -L "$cache_parent" ] && [ ! -L "$cache_root" ] || {
  echo "refresh-codex-plugin: cache path must not contain a symlink" >&2
  exit 1
}
lock_file="$codex_home/plugins/.refresh-$marketplace-$plugin.lock"
exec 9> "$lock_file"
flock 9

grace_seconds="${CODEX_PLUGIN_RETAIN_SECONDS:-604800}"
max_retained="${CODEX_PLUGIN_RETAIN_MAX:-8}"
[[ "$grace_seconds" =~ ^[0-9]+$ ]] || {
  echo "refresh-codex-plugin: CODEX_PLUGIN_RETAIN_SECONDS must be a non-negative integer" >&2
  exit 2
}
[[ "$max_retained" =~ ^[1-9][0-9]*$ ]] || {
  echo "refresh-codex-plugin: CODEX_PLUGIN_RETAIN_MAX must be a positive integer" >&2
  exit 2
}

backup="$(mktemp -d "$codex_home/plugins/.refresh-$plugin.XXXXXX")"
trap 'rm -rf -- "$backup"' EXIT
had_cache=0
if [ -d "$cache_root" ]; then
  mkdir "$backup/old"
  cp -a -- "$cache_root/." "$backup/old/"
  had_cache=1
fi

set +e
"$codex_bin" plugin add "$selector"
install_rc=$?
set -e

restore_previous() {
  local old version target now marker old_marker
  [ "$had_cache" -eq 1 ] || return 0
  mkdir -p "$cache_root"
  retention_dir="$cache_root/.retained"
  [ ! -L "$retention_dir" ] || {
    echo "refresh-codex-plugin: retention state must not be a symlink" >&2
    return 1
  }
  mkdir -p "$retention_dir"
  now="$(date +%s)"
  for old in "$backup/old"/*; do
    [ -d "$old" ] && [ ! -L "$old" ] || continue
    version="${old##*/}"
    target="$cache_root/$version"
    if [ ! -e "$target" ]; then
      marker="$retention_dir/$version"
      old_marker="$backup/old/.retained/$version"
      if [ -f "$old_marker" ] && [ ! -L "$old_marker" ]; then
        mv -- "$old_marker" "$marker"
      else
        printf '%s\n' "$now" > "$marker"
      fi
      mv -- "$old" "$target"
      restored_versions+=("$version")
    fi
  done
}

if [ "$install_rc" -ne 0 ]; then
  rm -rf -- "$cache_root"
  if [ "$had_cache" -eq 1 ]; then
    mv -- "$backup/old" "$cache_root"
  fi
  exit "$install_rc"
fi

restored_versions=()
if ! restore_previous; then
  rm -rf -- "$cache_root"
  [ "$had_cache" -eq 0 ] || mv -- "$backup/old" "$cache_root"
  exit 1
fi
if [ "${#restored_versions[@]}" -gt 0 ]; then
  printf 'refresh-codex-plugin: retained previous version(s): %s; active sessions keep their original locators, and a new thread is required to load the installed version\n' \
    "${restored_versions[*]}" >&2
fi

now="$(date +%s)"
retention_dir="$cache_root/.retained"
read_retired_at() {
  local marker="$1" raw=""
  raw="$(head -n 1 "$marker" 2>/dev/null || true)"
  if [[ "$raw" =~ ^[0-9]{1,18}$ ]]; then
    RETIRED_AT="$((10#$raw))"
  else
    echo "refresh-codex-plugin: resetting invalid retention marker: $marker" >&2
    RETIRED_AT="$now"
    printf '%s\n' "$RETIRED_AT" > "$marker"
  fi
  if [ "$RETIRED_AT" -gt "$now" ]; then
    echo "refresh-codex-plugin: resetting future retention marker: $marker" >&2
    RETIRED_AT="$now"
    printf '%s\n' "$RETIRED_AT" > "$marker"
  fi
}
for retained in "$cache_root"/*; do
  [ -d "$retained" ] && [ ! -L "$retained" ] || continue
  marker="$retention_dir/${retained##*/}"
  [ -f "$marker" ] && [ ! -L "$marker" ] || continue
  read_retired_at "$marker"
  if [ "$((now - RETIRED_AT))" -ge "$grace_seconds" ]; then
    rm -rf -- "$retained"
    rm -f -- "$marker"
  fi
done

mapfile -t retained_versions < <(
  for retained in "$cache_root"/*; do
    [ -d "$retained" ] && [ ! -L "$retained" ] || continue
    marker="$retention_dir/${retained##*/}"
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    read_retired_at "$marker"
    printf '%020d\t%s\n' "$RETIRED_AT" "${retained##*/}"
  done | sort -n
)
excess=$((${#retained_versions[@]} - max_retained))
for ((i=0; i<excess; i++)); do
  entry="${retained_versions[$i]}"
  retired_at="${entry%%$'\t'*}"
  retired_at="$((10#$retired_at))"
  version="${entry#*$'\t'}"
  if [ "$((now - retired_at))" -lt "$grace_seconds" ]; then
    echo "refresh-codex-plugin: retention cap is evicting $version before the grace period; an older active locator may require same-plugin resolution" >&2
  fi
  rm -rf -- "$cache_root/$version"
  rm -f -- "$retention_dir/$version"
done

for marker in "$retention_dir"/*; do
  [ -f "$marker" ] && [ ! -L "$marker" ] || continue
  [ -d "$cache_root/${marker##*/}" ] || rm -f -- "$marker"
done
