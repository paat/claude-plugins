#!/usr/bin/env bash
# review-gate.sh — combine review legs into one verdict and enforce that an
# advisory-only engine is never the sole reviewer.
#
# The local Qwen leg reads the diff and has no shell, so it cannot verify by
# execution. It is a decorrelated extra lens, never the review itself. That rule
# used to live in prose; this script enforces it.
#
# Usage:
#   review-gate.sh [--author <provider-or-model>] --leg <provider>=<final-message-file> [--leg ...]
#
# --author names who wrote the change. A leg from the same provider family then no longer
# counts as the independent reviewer (a model reviewing its own family's work shares its
# blind spots). Omit it only when the run is restricted to one provider.
#
# Fail-closed: only a label naming a hosted catalog provider or model counts as an
# independent reviewer (claude/opus/sonnet/haiku/fable, codex/gpt/astra/terra/luna,
# grok, muse, plus agy/claude-opus-5-5 as Claude). Anything else — `Local Qwen`,
# `qwen3.8-27b-local`, plain `agy`, a typo — is advisory,
# so a label the gate does not recognize can never satisfy independence.
#
# Exit codes:
#   0  APPROVE     — every leg approved and at least one independent leg did
#   1  NEEDS_WORK  — at least one leg asked for work
#   2  usage, unreadable leg, or a leg without a terminal verdict
#   3  no leg from an independent hosted provider (advisory-only set), or with --author
#      none from another provider than the author
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"
. "$SCRIPT_DIR/lib-outcomes.sh"
repo_dir="$PWD"
mode=gate
mmo_outcome_init ""
mmo_outcome_head_sha="$(git rev-parse --verify HEAD 2>/dev/null || true)"

usage() {
  printf '%s\n' 'Usage: review-gate.sh [--author <provider-or-model>] --leg <provider>=<final-message-file> [--leg ...]'
}

legs=()
author=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --author) [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }; author="$2"; shift 2 ;;
    --leg) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; legs+=("$2"); shift 2 ;;
    -h|--help) trap - EXIT; usage; exit 0 ;;
    *) printf 'review-gate: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "${#legs[@]}" -gt 0 ] || { printf 'review-gate: no --leg given\n' >&2; usage >&2; exit 2; }

# Prints the hosted provider family of a label, or nothing for a label outside the catalog.
mmo_provider_family() {
  local label
  label="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  # A local engine is advisory whatever else the label contains.
  case "$label" in *qwen*|*local*) return 0 ;; esac
  # agy is advisory, except an Opus 5.5 leg, which reviews as Claude.
  case "$label" in agy/claude-opus-5-5) printf 'claude\n'; return 0 ;; agy*) return 0 ;; esac
  case "$label" in
    claude*|opus*|sonnet*|haiku*|fable*) printf 'claude\n' ;;
    codex*|gpt*|astra*|terra*|luna*) printf 'codex\n' ;;
    grok*) printf 'grok\n' ;;
    muse*) printf 'muse\n' ;;
  esac
}

author_family="$(mmo_provider_family "$author")"
independent=0
needs_work=0

for leg in "${legs[@]}"; do
  provider="${leg%%=*}"
  file="${leg#*=}"
  if [ -z "$provider" ] || [ "$provider" = "$leg" ] || [ -z "$file" ]; then
    printf 'review-gate: --leg must be <provider>=<file>, got: %s\n' "$leg" >&2
    exit 2
  fi
  if [ ! -r "$file" ]; then
    printf 'review-gate: cannot read %s leg: %s\n' "$provider" "$file" >&2
    exit 2
  fi
  if ! mmo_has_review_verdict "$file"; then
    printf 'review-gate: %s leg has no terminal APPROVE/NEEDS_WORK: %s\n' "$provider" "$file" >&2
    exit 2
  fi
  # Classify explicitly: an empty or unexpected result must not read as APPROVE.
  case "$(mmo_terminal_verdict "$file")" in
    APPROVE) ;;
    NEEDS_WORK) needs_work=1 ;;
    *)
      printf 'review-gate: cannot classify the terminal verdict of the %s leg: %s\n' "$provider" "$file" >&2
      exit 2
      ;;
  esac
  family="$(mmo_provider_family "$provider")"
  if [ -n "$family" ] && [ "$family" != "$author_family" ]; then
    independent=1
  fi
done

if [ "$independent" -eq 0 ] && [ -n "$author_family" ]; then
  printf 'review-gate: no leg is from a hosted provider other than the author (%s): a %s reviewer does not make the review independent\n' "$author" "$author_family" >&2
  exit 3
fi
if [ "$independent" -eq 0 ]; then
  printf 'review-gate: advisory-only review set — no leg is from an independent hosted provider (claude, codex, grok, muse); the local engine reads the diff and cannot run probes, so it may not be the only reviewer\n' >&2
  exit 3
fi

if [ "$needs_work" -eq 1 ]; then
  mmo_outcome_verdict=NEEDS_WORK
  printf 'NEEDS_WORK\n'
  exit 1
fi

mmo_outcome_verdict=APPROVE
printf 'APPROVE\n'
exit 0
