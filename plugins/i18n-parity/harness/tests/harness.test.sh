#!/usr/bin/env bash
# Self-tests for the harness: idempotent install + CI snippet sanity.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/.."
fail=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q

# install once, then again -> must be idempotent (single marker).
( cd "$tmp" && "$HARNESS/install-pre-push.sh" >/dev/null 2>&1 )
( cd "$tmp" && "$HARNESS/install-pre-push.sh" >/dev/null 2>&1 )
count="$(grep -cF '# >>> i18n-parity pre-push >>>' "$tmp/.git/hooks/pre-push" 2>/dev/null || echo 99)"
if [ "$count" -eq 1 ]; then echo "PASS  idempotent install"; else echo "FAIL  install not idempotent (markers=$count)"; fail=1; fi

# CI snippets reference the engine entrypoint.
if grep -q "i18n-parity.py" "$HARNESS/ci/github-actions.yml" && grep -q "i18n-parity.py" "$HARNESS/ci/gitlab-ci.yml"; then
  echo "PASS  CI snippets reference engine"
else
  echo "FAIL  CI snippets missing engine reference"; fail=1
fi

# README documents CI-as-authoritative.
if grep -qi "authoritative" "$HARNESS/README.md"; then echo "PASS  README marks CI authoritative"; else echo "FAIL  README missing authoritative note"; fail=1; fi

# --- pre-push stdin/range handling + exit propagation ---
ENGINE_DIR="$(cd "$HARNESS/../scripts" && pwd)"
ZERO="0000000000000000000000000000000000000000"
HASH="1111111111111111111111111111111111111111"

ppx="$(mktemp -d)"
git -C "$ppx" init -q
mkdir -p "$ppx/scripts" "$ppx/messages"
cp "$ENGINE_DIR/i18n-parity.py" "$ENGINE_DIR/i18n-parity.sh" "$ppx/scripts/"
chmod +x "$ppx/scripts/i18n-parity.sh" "$ppx/scripts/i18n-parity.py"
cat > "$ppx/.i18n-parity.json" <<'JSON'
{ "primaryLocale": "et", "locales": ["et", "en"], "catalogs": [{ "pattern": "messages/{locale}.json" }] }
JSON
# et has 'b', en does not -> a real parity violation (the gate must exit 1 when it runs).
printf '{"a":"x","b":"y"}\n' > "$ppx/messages/et.json"
printf '{"a":"x"}\n'         > "$ppx/messages/en.json"

# new branch (remote sha all-zero) -> ambiguous range -> fail-safe: run gate -> exit 1
rc=$( cd "$ppx" && printf 'refs/heads/main %s refs/heads/main %s\n' "$HASH" "$ZERO" | "$HARNESS/pre-push.sh" >/dev/null 2>&1; echo $? )
if [ "$rc" -eq 1 ]; then echo "PASS  pre-push new-branch fail-safe runs gate"; else echo "FAIL  pre-push new-branch expected 1, got $rc"; fail=1; fi

# empty stdin -> nothing parsed -> fail-safe: run gate -> exit 1
rc=$( cd "$ppx" && printf '' | "$HARNESS/pre-push.sh" >/dev/null 2>&1; echo $? )
if [ "$rc" -eq 1 ]; then echo "PASS  pre-push empty-stdin fail-safe runs gate"; else echo "FAIL  pre-push empty-stdin expected 1, got $rc"; fail=1; fi

# branch deletion (local sha all-zero) -> nothing to check -> exit 0
rc=$( cd "$ppx" && printf 'refs/heads/main %s refs/heads/main %s\n' "$ZERO" "$HASH" | "$HARNESS/pre-push.sh" >/dev/null 2>&1; echo $? )
if [ "$rc" -eq 0 ]; then echo "PASS  pre-push deletion is a no-op"; else echo "FAIL  pre-push deletion expected 0, got $rc"; fail=1; fi

# no config in repo -> gate skipped entirely -> exit 0
rm -f "$ppx/.i18n-parity.json"
rc=$( cd "$ppx" && printf 'refs/heads/main %s refs/heads/main %s\n' "$HASH" "$ZERO" | "$HARNESS/pre-push.sh" >/dev/null 2>&1; echo $? )
if [ "$rc" -eq 0 ]; then echo "PASS  pre-push no-config is a no-op"; else echo "FAIL  pre-push no-config expected 0, got $rc"; fail=1; fi
rm -rf "$ppx"

[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "SOME RED"
exit "$fail"
