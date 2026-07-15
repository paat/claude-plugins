#!/usr/bin/env bash
# Unit + integration proofs for codex-run.sh.
# No real codex calls: a stub `codex` on PATH simulates each scenario.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/codex-run.sh"
IMPLEMENT_COMMAND="$HERE/../commands/codex-implement.md"
REVIEW_COMMAND="$HERE/../commands/codex-review.md"
REVIEW_AGENT="$HERE/../agents/codex-reviewer.md"
CONTROLLER_SKILL="$HERE/../skills/codex-subagent-driven-development/SKILL.md"
README="$HERE/../README.md"
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
help="$("$SCRIPT" --help)";                   check "help exits 0" 0 "$?"
contains "help documents effort" "--effort LEVEL" "$help"
check "help omits sandbox selector" 0 "$(printf '%s\n' "$help" | grep -c -- '--sandbox')"
check "help hides implementation" 0 "$(printf '%s\n' "$help" | grep -c 'set -euo pipefail')"
"$SCRIPT" --bogus </dev/null >/dev/null 2>&1; check "unknown option exits 2" 2 "$?"
"$SCRIPT" --sandbox danger-full-access </dev/null >/dev/null 2>&1; check "sandbox override exits 2" 2 "$?"
"$SCRIPT" "" </dev/null >/dev/null 2>&1;      check "empty prompt exits 2" 2 "$?"

# --- cs_build_cmd via --print-cmd ---
cmd="$("$SCRIPT" --print-cmd -C /repo -m gpt-5.6-terra -e medium)"
contains "print-cmd has exact bypass" "--dangerously-bypass-approvals-and-sandbox" "$cmd"
check "print-cmd has no sandbox selector" 0 "$(printf '%s\n' "$cmd" | grep -cx -- '-s')"
contains "print-cmd has skip-git-repo-check" "--skip-git-repo-check" "$cmd"
contains "print-cmd has -C dir"              "/repo"               "$cmd"
contains "print-cmd has model"               "gpt-5.6-terra"       "$cmd"
contains "print-cmd has effort"              'model_reasoning_effort="medium"' "$cmd"
check "print-cmd ends with stdin dash" "-" "$(printf '%s' "$cmd" | tail -1)"

defaults="$("$SCRIPT" --print-cmd -C /repo)"
contains "default model is pinned" "gpt-5.6-sol" "$defaults"
contains "default effort is pinned" 'model_reasoning_effort="high"' "$defaults"

env_defaults="$(CODEX_SUBAGENT_MODEL=gpt-5.6-terra CODEX_SUBAGENT_EFFORT=low "$SCRIPT" --print-cmd -C /repo)"
contains "environment overrides model" "gpt-5.6-terra" "$env_defaults"
contains "environment overrides effort" 'model_reasoning_effort="low"' "$env_defaults"

# --- Prompt scope and convergence contracts ---
implement_contract="$(<"$IMPLEMENT_COMMAND")"
review_contract="$(<"$REVIEW_COMMAND")"
review_agent_contract="$(<"$REVIEW_AGENT")"
controller_contract="$(<"$CONTROLLER_SKILL")"
readme_contract="$(<"$README")"
contains "implement defaults routine work to medium" 'else `medium`' "$implement_contract"
contains "implement quarantines adjacent issues" 'do not investigate or fix them' "$implement_contract"
contains "implement stops after commit and report" 'complete the required commit and report, then stop' "$implement_contract"
contains "controller permits one correction" 'at most one targeted correction' "$controller_contract"
contains "review defaults routine work to medium" 'else `medium`' "$review_contract"
contains "controller applies review scope rules" 'same target, evidence, causation, and adjacency limits' "$review_contract"
contains "review accepts build and contract evidence" 'failing build/test' "$review_contract"
contains "review does not audit the tree" 'do not audit the tree' "$review_contract"
contains "standalone reviewer pins medium" '--effort medium' "$review_agent_contract"
contains "standalone reviewer uses the evidence gate" 'failing build/test' "$review_agent_contract"
contains "review keeps semantic read-only contract" 'do NOT modify, stage, or commit anything' "$review_contract"
contains "reviewer keeps semantic read-only contract" 'do NOT modify, stage, or commit anything' "$review_agent_contract"
contains "controller fixes unrestricted posture" 'execution posture is not configurable' "$controller_contract"
contains "README names container boundary" 'development container is the security boundary' "$readme_contract"

# --- Source for pure-function unit tests ---
source "$SCRIPT"
set +e  # sourced script enabled errexit; keep the runner resilient

# cs_extract_final_answer: text after the LAST "tokens used" marker.
out="$(printf 'reading files...\ntokens used: 50\nthinking\ntokens used: 120\nFINAL LINE A\nFINAL LINE B\n' | cs_extract_final_answer)"
check "extract after last marker" "$(printf 'FINAL LINE A\nFINAL LINE B')" "$out"
# No marker => passthrough unchanged.
out="$(printf 'just an answer\nno marker here\n' | cs_extract_final_answer)"
check "extract passthrough when no marker" "$(printf 'just an answer\nno marker here')" "$out"

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

# (c) Subprocess failure propagates without a sandbox retry path.
make_stub <<'STUB'
#!/usr/bin/env bash
echo "provider unavailable" >&2
exit 1
STUB
err="$(run -C /tmp "x" 2>&1 >/dev/null)"; rc=$?
check "subprocess failure returns 1" 1 "$rc"
contains "failure footer records exit" "codex-run: exit 1" "$err"

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
