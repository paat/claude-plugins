#!/usr/bin/env bash
# Tests for install-pre-push.sh: managed-block install/uninstall, exec-bit preservation,
# existing-hook composition (block runs FIRST so an early exit can't skip the gate), hook-manager
# detection (no-clobber, no-conf), git-dir-internal conf (never in the work tree), malformed-block
# refusal, and linked-worktree support. Each case runs in a fresh throwaway git repo under mktemp —
# never touches the real repo.
set -uo pipefail
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$HARNESS/install-pre-push.sh"
HOOKBODY="$HARNESS/pre-push.sh"
BEGIN='# >>> payment-contract-tester >>>'
END='# <<< payment-contract-tester <<<'
fail=0
pass() { echo "OK: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

newrepo() {  # echoes a fresh repo path; safe to rm afterwards
  local d; d=$(mktemp -d)
  git -C "$d" init -q
  printf '%s\n' "$d"
}
confpath() {  # path of the git-dir-internal conf for repo $1
  printf '%s/payment-contract-tester-hook.conf\n' "$(git -C "$1" rev-parse --absolute-git-dir)"
}

# 1) fresh install creates an executable hook with our block; conf is recorded INSIDE the git dir
#    (never in the work tree, so it cannot be committed / set by a branch or PR)
r=$(newrepo)
bash "$INSTALL" --repo "$r" --test-cmd 'echo subset' >/dev/null 2>&1
h="$r/.git/hooks/pre-push"
if [ -x "$h" ] && grep -qF "$BEGIN" "$h" && grep -qF "$END" "$h"; then
  pass "fresh install writes executable managed block"
else
  bad "fresh install did not write an executable managed block"
fi
c=$(confpath "$r")
if grep -qF 'PCT_TEST_CMD=echo subset' "$c" && [ ! -f "$r/.pct-hook.conf" ]; then
  pass "test command recorded in git-dir conf, not in the work tree"
else
  bad "conf not in the git dir, or leaked into the work tree (.pct-hook.conf)"
fi
rm -rf "$r"

# 2) re-install is idempotent (exactly one managed block)
r=$(newrepo)
bash "$INSTALL" --repo "$r" --test-cmd 'echo a' >/dev/null 2>&1
bash "$INSTALL" --repo "$r" --test-cmd 'echo b' >/dev/null 2>&1
n=$(grep -cF "$BEGIN" "$r/.git/hooks/pre-push")
if [ "$n" -eq 1 ]; then pass "re-install stays idempotent (one block)"; else bad "re-install produced $n blocks"; fi
rm -rf "$r"

# 3) uninstall removes only our block, preserving pre-existing hook content + exec bit
r=$(newrepo)
h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho "pre-existing custom hook"\n' >"$h"; chmod +x "$h"
bash "$INSTALL" --repo "$r" --test-cmd 'echo x' >/dev/null 2>&1
bash "$INSTALL" --repo "$r" --uninstall >/dev/null 2>&1
if [ -x "$h" ] && grep -qF 'pre-existing custom hook' "$h" && ! grep -qF "$BEGIN" "$h"; then
  pass "uninstall preserves existing hook + exec bit, drops our block"
else
  bad "uninstall damaged the existing hook or left our block"
fi
rm -rf "$r"

# 4) installing alongside an existing hook composes (does not clobber) AND places our block FIRST
r=$(newrepo)
h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho "keep me"\n' >"$h"; chmod +x "$h"
bash "$INSTALL" --repo "$r" --test-cmd 'echo y' >/dev/null 2>&1
bpos=$(grep -nF "$BEGIN" "$h" | head -1 | cut -d: -f1)
kpos=$(grep -nF 'keep me' "$h" | head -1 | cut -d: -f1)
if grep -qF 'keep me' "$h" && grep -qF "$BEGIN" "$h" && [ -x "$h" ] && [ -n "$bpos" ] && [ -n "$kpos" ] && [ "$bpos" -lt "$kpos" ]; then
  pass "install composes with existing hook, our block runs first"
else
  bad "install clobbered, lost existing content, or placed our block after it"
fi
rm -rf "$r"

# 5) hook manager present (core.hooksPath) -> print instructions, write NOTHING to .git/hooks
r=$(newrepo)
git -C "$r" config core.hooksPath .husky
out=$(bash "$INSTALL" --repo "$r" --test-cmd 'echo z' 2>&1)
if [ ! -e "$r/.git/hooks/pre-push" ] && printf '%s' "$out" | grep -qi 'hooksPath\|husky\|manager'; then
  pass "core.hooksPath detected -> no clobber, prints integration guidance"
else
  bad "core.hooksPath case wrote a hook or gave no guidance"
fi
rm -rf "$r"

# 6) husky directory present -> no clobber, prints guidance
r=$(newrepo); mkdir -p "$r/.husky"
out=$(bash "$INSTALL" --repo "$r" --test-cmd 'echo z' 2>&1)
if [ ! -e "$r/.git/hooks/pre-push" ] && printf '%s' "$out" | grep -qi 'husky'; then
  pass "husky detected -> no clobber, prints guidance"
else
  bad "husky case wrote a hook or gave no guidance"
fi
rm -rf "$r"

# 7) fail-safe: existing NON-executable non-empty hook -> modify nothing, print instructions
r=$(newrepo); h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho weird\n' >"$h"   # intentionally not chmod +x
before=$(cat "$h")
out=$(bash "$INSTALL" --repo "$r" --test-cmd 'echo z' 2>&1)
if [ "$(cat "$h")" = "$before" ] && printf '%s' "$out" | grep -qi 'manual\|nothing was modified\|not modif'; then
  pass "ambiguous non-executable hook -> fail-safe, no modification"
else
  bad "ambiguous hook case modified the file instead of failing safe"
fi
rm -rf "$r"

# 8) the installed hook actually fails the push when the test command fails
r=$(newrepo)
bash "$INSTALL" --repo "$r" --test-cmd 'exit 7' >/dev/null 2>&1
if ( cd "$r" && ! bash .git/hooks/pre-push </dev/null >/dev/null 2>&1 ); then
  pass "installed hook propagates a red test command (non-zero exit)"
else
  bad "installed hook did not fail on a red test command"
fi
rm -rf "$r"

# 9) the hook body fails OPEN (exit 0) when no test command is configured
r=$(newrepo)
if ( cd "$r" && PCT_TEST_CMD= bash "$HOOKBODY" </dev/null >/dev/null 2>&1 ); then
  pass "hook body fails open (exit 0) when unconfigured"
else
  bad "hook body blocked the push despite no configured command"
fi
rm -rf "$r"

# 10) manager detected (core.hooksPath) -> conf must NOT be written anywhere
r=$(newrepo)
git -C "$r" config core.hooksPath .husky
bash "$INSTALL" --repo "$r" --test-cmd 'echo z' >/dev/null 2>&1
c=$(confpath "$r")
if [ ! -f "$c" ] && [ ! -f "$r/.pct-hook.conf" ]; then
  pass "core.hooksPath detected -> conf not written (bail-out path)"
else
  bad "core.hooksPath detected but a conf was written (bail-out path should not write it)"
fi
rm -rf "$r"

# 11) fail-safe non-executable hook -> conf must NOT be written anywhere
r=$(newrepo); h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho weird\n' >"$h"   # intentionally not chmod +x
bash "$INSTALL" --repo "$r" --test-cmd 'echo z' >/dev/null 2>&1
c=$(confpath "$r")
if [ ! -f "$c" ] && [ ! -f "$r/.pct-hook.conf" ]; then
  pass "ambiguous non-executable hook -> conf not written (bail-out path)"
else
  bad "ambiguous non-executable hook but a conf was written (bail-out path should not write it)"
fi
rm -rf "$r"

# 12) uninstall with missing END marker -> file left intact, nothing modified
r=$(newrepo)
bash "$INSTALL" --repo "$r" --test-cmd 'echo q' >/dev/null 2>&1
h="$r/.git/hooks/pre-push"
grep -v "$END" "$h" >"$h.tmp" && mv "$h.tmp" "$h"   # corrupt: drop the END marker
before=$(cat "$h")
bash "$INSTALL" --repo "$r" --uninstall >/dev/null 2>&1
if [ "$(cat "$h")" = "$before" ]; then
  pass "uninstall with missing END marker leaves file intact"
else
  bad "uninstall with missing END marker modified the file (should have bailed out)"
fi
rm -rf "$r"

# 13) composed hook runs our gate FIRST: an existing hook that exits 0 must NOT skip the payment gate
r=$(newrepo)
h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\nexit 0\n' >"$h"; chmod +x "$h"   # existing hook exits before EOF
bash "$INSTALL" --repo "$r" --test-cmd 'exit 7' >/dev/null 2>&1
if ( cd "$r" && ! bash .git/hooks/pre-push </dev/null >/dev/null 2>&1 ); then
  pass "composed hook runs our gate first (early-exit existing hook can't skip it)"
else
  bad "composed hook let an existing 'exit 0' skip the payment gate (false-green)"
fi
rm -rf "$r"

# 14) uninstall refuses a malformed (out-of-order) block: END before BEGIN -> file intact
r=$(newrepo)
h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\n%s\necho x\n%s\n' "$END" "$BEGIN" >"$h"; chmod +x "$h"
before=$(cat "$h")
bash "$INSTALL" --repo "$r" --uninstall >/dev/null 2>&1
if [ "$(cat "$h")" = "$before" ]; then
  pass "uninstall refuses a malformed out-of-order block (file intact)"
else
  bad "uninstall modified a malformed block instead of bailing"
fi
rm -rf "$r"

# 15) installs in a LINKED WORKTREE where .git is a file, not a directory
r=$(newrepo)
git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
wt=$(mktemp -d)
if git -C "$r" worktree add -q "$wt" >/dev/null 2>&1; then
  bash "$INSTALL" --repo "$wt" --test-cmd 'echo w' >/dev/null 2>&1
  wtgit=$(git -C "$wt" rev-parse --absolute-git-dir)
  if [ -x "$wtgit/hooks/pre-push" ] && grep -qF "$BEGIN" "$wtgit/hooks/pre-push"; then
    pass "installs in a linked worktree (.git-as-file)"
  else
    bad "failed to install in a linked worktree (.git-as-file)"
  fi
  git -C "$r" worktree remove --force "$wt" >/dev/null 2>&1
else
  bad "could not create a linked worktree to test (.git-as-file path unverified)"
fi
rm -rf "$r" "$wt"

[ "$fail" -eq 0 ] && echo "install-pre-push tests: ALL PASS" || echo "install-pre-push tests: FAILURES"
exit $fail
