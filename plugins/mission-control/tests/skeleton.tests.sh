#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

t "plugin.json parses"          jq -e '.name == "mission-control" and .version == "0.2.0"' "$PLUGIN/.claude-plugin/plugin.json"
t "marketplace entry exists"    jq -e '.plugins[] | select(.name == "mission-control") | .version == "0.2.0"' "$REPO_ROOT/.claude-plugin/marketplace.json"
t "example config parses"       jq -e '.engines and .pools and .slots and .projects and .admission' "$PLUGIN/examples/portfolio.example.json"
t "example engines have pool+cmd" jq -e '[.engines[] | has("pool") and has("cmd")] | all' "$PLUGIN/examples/portfolio.example.json"
t "example projects complete"   jq -e '[.projects[] | has("name") and has("container") and has("repo_path") and has("stage") and has("engine") and has("command") and has("hold")] | all' "$PLUGIN/examples/portfolio.example.json"
t "README has Installation"     grep -q '^## Installation' "$PLUGIN/README.md"
t "no real project names"       bash -c '! grep -rEiq --exclude=skeleton.tests.sh "aruannik|varustame|vastav|reklaamivaht|est-biz" "$0"/scripts "$0"/commands "$0"/tests "$0"/examples 2>/dev/null' "$PLUGIN"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
