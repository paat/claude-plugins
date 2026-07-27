#!/usr/bin/env bash
# Sensitive-surface risk floor (no model/profile regex routing).
#
# classify --mode autonomous|interactive-tweak --task-file FILE [--labels-file FILE]
# classify-issue --mode autonomous|interactive-tweak --issue N [--repo OWNER/NAME]
# check-diff --base REF [--cached]
# schema-version
#
# Exit 0: not elevated (profile standard|mechanical for empty diffs).
# Exit 20: sensitive surface elevated (profile deep).
# Exit 2: invalid input.

set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_EXTERNAL_DIFF

SCHEMA_VERSION=1
REASONS=()

# Shared vocabulary for task text and post-diff path/content inspection.
SENSITIVE_PATH_PATTERN='(^|/)(auth|login|session|oauth2?|oidc|openid|sso|saml|mfa|2fa|webauthn|passkeys?|security|secrets?|credentials?|encrypt(ion)?|crypto(graphy)?|tls|ssl|certs?|certificates?|rbac|acl|payments?|billing|checkout|invoices?|credit[-_]?cards?|debit[-_]?cards?|cardholders?|pci([-_]?dss)?|sepa|chargebacks?|bank[-_]?(accounts?|details)|accounting|financial([-_/]?(report(ing)?|reports?))?|xbrl|arelle|taxonom(y|ies)|andmesild|migrations?|database|legal|compliance|privacy|cookies?|dpa|dsar)(/|\.|$)|(^|/)\.env($|\.)|\.(pem|key|p12|pfx|sql)$'
SENSITIVE_CONTENT_PATTERN='(authorization:|bearer[[:space:]]|password|passwd|secret|api[_-]?key|checkout|payment|billing|migration|personal data|gdpr|security|credit[[:space:]_-]*cards?|debit[[:space:]_-]*cards?|card[[:space:]_-]*holders?|chargebacks?|bank[[:space:]_-]*(accounts?|details)|accounting|financial[[:space:]_-]+report(ing|s?)|xbrl|arelle|taxonom(y|ies)|andmesild|(^|[^[:alnum:]_])(auth(entication|ori[sz]ation)?|oauth2?|oidc|openid|login|session|sso|saml|mfa|2fa|webauthn|passkeys?|encrypt(ion|ed|ing)?|decrypt(ion|ed|ing)?|cryptograph(y|ic|ical)?|crypto|tls|ssl|certs?|certificates?|rbac|acl|pci([[:space:]_-]*dss)?|sepa|dpa|dsar|cookies?)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])\.env([^[:alnum:]_]|$)|[[:alnum:]_.-]+\.(pem|key|p12|pfx|sql)([^[:alnum:]_]|$))'

usage() {
  echo "usage: delivery-route.sh classify --mode autonomous|interactive-tweak --task-file FILE [--labels-file FILE]" >&2
  echo "       delivery-route.sh classify-issue --mode autonomous|interactive-tweak --issue N [--repo OWNER/NAME]" >&2
  echo "       delivery-route.sh check-diff --base REF [--cached]" >&2
  echo "       delivery-route.sh schema-version" >&2
  exit 2
}

add_reason() {
  local reason=$1 existing
  for existing in "${REASONS[@]:-}"; do
    [ "$existing" = "$reason" ] && return 0
  done
  REASONS+=("$reason")
}

has() {
  local text=$1 pattern=$2
  printf '%s\n' "$text" | grep -qiE -- "$pattern"
}

