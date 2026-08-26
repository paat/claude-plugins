#!/usr/bin/env bash
# gate.sh — single deterministic gate CLI for schema, PII, legal, spend,
# regression, acceptance, and release checks (issue #391).
#
# Usage:
#   gate.sh schema  --file PATH | --hook-stdin
#   gate.sh pii     --text STR | --file PATH | --hook-stdin [--mode detect|block]
#   gate.sh legal   [--enforce|--validate] DOC...
#   gate.sh spend   envelope [--channel NAME] PATH
#   gate.sh spend   ads [--file PATH | --hook-stdin]
#   gate.sh spend   linkedin [--file PATH | --hook-stdin]
#   gate.sh regression [--hook-stdin]
#   gate.sh acceptance <acceptance-packs args...>
#   gate.sh release signoff --source-root DIR [--target-root DIR]
#   gate.sh release poll <poll-gate args...>
#
# Severity:
#   Critical rules exit 2 (fail closed). Advisory rules exit 0 with a
#   systemMessage on stderr (fail open). Never commits or mutates git/state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die_usage() {
  printf 'gate: %s\n' "$1" >&2
  exit 2
}

sysmsg() {
  # Emit a Claude/Codex hook systemMessage JSON object on stderr.
  jq -nc --arg msg "$1" '{systemMessage:$msg}' >&2
}

read_hook_stdin() {
  # Capture hook JSON once; empty on timeout/EOF.
  HOOK_JSON=$(timeout 5 cat 2>/dev/null || true)
  [ -n "${HOOK_JSON:-}" ] || HOOK_JSON='{}'
}

hook_file_path() {
  printf '%s' "$HOOK_JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true
}

hook_content() {
  printf '%s' "$HOOK_JSON" | jq -r '.tool_input.content // empty' 2>/dev/null || true
}

cmd_schema() {
  local file="" mode="file"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) [ "$#" -ge 2 ] || die_usage "schema --file needs a path"; file="$2"; shift 2 ;;
      --hook-stdin) mode="hook"; shift ;;
      *) die_usage "schema: unknown arg: $1" ;;
    esac
  done
  if [ "$mode" = "hook" ]; then
    read_hook_stdin
    file="$(hook_file_path)"
    [ -n "$file" ] || exit 0
  fi
  [ -n "$file" ] || die_usage "schema needs --file or --hook-stdin"
  case "$file" in
    *.json) ;;
    *) exit 0 ;;
  esac
  # Pre-write: validate tool_input.content when present.
  local content
  content="$(hook_content 2>/dev/null || true)"
  if [ -n "${content:-}" ] && [ "$mode" = "hook" ]; then
    if ! printf '%s' "$content" | python3 -m json.tool >/dev/null 2>&1; then
      local detail
      detail=$(printf '%s' "$content" | python3 -m json.tool 2>&1 | tail -1 || true)
      sysmsg "JSON syntax error in ${file##*/}: ${detail}. Fix before writing."
      exit 2
    fi
    exit 0
  fi
  [ -f "$file" ] || exit 0
  if ! python3 -m json.tool "$file" >/dev/null 2>&1; then
    local detail
    detail=$(python3 -m json.tool "$file" 2>&1 | tail -1 || true)
    sysmsg "JSON syntax error in ${file##*/}: ${detail}. Fix the JSON before continuing."
    exit 2
  fi
  exit 0
}

secrets_hit() {
  # Credentials/tokens only — not emails/names (those stay in pii_hit for issue-file).
  printf '%s' "$1" | grep -qiE \
    'sk-[a-z0-9_-]{18,}|(sk|rk|pk)_(live|test)_[a-z0-9]{16,}|dl-[a-f0-9]{20,}|gh[oprsu]_[a-z0-9]{20,}|glpat-[a-z0-9_-]{18,}|akia[0-9a-z]{12,}|aiza[a-z0-9_-]{30,}|ya29\.[0-9a-z_-]{20,}|xox[baprs]-[a-z0-9-]{10,}|eyj[a-z0-9_-]{8,}\.[a-z0-9_-]{8,}\.[a-z0-9_-]{6,}|-----begin [a-z ]*private key-----|authorization:[[:space:]]*(bearer|basic)[[:space:]]+[a-z0-9+/=_-]{20,}'
}

