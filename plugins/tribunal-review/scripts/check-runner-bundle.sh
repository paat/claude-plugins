#!/usr/bin/env bash
# Validate the installed merge-gate runner bundle against one pinned manifest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST="$PLUGIN_ROOT/integrity/runner-bundle.json"
EXPECTED=""
REQUIRED='["scripts/check-runner-bundle.sh","scripts/collect-review-evidence.sh","scripts/generate-runner-bundle.sh","scripts/lib.sh","scripts/run-claude-review.sh","scripts/run-codex-review.sh","scripts/run-gemini-review.sh","scripts/run-opencode-review.sh","scripts/run-qwen-review.sh"]'

while [ "$#" -gt 0 ]; do
  case "$1" in
    --expected-manifest-sha256) [ "$#" -ge 2 ] || exit 2; EXPECTED="$2"; shift 2 ;;
    *) printf 'Usage: %s [--expected-manifest-sha256 SHA]\n' "$0" >&2; exit 2 ;;
  esac
done
for tool in jq sha256sum awk; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s is required\n' "$tool" >&2; exit 1; }
done
[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || { printf 'runner bundle manifest missing or symbolic\n' >&2; exit 1; }
digest="$(sha256sum "$MANIFEST" | awk '{print $1}')"
if [ -n "$EXPECTED" ]; then
  case "$EXPECTED" in *[!0-9a-f]*|'') printf 'invalid expected manifest digest\n' >&2; exit 2 ;; esac
  [ "${#EXPECTED}" -eq 64 ] || { printf 'invalid expected manifest digest\n' >&2; exit 2; }
  [ "$digest" = "$EXPECTED" ] || { printf 'runner bundle manifest digest mismatch\n' >&2; exit 1; }
fi
version="$(jq -er '.version | select(type=="string" and length>0)' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
jq -e --arg version "$version" --argjson required "$REQUIRED" '
  (type=="object") and ((keys-["schema","plugin","version","files"]|length)==0)
  and .schema=="tribunal-runner-bundle/v1" and .plugin=="tribunal-review" and .version==$version
  and (.files|type=="array" and length==($required|length)
       and all(.[]; type=="object" and ((keys-["path","sha256"]|length)==0)
         and (.path|type=="string") and (.sha256|type=="string" and test("^[0-9a-f]{64}$")))
       and ([.[].path]|sort)==($required|sort))
' "$MANIFEST" >/dev/null || { printf 'runner bundle manifest schema invalid\n' >&2; exit 1; }

while IFS=$'\t' read -r path sha; do
  [ -f "$PLUGIN_ROOT/$path" ] && [ ! -L "$PLUGIN_ROOT/$path" ] \
    || { printf 'bundle file missing or symbolic: %s\n' "$path" >&2; exit 1; }
  [ "$(sha256sum "$PLUGIN_ROOT/$path" | awk '{print $1}')" = "$sha" ] \
    || { printf 'bundle file digest mismatch: %s\n' "$path" >&2; exit 1; }
done < <(jq -r '.files[] | [.path,.sha256] | @tsv' "$MANIFEST")

jq -nc --arg manifest "$MANIFEST" --arg sha256 "$digest" --arg version "$version" \
  '{manifest:$manifest,sha256:$sha256,version:$version,status:"valid"}'