emit_route() {
  local profile=$1 ui_touch=$2 sensitive=$3
  local product_judgment=$4 legal_judgment=$5 decision=$6
  local reasons_json
  reasons_json=$(printf '%s\n' "${REASONS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -cn \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg profile "$profile" \
    --argjson reasons "$reasons_json" \
    --argjson ui_touch "$ui_touch" \
    --argjson sensitive "$sensitive" \
    --argjson product "$product_judgment" \
    --argjson legal "$legal_judgment" \
    --arg decision "$decision" \
    '{schema_version:$schema_version,profile:$profile,reasons:$reasons,ui_touch:$ui_touch,sensitive:$sensitive,requires_product_judgment:$product,requires_legal_judgment:$legal,decision:$decision}'
}

labels_text() {
  local file=$1
  if jq -e . "$file" >/dev/null 2>&1; then
    jq -r '.. | strings' "$file" 2>/dev/null || return 1
  else
    cat "$file"
  fi
}

scan_sensitive() {
  # Sets: sensitive, legal, product (true/false strings) via namerefs-like globals.
  local text=$1
  sensitive=false legal=false product=false

  if has "$text" '(legal|lawyer|gdpr|privacy (law|policy|notice)|terms[[:space:]]*(&|and|of)|cookie (notice|banner|consent|policy)|eprivacy|contract|licen[cs](e|ing)|regulat|compliance|consent|data protection|(^|[^[:alnum:]_])(tax|vat|dpa|dsar)([^[:alnum:]_]|$))'; then
    sensitive=true; legal=true; add_reason sensitive_legal
  fi
  if has "$text" '(security|vulnerab|exploit|password|passwd|credential|secret|token|permission|access control|(^|[^[:alnum:]_])(auth(entication|ori[sz]ation)?|oauth2?|oidc|openid|login|session|sso|saml|mfa|2fa|webauthn|passkeys?|encrypt(ion|ed|ing)?|decrypt(ion|ed|ing)?|cryptograph(y|ic|ical)?|crypto|tls|ssl|certificates?|rbac|acl)([^[:alnum:]_]|$))'; then
    sensitive=true; add_reason sensitive_security_auth
  fi
  if has "$text" '(payment|billing|checkout|invoice|stripe|payout|refund|subscription|pricing|price change|plan amount|credit[[:space:]_-]*cards?|debit[[:space:]_-]*cards?|card[[:space:]_-]*holders?|(^|[^[:alnum:]_])pci([[:space:]_-]*dss)?([^[:alnum:]_]|$)|(^|[^[:alnum:]_])sepa([^[:alnum:]_]|$)|chargebacks?|bank[[:space:]_-]*(accounts?|details))'; then
    sensitive=true; product=true; add_reason sensitive_payment_pricing
  fi
  if has "$text" '(accounting|financial[[:space:]_-]+report(ing|s?)|(^|[^[:alnum:]_])(xbrl|arelle|andmesild)([^[:alnum:]_]|$)|taxonom(y|ies))'; then
    sensitive=true; add_reason sensitive_accounting_reporting
  fi
  if has "$text" '(database|schema change|data model|migration|personal data|customer data|pii([^[:alnum:]_]|$)|data loss|data integrity|retention|deletion request)'; then
    sensitive=true; add_reason sensitive_data_migration
  fi
  if has "$text" "$SENSITIVE_PATH_PATTERN" || has "$text" "$SENSITIVE_CONTENT_PATTERN"; then
    sensitive=true; add_reason sensitive_surface_vocabulary
  fi
}

classify_issue() {
  local mode="" issue="" repo="" issue_json task_file labels_file rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) [ $# -ge 2 ] || usage; mode=$2; shift 2 ;;
      --issue) [ $# -ge 2 ] || usage; issue=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$mode" in autonomous|interactive-tweak) : ;; *) usage ;; esac
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || {
    echo "delivery-route: --issue must be a positive integer" >&2
    exit 2
  }
  command -v gh >/dev/null 2>&1 || {
    echo "delivery-route: gh is required for classify-issue" >&2
    exit 2
  }
  issue_json=$(mktemp) || exit 2
  task_file=$(mktemp) || { rm -f -- "$issue_json"; exit 2; }
  labels_file=$(mktemp) || { rm -f -- "$issue_json" "$task_file"; exit 2; }
  # shellcheck disable=SC2064
  trap 'rm -f -- "$issue_json" "$task_file" "$labels_file"' RETURN
  if [ -n "$repo" ]; then
    gh issue view "$issue" -R "$repo" --json number,title,body,labels,comments >"$issue_json"
  else
    gh issue view "$issue" --json number,title,body,labels,comments >"$issue_json"
  fi
  jq -r '[.title, .body, (.comments[]?.body // empty)] | map(select(. != null and . != "")) | join("\n\n")' \
    "$issue_json" >"$task_file"
  jq '[.labels[]?.name]' "$issue_json" >"$labels_file"
  set +e
  classify --mode "$mode" --task-file "$task_file" --labels-file "$labels_file"
  rc=$?
  set -e
  return "$rc"
}

classify() {
  local mode="" task_file="" labels_file="" task labels="" text
  local sensitive=false legal=false product=false profile decision rc=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) [ $# -ge 2 ] || usage; mode=$2; shift 2 ;;
      --task-file) [ $# -ge 2 ] || usage; task_file=$2; shift 2 ;;
      --labels-file) [ $# -ge 2 ] || usage; labels_file=$2; shift 2 ;;
      *) usage ;;
    esac
  done

  case "$mode" in autonomous|interactive-tweak) : ;; *) usage ;; esac
  [ -n "$task_file" ] && [ -f "$task_file" ] && [ -r "$task_file" ] || {
    echo "delivery-route: readable --task-file is required" >&2
    exit 2
  }
  if [ -n "$labels_file" ] && { [ ! -f "$labels_file" ] || [ ! -r "$labels_file" ]; }; then
    echo "delivery-route: --labels-file is not readable: $labels_file" >&2
    exit 2
  fi

  task=$(cat "$task_file")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ] || {
    echo "delivery-route: task file is empty" >&2
    exit 2
  }
  [ -z "$labels_file" ] || labels=$(labels_text "$labels_file") || {
    echo "delivery-route: could not parse labels file" >&2
    exit 2
  }
  text=$(printf '%s\n%s\n' "$task" "$labels" | tr '[:upper:]' '[:lower:]')

  scan_sensitive "$text"

  # Risk floor only: elevated when sensitive; otherwise harness picks model/effort.
  if [ "$sensitive" = true ]; then
    profile=deep; decision=restart_deep; rc=20
  else
    profile=standard; decision=continue; add_reason risk_floor_clear
  fi

  emit_route "$profile" false "$sensitive" "$product" "$legal" "$decision"
  return "$rc"
}

