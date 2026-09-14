#!/usr/bin/env bash
# Unit + integration proofs for subagent-local-qwen3.8-27b-run.sh.
# No live llama.cpp: stub qwen + curl on PATH.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/subagent-local-qwen3.8-27b-run.sh"
IMPLEMENT_CONTRACT="$HERE/../references/implement-contract.md"
REVIEW_CONTRACT="$HERE/../references/review-contract.md"
IMPLEMENT_COMMAND="$HERE/../commands/subagent-local-qwen3.8-27b-implement.md"
REVIEW_COMMAND="$HERE/../commands/subagent-local-qwen3.8-27b-review.md"
SKILL="$HERE/../skills/subagent-local-qwen3.8-27b/SKILL.md"
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

# --- Help / arg handling ---
help="$("$SCRIPT" --help)";                   check "help exits 0" 0 "$?"
contains "help documents yolo" "--yolo" "$help"
contains "help documents approval-mode" "--approval-mode" "$help"
contains "help documents print-cmd" "--print-cmd" "$help"
check "help hides implementation" 0 "$(printf '%s\n' "$help" | grep -c 'set -euo pipefail')"
"$SCRIPT" --bogus </dev/null >/dev/null 2>&1; check "unknown option exits 2" 2 "$?"
"$SCRIPT" --effort high --print-cmd >/dev/null 2>&1; check "effort high exits 2" 2 "$?"
"$SCRIPT" --effort extreme --print-cmd >/dev/null 2>&1; check "unknown effort exits 2" 2 "$?"
"$SCRIPT" "" </dev/null >/dev/null 2>&1;      check "empty prompt exits 2" 2 "$?"

# --- print-cmd flags ---
cmd="$("$SCRIPT" --print-cmd -m Qwen3.8-27B-UD-Q6_K_XL-coding --yolo)"
contains "print-cmd has qwen" "qwen" "$cmd"
contains "print-cmd has model" "Qwen3.8-27B-UD-Q6_K_XL-coding" "$cmd"
contains "print-cmd has -o json" "json" "$cmd"
contains "print-cmd has Concise" "Concise" "$cmd"
contains "print-cmd excludes agent" "--exclude-tools" "$cmd"
contains "print-cmd has yolo" "--yolo" "$cmd"
contains "print-cmd has append-system-prompt" "--append-system-prompt" "$cmd"
contains "print-cmd appends implement contract needle" "bounded coding implementer for ONE named task" "$cmd"
# Contract must be one print-cmd line (newlines encoded as \n), not split across argv lines.
impl_prompt_line="$(printf '%s\n' "$cmd" | awk 'f{print; exit} /^--append-system-prompt$/{f=1}')"
contains "print-cmd implement contract line encodes newline" '\n' "$impl_prompt_line"
contains "print-cmd implement contract line has last bullet" \
  "Do not add features, abstractions, fallbacks, or comments that restate the code." \
  "$impl_prompt_line"
check "print-cmd has no approval-mode plan under yolo" 0 \
  "$(printf '%s\n' "$cmd" | grep -c -- '--approval-mode')"

plan_cmd="$("$SCRIPT" --print-cmd --approval-mode plan)"
contains "print-cmd plan mode" "--approval-mode" "$plan_cmd"
contains "print-cmd plan has plan value" "plan" "$plan_cmd"
check "print-cmd plan omits yolo" 0 "$(printf '%s\n' "$plan_cmd" | grep -cx -- '--yolo')"
contains "print-cmd appends review contract needle" "Read-only. Do not modify, stage, or commit." "$plan_cmd"
rev_prompt_line="$(printf '%s\n' "$plan_cmd" | awk 'f{print; exit} /^--append-system-prompt$/{f=1}')"
contains "print-cmd review contract line encodes newline" '\n' "$rev_prompt_line"
contains "print-cmd review contract line has Read-only" \
  "Read-only. Do not modify, stage, or commit." "$rev_prompt_line"
contains "print-cmd review contract line has verdict" \
  "APPROVE | NEEDS_WORK | BLOCK" "$rev_prompt_line"

