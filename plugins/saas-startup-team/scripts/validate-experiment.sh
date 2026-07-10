#!/usr/bin/env bash
#
# validate-experiment.sh - mechanical machinery for /validate-experiment.
#
# Deterministic, side-effect-scoped helpers for the demand-validation flow: plan
# validation, fake-door page render, ad-smoke spend gate, and the measured-results
# writer. No network access. The command orchestrates deploy/ad delegation; this
# script only does the parts that must be exact and test-covered.
#
# Honest-evidence rule (stated once, enforced here): results carry MEASURED values
# only. An absent metric is emitted as null — never estimated, never inferred.
#
# Subcommands:
#   validate <plan.json>
#   render   <plan.json> --out-dir DIR [--template FILE]
#   ad-smoke <plan.json> --landing-url URL [--root DIR]
#   results  <plan.json> --signals FILE --out FILE

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2

die() { echo "validate-experiment: $*" >&2; exit 2; }

_need_val() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

# Required plan fields (signup target is validated separately: endpoint OR fallback).
REQUIRED_FIELDS=(idea_id value_prop audience cta cap_eur duration_days)

# HTML-escape stdin's single argument for safe interpolation into the template.
html_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
  printf '%s' "$s"
}

load_plan() {  # $1=plan.json → validates required fields, exits non-zero on the first gap
  local plan="$1"
  [ -f "$plan" ] || die "plan file not found: $plan"
  jq empty "$plan" 2>/dev/null || die "plan file is not valid JSON: $plan"
  local f v
  for f in "${REQUIRED_FIELDS[@]}"; do
    v=$(jq -r --arg k "$f" '.[$k] // empty' "$plan" 2>/dev/null)
    [ -n "$v" ] || die "plan missing required field: $f"
  done
  # cap_eur / duration_days must be non-negative numbers.
  jq -e '(.cap_eur | type == "number") and .cap_eur >= 0' "$plan" >/dev/null 2>&1 \
    || die "cap_eur must be a number >= 0"
  jq -e '(.duration_days | type == "number") and .duration_days >= 1' "$plan" >/dev/null 2>&1 \
    || die "duration_days must be a number >= 1"
  # Signup target: endpoint OR a named static-host fallback. Never invent one.
  local endpoint fallback target
  endpoint=$(jq -r '.signup_endpoint // empty' "$plan" 2>/dev/null)
  fallback=$(jq -r '.signup_fallback // empty' "$plan" 2>/dev/null)
  [ -n "$endpoint" ] || [ -n "$fallback" ] \
    || die "signup_endpoint is null and no signup_fallback named — the plan must name one"
  # Fail closed on the form target: an https:// URL or a relative path only. A scheme
  # other than https (javascript:, data:, http:) on a public page is rejected.
  target="${endpoint:-$fallback}"
  if [[ "$target" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*: ]] && [[ ! "$target" =~ ^https:// ]]; then
    die "signup target must be an https:// URL or a relative path (rejected: $target)"
  fi
}

cmd_validate() {
  [ $# -ge 1 ] || die "validate needs a plan file"
  load_plan "$1"
  echo "validate-experiment: plan OK ($(jq -r '.idea_id' "$1"))"
}

cmd_render() {
  local plan="" outdir="" template=""
  [ $# -ge 1 ] || die "render needs a plan file"
  plan="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --out-dir)  _need_val "$#" "$1"; outdir="$2"; shift 2 ;;
      --template) _need_val "$#" "$1"; template="$2"; shift 2 ;;
      *) die "render: unknown arg: $1" ;;
    esac
  done
  [ -n "$outdir" ] || die "render needs --out-dir"
  load_plan "$plan"
  [ -n "$template" ] || template="$SCRIPT_DIR/../templates/fake-door/index.html"
  [ -f "$template" ] || die "fake-door template not found: $template"

  local idea value_prop cta audience endpoint fallback consent action
  idea=$(jq -r '.idea_id' "$plan")
  value_prop=$(html_escape "$(jq -r '.value_prop' "$plan")")
  cta=$(html_escape "$(jq -r '.cta' "$plan")")
  audience=$(html_escape "$(jq -r '.audience' "$plan")")
  endpoint=$(jq -r '.signup_endpoint // empty' "$plan")
  fallback=$(jq -r '.signup_fallback // empty' "$plan")
  action="${endpoint:-$fallback}"
  # Default consent wording is a placeholder the plan overrides. Honest to visitors:
  # waitlist collects an email with consent; no payment is ever taken here.
  consent=$(jq -r '.consent // "Join the waitlist to hear about early access. We only email you about this; no payment is taken. See our privacy notice before submitting."' "$plan")
  consent=$(html_escape "$consent")

  local tpl
  tpl="$(cat "$template")"
  tpl="${tpl//\{\{IDEA_ID\}\}/$(html_escape "$idea")}"
  tpl="${tpl//\{\{VALUE_PROP\}\}/$value_prop}"
  tpl="${tpl//\{\{CTA\}\}/$cta}"
  tpl="${tpl//\{\{AUDIENCE\}\}/$audience}"
  tpl="${tpl//\{\{SIGNUP_ENDPOINT\}\}/$(html_escape "$action")}"
  tpl="${tpl//\{\{CONSENT\}\}/$consent}"

  mkdir -p "$outdir"
  printf '%s\n' "$tpl" > "$outdir/index.html"
  echo "validate-experiment: rendered fake-door → $outdir/index.html"
}

# Resolve an active spend envelope, fail closed. Prints remaining EUR (integer) on
# success, exits non-zero with an explanatory message otherwise.
cmd_ad_smoke() {
  local plan="" landing="" root="."
  [ $# -ge 1 ] || die "ad-smoke needs a plan file"
  plan="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --landing-url) _need_val "$#" "$1"; landing="$2"; shift 2 ;;
      --root)        _need_val "$#" "$1"; root="$2"; shift 2 ;;
      *) die "ad-smoke: unknown arg: $1" ;;
    esac
  done
  [ -n "$landing" ] || die "ad-smoke needs --landing-url (the live experiment URL)"
  load_plan "$plan"
  local cap; cap=$(jq -r '.cap_eur' "$plan")

  local env_file="$root/docs/growth/envelope.json"
  [ -f "$env_file" ] || die "ad-smoke refused: no spend envelope ($env_file) — paid smoke-test stays owner-gated"
  # Same fail-closed predicate as /growth: positive monthly cap, buyer-intent-only,
  # a listed channel, and a valid future expiry. "ads" must be an authorized channel.
  jq -e '
    (.monthly_cap_eur // 0) > 0 and (.buyer_intent_only == true)
    and ((.channels // []) | index("ads") != null) and (.expires_at != null)
  ' "$env_file" >/dev/null 2>&1 \
    || die "ad-smoke refused: envelope invalid (needs positive monthly_cap_eur, buyer_intent_only, \"ads\" channel, expires_at)"
  local exp exp_epoch now_epoch
  exp=$(jq -r '.expires_at' "$env_file")
  exp_epoch=$(date -d "$exp" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  [ "$now_epoch" -le "$exp_epoch" ] || die "ad-smoke refused: spend envelope expired ($exp)"

  # Remaining = monthly cap minus spend already recorded in ads.md (integer math,
  # matching check-ad-budget.sh). Missing spend line ⇒ 0 spent.
  local monthly spent ads="$root/docs/growth/channels/ads.md"
  monthly=$(jq -r '.monthly_cap_eur' "$env_file")
  spent=0
  if [ -f "$ads" ]; then
    spent=$(grep -ioP 'total\s*spend:\s*[^0-9]*\K[0-9]+' "$ads" | tail -1)
    spent=${spent:-0}
  fi
  local remaining=$(( monthly - spent ))
  # Ceil cap_eur so a fractional cap can never authorize on a floored compare (fail
  # closed): 20.99 must require 21 remaining, not 20.
  local cap_ceil
  cap_ceil=$(awk -v c="$cap" 'BEGIN{printf "%d", (c==int(c))?c:int(c)+1}')
  if [ "$remaining" -lt "$cap_ceil" ]; then
    die "ad-smoke refused: remaining envelope budget (${remaining} EUR) < experiment cap (${cap} EUR)"
  fi
  echo "validate-experiment: ad-smoke authorized — cap ${cap} EUR within remaining ${remaining} EUR; landing ${landing}"
}

cmd_results() {
  local plan="" signals="" out=""
  [ $# -ge 1 ] || die "results needs a plan file"
  plan="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --signals) _need_val "$#" "$1"; signals="$2"; shift 2 ;;
      --out)     _need_val "$#" "$1"; out="$2"; shift 2 ;;
      *) die "results: unknown arg: $1" ;;
    esac
  done
  [ -n "$signals" ] || die "results needs --signals"
  [ -n "$out" ] || die "results needs --out"
  load_plan "$plan"
  [ -f "$signals" ] || die "signals file not found: $signals"
  jq empty "$signals" 2>/dev/null || die "signals file is not valid JSON: $signals"
  # Measured metrics, when present, must be non-negative numbers — a string or negative
  # would masquerade as measured evidence. Absent stays null (honest-evidence rule).
  local m
  for m in visits signups ad_spend_eur; do
    jq -e --arg k "$m" '
      if has($k) and .[$k] != null then (.[$k] | type == "number") and .[$k] >= 0 else true end
    ' "$signals" >/dev/null 2>&1 || die "signal '$m' must be a non-negative number"
  done

  local idea cap duration gen
  idea=$(jq -r '.idea_id' "$plan")
  cap=$(jq -r '.cap_eur' "$plan")
  duration=$(jq -r '.duration_days' "$plan")
  gen=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$(dirname "$out")"
  # Measured-only: each metric passes through from signals or becomes null. conversion
  # is a deterministic ratio of two measured values, else null — never an estimate.
  jq -n \
    --arg idea "$idea" --arg gen "$gen" \
    --argjson cap "$cap" --argjson duration "$duration" \
    --slurpfile s "$signals" '
    ($s[0]) as $sig
    | ($sig.visits // null) as $visits
    | ($sig.signups // null) as $signups
    | ($sig.ad_spend_eur // null) as $spend
    | {
        idea_id: $idea,
        generated_at: $gen,
        duration_days: $duration,
        cap_eur: $cap,
        evidence: "measured-only",
        measured: {
          visits: $visits,
          signups: $signups,
          ad_spend_eur: $spend,
          conversion: (
            if ($visits != null and $signups != null and $visits > 0)
            then (($signups / $visits) * 10000 | round) / 10000
            else null end
          )
        }
      }' > "$out"
  echo "validate-experiment: results → $out"
}

main() {
  [ $# -ge 1 ] || die "usage: validate-experiment.sh {validate|render|ad-smoke|results} ..."
  local sub="$1"; shift
  case "$sub" in
    validate) cmd_validate "$@" ;;
    render)   cmd_render "$@" ;;
    ad-smoke) cmd_ad_smoke "$@" ;;
    results)  cmd_results "$@" ;;
    *) die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
