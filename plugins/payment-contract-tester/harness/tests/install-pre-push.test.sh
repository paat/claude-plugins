#!/usr/bin/env bash
# Tests for install-pre-push.sh: managed-block install/uninstall, exec-bit preservation,
# existing-hook composition, hook-manager detection (no-clobber), and fail-safe on ambiguity.
# Each case runs in a fresh throwaway git repo under mktemp — never touches the real repo.
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

# 1) fresh install creates an executable hook containing our managed block
r=$(newrepo)
bash "$INSTALL" --repo "$r" --test-cmd 'echo subset' >/dev/null 2>&1
h="$r/.git/hooks/pre-push"
if [ -x "$h" ] && grep -qF "$BEGIN" "$h" && grep -qF "$END" "$h"; then
  pass "fresh install writes executable managed block"
else
  bad "fresh install did not write an executable managed block"
fi
# .pct-hook.conf records the test command
if grep -qF 'PCT_TEST_CMD=echo subset' "$r/.pct-hook.conf"; then
  pass "test command recorded in .pct-hook.conf"
else
  bad ".pct-hook.conf missing the test command"
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

# 4) installing alongside an existing hook appends (does not clobber)
r=$(newrepo)
h="$r/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho "keep me"\n' >"$h"; chmod +x "$h"
bash "$INSTALL" --repo "$r" --test-cmd 'echo y' >/dev/null 2>&1
if grep -qF 'keep me' "$h" && grep -qF "$BEGIN" "$h" && [ -x "$h" ]; then
  pass "install composes with existing hook content"
else
  bad "install clobbered or failed to compose with existing hook"
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
if [ "$(cat "$h")" = "$before" ] && printf '%s' "$out" | grep -qi 'manual\|instruction\|not modif'; then
  pass "ambiguous non-executable hook -> fail-safe, no modification"
else
  bad "ambiguous hook case modified the file instead of failing safe"
fi
rm -rf "$r"

# 8) the installed hook body actually fails the push when the test command fails
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

[ "$fail" -eq 0 ] && echo "install-pre-push tests: ALL PASS" || echo "install-pre-push tests: FAILURES"
exit $fail
