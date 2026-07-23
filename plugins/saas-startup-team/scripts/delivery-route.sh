#!/usr/bin/env bash
# Semantic delivery routing and post-diff containment.
#
# classify --mode autonomous|interactive-tweak --task-file FILE [--labels-file FILE]
# classify-issue --mode autonomous|interactive-tweak --issue N [--repo OWNER/NAME]
# check-diff --base REF [--cached]
# schema-version
#
# Exit 0: classification/continuation accepted.
# Exit 20: restart or escalate at the deep profile.
# Exit 2: invalid input or routing failure.
#
# classify-issue is the agent-safe entrypoint under Codex sandboxes that reject
# outer `rm -f` (agents must not compose temp-file + rm -f pipelines).

set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
unset GIT_EXTERNAL_DIFF

SCHEMA_VERSION=1
REASONS=()

# Shared by pre-route task/label classification and post-diff inspection. Keep
# path and content vocabulary in one place so a sensitive task cannot start at a
# cheaper profile only to restart after implementation exposes the same surface.
SENSITIVE_PATH_PATTERN='(^|/)(auth|login|session|oauth2?|oidc|openid|sso|saml|mfa|2fa|webauthn|passkeys?|security|secrets?|credentials?|encrypt(ion)?|crypto(graphy)?|tls|ssl|certs?|certificates?|rbac|acl|payments?|billing|checkout|invoices?|credit[-_]?cards?|debit[-_]?cards?|cardholders?|pci([-_]?dss)?|sepa|chargebacks?|bank[-_]?(accounts?|details)|accounting|financial([-_/]?(report(ing)?|reports?))?|xbrl|arelle|taxonom(y|ies)|andmesild|migrations?|database|legal|compliance|privacy|cookies?|dpa|dsar)(/|\.|$)|(^|/)\.env($|\.)|\.(pem|key|p12|pfx|sql)$'
SENSITIVE_CONTENT_PATTERN='(authorization:|bearer[[:space:]]|password|passwd|secret|api[_-]?key|checkout|payment|billing|migration|personal data|gdpr|security|credit[[:space:]_-]*cards?|debit[[:space:]_-]*cards?|card[[:space:]_-]*holders?|chargebacks?|bank[[:space:]_-]*(accounts?|details)|accounting|financial[[:space:]_-]+report(ing|s?)|xbrl|arelle|taxonom(y|ies)|andmesild|(^|[^[:alnum:]_])(auth(entication|ori[sz]ation)?|oauth2?|oidc|openid|login|session|sso|saml|mfa|2fa|webauthn|passkeys?|encrypt(ion|ed|ing)?|decrypt(ion|ed|ing)?|cryptograph(y|ic|ical)?|crypto|tls|ssl|certs?|certificates?|rbac|acl|pci([[:space:]_-]*dss)?|sepa|dpa|dsar|cookies?)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])\.env([^[:alnum:]_]|$)|[[:alnum:]_.-]+\.(pem|key|p12|pfx|sql)([^[:alnum:]_]|$))'

usage() {
  echo "usage: delivery-route.sh classify --mode autonomous|interactive-tweak --task-file FILE [--labels-file FILE]" >&2
  echo "       delivery-route.sh classify-issue --mode autonomous|interactive-tweak --issue N [--repo OWNER/NAME]" >&2
  echo "       delivery-route.sh check-diff --base REF [--cached]" >&2
  echo "       delivery-route.sh schema-version" >&2
  exit 2
}

# Fetch a GitHub issue and classify without requiring the agent to manage temps
# or emit `rm -f` (rejected by Codex CreateProcess policy).
classify_issue() {
  local mode="" issue="" repo="" issue_json task_file labels_file rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) [ "$#" -ge 2 ] || usage; mode="$2"; shift 2 ;;
      --issue) [ "$#" -ge 2 ] || usage; issue="$2"; shift 2 ;;
      --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
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

add_reason() {
  local reason="$1" existing
  for existing in "${REASONS[@]:-}"; do
    [ "$existing" = "$reason" ] && return 0
  done
  REASONS+=("$reason")
}

has() {
  local text="$1" pattern="$2"
  printf '%s\n' "$text" | grep -qiE -- "$pattern"
}

