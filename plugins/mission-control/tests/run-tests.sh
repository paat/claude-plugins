#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
rc=0
for f in ./*.tests.sh; do
  echo "== $f"
  bash "$f" || rc=1
done
exit $rc
