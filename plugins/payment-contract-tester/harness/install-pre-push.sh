#!/usr/bin/env bash
# payment-contract-tester — installs/uninstalls the optional pre-push hook (convenience only).
# Fails SAFE: detects existing hook managers and prints guidance rather than clobbering; composes
# with an existing hook via a clearly-delimited managed block that runs FIRST (so an early `exit`
# in a pre-existing hook can't skip the payment gate); preserves the executable bit; supports clean
# removal. CI remains the authoritative gate; this hook is bypassable (--no-verify).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKBODY="$HERE/pre-push.sh"
BEGIN='# >>> payment-contract-tester >>>'
END='# <<< payment-contract-tester <<<'

uninstall=0 testcmd='' repo=''
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) uninstall=1 ;;
    --test-cmd)  testcmd="${2:-}"; shift ;;
    --repo)      repo="${2:-}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null || true)
# Resolve the git dir via plumbing — handles worktrees/submodules where .git is a FILE, not a dir.
gitdir=''
[ -n "$repo" ] && gitdir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)
if [ -z "$repo" ] || [ -z "$gitdir" ]; then
  echo "Not a git repository (no --repo and not inside a work tree). Nothing to do." >&2
  exit 0
fi
hook="$gitdir/hooks/pre-push"
# Store the configured command INSIDE the git dir: it is never part of the work tree, so it cannot
# be committed or altered by a branch/PR (closes the repo-controlled-command path on push).
conf="$gitdir/payment-contract-tester-hook.conf"

# --- managed-block helpers (POSIX awk; no GNU-only flags) ---
strip_block() {  # prints $1 with our block removed
  awk -v b="$BEGIN" -v e="$END" '
    $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}
  ' "$1"
}
block_text() {
  printf '%s\n' "$BEGIN"
  printf '%s\n' "# Managed by payment-contract-tester. Edit via install-pre-push.sh, not by hand."
  printf '%s\n' "# Runs first so a later early-exit in this hook cannot skip the payment-test gate."
  printf '"%s" "$@" || exit $?\n' "$HOOKBODY"
  printf '%s\n' "$END"
}

# Atomically install the contents of $1 as the executable hook (checked at every step).
write_hook() {
  local src="$1" dir dest_tmp
  dir=$(dirname "$hook")
  mkdir -p "$dir"        || { echo "ERROR: cannot create hook directory $dir" >&2; exit 1; }
  dest_tmp="$dir/.pct-pre-push.$$"
  cat "$src" >"$dest_tmp" || { echo "ERROR: failed writing hook contents" >&2; rm -f "$dest_tmp"; exit 1; }
  chmod +x "$dest_tmp"    || { echo "ERROR: chmod failed on new hook" >&2; rm -f "$dest_tmp"; exit 1; }
  mv "$dest_tmp" "$hook"  || { echo "ERROR: failed to move hook into place" >&2; rm -f "$dest_tmp"; exit 1; }
}

# Emit (to stdout) $1's content with our block inserted right after a leading shebang (or at top).
compose_with_block() {
  local f="$1"
  if head -1 "$f" | grep -q '^#!'; then
    head -1 "$f"; block_text; tail -n +2 "$f"
  else
    block_text; cat "$f"
  fi
}

if [ "$uninstall" -eq 1 ]; then
  if [ ! -f "$hook" ]; then echo "No pre-push hook present — nothing to uninstall."; exit 0; fi
  if ! grep -qF "$BEGIN" "$hook"; then echo "No payment-contract-tester block found — leaving hook untouched."; exit 0; fi
  # Require exactly one well-formed block: one BEGIN, one END, BEGIN before END. Anything else is
  # malformed (hand-edited / duplicated / reversed) — refuse rather than risk deleting unrelated content.
  bcount=$(grep -cF "$BEGIN" "$hook"); ecount=$(grep -cF "$END" "$hook")
  bline=$(grep -nF "$BEGIN" "$hook" | head -1 | cut -d: -f1)
  eline=$(grep -nF "$END"   "$hook" | head -1 | cut -d: -f1)
  if [ "$bcount" -ne 1 ] || [ "$ecount" -ne 1 ] || [ -z "$bline" ] || [ -z "$eline" ] || [ "$bline" -ge "$eline" ]; then
    echo "payment-contract-tester block is malformed (markers missing, duplicated, or out of order) — manual cleanup required, nothing modified." >&2
    exit 0
  fi
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  strip_block "$hook" >"$tmp"
  # if only a shebang / blank lines remain, remove the file entirely
  if ! grep -Eq '[^[:space:]]' <(grep -vE '^#!' "$tmp"); then
    rm -f "$hook" || { echo "ERROR: failed to remove hook" >&2; exit 1; }
    echo "Removed payment-contract-tester block; hook was otherwise empty, deleted it."
  else
    write_hook "$tmp"
    echo "Removed payment-contract-tester block; preserved the rest of the hook."
  fi
  exit 0
fi

# --- fail-safe: detect existing hook managers; print guidance, do NOT clobber and do NOT write conf ---
hookspath=$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)
manager=''
case "$hookspath" in ""|".git/hooks") ;; *) manager="core.hooksPath ($hookspath)";; esac
[ -d "$repo/.husky" ] && manager="Husky (.husky/)"
for f in lefthook.yml lefthook.yaml lefthook.toml; do [ -f "$repo/$f" ] && manager="lefthook ($f)"; done
[ -f "$repo/.pre-commit-config.yaml" ] && manager="pre-commit (.pre-commit-config.yaml)"

if [ -n "$manager" ]; then
  cat <<EOF
Detected an existing hook manager: $manager
Not writing the git hook (it would be ignored or would clobber your setup).
Add a pre-push step in your manager that runs the payment-test subset with PCT_TEST_CMD set, e.g.:

    PCT_TEST_CMD='<your subset command>' "$HOOKBODY"

See harness/README.md for Husky / lefthook / pre-commit snippets.
EOF
  exit 0
fi

# --- fail-safe: an existing, non-empty, NON-executable hook is an unusual setup — don't fight it ---
if [ -f "$hook" ] && [ -s "$hook" ] && [ ! -x "$hook" ]; then
  cat <<EOF
A non-executable pre-push hook already exists at:
    $hook
This is an unusual setup, so nothing was modified. To install manually, add this block just after the
shebang (it must run before any early exit), then chmod +x the file:

$(block_text)
EOF
  exit 0
fi

# record the test command for the hook body to read (only on the direct-install path, into the git dir)
if [ -n "$testcmd" ]; then
  printf 'PCT_TEST_CMD=%s\n' "$testcmd" >"$conf" || { echo "ERROR: failed writing $conf" >&2; exit 1; }
fi

# --- install: create fresh, or compose with an existing hook (block runs first; idempotent replace) ---
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if [ ! -f "$hook" ]; then
  { printf '#!/usr/bin/env bash\n'; block_text; } >"$tmp"
elif grep -qF "$BEGIN" "$hook"; then
  # already managed: strip our old block, then re-insert after the shebang (idempotent)
  stripped=$(mktemp); strip_block "$hook" >"$stripped"
  compose_with_block "$stripped" >"$tmp"; rm -f "$stripped"
else
  compose_with_block "$hook" >"$tmp"
fi
write_hook "$tmp"
echo "Installed payment-contract-tester pre-push hook at $hook"
echo "  (convenience only — CI is the authoritative gate; bypass with: git push --no-verify)"
exit 0
