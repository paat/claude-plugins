#!/usr/bin/env bash
# /lawyer unregister <slug> — remove a registry entry and its snapshot.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

SLUG="${1:-}"
[ -n "$SLUG" ] || { echo "Usage: lawyer-unregister.sh <slug>"; exit 1; }

if [ ! -f "$REGISTRY" ]; then
  echo "No registry present; nothing to unregister."
  exit 0
fi

existing=$(jq -r --arg slug "$SLUG" '.entries[$slug] // empty' "$REGISTRY")
if [ -z "$existing" ]; then
  echo "Slug '$SLUG' not in registry; nothing to unregister."
  rm -f "${LAWS_DIR}/${SLUG}.txt"   # clean a stray orphan snapshot if present
  exit 0
fi

jq --arg slug "$SLUG" 'del(.entries[$slug])' "$REGISTRY" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"
rm -f "${LAWS_DIR}/${SLUG}.txt"

echo "Unregistered: $SLUG"
exit 0
