#!/bin/bash
# check-ad-budget.sh — PostToolUse hook for Write events
# Hard stop at 100% of the ad-spend cap.
# Cap source: docs/growth/envelope.json (owner pre-authorized, unexpired) if valid,
# else the "Approved budget:" text line in docs/growth/channels/ads.md (fallback).
# Fail closed: a missing / expired / malformed envelope reverts to the text-line cap;
# no cap anywhere → cannot validate → allow (unchanged from the pre-envelope behavior).
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not ads.md, or within budget
# Exit 2: blocked, systemMessage on stderr

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check ads.md writes
if [[ ! "$file_path" =~ docs/growth/channels/ads\.md$ ]]; then
  exit 0
fi

content=$(cat "$file_path" 2>/dev/null || exit 0)

# Spend from the ads.md summary line. Tolerate a currency token (EUR/€/$) between the
# label and the number; the integer part is authoritative (bash arithmetic is integer).
spent=$(echo "$content" | grep -ioP 'total\s*spend:\s*[^0-9]*\K[0-9]+' | tail -1)
spent=${spent:-0}

# Cap: prefer a complete owner-authorized, currently active envelope. A valid envelope is
# AUTHORITATIVE — including a cap of 0 (no spend) — and never falls back to the text line.
cap=0
cap_src="approved-budget line"
have_envelope_cap=0
envelope="${file_path%docs/growth/channels/ads.md}docs/growth/envelope.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if envelope_state=$(bash "$SCRIPT_DIR/validate-spend-envelope.sh" --channel ads "$envelope" 2>/dev/null); then
  cap=$(jq -r '.monthly_cap_eur' <<< "$envelope_state")
  cap_src="spend envelope (monthly cap)"
  have_envelope_cap=1
elif [ -f "$envelope" ]; then
  # An envelope file that exists but fails canonical validation (legacy shape,
  # expired, channel not authorized, malformed) must never fall back to a
  # possibly-higher approved-budget line: cap 0, hard stop on any spend.
  cap=0
  cap_src="invalid spend envelope (fails canonical validation — fix docs/growth/envelope.json)"
  have_envelope_cap=1
fi

if [ "$have_envelope_cap" -eq 0 ]; then
  # No envelope file at all — fall back to the ads.md approved-budget line.
  cap=$(echo "$content" | grep -ioP 'approved\s*budget:\s*[^0-9]*\K[0-9]+' | tail -1)
  cap=${cap:-0}
  if [ "$cap" -eq 0 ] 2>/dev/null; then
    # No cap anywhere — pre-envelope behavior: cannot validate, allow the write.
    exit 0
  fi
fi

if [ "$spent" -ge "$cap" ] 2>/dev/null; then
  cat >&2 <<MSG
{"systemMessage":"AD BUDGET HARD STOP: Total spend (${spent}) has reached or exceeded the ${cap_src} of ${cap}. Do NOT make any further ad purchases. Add a human task requesting the investor to raise the spend envelope with ROAS data."}
MSG
  exit 2
fi

# Warn at 80% but allow the write (exit 0, not exit 2). cap > 0 here (cap==0 blocks above).
threshold=$(( cap * 80 / 100 ))
if [ "$spent" -ge "$threshold" ] 2>/dev/null; then
  cat >&2 <<MSG
{"systemMessage":"Ad budget warning: ${spent} of ${cap} spent ($(( spent * 100 / cap ))%) against the ${cap_src}. Add a human task alerting the investor that budget is running low."}
MSG
  exit 0
fi

exit 0