cmd_pii() {
  # shellcheck source=pii-gate.sh
  . "$SCRIPT_DIR/pii-gate.sh" || die_usage "pii-gate unavailable"
  local mode="block" text="" file="" use_hook=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) [ "$#" -ge 2 ] || die_usage "pii --mode needs detect|block|secrets"; mode="$2"; shift 2 ;;
      --text) [ "$#" -ge 2 ] || die_usage "pii --text needs a value"; text="$2"; shift 2 ;;
      --file) [ "$#" -ge 2 ] || die_usage "pii --file needs a path"; file="$2"; shift 2 ;;
      --hook-stdin) use_hook=1; shift ;;
      *) die_usage "pii: unknown arg: $1" ;;
    esac
  done
  if [ "$use_hook" -eq 1 ]; then
    read_hook_stdin
    file="$(hook_file_path)"
    text="$(hook_content)"
    # Prefer pre-write content; fall back to on-disk file for post-write.
    if [ -z "$text" ] && [ -n "$file" ] && [ -f "$file" ]; then
      text=$(cat "$file" 2>/dev/null || true)
    fi
  elif [ -n "$file" ] && [ -z "$text" ]; then
    [ -f "$file" ] || die_usage "pii: file not found: $file"
    text=$(cat "$file")
  fi
  [ -n "$text" ] || exit 0
  local hit=1
  if [ "$mode" = "secrets" ]; then
    secrets_hit "$text" && hit=0
  else
    pii_hit "$text" && hit=0
  fi
  if [ "$hit" -eq 0 ]; then
    if [ "$mode" = "detect" ]; then
      sysmsg "PII/secret pattern detected${file:+ in $file} (advisory)."
      exit 0
    fi
    sysmsg "BLOCKED: secret/PII pattern detected${file:+ in ${file##*/}}. Remove credentials and tokens before writing. Reference env var NAMES only."
    exit 2
  fi
  exit 0
}

cmd_legal() {
  exec bash "$SCRIPT_DIR/legal-verdict-gate.sh" "$@"
}

cmd_spend_envelope() {
  exec bash "$SCRIPT_DIR/validate-spend-envelope.sh" "$@"
}

cmd_spend_ads() {
  local file="" use_hook=0 content=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) [ "$#" -ge 2 ] || die_usage "spend ads --file needs a path"; file="$2"; shift 2 ;;
      --hook-stdin) use_hook=1; shift ;;
      *) die_usage "spend ads: unknown arg: $1" ;;
    esac
  done
  if [ "$use_hook" -eq 1 ]; then
    read_hook_stdin
    file="$(hook_file_path)"
    content="$(hook_content)"
  fi
  [ -n "$file" ] || exit 0
  case "$file" in
    */docs/growth/channels/ads.md|docs/growth/channels/ads.md) ;;
    *) exit 0 ;;
  esac
  if [ -z "$content" ]; then
    [ -f "$file" ] || exit 0
    content=$(cat "$file" 2>/dev/null || exit 0)
  fi

  local spent cap cap_src have_envelope_cap envelope envelope_state
  spent=$(printf '%s' "$content" | grep -ioP 'total\s*spend:\s*[^0-9]*\K[0-9]+' | tail -1)
  spent=${spent:-0}
  cap=0
  cap_src="approved-budget line"
  have_envelope_cap=0
  envelope="${file%docs/growth/channels/ads.md}docs/growth/envelope.json"
  if envelope_state=$(bash "$SCRIPT_DIR/validate-spend-envelope.sh" --channel ads "$envelope" 2>/dev/null); then
    cap=$(jq -r '.monthly_cap_eur' <<<"$envelope_state")
    cap_src="spend envelope (monthly cap)"
    have_envelope_cap=1
  elif [ -f "$envelope" ]; then
    cap=0
    cap_src="invalid spend envelope (fails canonical validation — fix docs/growth/envelope.json)"
    have_envelope_cap=1
  fi
  if [ "$have_envelope_cap" -eq 0 ]; then
    cap=$(printf '%s' "$content" | grep -ioP 'approved\s*budget:\s*[^0-9]*\K[0-9]+' | tail -1)
    cap=${cap:-0}
    if [ "$cap" -eq 0 ] 2>/dev/null; then
      exit 0
    fi
  fi
  if [ "$spent" -ge "$cap" ] 2>/dev/null; then
    sysmsg "AD BUDGET HARD STOP: Total spend (${spent}) has reached or exceeded the ${cap_src} of ${cap}. Do NOT make any further ad purchases. Add a human task requesting the investor to raise the spend envelope with ROAS data."
    exit 2
  fi
  local threshold
  threshold=$(( cap * 80 / 100 ))
  if [ "$spent" -ge "$threshold" ] 2>/dev/null; then
    sysmsg "Ad budget warning: ${spent} of ${cap} spent ($(( spent * 100 / cap ))%) against the ${cap_src}. Add a human task alerting the investor that budget is running low."
    exit 0
  fi
  exit 0
}

