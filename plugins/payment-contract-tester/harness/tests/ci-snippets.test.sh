#!/usr/bin/env bash
# Validates the CI snippets parse as YAML and carry both adaptable runner commands + the
# "authoritative gate" framing. The YAML parse uses PyYAML when available; if PyYAML is absent it is
# SKIPped (the content greps still run) — never a false green, mirroring the runtime-guard pattern.
set -uo pipefail
CI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ci" && pwd)"
fail=0
pass() { echo "OK: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

HAVE_YAML=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then HAVE_YAML=1; fi
[ "$HAVE_YAML" -eq 1 ] || echo "SKIP: PyYAML not available — skipping YAML parse (content checks still run)"

for f in github-actions.yml gitlab-ci.yml; do
  p="$CI/$f"
  if [ ! -f "$p" ]; then bad "$f missing"; continue; fi
  if [ "$HAVE_YAML" -eq 1 ]; then
    if python3 -c "import sys,yaml; yaml.safe_load(open('$p'))" 2>/dev/null; then
      pass "$f is valid YAML"
    else
      bad "$f failed to parse as YAML"
    fi
  fi
  grep -qF 'pytest -k' "$p"        && pass "$f has the pytest runner" || bad "$f missing the pytest runner"
  grep -qF 'dotnet test --filter' "$p" && pass "$f has the dotnet runner" || bad "$f missing the dotnet runner"
  grep -qi 'authoritative' "$p"    && pass "$f states the authoritative-gate framing" || bad "$f missing authoritative-gate framing"
done

[ "$fail" -eq 0 ] && echo "ci-snippets tests: ALL PASS" || echo "ci-snippets tests: FAILURES"
exit $fail
