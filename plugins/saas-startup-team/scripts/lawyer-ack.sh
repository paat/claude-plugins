#!/usr/bin/env bash
# /lawyer ack <slug> — refresh one slug's snapshot + clear its flags after the
# code fix. MUST run inside the branch/PR that carries the fix; commit the
# registry + snapshot changes together with the code so the merge is atomic.
set -uo pipefail
source "$(dirname "$0")/lawyer-common.sh"

SLUG="$1"
[ -n "$SLUG" ] || { echo "Error: slug required"; exit 1; }

entry=$(jq -r --arg s "$SLUG" '.entries[$s] // empty' "$REGISTRY")
[ -n "$entry" ] || { echo "Error: no registry entry for '$SLUG'"; exit 1; }

lawyer_ack_one "$SLUG"; rc=$?
case "$rc" in
  2) echo "Error: datalake returned empty text for act_id=$ACK_ACT_ID slug=$SLUG"; exit 1 ;;
  3) echo "Error: act $ACK_ACT_ID is status=${ACK_STATUS:-unknown}, in_force=${ACK_IN_FORCE:-unknown} — not in force."
     echo "       Refusing to ack '$SLUG': a non-valid act is exactly what must be resolved, not absorbed."
     echo "       Remove or replace the dependency on this paragraph in code, then unregister the slug — do not re-snapshot repealed text."
     exit 1 ;;
esac

echo "Ack: $SLUG — snapshot refreshed, flags cleared."
echo "Remember to commit both .startup/law-registry.json and .startup/laws/${SLUG}.txt in this PR alongside your code changes."
exit 0