# --- Contract / README needles (must stay one line) ---
impl_c="$(<"$IMPLEMENT_CONTRACT")"
rev_c="$(<"$REVIEW_CONTRACT")"
readme="$(<"$README")"
skill="$(<"$SKILL")"
impl_cmd="$(<"$IMPLEMENT_COMMAND")"
rev_cmd="$(<"$REVIEW_COMMAND")"
contains "implement contract ONE named task" "bounded coding implementer for ONE named task" "$impl_c"
contains "implement contract no agent tool" "Do not push, open PRs, or call the agent/subagent tool." "$impl_c"
contains "review contract read-only line" "Read-only. Do not modify, stage, or commit." "$rev_c"
contains "review contract verdict line" "End with one line: APPROVE | NEEDS_WORK | BLOCK." "$rev_c"
contains "README bound model Qwen3.8-27B" "Qwen3.8-27B" "$readme"
contains "README naming pattern" "subagent-local-<modelname>-<version>" "$readme"
contains "README documents qwen CLI" "qwen" "$readme"
contains "README documents curl" "curl" "$readme"
contains "README documents jq" "jq" "$readme"
contains "README Installation Install for you" "Install for you" "$readme"
contains "README Installation collaborators" "Install for all collaborators on this repository" "$readme"
contains "README Installation repo only" "Install for you, in this repo only" "$readme"
contains "skill keeps built-in prompt" 'never `--system-prompt` replace' "$skill"
contains "implement command calls wrapper" "subagent-local-qwen3.8-27b-run.sh" "$impl_cmd"
contains "review command uses plan mode" "--approval-mode plan" "$rev_cmd"

# --- Source helpers ---
# shellcheck disable=SC1090
source "$SCRIPT"
set +e

out="$(printf '%s' '[{"type":"message"},{"type":"result","result":"FINAL FROM JSON"}]' | ql_extract_final_answer)"
check "extract JSON array last result" "FINAL FROM JSON" "$out"

out="$(printf '%s\n' 'not json at all' 'TAIL FALLBACK' | ql_extract_final_answer)"
contains "extract fallback keeps raw" "TAIL FALLBACK" "$out"

ql_is_coding_profile "Qwen3.8-27B-UD-Q6_K_XL-coding"; check "coding profile ok" 0 "$?"
ql_is_coding_profile "Qwen3.8-27B-UD-Q6_K_XL-longctx"; check "longctx refused" 1 "$?"
ql_is_coding_profile "other-model"; check "other model refused" 1 "$?"