check_diff() {
  local base="" cached=0 repo_root tmp names patch
  local sensitive=false legal=false product=false profile decision rc=0
  local diff_args=() nfiles

  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || usage; base=$2; shift 2 ;;
      --cached) cached=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$base" ] || usage
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "delivery-route: check-diff requires a git worktree" >&2
    exit 2
  }
  git -C "$repo_root" rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 || {
    echo "delivery-route: invalid base ref: $base" >&2
    exit 2
  }

  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmp"' RETURN
  [ "$cached" -eq 0 ] || diff_args+=(--cached)
  if ! git -c core.fsmonitor=false -C "$repo_root" diff --no-ext-diff --no-textconv "${diff_args[@]}" "$base" --name-only >"$tmp/names" \
    || ! git -c core.fsmonitor=false -C "$repo_root" diff --no-ext-diff --no-textconv "${diff_args[@]}" "$base" -- >"$tmp/patch"; then
    echo "delivery-route: git diff failed for base $base" >&2
    exit 2
  fi
  if [ "$cached" -eq 0 ]; then
    git -c core.fsmonitor=false -C "$repo_root" ls-files --others --exclude-standard >"$tmp/untracked"
    if [ -s "$tmp/untracked" ]; then
      while IFS= read -r file; do
        [ -n "$file" ] || continue
        printf '%s\n' "$file" >>"$tmp/names"
        printf 'diff --git a/%s b/%s\n--- /dev/null\n+++ b/%s\n' "$file" "$file" "$file" >>"$tmp/patch"
        if [ -f "$repo_root/$file" ] && grep -Iq . "$repo_root/$file" 2>/dev/null; then
          sed 's/^/+/' "$repo_root/$file" >>"$tmp/patch"
        fi
      done <"$tmp/untracked"
    fi
  fi
  names=$(cat "$tmp/names")
  patch=$(cat "$tmp/patch")
  nfiles=$(printf '%s\n' "$names" | grep -c . || true)

  if [ "$nfiles" -eq 0 ]; then
    add_reason empty_diff
    emit_route mechanical false false false false continue
    return 0
  fi

  if printf '%s\n%s\n' "$names" "$patch" | grep -qiE "$SENSITIVE_PATH_PATTERN" \
    || printf '%s\n' "$patch" | grep -qiE "$SENSITIVE_CONTENT_PATTERN"; then
    sensitive=true; add_reason diff_sensitive_surface
  fi
  if printf '%s\n' "$names" | grep -qiE '(^|/)(legal|compliance|privacy)(/|\.|$)' \
    || printf '%s\n' "$patch" | grep -qiE '(legal|gdpr|compliance|consent|terms[[:space:]]*(&|and|of)|cookie (notice|banner|consent|policy)|eprivacy|(^|[^[:alnum:]_])(tax|vat|dpa|dsar)([^[:alnum:]_]|$))'; then
    legal=true; sensitive=true; add_reason diff_legal_judgment
  fi
  if printf '%s\n' "$patch" | grep -qiE '(pricing|price change|product strategy|choose between|redesign)'; then
    product=true; sensitive=true; add_reason diff_product_judgment
  fi

  if [ "$sensitive" = true ]; then
    profile=deep; decision=restart_deep; rc=20
  else
    profile=standard; decision=continue; add_reason risk_floor_clear
  fi

  emit_route "$profile" false "$sensitive" "$product" "$legal" "$decision"
  return "$rc"
}

case "${1:-}" in
  classify) shift; classify "$@" ;;
  classify-issue) shift; classify_issue "$@" ;;
  check-diff) shift; check_diff "$@" ;;
  schema-version) [ $# -eq 1 ] || usage; jq -cn --argjson schema_version "$SCHEMA_VERSION" '{schema_version:$schema_version}' ;;
  *) usage ;;
esac
