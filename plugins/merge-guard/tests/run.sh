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

# Junk leak: universally safe built-ins added in range.
mkrepo
printf 'x\n' > "$R/.DS_Store"; printf 'y\n' > "$R/debug.log"
printf 'legit\n' > "$R/feature.txt"
git -C "$R" add -A -f && git -C "$R" commit -qm leak
junk_flagged() {
  out="$(run check --base "$BASE")"; rc=$?
  [ "$rc" -eq 3 ] &&
  printf '%s' "$out" | grep -q ".DS_Store" &&
  printf '%s' "$out" | grep -q "debug.log" &&
  ! printf '%s' "$out" | grep -q "feature.txt"
}
t "junk additions flagged (exit 3), legit file not flagged" junk_flagged

# .startup contains both durable project knowledge and runtime state. The
# directory alone is never a junk signal; target repos can name narrow runtime
# paths through extra_junk.
mkrepo
mkdir -p "$R/.startup/workflows" "$R/.startup/laws"
printf 'workflow\n' > "$R/.startup/workflows/WORKFLOW-billing.md"
printf 'law snapshot\n' > "$R/.startup/laws/vat.txt"
git -C "$R" add -A && git -C "$R" commit -qm durable-startup
startup_durable_ok() {
  run check --base "$BASE" | grep -q "clean"
}
t "durable .startup workflow and law artifacts are clean" startup_durable_ok

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

# extra_junk and not_junk config, including explicit runtime leakage.
mkrepo
mkdir -p "$R/.claude" "$R/docs/decisions" "$R/.startup/reviews"
printf '{"extra_junk":["scratch-*",".startup/reviews/*"],"not_junk":["docs/decisions/*"]}\n' > "$R/.claude/merge-guard.json"
git -C "$R" add -A && git -C "$R" commit -qm cfg
BASE="$(git -C "$R" rev-parse HEAD)"
printf 'x\n' > "$R/scratch-1.txt"
printf 'kept\n' > "$R/docs/decisions/adr.log"
printf 'runtime review\n' > "$R/.startup/reviews/handoff-1.md"
git -C "$R" add -A && git -C "$R" commit -qm extras
extra_junk_config() {
  out="$(run check --base "$BASE")"; rc=$?
  [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "scratch-1.txt" &&
  printf '%s' "$out" | grep -q ".startup/reviews/handoff-1.md" &&
  ! printf '%s' "$out" | grep -q "adr.log"
}
t "extra_junk flags explicit runtime paths, not_junk exempts" extra_junk_config

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

# Unintended DELETION is a change too.
mkrepo
printf 'app v2\n' > "$R/app.txt"
git -C "$R" rm -q src/checkout/pay.js && git -C "$R" commit -qam del
printf 'app.txt\n' > "$R/intended.txt"
deletion_flagged() {
  out="$(run check --base "$BASE" --intended-file intended.txt)"; rc=$?
  [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q "UNINTENDED change: src/checkout/pay.js"
}
t "unintended deletion flagged" deletion_flagged

# Junk filename with spaces survives reporting intact.
mkrepo
printf 'x\n' > "$R/My Draft.tmp"
git -C "$R" add -f "My Draft.tmp" && git -C "$R" commit -qm space-junk
space_junk() {
  out="$(run check --base "$BASE")"; rc=$?
  [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -qF "  My Draft.tmp"
}
t "junk path with spaces reported intact" space_junk

# Malformed config and invalid invariant regex fail loudly, never false-clean.
mkrepo
mkdir -p "$R/.claude"; printf '{broken' > "$R/.claude/merge-guard.json"
malformed_cfg() { run check --base "$BASE"; [ $? -eq 1 ]; }
t "malformed config exits 1" malformed_cfg
printf '{"invariants":[{"id":"bad","pattern":"([unclosed","must":"absent"}]}\n' > "$R/.claude/merge-guard.json"
git -C "$R" add -A >/dev/null 2>&1
bad_regex() { run check --base "$BASE"; [ $? -eq 1 ]; }
t "invalid invariant regex exits 1 (never false-clean)" bad_regex

# cleanup --apply end-to-end against a local bare origin and a stub gh;
# gh failure must still leave the branch pushed and report exit 1.
mkrepo
ORIGIN="$(mktemp -d)"; git init -q --bare "$ORIGIN"
git -C "$R" remote add origin "$ORIGIN"
printf 'x\n' > "$R/.DS_Store"
git -C "$R" add -f .DS_Store && git -C "$R" commit -qm leak
STUB="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "$STUB/gh"; chmod +x "$STUB/gh"
git -C "$R" branch -M main
CB="cleanup/merge-guard-$(git -C "$R" rev-parse --short main)"
apply_flow() {
  (cd "$R" && PATH="$STUB:$PATH" bash "$MG" cleanup --base "$BASE" --apply) &&
  git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$CB" >/dev/null &&
  ! git -C "$ORIGIN" cat-file -e "$CB:.DS_Store" 2>/dev/null
}
t "cleanup --apply removes junk on a pushed branch" apply_flow
rm -rf "$ORIGIN" "$STUB"

# Partial failure restores the original branch (push fails: no remote).
mkrepo
printf 'x\n' > "$R/.DS_Store"
git -C "$R" add -f .DS_Store && git -C "$R" commit -qm leak
git -C "$R" branch -M main
STUB="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "$STUB/gh"; chmod +x "$STUB/gh"
apply_restore() {
  (cd "$R" && PATH="$STUB:$PATH" bash "$MG" cleanup --base "$BASE" --apply)
  rc=$?
  [ "$rc" -eq 1 ] &&
  [ "$(git -C "$R" branch --show-current)" = "main" ] &&
  [ -z "$(git -C "$R" branch --list 'cleanup/*' | tr -d ' ')" ] &&
  [ -f "$R/.DS_Store" ]
}
t "cleanup failure restores the original branch" apply_restore
rm -rf "$STUB"

# Usage errors.
mkrepo
usage_no_base() { run check; [ $? -eq 2 ]; }
t "missing --base exits 2" usage_no_base
usage_bad_ref() { run check --base deadbeef123; [ $? -eq 2 ]; }
t "unknown ref exits 2" usage_bad_ref

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
