#!/bin/bash
# notify.sh <ENV_VAR_NAME> <title> — POST stdin body to the URL held in the
# named env var (ntfy/webhook contract). Unset var = silent no-op. Never
# fails the caller: push loss must not break a scheduler tick.
set -uo pipefail
VAR="${1:?usage: notify.sh ENV_VAR_NAME TITLE}"
TITLE="${2:?usage: notify.sh ENV_VAR_NAME TITLE}"
URL="${!VAR:-}"
[ -n "$URL" ] || exit 0
curl -fsS -m 15 -H "Title: $TITLE" --data-binary @- "$URL" >/dev/null 2>&1 || true
exit 0