# Executed argv rebuild: contract after --append-system-prompt is one element with real newlines.
impl_argv=()
while IFS= read -r -d '' arg; do impl_argv+=("$arg"); done < <(
  ql_build_cmd "Qwen3.8-27B-UD-Q6_K_XL-coding" "yolo" "40" "15m" "$(cat "$IMPLEMENT_CONTRACT")"
)
impl_next=""
for ((i = 0; i < ${#impl_argv[@]}; i++)); do
  if [ "${impl_argv[$i]}" = "--append-system-prompt" ]; then
    impl_next="${impl_argv[$((i + 1))]:-}"
    break
  fi
done
check "implement argv next has real newline" 1 \
  "$(printf '%s' "$impl_next" | grep -q $'\n' && echo 1 || echo 0)"
contains "implement argv next has ONE named task" "ONE named task" "$impl_next"
contains "implement argv next has comments that restate the code" \
  "comments that restate the code" "$impl_next"

rev_argv=()
while IFS= read -r -d '' arg; do rev_argv+=("$arg"); done < <(
  ql_build_cmd "Qwen3.8-27B-UD-Q6_K_XL-coding" "plan" "40" "15m" "$(cat "$REVIEW_CONTRACT")"
)
rev_next=""
for ((i = 0; i < ${#rev_argv[@]}; i++)); do
  if [ "${rev_argv[$i]}" = "--append-system-prompt" ]; then
    rev_next="${rev_argv[$((i + 1))]:-}"
    break
  fi
done
check "review argv next has real newline" 1 \
  "$(printf '%s' "$rev_next" | grep -q $'\n' && echo 1 || echo 0)"
contains "review argv next has Read-only" "Read-only" "$rev_next"
contains "review argv next has verdict" "APPROVE | NEEDS_WORK | BLOCK" "$rev_next"

# --- Integration stubs ---
stubdir="$(mktemp -d)"
host_qwen_dir="$(mktemp -d)"
mkdir -p "$host_qwen_dir/.qwen"
printf '%s\n' '{"host":"marker-do-not-touch"}' > "$host_qwen_dir/.qwen/settings.json"
host_settings_before="$(cat "$host_qwen_dir/.qwen/settings.json")"

make_qwen() { cat > "$stubdir/qwen"; chmod +x "$stubdir/qwen"; }
make_curl() { cat > "$stubdir/curl"; chmod +x "$stubdir/curl"; }

# Default healthy models response.
make_curl <<'CURL'
#!/usr/bin/env bash
# Emulate: curl -sS -m 5 -w '\n%{http_code}' URL
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -sS|-s|--silent) shift ;;
    -m) shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */models)
    printf '%s\n' '{"data":[{"id":"Qwen3.8-27B-UD-Q6_K_XL-coding"}]}'
    printf '%s\n' '200'
    ;;
  *)
    printf '%s\n' 'not found' >&2
    printf '%s\n' '404'
    exit 0
    ;;
esac
CURL

run() {
  HOME="$host_qwen_dir" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
    PATH="$stubdir:$PATH" "$SCRIPT" "$@"
}

# (a) Happy path + isolated HOME + stdin prompt + yolo
make_qwen <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  echo "Usage: qwen --yolo --approval-mode"
  exit 0
fi
# Record argv + whether prompt arrived on stdin; emit JSON result.
printf '%s\n' "$@" > "${QL_STUB_ARGV:-/tmp/ql-stub-argv}"
if [ ! -t 0 ]; then
  cat > "${QL_STUB_STDIN:-/tmp/ql-stub-stdin}"
else
  : > "${QL_STUB_STDIN:-/tmp/ql-stub-stdin}"
fi
# Prove isolated HOME: must be a temp dir containing our settings, not host.
printf '%s\n' "$HOME" > "${QL_STUB_HOME:-/tmp/ql-stub-home}"
if [ -f "$HOME/.qwen/settings.json" ]; then
  cp "$HOME/.qwen/settings.json" "${QL_STUB_SETTINGS:-/tmp/ql-stub-settings}"
fi
printf '%s\n' '[{"type":"result","result":"CLEAN FINAL MESSAGE"}]'
exit 0
STUB

argv_file="$(mktemp)"; stdin_file="$(mktemp)"; home_file="$(mktemp)"; settings_file="$(mktemp)"
got="$(
  QL_STUB_ARGV="$argv_file" QL_STUB_STDIN="$stdin_file" \
  QL_STUB_HOME="$home_file" QL_STUB_SETTINGS="$settings_file" \
  run -C /tmp --yolo <<'PROMPT' 2>/dev/null
do a thing from stdin
PROMPT
)"
check "happy path prints JSON result" "CLEAN FINAL MESSAGE" "$got"
contains "stdin delivered prompt" "do a thing from stdin" "$(cat "$stdin_file")"
check "argv does not carry giant prompt" 0 \
  "$(grep -c 'do a thing from stdin' "$argv_file" || true)"
contains "yolo flag passed" "--yolo" "$(tr '\n' ' ' <"$argv_file")"
check "host ~/.qwen/settings.json unchanged" "$host_settings_before" \
  "$(cat "$host_qwen_dir/.qwen/settings.json")"
iso_home="$(cat "$home_file")"
check "isolated HOME differs from host" 1 \
  "$([ "$iso_home" != "$host_qwen_dir" ] && echo 1 || echo 0)"
contains "isolated settings has modelProviders" "modelProviders" "$(cat "$settings_file")"
contains "isolated settings enable_thinking" "enable_thinking" "$(cat "$settings_file")"
contains "isolated settings reasoning_effort medium" '"reasoning_effort": "medium"' "$(cat "$settings_file")"

# (b) approval-mode plan
make_qwen <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  echo "Usage: qwen --yolo --approval-mode"
  exit 0
fi
printf '%s\n' "$@" > /tmp/ql-stub-argv-plan
printf '%s\n' '[{"type":"result","result":"REVIEW OK"}]'
exit 0
STUB
got="$(run -C /tmp --approval-mode plan "review please" 2>/dev/null)"
check "plan mode prints result" "REVIEW OK" "$got"
contains "plan flag passed" "--approval-mode" "$(tr '\n' ' ' </tmp/ql-stub-argv-plan)"
contains "plan value passed" "plan" "$(tr '\n' ' ' </tmp/ql-stub-argv-plan)"
check "plan mode omits yolo" 0 "$(grep -cx -- '--yolo' /tmp/ql-stub-argv-plan || true)"

# (c) missing qwen → 127
rm -f "$stubdir/qwen"
PATH="$stubdir:$PATH" HOME="$host_qwen_dir" OPENAI_BASE_URL="http://127.0.0.1:9/v1" \
  "$SCRIPT" -C /tmp "x" >/dev/null 2>&1
check "missing qwen exits 127" 127 "$?"

# Restore qwen stub for later tests
make_qwen <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  echo "Usage: qwen --yolo --approval-mode"
  exit 0
fi
exit 0
STUB

# (d) down preflight
make_curl <<'CURL'
#!/usr/bin/env bash
echo "connection refused" >&2
exit 7
CURL
err="$(run -C /tmp "x" 2>&1 >/dev/null)"; rc=$?
check "down preflight non-zero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
contains "down message" "down or unreachable" "$err"

# (e) wrong-model (longctx only)
make_curl <<'CURL'
#!/usr/bin/env bash
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -sS|-s|--silent) shift ;;
    -m) shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' '{"data":[{"id":"Qwen3.8-27B-UD-Q6_K_XL-longctx"}]}'
