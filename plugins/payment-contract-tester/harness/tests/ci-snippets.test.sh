#!/usr/bin/env bash
# Validates the CI snippets parse as YAML and carry both adaptable runner commands + the
# "authoritative gate" framing. Uses python3 (always present here) for a real YAML parse.
set -uo pipefail
CI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ci" && pwd)"
fail=0
pass() { echo "OK: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

for f in github-actions.yml gitlab-ci.yml; do
  p="$CI/$f"
  if [ ! -f "$p" ]; then bad "$f missing"; continue; fi
  if python3 -c "import sys,yaml; yaml.safe_load(open('$p'))" 2>/dev/null; then
    pass "$f is valid YAML"
  else
    bad "$f failed to parse as YAML"
  fi
  grep -qF 'pytest -k' "$p"        && pass "$f has the pytest runner" || bad "$f missing the pytest runner"
  grep -qF 'dotnet test --filter' "$p" && pass "$f has the dotnet runner" || bad "$f missing the dotnet runner"
  grep -qi 'authoritative' "$p"    && pass "$f states the authoritative-gate framing" || bad "$f missing authoritative-gate framing"
done

[ "$fail" -eq 0 ] && echo "ci-snippets tests: ALL PASS" || echo "ci-snippets tests: FAILURES"
exit $fail
