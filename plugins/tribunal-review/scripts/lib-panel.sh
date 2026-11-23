#!/usr/bin/env bash
# Tribunal panel selection, risk tiers, backup legs, and provider availability probes.
# Sourced by scripts/lib.sh.

tribunal_deepseek_model() {
  printf '%s\n' "${TRIBUNAL_DEEPSEEK_MODEL:-deepseek-v4-pro}"
}

# Per-environment APPROVE floor (issue #519). Unset/empty ⇒ 2; otherwise an
# integer in 2..7 (seven legs exist, so a floor of 8 could never pass).
# A 1-leg APPROVE is never permitted.
tribunal_min_ok_legs() {
  local raw="${TRIBUNAL_MIN_OK_LEGS:-}"
  if [ -z "$raw" ]; then
    printf '%s\n' 2
    return 0
  fi
  case "$raw" in
    1)
      printf 'invalid TRIBUNAL_MIN_OK_LEGS value: 1 (a one-leg APPROVE is not allowed; want integer 2..7)\n' >&2
      return 1
      ;;
    [2-7]) printf '%s\n' "$raw"; return 0 ;;
  esac
  printf 'invalid TRIBUNAL_MIN_OK_LEGS value: %s (want integer 2..7)\n' "$raw" >&2
  return 1
}

# Selected panel size (environment only). Unset/empty ⇒ 3; otherwise 2..7
# (seven legs exist, so a panel of 8 could never seat).
tribunal_panel_size() {
  local raw="${TRIBUNAL_PANEL_SIZE:-}"
  if [ -z "$raw" ]; then
    printf '%s\n' 3
    return 0
  fi
  case "$raw" in
    [2-7]) printf '%s\n' "$raw"; return 0 ;;
  esac
  printf 'invalid TRIBUNAL_PANEL_SIZE value: %s (want integer 2..7)\n' "$raw" >&2
  return 1
}

# PR risk tier (environment only, never from the reviewed repository): T1..T4, or
# empty when unset so standalone legs keep their CLI default effort and panel
# selection uses T2.
tribunal_risk_tier() {
  case "${TRIBUNAL_RISK:-}" in
    ''|T1|T2|T3|T4) printf '%s\n' "${TRIBUNAL_RISK:-}"; return 0 ;;
  esac
  printf 'invalid TRIBUNAL_RISK value: %s (want T1, T2, T3, or T4)\n' "$TRIBUNAL_RISK" >&2
  return 1
}

# Standalone reviewer effort for the risk tier; empty when TRIBUNAL_RISK is unset
# or when tribunal_select_panel already exported per-row efforts. Only Codex goes
# to xhigh, and only at T4: maximum-effort reviewers over-report speculative findings.
tribunal_risk_effort() {
  local tier
  tier="$(tribunal_risk_tier)" || return 1
  [ "${TRIBUNAL_PANEL_SELECTED:-0}" = 1 ] && return 0
  case "$tier" in
    '') ;;
    T1) printf 'low\n' ;;
    T2) printf 'medium\n' ;;
    T3) if [ "${1:-}" = grok ]; then printf 'medium\n'; else printf 'high\n'; fi ;;
    T4) if [ "${1:-}" = codex ]; then printf 'xhigh\n'; else printf 'high\n'; fi ;;
  esac
}

