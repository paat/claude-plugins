#!/usr/bin/env bash
# Issue #743: scratch input paths in files_examined must not fail the pinned-tree check.
# Issue #726: Grok T3 default inspect budget must be at least 60 turns, with a timeout that can finish them.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$PLUGIN_ROOT/scripts/lib.sh"
fail=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name" >&2
    fail=1
  fi
}

approve_json() {
  local examined="$1"
  jq -nc --argjson examined "$examined" \
    '{provider:"claude",model:"fixture",files_examined:$examined,findings:[],
      summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"}}'
}

init_repo() {
  local work="$1"
  git -C "$work" init -q
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf 'base\n' > "$work/changed.txt"
  git -C "$work" add changed.txt
  git -C "$work" commit -q -m base
  printf 'head\n' > "$work/changed.txt"
  git -C "$work" commit -q -am head
}

stamp_case() {
  local work="$1" examined="$2" input_dir="${3:-}"
  (
    cd "$work"
    # shellcheck disable=SC1090
    . "$LIB"
    if [ -n "$input_dir" ]; then
      TRIBUNAL_REVIEW_INPUT_DIR="$input_dir"
      export TRIBUNAL_REVIEW_INPUT_DIR
    else
      unset TRIBUNAL_REVIEW_INPUT_DIR
    fi
    approve_json "$examined" | tribunal_stamp_diff_stat "$STAT" > "$work/out.json"
  )
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
init_repo "$work"
(
  cd "$work"
  # shellcheck disable=SC1090
  . "$LIB"
  TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/range.diff"
  tribunal_take_diff_stat "$work/range.diff" > "$work/stat.json"
)
STAT="$(cat "$work/stat.json")"
input="$(mktemp -d "$work/input.XXXXXX")"
mkdir -p "$input/input"
printf 'diff\n' > "$input/input/review.diff"
printf 'context\n' > "$input/input/context.md"
scratch_diff="$input/input/review.diff"
scratch_context="$input/input/context.md"
other="$(mktemp -d "$work/other.XXXXXX")"
mkdir -p "$other/input"
printf 'other\n' > "$other/input/review.diff"
foreign="$other/input/review.diff"

examined="$(jq -nc --arg diff "$scratch_diff" --arg ctx "$scratch_context" '[$diff,$ctx,"changed.txt"]')"
stamp_case "$work" "$examined" "$input/input"
check "scratch input paths are stripped and the leg stays ok" \
  jq -e --argjson stat "$STAT" \
    '(has("error") | not) and .diff_stat==$stat and .files_examined==["changed.txt"]' \
    "$work/out.json"

examined="$(jq -nc --arg diff "$scratch_diff" '[$diff,"invented.txt"]')"
stamp_case "$work" "$examined" "$input/input"
check "a genuinely absent repo path is still excluded" \
  jq -e '.error | contains("invented.txt") and contains("paths absent")' "$work/out.json"

examined="$(jq -nc --arg foreign "$foreign" '["changed.txt",$foreign]')"
stamp_case "$work" "$examined" "$input/input"
check "another runner input dir is not treated as this leg scratch" \
  jq -e --arg foreign "$foreign" '.error | contains($foreign)' "$work/out.json"

examined="$(jq -nc --arg diff "$scratch_diff" '[$diff,"changed.txt"]')"
stamp_case "$work" "$examined" ""
check "scratch paths still fail when the runner did not declare an input dir" \
  jq -e --arg diff "$scratch_diff" '.error | contains($diff)' "$work/out.json"

for runner in "$PLUGIN_ROOT"/scripts/run-*-review.sh; do
  check "$(basename "$runner") declares the shared review input dir" \
    grep -q 'tribunal_prepare_review_input' "$runner"
done

leg_repo="$(mktemp -d "$work/leg.XXXXXX")"
init_repo "$leg_repo"
fake="$(mktemp -d "$work/fake.XXXXXX")"
timeout_bin="$(command -v timeout)"

cat > "$fake/timeout" <<EOF
#!/usr/bin/env bash
seconds=""
i=0
args=("\$@")
while [ "\$i" -lt "\${#args[@]}" ]; do
  case "\${args[\$i]}" in
    -k) i=\$((i + 2)); continue ;;
    --) i=\$((i + 1)); break ;;
    -*) i=\$((i + 1)); continue ;;
    *) seconds="\${args[\$i]}"; i=\$((i + 1)); break ;;
  esac
