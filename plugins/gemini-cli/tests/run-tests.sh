#!/usr/bin/env bash
# Unit tests for scripts/run-agy.sh against a fake agy.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run-agy.sh"
PASS=0 FAIL=0
check() { if [ "$1" -eq 0 ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fake="$work/bin" state="$work/state" home="$work/home"
mkdir -p "$fake" "$state" "$home/.gemini/antigravity-cli" "$work/repo"
printf 'token\n' > "$home/.gemini/antigravity-cli/antigravity-oauth-token"
printf 'SECRET_LINE_42\n' > "$work/repo/code.py"
cat > "$fake/agy" <<FAKE
#!/usr/bin/env bash
dir="\$HOME/.gemini/antigravity-cli"
cp "\$dir/settings.json" "$state/settings.json"
[ ! -f "\$dir/antigravity-oauth-token" ] || : > "$state/token-staged"
printf '%s\n' "\$HOME" > "$state/home"
pwd -P > "$state/cwd"
printf '%s\n' "\$*" > "$state/args"
env > "$state/env"
jq -r 'select(.event=="user") | .message.content' > "$state/prompt"
case "\$(cat "$state/mode" 2>/dev/null || echo ok)" in
  ok) jq -nc '{event:"result",result:{status:"SUCCESS",response:"FAKE ANSWER"}}' ;;
  error) jq -nc '{event:"result",result:{status:"ERROR",response:"",error:("model exploded\n" + ("x" * 200000))}}'; exit 1 ;;
  stderr) echo "boom: quota exhausted" >&2; exit 1 ;;
  empty) jq -nc '{event:"result",result:{status:"SUCCESS",response:"  \n"}}' ;;
esac
FAKE
chmod +x "$fake/agy"
run() { (cd "$work/repo" && env -u GEMINI_API_KEY HOME="$home" PATH="$fake:$PATH" "$@"); }

# Signed-in success: isolated home, sterile cwd, full deny policy, file inlined via stdin.
out="$(run GEMINI_API_KEY=unused bash "$RUNNER" --model m1 --file code.py -- "Review it" 2>/dev/null)"; rc=$?
ok=0
[ "$rc" -eq 0 ] && [ "$out" = "FAKE ANSWER" ] || ok=1
jq -e '.permissions.deny==["read_file(*)","write_file(*)","command(*)","read_url(*)","execute_url(*)","mcp(*)"] and (.permissions.allow==null) and (has("modelProvider")|not)' "$state/settings.json" >/dev/null || ok=1
[ -e "$state/token-staged" ] && [ "$(cat "$state/home")" != "$home" ] || ok=1
case "$(cat "$state/cwd")" in "$(cd "$work/repo" && pwd -P)"*) ok=1 ;; esac
grep -q '^Review it$' "$state/prompt" && grep -q '^=== FILE: code.py ===$' "$state/prompt" && grep -q '^SECRET_LINE_42$' "$state/prompt" || ok=1
grep -q -- '--model m1 --input-format stream-json --output-format stream-json' "$state/args" || ok=1
! grep -q '^GEMINI_API_KEY=' "$state/env" || ok=1
check "$ok" "signed-in run is isolated, read-only, and inlines files"

# API-key mode when no token.
rm -f "$home/.gemini/antigravity-cli/antigravity-oauth-token" "$state/token-staged"
run GEMINI_API_KEY=key bash "$RUNNER" -- "hi" >/dev/null 2>&1; rc=$?
ok=0
[ "$rc" -eq 0 ] && jq -e '.modelProvider=="gemini"' "$state/settings.json" >/dev/null \
  && grep -q '^GEMINI_API_KEY=key$' "$state/env" && [ ! -e "$state/token-staged" ] || ok=1
check "$ok" "API-key mode passes the key and sets modelProvider"

# Not signed in: exit 4 before agy runs.
rm -f "$state/args"
run bash "$RUNNER" -- "hi" >/dev/null 2>"$work/err"; rc=$?
ok=0; [ "$rc" -eq 4 ] && [ ! -e "$state/args" ] && grep -q 'not signed in' "$work/err" || ok=1
check "$ok" "missing sign-in exits 4 without calling agy"

printf 'token\n' > "$home/.gemini/antigravity-cli/antigravity-oauth-token"

# Provider error: exit 3 with a one-line reason, no stdout.
echo error > "$state/mode"
out="$(run bash "$RUNNER" -- "hi" 2>"$work/err")"; rc=$?
ok=0; [ "$rc" -eq 3 ] && [ -z "$out" ] && [ "$(wc -l < "$work/err")" -eq 1 ] && grep -q 'model exploded' "$work/err" || ok=1
check "$ok" "large multi-line provider error exits 3 with a one-line reason"

# No result event: the reason falls back to agy stderr.
echo stderr > "$state/mode"
run bash "$RUNNER" -- "hi" >/dev/null 2>"$work/err"; rc=$?
ok=0; [ "$rc" -eq 3 ] && grep -q 'boom: quota exhausted' "$work/err" && ! grep -q 'null' "$work/err" || ok=1
check "$ok" "stderr-only failure reports the agy stderr reason"

# Whitespace-only response counts as failure.
echo empty > "$state/mode"
run bash "$RUNNER" -- "hi" >/dev/null 2>&1; rc=$?
ok=0; [ "$rc" -eq 3 ] || ok=1
check "$ok" "empty response exits 3"

rm -f "$state/mode"

# Usage errors and unreadable files exit 2.
ok=0
run bash "$RUNNER" >/dev/null 2>&1; [ $? -eq 2 ] || ok=1
run bash "$RUNNER" --timeout 5 -- "hi" >/dev/null 2>&1; [ $? -eq 2 ] || ok=1
run bash "$RUNNER" --file missing.txt -- "hi" >/dev/null 2>&1; [ $? -eq 2 ] || ok=1
run bash "$RUNNER" --timeout 090 -- "hi" >/dev/null 2>&1; [ $? -eq 2 ] || ok=1
check "$ok" "usage errors and unreadable files exit 2"

# A file that fails mid-read (after the pre-check) aborts instead of sending partial input.
printf 'two\n' > "$work/repo/two.py"
printf '#!/bin/bash\n[ "$2" = code.py ] && exit 1\nexec /usr/bin/cat "$@"\n' > "$fake/cat"; chmod +x "$fake/cat"
rm -f "$state/args"
run bash "$RUNNER" --file code.py --file two.py -- "hi" >/dev/null 2>&1; rc=$?
rm -f "$fake/cat"
ok=0; [ "$rc" -eq 2 ] && [ ! -e "$state/args" ] || ok=1
check "$ok" "mid-read file failure exits 2 without calling agy"

# Missing agy exits 4.
(cd "$work/repo" && env HOME="$home" PATH="/usr/bin:/bin" bash "$RUNNER" -- "hi" >/dev/null 2>&1); rc=$?
ok=0; [ "$rc" -eq 4 ] || ok=1
check "$ok" "missing agy exits 4"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
