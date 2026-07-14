#!/usr/bin/env bash
# Regenerate the static integrity manifest for the merge-gate runner bundle.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT="$PLUGIN_ROOT/integrity/runner-bundle.json"
FILES=(
  scripts/check-runner-bundle.sh
  scripts/collect-review-evidence.sh
  scripts/generate-runner-bundle.sh
  scripts/lib.sh
  scripts/run-claude-review.sh
  scripts/run-codex-review.sh
  scripts/run-gemini-review.sh
  scripts/run-opencode-review.sh
  scripts/run-qwen-review.sh
)

mode="${1:-}"
case "$mode" in ''|--check) ;; *) printf 'Usage: %s [--check]\n' "$0" >&2; exit 2 ;; esac
for tool in jq sha256sum mktemp cmp; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s is required\n' "$tool" >&2; exit 1; }
done

version="$(jq -er '.version | select(type=="string" and length>0)' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
tmp="$(mktemp)"; entries="$(mktemp)"
trap 'rm -f "$tmp" "$entries"' EXIT HUP INT TERM
: > "$entries"
for path in "${FILES[@]}"; do
  [ -f "$PLUGIN_ROOT/$path" ] && [ ! -L "$PLUGIN_ROOT/$path" ] \
    || { printf 'bundle file missing or symbolic: %s\n' "$path" >&2; exit 1; }
  jq -nc --arg path "$path" --arg sha256 "$(sha256sum "$PLUGIN_ROOT/$path" | awk '{print $1}')" \
    '{path:$path,sha256:$sha256}' >> "$entries"
done
jq -S -n --arg schema tribunal-runner-bundle/v1 --arg plugin tribunal-review \
  --arg version "$version" --slurpfile files "$entries" \
  '{schema:$schema,plugin:$plugin,version:$version,files:$files}' > "$tmp"

if [ "$mode" = --check ]; then
  [ -f "$OUTPUT" ] && cmp -s "$tmp" "$OUTPUT" \
    || { printf 'runner bundle manifest is stale; run %s\n' "$0" >&2; exit 1; }
  printf 'runner bundle manifest is current: %s\n' "$OUTPUT"
else
  mkdir -p "$(dirname "$OUTPUT")"
  chmod 0644 "$tmp"
  mv "$tmp" "$OUTPUT"
  printf 'generated %s\n' "$OUTPUT"
fi
