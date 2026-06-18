#!/usr/bin/env bash
# payment-contract-tester — installs/uninstalls the optional pre-push hook (convenience only).
# Fails SAFE: detects existing hook managers and prints guidance rather than clobbering; composes
# with an existing hook via a clearly-delimited managed block; preserves the executable bit;
# supports clean removal. CI remains the authoritative gate; this hook is bypassable (--no-verify).
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
if [ -z "$repo" ] || [ ! -d "$repo/.git" ]; then
  echo "Not a git repository (no --repo and no .git found). Nothing to do." >&2
  exit 0
fi
hook="$repo/.git/hooks/pre-push"

# --- managed-block helpers (POSIX awk; no GNU-only flags) ---
strip_block() {  # prints $1 with our block removed
  awk -v b="$BEGIN" -v e="$END" '
    $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}
  ' "$1"
}
block_text() {
  printf '%s\n' "$BEGIN"
  printf '%s\n' "# Managed by payment-contract-tester. Edit via install-pre-push.sh, not by hand."
  printf '%s\n' "# NOTE: exec replaces the shell — any hook content after the END marker below will NOT run."
  printf 'exec "%s" "$@"\n' "$HOOKBODY"
  printf '%s\n' "$END"
}

if [ "$uninstall" -eq 1 ]; then
  if [ ! -f "$hook" ]; then echo "No pre-push hook present — nothing to uninstall."; exit 0; fi
  if ! grep -qF "$BEGIN" "$hook"; then echo "No payment-contract-tester block found — leaving hook untouched."; exit 0; fi
  if ! grep -qF "$END" "$hook"; then
    echo "payment-contract-tester block is missing its end marker — manual cleanup required, nothing modified." >&2
    exit 0
  fi
  tmp=$(mktemp); strip_block "$hook" >"$tmp"
  # if only a shebang / blank lines remain, remove the file entirely
  if ! grep -Eq '[^[:space:]]' <(grep -vE '^#!' "$tmp"); then
    rm -f "$hook"; echo "Removed payment-contract-tester block; hook was otherwise empty, deleted it."
  else
    cat "$tmp" >"$hook"; echo "Removed payment-contract-tester block; preserved the rest of the hook."
  fi
  rm -f "$tmp"; exit 0
fi

# --- fail-safe: detect existing hook managers; print guidance, do NOT clobber ---
hookspath=$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)
manager=''
case "$hookspath" in ""|".git/hooks") ;; *) manager="core.hooksPath ($hookspath)";; esac
[ -d "$repo/.husky" ] && manager="Husky (.husky/)"
for f in lefthook.yml lefthook.yaml lefthook.toml; do [ -f "$repo/$f" ] && manager="lefthook ($f)"; done
[ -f "$repo/.pre-commit-config.yaml" ] && manager="pre-commit (.pre-commit-config.yaml)"

if [ -n "$manager" ]; then
  cat <<EOF
Detected an existing hook manager: $manager
Not writing .git/hooks/pre-push (it would be ignored or would clobber your setup).
Add a pre-push step in your manager that runs the payment-test subset, e.g.:

    "$HOOKBODY"

with PCT_TEST_CMD set (or a .pct-hook.conf at the repo root containing:
    PCT_TEST_CMD=<your subset command>).
See harness/README.md for Husky / lefthook / pre-commit snippets.
EOF
  exit 0
fi

# --- fail-safe: an existing, non-empty, NON-executable hook is an unusual setup — don't fight it ---
if [ -f "$hook" ] && [ -s "$hook" ] && [ ! -x "$hook" ]; then
  cat <<EOF
A non-executable pre-push hook already exists at:
    $hook
This is an unusual setup, so nothing was modified. To install manually, add this block to that file:

$(block_text)

Then ensure the file is executable: chmod +x "$hook"
EOF
  exit 0
fi

# record the test command for the hook body to read (only on the direct-install path)
if [ -n "$testcmd" ]; then
  printf 'PCT_TEST_CMD=%s\n' "$testcmd" >"$repo/.pct-hook.conf"
fi

# --- install: create fresh, or compose with an existing hook (idempotent replace) ---
mkdir -p "$repo/.git/hooks"
if [ ! -f "$hook" ]; then
  { printf '#!/usr/bin/env bash\n'; block_text; } >"$hook"
elif grep -qF "$BEGIN" "$hook"; then
  tmp=$(mktemp); { strip_block "$hook"; block_text; } >"$tmp"; cat "$tmp" >"$hook"; rm -f "$tmp"
else
  block_text >>"$hook"
fi
chmod +x "$hook"
echo "Installed payment-contract-tester pre-push hook at $hook"
echo "  (convenience only — CI is the authoritative gate; bypass with: git push --no-verify)"
exit 0