# Backup leg order (environment override). When TRIBUNAL_BACKUP_LEGS is unset, uses
# the selection's remaining available rows (or deepseek when called standalone);
# empty or "off" disables backups. Prints one provider per line; duplicates are rejected.
tribunal_backup_legs() {
  if [ -z "${TRIBUNAL_BACKUP_LEGS+x}" ]; then
    if [ "${TRIBUNAL_PANEL_SELECTED:-0}" = 1 ]; then
      [ -z "${TRIBUNAL_SELECTED_BACKUPS:-}" ] || printf '%s\n' "$TRIBUNAL_SELECTED_BACKUPS"
    else
      printf '%s\n' deepseek
    fi
    return 0
  fi
  local raw="$TRIBUNAL_BACKUP_LEGS" leg seen=" "
  local -a legs=()
  [ -z "$raw" ] || [ "$raw" = off ] && return 0
  case "$raw" in
    *[[:space:]]*) printf 'invalid TRIBUNAL_BACKUP_LEGS value: whitespace is not allowed (comma-separated list)\n' >&2; return 1 ;;
    ,*|*,|*,,*) printf 'invalid TRIBUNAL_BACKUP_LEGS value: %s (want comma-separated providers or off)\n' "$raw" >&2; return 1 ;;
  esac
  IFS=, read -r -a legs <<< "$raw"
  for leg in ${legs[@]+"${legs[@]}"}; do
    case "$leg" in
      codex|gemini|deepseek|qwen|grok|muse|claude) ;;
      *) printf 'invalid TRIBUNAL_BACKUP_LEGS entry: %s (want codex, gemini, deepseek, qwen, grok, muse, claude, or off)\n' "$leg" >&2; return 1 ;;
    esac
    case "$seen" in *" $leg "*) printf 'duplicate TRIBUNAL_BACKUP_LEGS entry: %s\n' "$leg" >&2; return 1 ;; esac
    seen="$seen$leg "
    printf '%s\n' "$leg"
  done
}

tribunal_deepseek_available() {
  command -v dsh >/dev/null 2>&1 || { printf 'dsh CLI not on PATH\n'; return 1; }
  if [ -n "${DEEPSEEK_API_KEY:+present}" ] \
    || awk '
      /^refs:[[:space:]]*$/ { refs=1; next }
      /^[^[:space:]#]/ { refs=0 }
      refs && /^[[:space:]]+DEEPSEEK_API_KEY:[[:space:]]*/ {
        sub(/^[[:space:]]+DEEPSEEK_API_KEY:[[:space:]]*/, "")
        sub(/[[:space:]]+#.*$/, "")
        sub(/[[:space:]]+$/, "")
        if ($0 != "" && $0 != "\"\"" && $0 != "\047\047" && $0 != "null" && $0 != "~" && $0 !~ /^#/) found=1
      }
      END { exit !found }
    ' "${DSH_HOME:-${HOME}/.dsh}/.credentials.yaml" 2>/dev/null \
    || grep -q '^DEEPSEEK_API_KEY=.' "${DSH_HOME:-${HOME}/.dsh}/.env" 2>/dev/null; then
    return 0
  fi
  printf 'MISSING_CREDENTIAL: DEEPSEEK_API_KEY is not set and no dsh credential key entry exists\n'
  return 1
}

# A zero-byte OAuth token is not a sign-in: real agy prints
# "Authentication required" and waits for login. Selection and execution share
# this check so an empty token never takes a reviewer seat and never shadows
# a configured GEMINI_API_KEY.
tribunal_gemini_token_usable() {
  local token="${HOME:-}/.gemini/antigravity-cli/antigravity-oauth-token"
  [ -n "${HOME:-}" ] && [ ! -L "$token" ] && [ -f "$token" ] && [ -s "$token" ]
}

tribunal_gemini_available() {
  if tribunal_gemini_token_usable; then
    return 0
  fi
  if [ -n "${GEMINI_API_KEY:+present}" ]; then
    return 0
  fi
  printf 'agy is not signed in and GEMINI_API_KEY is unset\n'
  return 1
}

tribunal_backup_installed() {
  case "$1" in
    codex) command -v codex >/dev/null 2>&1 ;;
    claude) command -v claude >/dev/null 2>&1 && tribunal_claude_authenticated ;;
    grok) command -v grok >/dev/null 2>&1 && tribunal_grok_authenticated ;;
    muse) command -v muse >/dev/null 2>&1 ;;
    deepseek) tribunal_deepseek_available >/dev/null ;;
    gemini) command -v agy >/dev/null 2>&1 && tribunal_gemini_available >/dev/null ;;
    qwen) command -v qwen >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Select the active review panel and backup order from review-panel.tsv for the