cmd_spend_linkedin() {
  # Advisory: never blocks the counter write (agent must persist limit-reached state).
  local file="" use_hook=0 content=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) [ "$#" -ge 2 ] || die_usage "spend linkedin --file needs a path"; file="$2"; shift 2 ;;
      --hook-stdin) use_hook=1; shift ;;
      *) die_usage "spend linkedin: unknown arg: $1" ;;
    esac
  done
  if [ "$use_hook" -eq 1 ]; then
    read_hook_stdin
    file="$(hook_file_path)"
    content="$(hook_content)"
  fi
  [ -n "$file" ] || exit 0
  case "$file" in
    */docs/growth/channels/linkedin.md|docs/growth/channels/linkedin.md) ;;
    *) exit 0 ;;
  esac
  if [ -z "$content" ]; then
    [ -f "$file" ] || exit 0
    content=$(cat "$file" 2>/dev/null || exit 0)
  fi
  local connections messages views violations=""
  connections=$(printf '%s' "$content" | grep -oP 'connections sent: \K[0-9]+' | tail -1 || echo "0")
  messages=$(printf '%s' "$content" | grep -oP 'messages sent today: \K[0-9]+' | tail -1 || echo "0")
  views=$(printf '%s' "$content" | grep -oP 'profiles viewed today: \K[0-9]+' | tail -1 || echo "0")
  [ "${connections:-0}" -ge 50 ] 2>/dev/null && violations+="Weekly connection limit reached (${connections}/50). "
  [ "${messages:-0}" -ge 20 ] 2>/dev/null && violations+="Daily message limit reached (${messages}/20). "
  [ "${views:-0}" -ge 40 ] 2>/dev/null && violations+="Daily profile view limit reached (${views}/40). "
  if [ -n "$violations" ]; then
    sysmsg "LinkedIn rate limit warning: ${violations}Pause LinkedIn activity for this period and shift effort to cold email or community engagement."
  fi
  exit 0
}

cmd_spend() {
  local sub="${1:-}"
  [ -n "$sub" ] || die_usage "spend needs envelope|ads|linkedin"
  shift
  case "$sub" in
    envelope) cmd_spend_envelope "$@" ;;
    ads) cmd_spend_ads "$@" ;;
    linkedin) cmd_spend_linkedin "$@" ;;
    *) die_usage "spend: unknown subcommand: $sub" ;;
  esac
}

cmd_regression() {
  # Preserve characterized fail-open semantics of check-regression-test.sh.
  if [ "${1:-}" = "--hook-stdin" ] || [ $# -eq 0 ]; then
    exec bash "$SCRIPT_DIR/check-regression-test.sh"
  fi
  die_usage "regression: use --hook-stdin (hook JSON on stdin)"
}

cmd_acceptance() {
  exec bash "$SCRIPT_DIR/acceptance-packs.sh" "$@"
}

cmd_release() {
  local sub="${1:-}"
  [ -n "$sub" ] || die_usage "release needs signoff|poll"
  shift
  case "$sub" in
    signoff) exec bash "$SCRIPT_DIR/solution-signoff-gate.sh" "$@" ;;
    poll) exec bash "$SCRIPT_DIR/poll-gate.sh" "$@" ;;
    *) die_usage "release: unknown subcommand: $sub" ;;
  esac
}

main() {
  local top="${1:-}"
  [ -n "$top" ] || die_usage "usage: gate.sh schema|pii|legal|spend|regression|acceptance|release ..."
  shift
  case "$top" in
    schema) cmd_schema "$@" ;;
    pii) cmd_pii "$@" ;;
    legal) cmd_legal "$@" ;;
    spend) cmd_spend "$@" ;;
    regression) cmd_regression "$@" ;;
    acceptance) cmd_acceptance "$@" ;;
    release) cmd_release "$@" ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die_usage "unknown command: $top" ;;
  esac
}

main "$@"
