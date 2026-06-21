#!/usr/bin/env bash
# i18n-parity pre-push convenience gate (NOT authoritative — CI is the real gate).
# Resolves repo root, honours $I18N_PARITY_CONFIG, and only runs when a configured
# catalog or the config file itself changed in the pushed range. Fail-safe: when the
# range is ambiguous (new branch / no merge-base), run the full gate rather than skip.
set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
CONFIG="${I18N_PARITY_CONFIG:-$ROOT/.i18n-parity.json}"
[ -f "$CONFIG" ] || exit 0   # no config in this repo -> nothing to gate

WRAPPER="$ROOT/scripts/i18n-parity.sh"
[ -x "$WRAPPER" ] || WRAPPER="$ROOT/plugins/i18n-parity/scripts/i18n-parity.sh"
[ -x "$WRAPPER" ] || { echo "i18n-parity: wrapper not found; skipping pre-push gate." >&2; exit 0; }

run_gate() { "$WRAPPER" --config "$CONFIG" --root "$ROOT"; exit $?; }

z="0000000000000000000000000000000000000000"
changed=""
ran_any=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -z "${local_sha:-}" ] && continue
  ran_any=1
  if [ "$local_sha" = "$z" ]; then
    continue                       # branch deletion -> nothing to check
  fi
  if [ "$remote_sha" = "$z" ]; then
    run_gate                       # new branch -> ambiguous range -> fail-safe: run
  fi
  if ! range_files="$(git diff --name-only "$remote_sha" "$local_sha" 2>/dev/null)"; then
    run_gate                       # no merge-base / bad range -> fail-safe: run
  fi
  changed="$changed$range_files"$'\n'
done

[ "$ran_any" -eq 0 ] && run_gate   # nothing parsed from stdin -> fail-safe

# Run only if a catalog-ish or the config path changed. Heuristic: config filename,
# or any path containing 'messages/' or 'locales/' or 'i18n'.
if printf '%s' "$changed" | grep -Eq '(\.i18n-parity\.json|messages/|locales/|i18n)'; then
  run_gate
fi
exit 0
