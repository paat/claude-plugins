#!/usr/bin/env bash
# payment-contract-tester — optional pre-push hook BODY (fast-feedback convenience ONLY; NOT the
# security boundary — CI is the authoritative gate, and `git push --no-verify` bypasses this hook).
# Runs the configured payment-test subset and blocks the push on red. The command comes from the
# PCT_TEST_CMD env var, else from <repo-root>/.pct-hook.conf. Unconfigured => fail open (exit 0).
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cmd="${PCT_TEST_CMD:-}"
if [ -z "$cmd" ] && [ -f "$root/.pct-hook.conf" ]; then
  # read a single `PCT_TEST_CMD=...` line without sourcing arbitrary code
  cmd=$(sed -n 's/^PCT_TEST_CMD=//p' "$root/.pct-hook.conf" | head -n1)
fi

if [ -z "$cmd" ]; then
  echo "payment-contract-tester pre-push: no PCT_TEST_CMD configured — skipping (not blocking)."
  exit 0
fi

echo "payment-contract-tester pre-push: running payment-test subset:"
echo "  $cmd"
bash -c "$cmd"
status=$?
if [ "$status" -ne 0 ]; then
  echo "payment-contract-tester pre-push: payment tests FAILED — push blocked."
  echo "  (CI is the authoritative gate; to bypass locally: git push --no-verify)"
fi
exit $status