emit_route() {
  local profile="$1" ui_touch="$2" sensitive="$3"
  local product_judgment="$4" legal_judgment="$5" decision="$6"
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
  local file="$1"
  if jq -e . "$file" >/dev/null 2>&1; then
    jq -r '.. | strings' "$file" 2>/dev/null || return 1
  else
    cat "$file"
  fi
}

classify() {
  local mode="" task_file="" labels_file="" task labels="" text
  local ui_touch=false sensitive=false product=false legal=false profile decision rc=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) [ "$#" -ge 2 ] || usage; mode="$2"; shift 2 ;;
      --task-file) [ "$#" -ge 2 ] || usage; task_file="$2"; shift 2 ;;
      --labels-file) [ "$#" -ge 2 ] || usage; labels_file="$2"; shift 2 ;;
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

  if has "$text" '(css|scss|sass|less|tailwind|style|layout|visual|font[[:space:]-]+size|line[[:space:]-]+height|background[[:space:]-]+color|text[[:space:]-]+color|ui([^[:alnum:]_]|$)|ux([^[:alnum:]_]|$)|button|cta|page|screen|label|copy|locali[sz]ation|translation|i18n)'; then
    ui_touch=true
  fi

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
  if has "$text" '(architecture|cross-cutting|concurren|race condition|deadlock|transaction boundary|distributed|idempotency model|breaking change)'; then
    sensitive=true; add_reason sensitive_architecture_concurrency
  fi
  if has "$text" '(root cause|(^|[^[:alnum:]_])rca([^[:alnum:]_]|$)|arbitrat|ambiguous|unclear cause|investigate why|unknown failure)'; then
    sensitive=true; add_reason ambiguous_rca_or_arbitration
  fi
  if has "$text" '(choose|decide|what should|product strategy|prioriti[sz]|redesign|new user flow|conversion strategy|positioning)'; then
    product=true; add_reason product_judgment
  fi
  if has "$text" "$SENSITIVE_PATH_PATTERN" || has "$text" "$SENSITIVE_CONTENT_PATTERN"; then
    sensitive=true; add_reason sensitive_surface_vocabulary
  fi

  # Sensitive and judgment-bearing signals are evaluated before every cheap-route rule.
  if [ "$sensitive" = true ] || [ "$legal" = true ] || [ "$product" = true ]; then
    profile=deep; decision="restart_deep"; rc=20
  elif has "$text" '(^|[[:space:]])(run|execute|invoke|regenerate|generate|format|sync)([[:space:]]|$)' \
       && has "$text" '(script|\.sh([^[:alnum:]_]|$)|generator|formatter|sync command|codegen)' \
       && ! has "$text" '(implement|fix|change|edit|add|remove|refactor)'; then
    profile=mechanical; decision="run_script"; add_reason script_only
  elif [ "$mode" = "interactive-tweak" ]; then
    if has "$text" '(behavior|logic|feature|integration|dependency|test|workflow|migration|refactor|api([^[:alnum:]_]|$)|database|pointer-events|unclickable|disable[^[:space:]]*[[:space:]]+(click|interaction)|hide[[:space:]]|show[[:space:]]|(font[[:space:]-]+size|line[[:space:]-]+height).*(^|[^[:alnum:]_])(0|zero)([^[:alnum:]_]|$)|(margin|padding|gap).*(-[0-9]|[0-9]{3,}[[:space:]]*(px|rem|em))|transparent|negative margin)' ; then
      profile=standard; decision="continue"; add_reason interactive_behavior_excluded
    elif has "$text" '(typo|misspell|copy|text|wording|literal|broken link|url|css|scss|style|spacing|margin|padding|color|font)' ; then
      profile=light; decision="continue"; add_reason interactive_nonbehavioral_tweak
    else
      profile=standard; decision="continue"; add_reason interactive_scope_uncertain
    fi
  else
    if has "$text" '(read-only|read only|inspect|list|summari[sz]e|report|classify|triage)' \
       && ! has "$text" '(edit|change|fix|implement|write|update|add|remove)'; then
      profile=light; decision="continue"; add_reason bounded_read_only
    elif has "$text" '(css|scss|sass|less|tailwind|ui([^[:alnum:]_]|$)|ux([^[:alnum:]_]|$)|user-facing|product copy|copy|button|cta|page|screen|label|locali[sz]ation|translation|i18n|test|dependency|lockfile|workflow|behavior|logic)'; then
      profile=standard; decision="continue"; add_reason autonomous_light_exclusion
    elif has "$text" '(docs?|readme|comment|typo|misspell|literal link|broken link)' ; then
      profile=light; decision="continue"; add_reason autonomous_exact_text
    else
      profile=standard; decision="continue"; add_reason routine_scoped_work
    fi
  fi

  emit_route "$profile" "$ui_touch" "$sensitive" "$product" "$legal" "$decision"
  return "$rc"
}

