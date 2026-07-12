#!/usr/bin/env bash
# merge-guard tests: real git repos, real ranges. Exit non-zero on mismatch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MG="$PLUGIN/scripts/merge-guard.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkrepo() {
  R="$(mktemp -d)"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.invalid
  git -C "$R" config user.name t
  printf 'app\n' > "$R/app.txt"
  mkdir -p "$R/src/checkout"
  printf 'checkout with utm_source param\n' > "$R/src/checkout/pay.js"
  git -C "$R" add -A && git -C "$R" commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
}
run() { (cd "$R" && bash "$MG" "$@"); }

# Clean merge: only intended source change.
mkrepo
printf 'app v2\n' > "$R/app.txt"
git -C "$R" commit -qam change
clean_check() { run check --base "$BASE" | grep -q "clean"; }
t "clean range reports clean, exit 0" clean_check

# Junk leak: editor droppings + agent artifacts added in range.
mkrepo
printf 'x\n' > "$R/.DS_Store"; printf 'y\n' > "$R/debug.log"
mkdir -p "$R/.startup"; printf 's\n' > "$R/.startup/state.json"
printf 'legit\n' > "$R/feature.txt"
git -C "$R" add -A -f && git -C "$R" commit -qm leak
junk_flagged() {
  out="$(run check --base "$BASE")"; rc=$?
  [ "$rc" -eq 3 ] &&
  printf '%s' "$out" | grep -q ".DS_Store" &&
  printf '%s' "$out" | grep -q "debug.log" &&
  printf '%s' "$out" | grep -q ".startup/state.json" &&
  ! printf '%s' "$out" | grep -q "feature.txt"
}
t "junk additions flagged (exit 3), legit file not flagged" junk_flagged

# Pre-existing junk-looking files are not the merge's leak.
mkrepo
printf 'old\n' > "$R/notes.log"
git -C "$R" add -f notes.log && git -C "$R" commit -qm oldjunk
BASE="$(git -C "$R" rev-parse HEAD)"
printf 'old v2\n' > "$R/notes.log"
git -C "$R" commit -qam touch-old
preexisting_ok() { run check --base "$BASE" | grep -q "clean"; }
t "modified pre-existing junk-named file is not flagged" preexisting_ok

# Intended-file: unintended path flagged.
mkrepo
printf 'app v2\n' > "$R/app.txt"; printf 'stray\n' > "$R/stray.txt"
git -C "$R" add -A && git -C "$R" commit -qm mixed
printf 'app.txt\n' > "$R/intended.txt"
unintended_flagged() {
  out="$(run check --base "$BASE" --intended-file intended.txt)"; rc=$?
  [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "UNINTENDED change: stray.txt" &&
  ! printf '%s' "$out" | grep -q "UNINTENDED change: app.txt"
}
t "unintended path flagged against intended globs" unintended_flagged

# Invariants: present-invariant violation when the pattern is removed.
mkrepo
mkdir -p "$R/.claude"
cat > "$R/.claude/merge-guard.json" <<'JSON'
{"invariants":[
  {"id":"attribution","path_glob":"src/checkout/*","pattern":"utm_source|click_id","must":"present",
   "message":"conversion attribution must survive checkout changes"},
  {"id":"no-debugger","path_glob":"src/*","pattern":"debugger;","must":"absent",
   "message":"no debugger statements on main"}
]}
JSON
git -C "$R" add -A && git -C "$R" commit -qm cfg
BASE="$(git -C "$R" rev-parse HEAD)"
printf 'checkout without the param\n' > "$R/src/checkout/pay.js"
git -C "$R" commit -qam drop-param
invariant_present_violated() {
  out="$(run check --base "$BASE")"; rc=$?
  [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "INVARIANT attribution VIOLATED" &&
  printf '%s' "$out" | grep -q "conversion attribution"
}
t "dropped attribution pattern violates present-invariant" invariant_present_violated
git -C "$R" revert -n HEAD >/dev/null 2>&1 && git -C "$R" commit -qm restore
printf 'debugger;\n' >> "$R/src/checkout/pay.js"
git -C "$R" commit -qam add-debugger
invariant_absent_violated() {
  out="$(run check --base "$BASE")"; rc=$?
  [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "INVARIANT no-debugger VIOLATED"
}
t "forbidden pattern violates absent-invariant" invariant_absent_violated

# extra_junk and not_junk config.
mkrepo
mkdir -p "$R/.claude" "$R/docs/decisions"
printf '{"extra_junk":["scratch-*"],"not_junk":["docs/decisions/*"]}\n' > "$R/.claude/merge-guard.json"
git -C "$R" add -A && git -C "$R" commit -qm cfg
BASE="$(git -C "$R" rev-parse HEAD)"
printf 'x\n' > "$R/scratch-1.txt"
printf 'kept\n' > "$R/docs/decisions/adr.log"
git -C "$R" add -A && git -C "$R" commit -qm extras
extra_junk_config() {
  out="$(run check --base "$BASE")"; rc=$?
  [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "scratch-1.txt" &&
  ! printf '%s' "$out" | grep -q "adr.log"
}
t "extra_junk flags, not_junk exempts" extra_junk_config

# Cleanup dry-run prints, does not mutate; nothing-to-clean exits 3.
mkrepo
printf 'x\n' > "$R/.DS_Store"
git -C "$R" add -f .DS_Store && git -C "$R" commit -qm leak
cleanup_dry() {
  out="$(run cleanup --base "$BASE")"; rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "would remove" &&
  [ -f "$R/.DS_Store" ] && [ "$(git -C "$R" branch --list 'cleanup/*' | wc -l)" -eq 0 ]
}
t "cleanup dry-run prints and mutates nothing" cleanup_dry
mkrepo
printf 'v2\n' > "$R/app.txt"; git -C "$R" commit -qam clean
cleanup_nothing() { run cleanup --base "$BASE"; [ $? -eq 3 ]; }
t "cleanup with nothing to clean exits 3" cleanup_nothing

# Usage errors.
mkrepo
usage_no_base() { run check; [ $? -eq 2 ]; }
t "missing --base exits 2" usage_no_base
usage_bad_ref() { run check --base deadbeef123; [ $? -eq 2 ]; }
t "unknown ref exits 2" usage_bad_ref

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
