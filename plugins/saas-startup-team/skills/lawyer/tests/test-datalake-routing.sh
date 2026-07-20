#!/usr/bin/env bash
set -euo pipefail

# Offline guards for datalake routing/API refs and size budgets.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SKILL="$ROOT/SKILL.md"
ROUTING="$ROOT/references/datalake-routing.md"
API="$ROOT/references/datalake-api.md"
AGENT="$PLUGIN_ROOT/agents/lawyer.md"
CLAUDE_PLUGIN="$PLUGIN_ROOT/.claude-plugin/plugin.json"
CODEX_PLUGIN="$PLUGIN_ROOT/.codex-plugin/plugin.json"
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"

[[ -f "$ROUTING" ]] || { echo "FAIL: missing $ROUTING"; exit 1; }
[[ -f "$API" ]] || { echo "FAIL: missing $API"; exit 1; }
[[ -f "$SKILL" ]] || { echo "FAIL: missing $SKILL"; exit 1; }
[[ -f "$AGENT" ]] || { echo "FAIL: missing $AGENT"; exit 1; }

grep -q 'datalake-routing.md' "$SKILL" || {
  echo "FAIL: SKILL.md must reference datalake-routing.md"
  exit 1
}

for heading in '## Routing' '## Playbooks' '## Safeguards' '## Answer format'; do
  grep -qF "$heading" "$ROUTING" || {
    echo "FAIL: routing missing heading: $heading"
    exit 1
  }
done

grep -qF '## Tõendav materjal' "$ROUTING" || {
  echo "FAIL: routing must use ## Tõendav materjal (õ)"
  exit 1
}
if grep -qF '## Toendav materjal' "$ROUTING"; then
  echo "FAIL: routing has misspelled ## Toendav materjal"
  exit 1
fi

# Gate-compatible human-task heading required; optional next steps must not replace it
grep -qF '## Inimülesanded' "$ROUTING" || {
  echo "FAIL: routing answer format must require ## Inimülesanded"
  exit 1
}
grep -q 'never substitute' "$ROUTING" || {
  echo "FAIL: routing must forbid substituting Järgmised sammud for Inimülesanded"
  exit 1
}

# Core behavioural contract strings
grep -q 'exact name' "$ROUTING" || {
  echo "FAIL: routing must document exact municipality name matching"
  exit 1
}
grep -q 'zero rows' "$ROUTING" || {
  echo "FAIL: routing must document zero-rows name-mismatch caveat"
  exit 1
}
grep -q 'state-law' "$SKILL" || {
  echo "FAIL: SKILL must say pure state-law (not bare pure statute) skips routing"
  exit 1
}
grep -q 'courts' "$SKILL" || {
  echo "FAIL: SKILL load triggers must include courts"
  exit 1
}
grep -q 'political finance' "$SKILL" || {
  echo "FAIL: SKILL load triggers must include political finance"
  exit 1
}
grep -qE 'courts|case law' "$AGENT" || {
  echo "FAIL: agent load triggers must include courts"
  exit 1
}
grep -q 'political finance' "$AGENT" || {
  echo "FAIL: agent load triggers must include political finance"
  exit 1
}
grep -q 'state-law' "$AGENT" || {
  echo "FAIL: agent must say pure state-law skips routing"
  exit 1
}
grep -q 'not a credit rating' "$API" || {
  echo "FAIL: API ref must state distress is not a credit rating"
  exit 1
}
grep -q '/companies/{registry_code}/board' "$API" || {
  echo "FAIL: API ref must use full company drill paths"
  exit 1
}
grep -q '/grants/calls' "$API" || {
  echo "FAIL: API ref must document grants calls"
  exit 1
}

for anchor in municipality enforcement distress grants profile/full; do
  grep -qi "$anchor" "$API" || {
    echo "FAIL: datalake-api.md missing anchor: $anchor"
    exit 1
  }
done

skill_lines=$(wc -l < "$SKILL")
if (( skill_lines > 170 )); then
  echo "FAIL: SKILL.md has $skill_lines lines (max 170)"
  exit 1
fi

agent_bytes=$(wc -c < "$AGENT")
if (( agent_bytes > 3392 )); then
  echo "FAIL: agents/lawyer.md is $agent_bytes bytes (budget 3392)"
  exit 1
fi

# Three-way version parity
claude_ver=$(jq -r '.version' "$CLAUDE_PLUGIN")
codex_ver=$(jq -r '.version' "$CODEX_PLUGIN")
market_ver=$(jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' "$MARKETPLACE")
if [[ -z "$claude_ver" || "$claude_ver" != "$codex_ver" || "$claude_ver" != "$market_ver" ]]; then
  echo "FAIL: version mismatch claude=$claude_ver codex=$codex_ver marketplace=$market_ver"
  exit 1
fi

echo "PASS: test-datalake-routing"
