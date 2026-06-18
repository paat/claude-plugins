#!/usr/bin/env bash
# payment-contract-tester — installs/uninstalls the optional pre-push hook (convenience only).
# Fails SAFE: detects existing hook managers and prints guidance rather than clobbering; composes
# with an existing SHELL hook via a clearly-delimited managed block that runs FIRST (so an early
# `exit` in a pre-existing hook can't skip the payment gate); refuses to touch non-shell hooks or
# malformed blocks; preserves the executable bit; supports clean removal. CI remains the
# authoritative gate; this hook is bypassable (--no-verify).
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
# Validate we're in a git repo (works where .git is a FILE, e.g. worktrees/submodules).
gitdir=''
[ -n "$repo" ] && gitdir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || true)
if [ -z "$repo" ] || [ -z "$gitdir" ]; then
  echo "Not a git repository (no --repo and not inside a work tree). Nothing to do." >&2
  exit 0
fi
# Resolve paths via `git rev-parse --git-path`, which honors the common-dir layout: in a linked
# worktree `hooks/` lives in the COMMON dir (where Git actually runs it), not the per-worktree dir.
# Absolutize relative output against $repo. The hook body reads the conf with the same `--git-path`,
# so writer and reader always agree on the file. The conf lives in the git dir (never the work tree),
# so it cannot be committed or altered by a branch/PR.
abspath() { case "$1" in /*) printf '%s\n' "$1";; *) printf '%s/%s\n' "$repo" "$1";; esac; }
hook=$(abspath "$(git -C "$repo" rev-parse --git-path hooks/pre-push)")
conf=$(abspath "$(git -C "$repo" rev-parse --git-path payment-contract-tester-hook.conf)")

# --- helpers (POSIX awk/sed/grep; no GNU-only flags) ---
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
validate_block() {  # 0 iff $1 contains exactly one well-formed block: one BEGIN, one END, BEGIN<END
  local f="$1" bc ec bl el
  bc=$(grep -cF "$BEGIN" "$f"); ec=$(grep -cF "$END" "$f")
  bl=$(grep -nF "$BEGIN" "$f" | head -1 | cut -d: -f1)
  el=$(grep -nF "$END"   "$f" | head -1 | cut -d: -f1)
  [ "$bc" -eq 1 ] && [ "$ec" -eq 1 ] && [ -n "$bl" ] && [ -n "$el" ] && [ "$bl" -lt "$el" ]
}
is_shell_hook() {  # 0 iff $1's first line is a shebang for a known POSIX-ish shell
  local line interp base
  line=$(head -1 "$1")
  case "$line" in '#!'*) ;; *) return 1;; esac   # no shebang -> not a recognized shell hook
  interp=$(printf '%s' "$line" | sed -E 's/^#!\s*//; s/\s.*$//')
  base=$(basename "$interp")
  if [ "$base" = "env" ]; then                   # `#!/usr/bin/env bash` -> take the next token
    base=$(printf '%s' "$line" | sed -E 's/^#!\s*[^[:space:]]+[[:space:]]+//; s/[[:space:]].*$//')
    base=$(basename "$base")
  fi
  case "$base" in sh|bash|dash|zsh|ksh|ash) return 0;; *) return 1;; esac
}
write_hook() {  # atomically install the contents of $1 as the executable hook (checked at every step)
  local src="$1" dir dest_tmp
  dir=$(dirname "$hook")
  mkdir -p "$dir"         || { echo "ERROR: cannot create hook directory $dir" >&2; exit 1; }
  dest_tmp="$dir/.pct-pre-push.$$"
  cat "$src" >"$dest_tmp" || { echo "ERROR: failed writing hook contents" >&2; rm -f "$dest_tmp"; exit 1; }
  chmod +x "$dest_tmp"    || { echo "ERROR: chmod failed on new hook" >&2; rm -f "$dest_tmp"; exit 1; }
  mv "$dest_tmp" "$hook"  || { echo "ERROR: failed to move hook into place" >&2; rm -f "$dest_tmp"; exit 1; }
}
compose_with_block() {  # emit $1's content with our block inserted right after a leading shebang
  local f="$1"
  head -1 "$f"; block_text; tail -n +2 "$f"
}

if [ "$uninstall" -eq 1 ]; then
  if [ ! -f "$hook" ]; then echo "No pre-push hook present — nothing to uninstall."; exit 0; fi
  if ! grep -qF "$BEGIN" "$hook"; then echo "No payment-contract-tester block found — leaving hook untouched."; exit 0; fi
  if ! validate_block "$hook"; then
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

# --- build the new hook content into $tmp (bailing safe on anything we cannot compose cleanly) ---
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if [ ! -f "$hook" ]; then
  { printf '#!/usr/bin/env bash\n'; block_text; } >"$tmp"
else
  # An existing executable hook may be in any language; we only compose into a known SHELL hook —
  # injecting shell syntax into a python/node/ruby/etc. hook would corrupt it.
  if ! is_shell_hook "$hook"; then
    cat <<EOF
The existing pre-push hook is not a shell script:
    $(head -1 "$hook")
Composing shell syntax into it would corrupt it, so nothing was modified. Add a step that runs the
payment-test subset by hand (before any early exit), invoking with PCT_TEST_CMD set:

    PCT_TEST_CMD='<your subset command>' "$HOOKBODY"
EOF
    exit 0
  fi
  # If EITHER marker is present, require a single well-formed block before touching it — this catches
  # an orphan END (no BEGIN) too, which would otherwise leave a stuck state for future un/reinstall.
  if grep -qF "$BEGIN" "$hook" || grep -qF "$END" "$hook"; then
    if ! validate_block "$hook"; then
      echo "Existing payment-contract-tester markers are malformed (missing, duplicated, or out of order) — manual cleanup required, nothing modified." >&2
      exit 0
    fi
    stripped=$(mktemp); strip_block "$hook" >"$stripped"
    compose_with_block "$stripped" >"$tmp"; rm -f "$stripped"
  else
    compose_with_block "$hook" >"$tmp"
  fi
fi

# all bail conditions passed — now (and only now) record the command and install atomically
if [ -n "$testcmd" ]; then
  printf 'PCT_TEST_CMD=%s\n' "$testcmd" >"$conf" || { echo "ERROR: failed writing $conf" >&2; exit 1; }
fi
write_hook "$tmp"
echo "Installed payment-contract-tester pre-push hook at $hook"
echo "  (convenience only — CI is the authoritative gate; bypass with: git push --no-verify)"
exit 0
