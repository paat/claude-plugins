#!/usr/bin/env bash
# /lawyer issue <slug> [body-file] — create the GitHub issue for one flagged slug
# and store its URL in the registry. With no body-file, a minimal body is built
# (non-interactive Disposition A). With a body-file, its content is used verbatim
# (the interactive confirmation flow passes the agent's per-slug fix plan).
# Guards: entry must have needs_review=true AND gh_issue_url=null, else no-op.
# Does NOT touch the snapshot or any field other than gh_issue_url.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

SLUG="${1:-}"
BODY_FILE="${2:-}"
[ -n "$SLUG" ] || { echo "Usage: lawyer-issue.sh <slug> [body-file]"; exit 1; }

entry=$(jq -r --arg s "$SLUG" '.entries[$s] // empty' "$REGISTRY")
[ -n "$entry" ] || { echo "Error: no registry entry for '$SLUG'"; exit 1; }

needs_review=$(jq -r --arg s "$SLUG" '.entries[$s].needs_review' "$REGISTRY")
gh_issue_url=$(jq -r --arg s "$SLUG" '.entries[$s].gh_issue_url // empty' "$REGISTRY")
citation=$(jq -r --arg s "$SLUG" '.entries[$s].citation' "$REGISTRY")

if [ "$needs_review" != "true" ]; then
  echo "No-op: '$SLUG' does not have needs_review=true."
  exit 0
fi
if [ -n "$gh_issue_url" ]; then
  echo "No-op: '$SLUG' already has an open issue: $gh_issue_url"
  exit 0
fi

TMP=$(mktemp -d)
if [ -z "$BODY_FILE" ]; then
  BODY_FILE="$TMP/${SLUG}-issue-body.md"
  cat > "$BODY_FILE" <<ISSUEBODY
Seadusemuudatus tuvastatud: ${citation} (${SLUG})

Palun vaata muudatus üle ja uuenda vastavat koodiosa.
Pärast parandamist käivita PR-i harul:

    /lawyer ack ${SLUG}
ISSUEBODY
fi

if ! issue_url=$(gh issue create \
  --title "Seadusemuudatus: ${citation} — ${SLUG}" \
  --label "legal-review,seadusemuudatus" \
  --body-file "$BODY_FILE" 2>"$TMP/gh-err"); then
  echo "Error: gh issue create failed for '${SLUG}':"
  cat "$TMP/gh-err"
  echo "  Slug remains flagged; gh_issue_url left null. Next /lawyer run will re-prompt."
  exit 1
fi

# gh can exit 0 while still reporting an error on stderr, and a stored non-URL
# would permanently mask the flag. Store only a clean, plausible issue URL.
if [ -s "$TMP/gh-err" ] || [[ ! "$issue_url" =~ ^https://[^[:space:]]+/issues/[0-9]+$ ]]; then
  echo "Error: gh issue create for '${SLUG}' did not return a clean issue URL (got: '${issue_url}')."
  [ -s "$TMP/gh-err" ] && cat "$TMP/gh-err"
  echo "  Slug remains flagged; gh_issue_url left null. Next /lawyer run will re-prompt."
  exit 1
fi

jq --arg slug "$SLUG" --arg url "$issue_url" '.entries[$slug].gh_issue_url = $url' \
  "$REGISTRY" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"

echo "Issue created: $issue_url"
exit 0
