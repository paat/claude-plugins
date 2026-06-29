#!/usr/bin/env bash
# Unit + integration proofs for codex-run.sh.
# No real codex calls: a stub `codex` on PATH simulates each scenario.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/codex-run.sh"
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" == "$3" ]; then echo "PASS  $1"; else
    echo "FAIL  $1: expected [$2] got [$3]"; fail=1; fi
}
contains() { # contains <name> <needle> <haystack>
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS  $1"; else
    echo "FAIL  $1: [$3] does not contain [$2]"; fail=1; fi
}

# --- Dispatch / arg handling (executed, not sourced) ---
"$SCRIPT" --help >/dev/null 2>&1;            check "help exits 0" 0 "$?"
"$SCRIPT" --bogus </dev/null >/dev/null 2>&1; check "unknown option exits 2" 2 "$?"
"$SCRIPT" "" </dev/null >/dev/null 2>&1;      check "empty prompt exits 2" 2 "$?"

# --- cs_build_cmd via --print-cmd ---
cmd="$("$SCRIPT" --print-cmd -C /repo -m gpt-5.5 -s danger-full-access)"
contains "print-cmd has danger-full-access" "danger-full-access" "$cmd"
contains "print-cmd has skip-git-repo-check" "--skip-git-repo-check" "$cmd"
contains "print-cmd has -C dir"              "/repo"               "$cmd"
contains "print-cmd has model"               "gpt-5.5"             "$cmd"
check "print-cmd ends with stdin dash" "-" "$(printf '%s' "$cmd" | tail -1)"
# No model => no -m line.
nomodel="$("$SCRIPT" --print-cmd -C /repo)"
check "no model => no -m" 0 "$(printf '%s\n' "$nomodel" | grep -c -- '^-m$')"

# --- Source for pure-function unit tests ---
source "$SCRIPT"
set +e  # sourced script enabled errexit; keep the runner resilient

# cs_extract_final_answer: text after the LAST "tokens used" marker.
out="$(printf 'reading files...\ntokens used: 50\nthinking\ntokens used: 120\nFINAL LINE A\nFINAL LINE B\n' | cs_extract_final_answer)"
check "extract after last marker" "$(printf 'FINAL LINE A\nFINAL LINE B')" "$out"
# No marker => passthrough unchanged.
out="$(printf 'just an answer\nno marker here\n' | cs_extract_final_answer)"
check "extract passthrough when no marker" "$(printf 'just an answer\nno marker here')" "$out"

# cs_detect_bwrap
tmp="$(mktemp)"
printf 'bwrap: Failed to make / slave: Permission denied\n' > "$tmp"
cs_detect_bwrap "$tmp"; check "detect bwrap perm-denied" 0 "$?"
printf 'all good, no sandbox issue\n' > "$tmp"
cs_detect_bwrap "$tmp"; check "no bwrap => nonzero" 1 "$?"
rm -f "$tmp"

# --- Integration: stub codex on PATH ---
stubdir="$(mktemp -d)"
make_stub() { cat > "$stubdir/codex"; chmod +x "$stubdir/codex"; }
run() { PATH="$stubdir:$PATH" "$SCRIPT" "$@"; }

# (a) Happy path: stub writes the clean final message to its -o file.
make_stub <<'STUB'
#!/usr/bin/env bash
ofile=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && ofile="$2"; shift; done
echo "streaming reasoning noise..."; echo "tokens used: 99"
[ -n "$ofile" ] && printf 'CLEAN FINAL MESSAGE\n' > "$ofile"
exit 0
STUB
got="$(run -C /tmp "do a thing" 2>/dev/null)"
check "happy path prints clean final message" "CLEAN FINAL MESSAGE" "$got"

# (b) Fallback: stub ignores -o; wrapper tail-parses the stream.
make_stub <<'STUB'
#!/usr/bin/env bash
echo "noise"; echo "tokens used: 5"; echo "TAIL PARSED ANSWER"
exit 0
STUB
got="$(run -C /tmp "x" 2>/dev/null)"
check "fallback tail-parses stream" "TAIL PARSED ANSWER" "$got"

# (c) bwrap failure: stub prints the bwrap error and exits nonzero.
make_stub <<'STUB'
#!/usr/bin/env bash
echo "bwrap: Failed to make / slave: Permission denied" >&2
exit 1
STUB
err="$(run -C /tmp "x" 2>&1 >/dev/null)"; rc=$?
check "bwrap path returns 1" 1 "$rc"
contains "bwrap remedy mentions danger-full-access" "-s danger-full-access" "$err"

# (d) Timeout: stub sleeps; tiny --timeout forces a kill (exit 124/143).
make_stub <<'STUB'
#!/usr/bin/env bash
sleep 10
STUB
err="$(run -C /tmp -t 1 "x" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then echo "PASS  timeout exits 124/143 (got $rc)"; else
  echo "FAIL  timeout exits 124/143: got $rc"; fail=1; fi
contains "timeout surfaces recovery steps" "git -C" "$err"

# (e) codex missing: empty PATH dir, no codex binary.
emptydir="$(mktemp -d)"
PATH="$emptydir" "$SCRIPT" -C /tmp "x" >/dev/null 2>&1
check "missing codex exits 127" 127 "$?"

rm -rf "$stubdir" "$emptydir"
echo
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$fail"