# Accept only literal text substitutions whose surrounding markup is unchanged.
# Mixed template/code files otherwise fail closed, including attribute and
# expression changes.
ui_markup_diff_is_literal() {
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function tag_name(value) {
      value = trim(value)
      sub(/^<\//, "", value)
      sub(/^</, "", value)
      sub(/[[:space:]>\/].*$/, "", value)
      return value
    }
    function text_block(line_no, before, after, open_line, close_line, name) {
      before = line_no - 1
      while (before > 0 && substr(lines[before], 1, 1) ~ /[+-]/ && lines[before] !~ /^(---|\+\+\+)/) before--
      after = line_no + 1
      while (after <= line_count && substr(lines[after], 1, 1) ~ /[+-]/ && lines[after] !~ /^(---|\+\+\+)/) after++
      if (substr(lines[before], 1, 1) != " " || substr(lines[after], 1, 1) != " ") return 0
      open_line = substr(lines[before], 2)
      close_line = substr(lines[after], 2)
      if (open_line !~ /^[[:space:]]*<[[:alpha:]_][^>]*>[[:space:]]*$/ || open_line ~ /\/>[[:space:]]*$/) return 0
      if (close_line !~ /^[[:space:]]*<\/[[:alpha:]_][^>]*>[[:space:]]*$/) return 0
      name = tag_name(open_line)
      if (tolower(name) ~ /^(script|style)$/ || name != tag_name(close_line)) return 0
      return 1
    }
    function plain_literal(value, cleaned) {
      cleaned = trim(value)
      if (cleaned == "" || cleaned ~ /[<>{}\[\]=;`$\\\/"\047()]/) return 0
      if (cleaned !~ /^[[:alnum:]][[:alnum:][:space:].,!?:&%+-]*$/) return 0
      if (cleaned !~ /[[:space:].,!?:&%+-]/) return 0
      if (tolower(cleaned) ~ /^(if|else|return|throw|const|let|var|import|export|await|function|class|new)([[:space:]]|$)/) return 0
      return 1
    }
    function inline_skeleton(value, skeleton, lower) {
      lower = tolower(value)
      if (value ~ /[{}]/ || lower ~ /<(script|style)([[:space:]>])/) return ""
      if (value !~ /^[[:space:]]*<[^!][^>]*>.*<\/[^>]+>[[:space:]]*$/) return ""
      if (value ~ /<!--|<!doctype|<\?/) return ""
      skeleton = value
      while (match(skeleton, />[^<]+</)) {
        skeleton = substr(skeleton, 1, RSTART) "<" substr(skeleton, RSTART + RLENGTH)
      }
      return skeleton
    }
    { lines[++line_count] = $0 }
    END {
      for (i = 1; i <= line_count; i++) {
        prefix = substr(lines[i], 1, 1)
        if (prefix !~ /[+-]/ || lines[i] ~ /^(---|\+\+\+)/) continue
        changed++
        value = substr(lines[i], 2)
        skeleton = inline_skeleton(value)
        if (skeleton != "") {
          if (prefix == "-") removed[skeleton]++
          else added[skeleton]++
        } else if (!(plain_literal(value) && text_block(i))) {
          invalid = 1
        }
      }
      for (key in removed) if (removed[key] != added[key]) invalid = 1
      for (key in added) if (added[key] != removed[key]) invalid = 1
      exit (!changed || invalid)
    }
  '
}

ui_translation_diff_is_literal() {
  awk '
    /^[+-]/ && !/^(---|\+\+\+)/ {
      changed++
      value = substr($0, 2)
      if (value !~ /^[[:space:]]*msgstr(\[[0-9]+\])?[[:space:]]+".*"[[:space:]]*$/) invalid = 1
      key = value
      sub(/[[:space:]]+".*$/, "", key)
      if (substr($0, 1, 1) == "-") removed[key]++
      else added[key]++
    }
    END {
      for (key in removed) if (removed[key] != added[key]) invalid = 1
      for (key in added) if (added[key] != removed[key]) invalid = 1
      exit (!changed || invalid)
    }
  '
}

# Accept only value substitutions for a narrow set of presentational properties.
# Selectors, property names, interaction, visibility, positioning, animation, and
# content-affecting declarations fail closed.
ui_stylesheet_diff_is_nonbehavioral() {
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function length_px(value, number) {
      if (value == "0") return 0
      if (value !~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)(px|rem|em)$/) return -1
      number = value + 0
      if (value ~ /(rem|em)$/) number *= 16
      return number
    }
    function bounded_lengths(value, min, max, n, parts, i, number) {
      value = tolower(trim(value))
      n = split(value, parts, /[[:space:]]+/)
      if (n < 1 || n > 4) return 0
      for (i = 1; i <= n; i++) {
        number = length_px(parts[i])
        if (number < 0) return 0
        if (number < min || number > max) return 0
      }
      return 1
    }
    function safe_value(prop, value, lower, number) {
      lower = tolower(trim(value))
      if (lower ~ /var[[:space:]]*\(|calc[[:space:]]*\(|clamp[[:space:]]*\(|url[[:space:]]*\(|expression[[:space:]]*\(|javascript:|!important/) return 0
      if (prop == "color" || prop == "background-color" || prop ~ /^border-.*-color$/ || prop == "border-color") {
        if (lower ~ /transparent|currentcolor|inherit|initial|unset|revert|rgba[[:space:]]*\(|hsla[[:space:]]*\(/) return 0
        return (lower ~ /^#[0-9a-f][0-9a-f][0-9a-f]([0-9a-f][0-9a-f][0-9a-f])?$/ || lower ~ /^[a-z]+$/ || lower ~ /^(rgb|hsl)[[:space:]]*\([^)]*\)$/)
      }
      if (prop == "font-size") {
        if (lower ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)px$/) { number = lower + 0; return number >= 8 && number <= 72 }
        if (lower ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)(rem|em)$/) { number = lower + 0; return number >= 0.5 && number <= 4 }
        if (lower ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)%$/) { number = lower + 0; return number >= 50 && number <= 300 }
        return 0
      }
      if (prop == "line-height") {
        if (lower == "normal") return 1
        if (lower ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/) { number = lower + 0; return number >= 0.8 && number <= 3 }
        if (lower ~ /[[:space:]]/) return 0
        return bounded_lengths(lower, 8, 80)
      }
      if (prop ~ /^(margin|padding|gap|row-gap|column-gap)/ || prop == "border-radius") return bounded_lengths(lower, 0, 64)
      if (prop ~ /^border-.*-width$/ || prop == "border-width") return bounded_lengths(lower, 0, 8)
      if (prop ~ /^border-.*-style$/ || prop == "border-style") return lower ~ /^(none|solid|dashed|dotted|double)$/
      if (prop == "font-weight") return lower ~ /^(normal|bold|[1-9]00)$/
      if (prop == "font-style") return lower ~ /^(normal|italic|oblique)$/
      if (prop == "text-align") return lower ~ /^(start|end|left|right|center|justify)$/
      if (prop == "letter-spacing") {
        if (lower == "normal") return 1
        if (lower ~ /^-?([0-9]+([.][0-9]+)?|[.][0-9]+)px$/) { number = lower + 0; return number >= -2 && number <= 8 }
        if (lower ~ /^-?([0-9]+([.][0-9]+)?|[.][0-9]+)(rem|em)$/) { number = lower + 0; return number >= -0.1 && number <= 0.5 }
        return 0
      }
      if (prop == "font-family") return lower !~ /^(none|initial|unset)$/
      return 0
    }
    function normalize(value, selector, suffix, brace, count, n, parts, i, pair, colon, prop, val, result) {
      value = trim(value)
      if (value == "" || value ~ /\/\*|\*\/|^@/) return ""
      selector = ""; suffix = ""
      brace = index(value, "{")
      if (brace > 0) {
        selector = trim(substr(value, 1, brace))
        value = trim(substr(value, brace + 1))
      }
      if (value ~ /}[[:space:]]*$/) {
        sub(/}[[:space:]]*$/, "", value)
        value = trim(value); suffix = "}"
      }
      if (value ~ /[{}]/) return ""
      n = split(value, parts, ";")
      result = selector; count = 0
      for (i = 1; i <= n; i++) {
        pair = trim(parts[i])
        if (pair == "") continue
        colon = index(pair, ":")
        if (colon == 0) return ""
        prop = tolower(trim(substr(pair, 1, colon - 1)))
        val = trim(substr(pair, colon + 1))
        if (prop !~ /^(color|background-color|font-family|font-size|font-style|font-weight|line-height|letter-spacing|text-align|margin(-(top|right|bottom|left|inline|inline-start|inline-end|block|block-start|block-end))?|padding(-(top|right|bottom|left|inline|inline-start|inline-end|block|block-start|block-end))?|gap|row-gap|column-gap|border-(top|right|bottom|left)-(color|style|width)|border-(color|style|width|radius))$/) return ""
        if (val == "" || !safe_value(prop, val)) return ""
        result = result prop ":<value>;"; count++
      }
      if (count == 0) return ""
      return result suffix
    }
    /^[+-]/ && !/^(---|\+\+\+)/ {
      changed++
      skeleton = normalize(substr($0, 2))
      if (skeleton == "") invalid = 1
      else if (substr($0, 1, 1) == "-") removed[skeleton]++
      else added[skeleton]++
    }
    END {
      for (key in removed) if (removed[key] != added[key]) invalid = 1
      for (key in added) if (added[key] != removed[key]) invalid = 1
      exit (!changed || invalid)
    }
  '
}

check_diff() {
  local base="" cached=0 repo_root tmp names patch numstat nfiles nlines untracked=0 file lines
  local ui_touch=false sensitive=false product=false legal=false profile decision rc=0
  local ui_script file_patch ui_allowlisted
  local diff_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ "$#" -ge 2 ] || usage; base="$2"; shift 2 ;;
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
  trap 'rm -rf "$tmp"' RETURN
  [ "$cached" -eq 0 ] || diff_args+=(--cached)
  if ! git -c core.fsmonitor=false -C "$repo_root" diff --no-ext-diff --no-textconv "${diff_args[@]}" "$base" --name-only > "$tmp/names" \
    || ! git -c core.fsmonitor=false -C "$repo_root" diff --no-ext-diff --no-textconv "${diff_args[@]}" "$base" --numstat > "$tmp/numstat" \
    || ! git -c core.fsmonitor=false -C "$repo_root" diff --no-ext-diff --no-textconv "${diff_args[@]}" "$base" -- > "$tmp/patch"; then
    echo "delivery-route: git diff failed for base $base" >&2
    exit 2
  fi
  if [ "$cached" -eq 0 ]; then
    git -c core.fsmonitor=false -C "$repo_root" ls-files --others --exclude-standard > "$tmp/untracked"
    if [ -s "$tmp/untracked" ]; then
      untracked=1
      while IFS= read -r file; do
        [ -n "$file" ] || continue
        printf '%s\n' "$file" >> "$tmp/names"
        lines=0
        if [ -f "$repo_root/$file" ]; then
          lines=$(wc -l < "$repo_root/$file" | tr -d ' ')
          printf '%s\t0\t%s\n' "$lines" "$file" >> "$tmp/numstat"
          printf 'diff --git a/%s b/%s\n--- /dev/null\n+++ b/%s\n' "$file" "$file" "$file" >> "$tmp/patch"
          if grep -Iq . "$repo_root/$file" 2>/dev/null; then
            sed 's/^/+/' "$repo_root/$file" >> "$tmp/patch"
          else
            printf '+[binary untracked file]\n' >> "$tmp/patch"
          fi
        fi
      done < "$tmp/untracked"
    fi
  fi
  names=$(cat "$tmp/names")
  patch=$(cat "$tmp/patch")
  numstat=$(cat "$tmp/numstat")
  nfiles=$(printf '%s\n' "$names" | grep -c . || true)
  nlines=$(printf '%s\n' "$numstat" | awk '{ if ($1 ~ /^[0-9]+$/) a += $1; if ($2 ~ /^[0-9]+$/) a += $2 } END { print a+0 }')

  if [ "$nfiles" -eq 0 ]; then
    add_reason empty_diff
    emit_route mechanical false false false false continue
    return 0
  fi

  ui_script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui-touch.sh"
  if [ -x "$ui_script" ] && [ "$(printf '%s\n' "$names" | "$ui_script" --files 2>/dev/null || echo ui)" != "no-ui" ]; then
    ui_touch=true
  fi

  if printf '%s\n%s\n' "$names" "$patch" | grep -qiE "$SENSITIVE_PATH_PATTERN" \
     || printf '%s\n' "$patch" | grep -qiE "$SENSITIVE_CONTENT_PATTERN"; then
    sensitive=true; add_reason diff_sensitive_surface
  fi
  if printf '%s\n' "$names" | grep -qiE '(^|/)(legal|compliance|privacy)(/|\.|$)' \
     || printf '%s\n' "$patch" | grep -qiE '(legal|gdpr|compliance|consent|terms[[:space:]]*(&|and|of)|cookie (notice|banner|consent|policy)|eprivacy|(^|[^[:alnum:]_])(tax|vat|dpa|dsar)([^[:alnum:]_]|$))'; then
    legal=true; add_reason diff_legal_judgment
  fi
  if printf '%s\n' "$patch" | grep -qiE '(pricing|price change|product strategy|choose between|redesign)'; then
    product=true; add_reason diff_product_judgment
  fi

  if [ "$sensitive" = true ] || [ "$legal" = true ] || [ "$product" = true ]; then
    profile=deep; decision="restart_deep"; rc=20
  elif [ "$untracked" -eq 1 ]; then
    profile=deep; decision="restart_deep"; rc=20; add_reason diff_untracked_file
  elif [ "$nfiles" -gt 3 ] || [ "$nlines" -gt 15 ]; then
    profile=deep; decision="restart_deep"; rc=20; add_reason diff_containment_exceeded
  elif printf '%s\n' "$names" | grep -qiE '(^|/)(tests?|__tests__|spec|\.github/workflows|workflows?)(/|\.|$)|(^|/)(package(-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|requirements[^/]*\.txt|poetry\.lock|cargo\.lock|go\.(mod|sum))$'; then
    profile=deep; decision="restart_deep"; rc=20; add_reason diff_tests_dependencies_workflows
  else
    ui_allowlisted=true
    if [ "$ui_touch" = true ]; then
      while IFS= read -r file; do
        [ -n "$file" ] || continue
        file_patch="$tmp/file.patch"
        git -C "$repo_root" diff "${diff_args[@]}" "$base" -- "$file" > "$file_patch" || {
          echo "delivery-route: could not inspect UI diff" >&2
          exit 2
        }
        case "$file" in
          *.css|*.scss|*.sass|*.less)
            ui_stylesheet_diff_is_nonbehavioral < "$file_patch" || ui_allowlisted=false
            ;;
          *.tsx|*.jsx|*.vue|*.svelte|*.htm|*.html|*.mdx)
            ui_markup_diff_is_literal < "$file_patch" || ui_allowlisted=false
            ;;
          *.po|*.pot)
            ui_translation_diff_is_literal < "$file_patch" || ui_allowlisted=false
            ;;
          *) ui_allowlisted=false ;;
        esac
      done < "$tmp/names"
    fi
    if [ "$ui_touch" = true ] && [ "$ui_allowlisted" != true ]; then
      profile=deep; decision="restart_deep"; rc=20; add_reason diff_behavioral_ui_code
    elif [ "$ui_touch" = true ]; then
      profile=light; decision="continue"; add_reason diff_bounded_ui_text_or_css
    elif printf '%s\n' "$names" | grep -qEv '(^|/)(docs?/.*|README([^/]*)?|CHANGELOG([^/]*)?|[^/]+\.(md|txt|rst|adoc))$'; then
      profile=deep; decision="restart_deep"; rc=20; add_reason diff_behavioral_code
    else
      profile=light; decision="continue"; add_reason diff_bounded_text
    fi
  fi

  emit_route "$profile" "$ui_touch" "$sensitive" "$product" "$legal" "$decision"
  return "$rc"
}

case "${1:-}" in
  classify) shift; classify "$@" ;;
  classify-issue) shift; classify_issue "$@" ;;
  check-diff) shift; check_diff "$@" ;;
  schema-version) [ "$#" -eq 1 ] || usage; jq -cn --argjson schema_version "$SCHEMA_VERSION" '{schema_version:$schema_version}' ;;
  *) usage ;;
esac
