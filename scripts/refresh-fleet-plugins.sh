#!/usr/bin/env bash
# refresh-fleet-plugins.sh PLUGIN@MARKETPLACE VERSION CONTAINER...
# Refresh one marketplace plugin for Claude Code and Codex inside each named container, then
# print one PASS/FAIL/SKIP line per container. Run from the repository root on the Docker host
# (or a container with Docker access). Scripts go in over stdin: a tmpfs /tmp inside a container
# hides files copied there. Nothing is deleted inside the containers, and a refresh never
# installs: a side (Claude or Codex) where the plugin is not installed reports not-installed and
# is left alone. Exit 0 all PASS/SKIP, 1 any FAIL, 2 usage or Docker unreachable.
set -uo pipefail

[ "$#" -ge 3 ] || { echo "usage: refresh-fleet-plugins.sh PLUGIN@MARKETPLACE VERSION CONTAINER..." >&2; exit 2; }
selector="$1"; want="$2"; shift 2
case "$selector" in
  ?*@?*) ;;
  *) echo "refresh-fleet-plugins: expected PLUGIN@MARKETPLACE, got $selector" >&2; exit 2 ;;
esac
marketplace="${selector##*@}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
helper="${REFRESH_CODEX_HELPER:-$repo_root/scripts/refresh-codex-plugin.sh}"
[ -r "$helper" ] || { echo "refresh-fleet-plugins: cannot read $helper" >&2; exit 2; }
# Without a reachable daemon every container would look "not running" and SKIP.
docker version >/dev/null 2>&1 || { echo "refresh-fleet-plugins: Docker daemon unreachable" >&2; exit 2; }
stamp="$(date -u +%Y%m%d)"

read -r -d '' claude_script <<'INNER' || true
set -u
selector="$1"; want="$2"; marketplace="$3"; stamp="$4"
f="$HOME/.claude/plugins/installed_plugins.json"
if ! command -v claude >/dev/null 2>&1 || [ ! -f "$f" ] || ! jq -e --arg p "$selector" '.plugins[$p] | length > 0' "$f" >/dev/null 2>&1; then
  echo "claude=not-installed"; exit 0
fi
cd /workspace 2>/dev/null || cd "$HOME"
claude plugin marketplace update "$marketplace" >/dev/null 2>&1 || echo "note=marketplace-update-failed"
claude plugin update "$selector" --scope user >/dev/null 2>&1 || true
claude plugin update "$selector" --scope local >/dev/null 2>&1 || true
# Entries keyed to other project paths (worktrees) are not touched by `plugin update`: copy the
# fresh entry's version fields onto them.
fresh="$(jq -c --arg p "$selector" --arg w "$want" '[.plugins[$p][] | select(.version == $w)][0]' "$f")"
if [ "$fresh" != null ] && [ -n "$fresh" ]; then
  cp -p "$f" "$f.bak-$stamp"
  jq --arg p "$selector" --argjson fr "$fresh" \
    '.plugins[$p] |= map(. + {version: $fr.version, installPath: $fr.installPath, lastUpdated: $fr.lastUpdated, gitCommitSha: $fr.gitCommitSha})' \
    "$f" > "$f.new-$stamp" && mv "$f.new-$stamp" "$f"
fi
echo "claude=$(jq -r --arg p "$selector" '[.plugins[$p][].version] | unique | join("/")' "$f")"
INNER

# `codex plugin list` columns are separated by two or more spaces: PLUGIN STATUS VERSION SOURCE.
read -r -d '' codex_probe <<'INNER' || true
selector="$1"
if ! command -v codex >/dev/null 2>&1; then echo "codex=no-cli"; exit 0; fi
codex plugin list 2>/dev/null | awk -F '  +' -v s="$selector" '
  $1 == s { found = 1; if ($2 ~ /^not installed/) print "codex=not-installed"; else print "codex=installed " $3; exit }
  END { if (!found) print "codex=not-configured" }'
INNER

rc=0
for c in "$@"; do
  if ! docker exec -u dev "$c" true >/dev/null 2>&1; then
    printf '%-24s SKIP no dev user or not running\n' "$c"; continue
  fi
  claude_out="$(docker exec -i -u dev "$c" bash -l -s -- "$selector" "$want" "$marketplace" "$stamp" <<< "$claude_script" 2>&1 | tr '\n' ' ')"
  codex_out="$(docker exec -i -u dev "$c" bash -l -s -- "$selector" <<< "$codex_probe" 2>&1 | tail -n 1)"
  helper_out=''
  case "$codex_out" in
    codex=installed*)
      docker exec -u dev "$c" bash -lc 'codex plugin marketplace upgrade >/dev/null 2>&1 || true'
      helper_out="$(docker exec -i -u dev "$c" bash -l -s -- "$selector" < "$helper" 2>&1 | tail -n 2 | tr '\n' ' ')"
      codex_out="$(docker exec -i -u dev "$c" bash -l -s -- "$selector" <<< "$codex_probe" 2>&1 | tail -n 1)"
      ;;
  esac
  status=PASS
  case "$claude_out" in *"claude=$want "*|*"claude=not-installed"*) ;; *) status=FAIL ;; esac
  case "$codex_out" in "codex=installed $want"|codex=no-cli|codex=not-configured|codex=not-installed) ;; *) status=FAIL ;; esac
  [ "$status" = PASS ] || rc=1
  printf '%-24s %s %s| %s%s\n' "$c" "$status" "$claude_out" "$codex_out" "${helper_out:+ helper: ${helper_out:0:120}}"
done
exit "$rc"
