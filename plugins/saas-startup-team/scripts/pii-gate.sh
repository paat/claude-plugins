#!/usr/bin/env bash
#
# pii-gate.sh — shared PII/secrets gate for the self-improvement loop.
#
# Single source of truth so the regex cannot drift between harvest.sh (candidate
# gate) and lesson-file.sh (public-filing boundary). Sourced, not executed.
# Case-insensitive; errs toward OVER-blocking (safety > recall).
#
#   pii_hit "<text>"   -> exit 0 if a secret/PII pattern is present, else 1

pii_hit() {
  printf '%s' "$1" | grep -qiE \
    'sk-[a-z0-9_-]{18,}|(sk|rk|pk)_(live|test)_[a-z0-9]{16,}|dl-[a-f0-9]{20,}|gh[oprsu]_[a-z0-9]{20,}|glpat-[a-z0-9_-]{18,}|akia[0-9a-z]{12,}|aiza[0-9a-z_-]{30,}|ya29\.[0-9a-z_-]{20,}|xox[baprs]-[a-z0-9-]{10,}|eyj[a-z0-9_-]{8,}\.[a-z0-9_-]{8,}\.[a-z0-9_-]{6,}|-----begin [a-z ]*private key-----|authorization:[[:space:]]*(bearer|basic)[[:space:]]+[a-z0-9+/=_-]{20,}|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|(token|secret|password|passwd|api[_-]?key|access[_-]?key|private[_-]?key|auth[_-]?token)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}|[a-z][a-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]:@]+@'
}
