#!/bin/bash
# bootstrap-plan.sh — non-interactive brief + provenance for /bootstrap Step 6 (#206).
#
# Renders docs/business/brief.md from a plan file (JSON or frontmattered markdown) and
# records .startup/provenance.json — audit/plan-integrity record for the bootstrap.
# Fail-closed: a missing plan file or empty IDEA_DESCRIPTION exits non-zero and writes
# nothing. Never reads stdin, so it is safe under an unattended scheduler.
#
# Usage: bootstrap-plan.sh [--plan-file PATH] [--root DIR]
#   --plan-file  plan source; falls back to $SAAS_BOOTSTRAP_PLAN.
#   --root       project root to write into (default: cwd).
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="."
PLAN="${SAAS_BOOTSTRAP_PLAN:-}"

die() { echo "bootstrap-plan: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plan-file) PLAN="${2:-}"; shift 2 ;;
    --root)      ROOT="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

BRIEF="$ROOT/docs/business/brief.md"

# Idempotent + interactive-parity: an existing brief is left untouched (matches the
# "skip if brief exists" branch of Step 6), so a re-run — or a run with no plan file —
# is a no-op instead of a prompt.
if [ -f "$BRIEF" ]; then
  echo "bootstrap-plan: $BRIEF exists; skipping (idempotent)"
  exit 0
fi

[ -n "$PLAN" ] || die "no plan file (pass --plan-file or set SAAS_BOOTSTRAP_PLAN); cannot bootstrap non-interactively"
[ -f "$PLAN" ] || die "plan file not found: $PLAN"

# --- Parse plan into fields --------------------------------------------------
# Two formats: JSON, or markdown with a YAML frontmatter block. Frontmatter keys
# supply the metadata; the markdown body is the idea description when the
# frontmatter omits idea_description.
first_line="$(grep -m1 -v '^[[:space:]]*$' "$PLAN" || true)"

if [ "$first_line" = "---" ]; then
  fmval() {  # $1=key — first matching "key: value" in the frontmatter block, unquoted
    awk -v key="$1" '
      NR==1 && /^---[[:space:]]*$/ { infm=1; next }
      infm && /^---[[:space:]]*$/  { exit }
      infm {
        idx=index($0, ":"); if (idx==0) next
        k=substr($0,1,idx-1); v=substr($0,idx+1)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
        gsub(/^"|"$/,"",v); gsub(/^\047|\047$/,"",v)
        if (k==key) { print v; exit }
      }' "$PLAN"
  }
  fmbody() { awk '/^---[[:space:]]*$/ { d++; next } d>=2 { print }' "$PLAN"; }
  IDEA="$(fmval idea_description)"
  # A bare YAML block-scalar sigil (| or >, with optional chomp/indent) is not something
  # this line parser can expand — treat it as absent and fall back to the markdown body,
  # the intended carrier for a multi-line description.
  case "$IDEA" in ""|"|"|">"|"|-"|"|+"|">-"|">+"|"|"[0-9]*|">"[0-9]*) IDEA="";; esac
  [ -n "$IDEA" ] || IDEA="$(fmbody | sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed -e '/^$/d')"
  NOTES="$(fmval investor_notes)"
  BUDGET="$(fmval budget)"
  TIMELINE="$(fmval timeline)"
  MARKET="$(fmval target_market)"
  IDEA_ID="$(fmval idea_id)"
  CONF="$(fmval validated_confidence)"
  EVID="$(fmval experiment_evidence)"
else
  jq empty "$PLAN" 2>/dev/null || die "plan file is neither JSON nor frontmattered markdown: $PLAN"
  jqf() { jq -r "$1 // empty" "$PLAN"; }
  IDEA="$(jqf '.idea_description')"
  NOTES="$(jqf '.investor_notes')"
  BUDGET="$(jqf '.budget')"
  TIMELINE="$(jqf '.timeline')"
  MARKET="$(jqf '.target_market')"
  IDEA_ID="$(jqf '.idea_id')"
  CONF="$(jq -r 'if .validated_confidence == null then empty else .validated_confidence end' "$PLAN")"
  EVID="$(jqf '.experiment_evidence')"
fi

# Fail closed BEFORE any write: idea_description is the one mandatory field, and a
# whitespace-only value does not satisfy it (would render an empty brief).
[[ "$IDEA" =~ [^[:space:]] ]] || die "plan is missing the mandatory field: idea_description (empty or whitespace-only)"

plan_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "no sha256 tool (sha256sum or shasum) available"; fi
}
PLAN_SHA="$(plan_sha "$PLAN")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Render brief.md ---------------------------------------------------------
# Literal, per-line token replacement — no sed/regex, so arbitrary plan text
# (ampersands, backslashes, slashes) substitutes verbatim.
lit_replace() {  # $1=token $2=value ; stdin -> stdout
  TOK="$1" VAL="$2" awk '
    BEGIN { tok=ENVIRON["TOK"]; val=ENVIRON["VAL"]; tl=length(tok) }
    {
      s=$0; out=""
      while ((p=index(s,tok))>0) { out=out substr(s,1,p-1) val; s=substr(s,p+tl) }
      print out s
    }'
}

mkdir -p "$ROOT/docs/business" "$ROOT/.startup"
cat "$PLUGIN_ROOT/templates/startup-brief.md" \
  | lit_replace "{{IDEA_DESCRIPTION}}" "$IDEA" \
  | lit_replace "{{INVESTOR_NOTES}}"   "$NOTES" \
  | lit_replace "{{BUDGET}}"           "$BUDGET" \
  | lit_replace "{{TIMELINE}}"         "$TIMELINE" \
  | lit_replace "{{TARGET_MARKET}}"    "$MARKET" \
  > "$BRIEF"

# --- Record provenance -------------------------------------------------------
jq -n \
  --arg idea_id "$IDEA_ID" \
  --arg sha "$PLAN_SHA" \
  --arg conf "$CONF" \
  --arg evid "$EVID" \
  --arg ts "$TS" \
  '{
    idea_id: ($idea_id | if . == "" then null else . end),
    source: "plan-file",
    plan_sha256: $sha,
    validated_confidence: ($conf | if . == "" then null else (tonumber? // null) end),
    experiment_evidence: ($evid | if . == "" then null else . end),
    created_at: $ts
  }' > "$ROOT/.startup/provenance.json"

echo "bootstrap-plan: wrote $BRIEF and $ROOT/.startup/provenance.json (plan sha256 $PLAN_SHA)"