done
if [ -n "\${TIMEOUT_LOG:-}" ]; then printf '%s\n' "\$seconds" >> "\$TIMEOUT_LOG"; fi
exec "\${args[@]:\$i}"
EOF
chmod +x "$fake/timeout"

cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
prompt="$(cat)"
diff="$(printf '%s\n' "$prompt" | sed -n 's/^Diff file: //p' | head -n 1)"
jq -nc --arg diff "$diff" '{result:({provider:"claude",model:"fixture",files_examined:[$diff,"changed.txt"],findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"}}|tojson)}'
EOF
chmod +x "$fake/claude"

host_grok="$(mktemp -d "$work/grok-home.XXXXXX")"
mkdir -p "$host_grok"
jq -nc '{"https://auth.x.ai::fixture":{key:"access-fixture",refresh_token:"refresh-fixture",expires_at:"2099-01-01T00:00:00Z",auth_mode:"oidc"}}' > "$host_grok/auth.json"
chmod 600 "$host_grok/auth.json"

cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$GROK_ARGS"
prompt=""
prev=""
for arg in "$@"; do
  if [ "$prev" = --prompt-file ]; then prompt="$arg"; fi
  prev="$arg"
done
diff="$(sed -n 's/^Diff file: //p' "$prompt" | head -n 1)"
jq -nc --arg diff "$diff" '{structuredOutput:{provider:"grok",model:"fixture",files_examined:[$diff,"changed.txt"],findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"}},modelUsage:{"grok-fixture":{}}}'
EOF
chmod +x "$fake/grok"

run_claude() {
  local out="$1"
  (
    cd "$leg_repo"
    env -u TRIBUNAL_REVIEW_INPUT_DIR -u TRIBUNAL_CLAUDE_EFFORT -u TRIBUNAL_CLAUDE_MODEL \
      PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_NATIVE_REVIEW=off \
      bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$out"
  )
}

run_grok() {
  local out="$1"
  shift
  : > "$work/grok.args"
  : > "$work/timeouts"
  (
    cd "$leg_repo"
    env -u XAI_API_KEY -u TRIBUNAL_REVIEW_INPUT_DIR -u TRIBUNAL_GROK_EFFORT -u TRIBUNAL_GROK_MODEL \
      -u TRIBUNAL_GROK_MAX_TURNS -u TRIBUNAL_GROK_TIMEOUT_SECONDS \
      PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_ARGS="$work/grok.args" TIMEOUT_LOG="$work/timeouts" \
      TRIBUNAL_BASE_REF=HEAD~1 \
      "$@" bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$out"
  )
}

run_claude "$work/claude.json"
check "claude leg stays ok when files_examined names its scratch diff" \
  jq -e '(has("error") | not) and .summary.verdict=="APPROVE" and .files_examined==["changed.txt"] and ([.files_examined[] | startswith("/")] | any | not)' \
    "$work/claude.json"

run_grok "$work/grok.json" TRIBUNAL_RISK=T3
check "grok leg stays ok when files_examined names its scratch diff" \
  jq -e '(has("error") | not) and .summary.verdict=="APPROVE" and .files_examined==["changed.txt"]' \
    "$work/grok.json"
check "grok T3 default inspect turns are at least 60" \
  awk 'p=="--max-turns" && $0+0>=60 { found=1 } { p=$0 } END { exit !found }' "$work/grok.args"
check "grok T3 default inspect timeout can finish 60 turns" \
  awk 'NR==1 && $1+0>=2400 { ok=1 } END { exit !ok }' "$work/timeouts"

run_grok "$work/grok-override.json" TRIBUNAL_RISK=T3 TRIBUNAL_GROK_MAX_TURNS=4 TRIBUNAL_GROK_TIMEOUT_SECONDS=90
check "explicit grok turn and timeout overrides still win at T3" \
  awk 'p=="--max-turns" && $0=="4" { turns=1 } { p=$0 } END { exit !turns }' "$work/grok.args"
check "explicit grok timeout override is not replaced by the T3 default" \
  awk 'NR==1 && $1=="90" { ok=1 } END { exit !ok }' "$work/timeouts"

run_grok "$work/grok-t2.json"
check "non-T3 grok inspect budget stays 30 turns and 600 seconds" \
  awk 'p=="--max-turns" && $0=="30" { turns=1 } { p=$0 } END { exit !turns }' "$work/grok.args"
check "non-T3 grok inspect timeout stays 600 seconds" \
  awk 'NR==1 && $1=="600" { ok=1 } END { exit !ok }' "$work/timeouts"

exit "$fail"
