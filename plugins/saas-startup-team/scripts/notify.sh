#!/bin/bash
# notify.sh — generic push sender for the maintenance loops.
# Levels: --digest (batched daily) and --blocker (immediate, high priority).
# Config resolution (first wins):
#   1. .startup/notify.json  {"kind":"ntfy|webhook|none","url":...,"token_env":...}
#   2. env  SAAS_NOTIFY_KIND / SAAS_NOTIFY_URL / SAAS_NOTIFY_TOKEN_ENV
# Secrets are NEVER read from config or argv: token_env NAMES an env var that
# holds the bearer token; the token value is read from that env var only.
# No hardcoded endpoints. HTTP calls carry a 10s (max 30s) timeout and up to 3 retries.
#
# Exit contract (callers gate cursor-advance / non-fatal handling on this):
#   0  message actually sent
#   3  no channel configured OR kind=none — clean no-op, NOT an error
#   2  usage error (bad/missing args)
#   1  config error — unknown non-empty kind OR malformed notify.json
#   10 send attempted but failed (fixed code — curl's raw exit never leaks into 0–3)
#
# Usage: notify.sh (--digest|--blocker) --title TITLE (--body BODY | --file FILE) [--root DIR]

set -euo pipefail

LEVEL=""; TITLE=""; BODY=""; FILE=""; ROOT=""
# A value-taking flag with no following value is a usage error (not a set -e shift abort).
need_val() { [ "$1" -ge 2 ] || { echo "notify: $2 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --digest)  LEVEL="digest"; shift ;;
    --blocker) LEVEL="blocker"; shift ;;
    --title)   need_val $# "$1"; TITLE="$2"; shift 2 ;;
    --body)    need_val $# "$1"; BODY="$2"; shift 2 ;;
    --file)    need_val $# "$1"; FILE="$2"; shift 2 ;;
    --root)    need_val $# "$1"; ROOT="$2"; shift 2 ;;
    *) echo "notify: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LEVEL" ] || { echo "notify: level required (--digest or --blocker)" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -n "$BODY" ] || [ -n "$FILE" ] || { echo "notify: --body or --file required" >&2; exit 2; }
[ -n "$BODY" ] || { [ -n "$FILE" ] && [ -f "$FILE" ] && BODY="$(cat "$FILE")"; }
[ -n "$BODY" ] || { echo "notify: --file '$FILE' not found or empty" >&2; exit 2; }
[ -n "$TITLE" ] || TITLE="SaaS ${LEVEL}"

# Config: .startup/notify.json wins over env.
CONFIG="$ROOT/.startup/notify.json"
KIND=""; URL=""; TOKEN_ENV=""
if [ -f "$CONFIG" ]; then
  # Malformed JSON is a config error, not a silent no-op.
  jq empty "$CONFIG" 2>/dev/null || { echo "notify: malformed $CONFIG (config error)" >&2; exit 1; }
  KIND="$(jq -r '.kind // empty' "$CONFIG")"
  URL="$(jq -r '.url // empty' "$CONFIG")"
  TOKEN_ENV="$(jq -r '.token_env // empty' "$CONFIG")"
else
  KIND="${SAAS_NOTIFY_KIND:-}"
  URL="${SAAS_NOTIFY_URL:-}"
  TOKEN_ENV="${SAAS_NOTIFY_TOKEN_ENV:-}"
fi

# Unconfigured (no kind, or kind=none) → clean no-op (exit 3, distinct from a real send).
if [ -z "$KIND" ] || [ "$KIND" = "none" ]; then
  echo "notify: no channel configured — skipping ${LEVEL} send (clean no-op)"
  exit 3
fi
# A real kind with an empty URL is a half-configured channel → config error, not a no-op.
if [ -z "$URL" ]; then
  echo "notify: kind $KIND configured but url is empty (config error)" >&2
  exit 1
fi

# Credential from the NAMED env var only (never from config or argv). An empty token_env
# is a valid no-auth send; a configured token_env that is unset OR empty is a
# half-configured channel (config error) — do not silently send unauthenticated.
CRED=""
[ -n "$TOKEN_ENV" ] && CRED="$(printenv "$TOKEN_ENV" 2>/dev/null || true)"
if [ -n "$TOKEN_ENV" ] && [ -z "$CRED" ]; then
  echo "notify: token_env '$TOKEN_ENV' is empty/unset (config error)" >&2
  exit 1
fi

# blocker → high urgency; digest → default.
case "$LEVEL" in blocker) PRIORITY="high" ;; *) PRIORITY="default" ;; esac

TIMEOUT="${SAAS_NOTIFY_TIMEOUT:-10}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=10 ;; esac
if [ "$TIMEOUT" -lt 1 ]; then TIMEOUT=10; fi
if [ "$TIMEOUT" -gt 30 ]; then TIMEOUT=30; fi

# Keep the credential out of the process argv (visible in `ps`): the Authorization
# header goes into a 0600 curl config file passed via -K, removed on exit. The trap
# ends in `:` so it never masks the explicit exit status below.
CURL_CONF=""
cleanup() { [ -n "$CURL_CONF" ] && rm -f "$CURL_CONF"; :; }
trap cleanup EXIT
if [ -n "$CRED" ]; then
  CURL_CONF="$(mktemp)"
  chmod 600 "$CURL_CONF"
  # Strip newlines/CR first — curl's -K parser splits on physical newlines regardless of
  # quoting, so a token newline would inject a second directive (e.g. `insecure`).
  CRED=${CRED//$'\n'/}; CRED=${CRED//$'\r'/}
  # Escape \ then " so a token containing either survives the quoted -K config value.
  esc=${CRED//\\/\\\\}; esc=${esc//\"/\\\"}
  printf 'header = "Authorization: Bearer %s"\n' "$esc" > "$CURL_CONF"
fi

# Turn an HTTP 4xx/5xx into a non-zero curl exit. --fail-with-body needs curl ≥ 7.76;
# fall back to the universal --fail on older curl (Ubuntu 20.04 / Debian 11 / RHEL 8).
FAIL_FLAG=--fail
if curl --help all 2>/dev/null | grep -q -- --fail-with-body; then FAIL_FLAG=--fail-with-body; fi
common=(curl -sS "$FAIL_FLAG" --max-time "$TIMEOUT" --retry 3)
[ -n "$CURL_CONF" ] && common+=(-K "$CURL_CONF")

# --data-raw so a body starting with @ is sent literally, never treated as a file upload.
case "$KIND" in
  ntfy)
    args=(-H "Title: $TITLE" -H "Priority: $PRIORITY" --data-raw "$BODY" "$URL")
    ;;
  webhook)
    payload="$(jq -nc --arg t "$TITLE" --arg b "$BODY" --arg l "$LEVEL" --arg p "$PRIORITY" \
      '{title:$t, body:$b, level:$l, priority:$p}')"
    args=(-X POST -H "Content-Type: application/json" --data-raw "$payload" "$URL")
    ;;
  *)
    echo "notify: unknown kind '$KIND' (config error)" >&2
    exit 1
    ;;
esac

rc=0
"${common[@]}" "${args[@]}" || rc=$?
if [ "$rc" -ne 0 ]; then
  # Exit a FIXED "send failed" code (10), never curl's raw code — curl exit 3 ("URL
  # malformed") would otherwise collide with the intentional no-op sentinel.
  echo "notify: ${LEVEL} send failed (curl exit $rc)" >&2
  exit 10
fi

echo "notify: ${LEVEL} sent via ${KIND}"
