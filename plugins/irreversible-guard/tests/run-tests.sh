#!/usr/bin/env bash
# Unified test entrypoint for irreversible-guard: runs both the hook integration
# suite (run.sh) and the Python matcher/rules unit tests.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

bash "$HERE/run.sh" || rc=1
python3 -m unittest discover -s "$HERE" -p 'test_*.py' || rc=1

exit "$rc"