# effective risk tier (default T2). Exports TRIBUNAL_<P>=on|off for all 7 providers
# and TRIBUNAL_<P>_MODEL / TRIBUNAL_<P>_EFFORT for selected and backup rows unless
# already set by the operator. Sets TRIBUNAL_SELECTED_PANEL_SIZE,
# TRIBUNAL_SELECTED_PANEL_JSON, TRIBUNAL_SELECTED_BACKUPS, and TRIBUNAL_EXPLICIT_OFF.
tribunal_select_panel() {
  local tier effective_tier panel_size panel_file explicit_backups=0 tab=$'\t'
  local p upper toggle_var toggle_val model_var effort_var eff_model eff_effort
  local line lineno=0 row_tier row_provider row_model row_effort
  local seen_rows=" " forced_set=" " explicit_off=" " avail_set=" " selected_set=" "
  local -a row_providers=() selected_list=() backup_list=() explicit_backup_list=()
  local -A row_models=() row_efforts=()

  tier="$(tribunal_risk_tier)" || return 1
  effective_tier="${tier:-T2}"
  panel_size="$(tribunal_panel_size)" || return 1
  panel_file="${TRIBUNAL_REVIEW_PANEL:-$TRIBUNAL_LIB_DIR/review-panel.tsv}"
  if [ ! -f "$panel_file" ] || [ ! -r "$panel_file" ]; then
    printf 'invalid TRIBUNAL_REVIEW_PANEL: %s is missing or unreadable\n' "$panel_file" >&2
    return 1
  fi

  for p in codex gemini deepseek qwen grok muse claude; do
    upper="${p^^}"
    toggle_var="TRIBUNAL_${upper}"
    toggle_val="${!toggle_var:-}"
    case "$toggle_val" in
      '') ;;
      auto)
        if [ "$p" != gemini ]; then
          printf 'invalid %s value: auto (only TRIBUNAL_GEMINI accepts auto; want on or off)\n' "$toggle_var" >&2
          return 1
        fi
        ;;
      on) forced_set="${forced_set}${p} " ;;
      off) explicit_off="${explicit_off}${p} " ;;
      *)
        printf 'invalid %s value: %s (want on, off, or auto)\n' "$toggle_var" "$toggle_val" >&2
        return 1
        ;;
    esac
  done

  if [ -n "${TRIBUNAL_BACKUP_LEGS+x}" ]; then
    explicit_backups=1
    local backup_out
    backup_out="$(tribunal_backup_legs)" || return 1
    if [ -n "$backup_out" ]; then
      mapfile -t explicit_backup_list <<< "$backup_out"
    fi
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
      continue
    fi
    if [[ ! "$line" =~ ^([^$tab]+)$tab([^$tab]+)$tab([^$tab]+)$tab([^$tab]+)$ ]]; then
      printf 'invalid review panel row at %s:%d (want 4 tab-separated columns)\n' "$panel_file" "$lineno" >&2
      return 1
    fi
    row_tier="${BASH_REMATCH[1]}"
    row_provider="${BASH_REMATCH[2]}"
    row_model="${BASH_REMATCH[3]}"
    row_effort="${BASH_REMATCH[4]}"
    case "$row_tier" in
      T1|T2|T3|T4) ;;
      *)
        printf 'invalid review panel row at %s:%d (bad tier: %s)\n' "$panel_file" "$lineno" "$row_tier" >&2
        return 1
        ;;
    esac
    case "$row_provider" in
      codex|gemini|deepseek|qwen|grok|muse|claude) ;;
      *)
        printf 'invalid review panel row at %s:%d (bad provider: %s)\n' "$panel_file" "$lineno" "$row_provider" >&2
        return 1
        ;;
    esac
    if [[ ! "$row_model" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      printf 'invalid review panel row at %s:%d (bad model: %s)\n' "$panel_file" "$lineno" "$row_model" >&2
      return 1
    fi
    if [ "$row_effort" != "-" ] && [[ ! "$row_effort" =~ ^[a-z]+$ ]]; then
      printf 'invalid review panel row at %s:%d (bad effort: %s)\n' "$panel_file" "$lineno" "$row_effort" >&2
      return 1
    fi
    [ "$row_tier" = "$effective_tier" ] || continue
    case "$seen_rows" in *" $row_provider "*) continue ;; esac
    seen_rows="${seen_rows}${row_provider} "
    row_providers+=("$row_provider")
    row_models["$row_provider"]="$row_model"
    row_efforts["$row_provider"]="$row_effort"
  done < "$panel_file"

  for p in ${row_providers[@]+"${row_providers[@]}"}; do
    case "$explicit_off" in *" $p "*) continue ;; esac
    if tribunal_backup_installed "$p"; then
      avail_set="${avail_set}${p} "
    fi
  done

  local forced_count=0 remaining_seats=0
  for p in codex gemini deepseek qwen grok muse claude; do
    case "$forced_set" in *" $p "*) forced_count=$((forced_count + 1)) ;; esac
  done
  if [ "$panel_size" -gt "$forced_count" ]; then
    remaining_seats=$((panel_size - forced_count))
  fi

  for p in ${row_providers[@]+"${row_providers[@]}"}; do
    case "$forced_set" in
      *" $p "*)
        selected_set="${selected_set}${p} "
        selected_list+=("$p")
        continue
        ;;
    esac
    case "$avail_set" in
      *" $p "*)
        if [ "$remaining_seats" -gt 0 ]; then
          selected_set="${selected_set}${p} "
          selected_list+=("$p")
          remaining_seats=$((remaining_seats - 1))
        else
          backup_list+=("$p")
        fi
        ;;
    esac
  done

  for p in codex gemini deepseek qwen grok muse claude; do
    case "$forced_set" in
      *" $p "*)
        case "$selected_set" in
          *" $p "*) ;;
          *)
            selected_set="${selected_set}${p} "
            selected_list+=("$p")
            ;;
        esac
        ;;
    esac
  done

  if [ "$explicit_backups" -eq 1 ]; then
    backup_list=(${explicit_backup_list[@]+"${explicit_backup_list[@]}"})
  fi
  local active_or_backup=" $selected_set"
  for p in ${backup_list[@]+"${backup_list[@]}"}; do
    active_or_backup="${active_or_backup}${p} "
  done

  for p in codex gemini deepseek qwen grok muse claude; do
    upper="${p^^}"
    case "$selected_set" in
      *" $p "*) export "TRIBUNAL_${upper}=on" ;;
      *) export "TRIBUNAL_${upper}=off" ;;
    esac
    case "$active_or_backup" in
      *" $p "*)
        model_var="TRIBUNAL_${upper}_MODEL"
        effort_var="TRIBUNAL_${upper}_EFFORT"
        row_model="${row_models[$p]:-}"
        row_effort="${row_efforts[$p]:-}"
        if [ -n "${!model_var:-}" ]; then
          export "$model_var=${!model_var}"
        elif [ -n "$row_model" ]; then
          export "$model_var=$row_model"
        fi
        if [ -n "${!effort_var+x}" ]; then
          if [ -n "${!effort_var}" ] && [ "${!effort_var}" != "-" ]; then
            export "$effort_var=${!effort_var}"
          else
            unset "$effort_var"
          fi
        elif [ -n "$row_effort" ] && [ "$row_effort" != "-" ]; then
          export "$effort_var=$row_effort"
        fi
        ;;
    esac
  done

  local panel_json="[]"
  for p in ${selected_list[@]+"${selected_list[@]}"}; do
    upper="${p^^}"
    model_var="TRIBUNAL_${upper}_MODEL"
    effort_var="TRIBUNAL_${upper}_EFFORT"
    eff_model="${!model_var:-${row_models[$p]:-default}}"
    eff_effort="${!effort_var:-}"
    [ "$eff_effort" != "-" ] || eff_effort=""
    panel_json="$(printf '%s' "$panel_json" | jq -c \
      --arg provider "$p" --arg model "$eff_model" --arg effort "$eff_effort" \
      '. + [{provider:$provider,model:$model,effort:(if $effort == "" then null else $effort end)}]')"
  done

  TRIBUNAL_EXPLICIT_OFF="$explicit_off"
  TRIBUNAL_SELECTED_PANEL_SIZE="$panel_size"
  TRIBUNAL_SELECTED_PANEL_JSON="$panel_json"
  if [ "${#backup_list[@]}" -gt 0 ]; then
    TRIBUNAL_SELECTED_BACKUPS="$(printf '%s\n' "${backup_list[@]}")"
  else
    TRIBUNAL_SELECTED_BACKUPS=""
  fi
  export TRIBUNAL_PANEL_SELECTED=1
}
