#!/usr/bin/env bash
# lifecycle-path.sh — deterministic path classification for the thin lifecycle.
# Pure flags → path name. Does not read or write .startup/state.json.
#
# Usage:
#   lifecycle-path.sh [--concrete] [--evidence-gap] [--has-goal] [--has-brief] [--scout-empty]
#
# Prints one of: fast | discovery | blocked
# Exit 0 on success, 2 on bad args.

set -euo pipefail

CONCRETE=0
EVIDENCE_GAP=0
HAS_GOAL=0
HAS_BRIEF=0
SCOUT_EMPTY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --concrete) CONCRETE=1; shift ;;
    --evidence-gap) EVIDENCE_GAP=1; shift ;;
    --has-goal) HAS_GOAL=1; shift ;;
    --has-brief) HAS_BRIEF=1; shift ;;
    --scout-empty) SCOUT_EMPTY=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "lifecycle-path: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Material evidence gap always selects discovery (can change Done).
if [ "$EVIDENCE_GAP" -eq 1 ]; then
  echo discovery
  exit 0
fi

# Concrete scoped feature/fix with clear outcome → fast path.
if [ "$CONCRETE" -eq 1 ]; then
  echo fast
  exit 0
fi

# No idea/goal and no brief, and scout empty → blocked intake.
if [ "$HAS_GOAL" -eq 0 ] && [ "$HAS_BRIEF" -eq 0 ] && [ "$SCOUT_EMPTY" -eq 1 ]; then
  echo blocked
  exit 0
fi

# Goal or brief present without evidence gap → fast (small scoped default).
if [ "$HAS_GOAL" -eq 1 ] || [ "$HAS_BRIEF" -eq 1 ]; then
  echo fast
  exit 0
fi

# No concrete flags and no demand signal → blocked.
echo blocked
exit 0