printf '%s\n' '200'
CURL
err="$(run -C /tmp "x" 2>&1 >/dev/null)"; rc=$?
check "wrong-model preflight non-zero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
contains "wrong-model message" "wrong-model" "$err"

# (f) busy
make_curl <<'CURL'
#!/usr/bin/env bash
printf '%s\n' 'server busy'
printf '%s\n' '503'
CURL
err="$(run -C /tmp "x" 2>&1 >/dev/null)"; rc=$?
check "busy preflight non-zero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
contains "busy message" "busy" "$err"

# Restore healthy curl + sleeping qwen for timeout
make_curl <<'CURL'
#!/usr/bin/env bash
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -sS|-s|--silent) shift ;;
    -m) shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' '{"data":[{"id":"Qwen3.8-27B-UD-Q6_K_XL-coding"}]}'
printf '%s\n' '200'
CURL
make_qwen <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  echo "Usage: qwen --yolo --approval-mode"
  exit 0
fi
sleep 10
STUB
err="$(run -C /tmp -t 1 "x" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then echo "PASS  timeout exits 124/143 (got $rc)"; else
  echo "FAIL  timeout exits 124/143: got $rc"; fail=1; fi
contains "timeout surfaces recovery steps" "git -C" "$err"

# Host settings still untouched after all runs
check "host settings still unchanged at end" "$host_settings_before" \
  "$(cat "$host_qwen_dir/.qwen/settings.json")"

# (g) old qwen without --yolo in --help
make_qwen <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  echo "Usage: qwen (old)"
  exit 0
fi
exit 0
STUB
make_curl <<'CURL'
#!/usr/bin/env bash
printf '%s\n' '{"data":[{"id":"Qwen3.8-27B-UD-Q6_K_XL-coding"}]}'
printf '%s\n' '200'
CURL
err="$(run -C /tmp "x" 2>&1 >/dev/null)"; rc=$?
check "old qwen exits 127" 127 "$rc"
contains "old qwen asks for 0.23.4" "install Qwen Code >= 0.23.4" "$err"

rm -rf "$stubdir" "$host_qwen_dir" "$argv_file" "$stdin_file" "$home_file" "$settings_file"
echo
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$fail"
