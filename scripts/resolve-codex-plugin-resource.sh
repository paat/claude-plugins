#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: resolve-codex-plugin-resource.sh STALE_CODEX_CACHE_PATH" >&2
  exit 2
}

codex_home="${CODEX_HOME:-${HOME:?HOME is required when CODEX_HOME is unset}/.codex}"
[ -d "$codex_home" ] || {
  echo "resolve-codex-plugin-resource: Codex home does not exist" >&2
  exit 1
}
codex_home="$(cd "$codex_home" && pwd -P)"
cache_base="$codex_home/plugins/cache"
[ ! -L "$codex_home/plugins" ] && [ ! -L "$cache_base" ] || {
  echo "resolve-codex-plugin-resource: Codex cache path must not contain a symlink" >&2
  exit 1
}
stale="$1"
case "$stale" in
  "$cache_base"/*) relative="${stale#"$cache_base"/}" ;;
  *)
    echo "resolve-codex-plugin-resource: path is not inside the Codex plugin cache; Claude cache fallback is prohibited" >&2
    exit 1
    ;;
esac

marketplace="${relative%%/*}"
remainder="${relative#*/}"
plugin="${remainder%%/*}"
remainder="${remainder#*/}"
old_version="${remainder%%/*}"
resource="${remainder#*/}"
[[ "$marketplace" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
  && [[ "$plugin" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
  && [ -n "$old_version" ] && [ "$resource" != "$remainder" ] && [ -n "$resource" ] || {
  echo "resolve-codex-plugin-resource: malformed Codex cache path" >&2
  exit 1
}
case "/$resource/" in
  */../*|*/./*)
    echo "resolve-codex-plugin-resource: resource path may not contain . or .. segments" >&2
    exit 1
    ;;
esac

plugin_root="$cache_base/$marketplace/$plugin"
[ -d "$cache_base/$marketplace" ] && [ ! -L "$cache_base/$marketplace" ] \
  && [ -d "$plugin_root" ] && [ ! -L "$plugin_root" ] \
  && [ ! -L "$plugin_root/.retained" ] || {
  echo "resolve-codex-plugin-resource: same-plugin Codex cache path is unsafe or missing" >&2
  exit 1
}
candidates=()
for version_dir in "$plugin_root"/*; do
  [ -d "$version_dir" ] && [ ! -L "$version_dir" ] || continue
  version="${version_dir##*/}"
  [ ! -f "$plugin_root/.retained/$version" ] || continue
  candidate="$version_dir/$resource"
  [ -f "$candidate" ] && [ -r "$candidate" ] && [ ! -L "$candidate" ] || continue
  version_root="$(cd "$version_dir" && pwd -P)"
  [ "$version_root" = "$version_dir" ] || continue
  candidate_parent="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || continue
  case "$candidate_parent" in
    "$version_root"|"$version_root"/*) candidates+=("$candidate") ;;
  esac
done

if [ "${#candidates[@]}" -ne 1 ]; then
  echo "resolve-codex-plugin-resource: expected one current same-plugin resource, found ${#candidates[@]}; start a new Codex thread" >&2
  exit 1
fi

current="${candidates[0]}"
current_version="${current#"$plugin_root"/}"
current_version="${current_version%%/*}"
echo "resolve-codex-plugin-resource: requested Codex version $old_version is unavailable; using same-plugin Codex version $current_version (never Claude cache)" >&2
printf '%s\n' "$current"
