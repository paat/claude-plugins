#!/usr/bin/env bash
# payment-contract-tester — optional pre-push hook BODY (fast-feedback convenience ONLY; NOT the
# security boundary — CI is the authoritative gate, and `git push --no-verify` bypasses this hook).
# Runs the configured payment-test subset and blocks the push on red. The command comes from the
# PCT_TEST_CMD env var, else from a conf file the installer wrote INSIDE the git dir (untracked, so
# it cannot be set by a branch/PR). Unconfigured => fail open (exit 0).
set -uo pipefail

cmd="${PCT_TEST_CMD:-}"
conf=$(git rev-parse --git-path payment-contract-tester-hook.conf 2>/dev/null || true)
if [ -z "$cmd" ] && [ -n "$conf" ] && [ -f "$conf" ]; then
  # read a single `PCT_TEST_CMD=...` line without sourcing arbitrary code
  cmd=$(sed -n 's/^PCT_TEST_CMD=//p' "$conf" | head -n1)
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
