#!/usr/bin/env bash
# Install/merge the i18n-parity pre-push gate into this repo's hooks.
set -eu

ROOT="$(git rev-parse --show-toplevel)"
HOOK_DIR="$(git config core.hooksPath || true)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="$ROOT/.git/hooks"
mkdir -p "$HOOK_DIR"
HOOK="$HOOK_DIR/pre-push"
SELF="$(cd "$(dirname "$0")" && pwd)"
MARK="# >>> i18n-parity pre-push >>>"
END="# <<< i18n-parity pre-push <<<"

BLOCK="$MARK
\"$SELF/pre-push.sh\" < /dev/stdin || exit \$?
$END"

if [ -f "$HOOK" ] && grep -qF "$MARK" "$HOOK"; then
  echo "i18n-parity: pre-push block already present in $HOOK"
  exit 0
fi

if [ ! -f "$HOOK" ]; then
  printf '#!/usr/bin/env bash\n%s\n' "$BLOCK" > "$HOOK"
else
  printf '\n%s\n' "$BLOCK" >> "$HOOK"
fi
chmod +x "$HOOK"
echo "i18n-parity: installed pre-push gate into $HOOK"
