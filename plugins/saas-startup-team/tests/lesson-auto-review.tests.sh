#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
AUTO="$PLUGIN_ROOT/scripts/lesson-auto-review.sh"
REVIEW="$PLUGIN_ROOT/scripts/lesson-review.sh"
BINDING="$PLUGIN_ROOT/scripts/lesson-review-binding.sh"
SCHEMA="$PLUGIN_ROOT/references/schemas/lesson-auto-review.schema.json"
DESIGN="$PLUGIN_ROOT/docs/design/self-improvement-loop.md"
REPO="owner/repo"
PASS=0
FAIL=0
WORKS=()

# shellcheck source=../scripts/lesson-review-binding.sh
. "$BINDING"

cleanup() {
  local dir
  for dir in "${WORKS[@]}"; do rm -rf -- "$dir"; done
}
trap cleanup EXIT

pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (expected '$3', got '$2')"; }
assert_contains() { grep -Fq -- "$3" "$2" && pass "$1" || fail "$1 (missing '$3')"; }
assert_not_contains() { ! grep -Fq -- "$3" "$2" && pass "$1" || fail "$1 (found '$3')"; }
assert_count() {
  local count
  count="$(find "$2" -maxdepth 1 -type f -name "$3" | wc -l | tr -d ' ')"
  assert_eq "$1" "$count" "$4"
}

verdict() {
  local file="$1" decision="$2" confidence="$3" generic="${4:-true}"
  local actionable="${5:-true}" safe="${6:-true}" testable="${7:-true}"
  jq -n --arg decision "$decision" --argjson confidence "$confidence" \
    --argjson generic "$generic" --argjson actionable "$actionable" \
    --argjson safe "$safe" --argjson testable "$testable" '
      {schema_version:1, decision:$decision, confidence:$confidence,
       generic:$generic, actionable:$actionable, safe:$safe,
       acceptance_testable:$testable, rationale:"bounded rationale"}
    ' > "$file"
}

candidates() {
  local file="$1" count="$2" i
  printf '[' > "$file"
  for ((i=1; i<=count; i++)); do
    [ "$i" -eq 1 ] || printf ',' >> "$file"
    jq -cn --argjson n "$i" \
      '{number:$n,title:("candidate " + ($n|tostring)),body:"body",updatedAt:"2026-07-17T00:00:00Z"}' >> "$file"
  done
  printf ']\n' >> "$file"
}

setup_auto() {
  CASE="$(mktemp -d)"
  WORKS+=("$CASE")
  mkdir -p "$CASE/bin" "$CASE/log" "$CASE/opus" "$CASE/sol" "$CASE/tmp"
  : > "$CASE/log/helper"
  : > "$CASE/log/timeout"
  printf '0\n' > "$CASE/log/claude.count"
  printf '0\n' > "$CASE/log/codex.count"

  cat > "$CASE/bin/lesson-review" <<'MOCK'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$MOCK_LOG/helper"
printf '\n' >> "$MOCK_LOG/helper"
if [ "${1:-}" = --list ]; then
  [ "${MOCK_LIST_RC:-0}" -eq 0 ] || exit "$MOCK_LIST_RC"
  limit=3
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --limit ] && [ "$#" -ge 2 ]; then limit="$2"; break; fi
    shift
  done
  jq --argjson limit "$limit" '.[0:$limit]' "$MOCK_CANDIDATES"
  exit 0
fi
if [ "${MOCK_MUTATION_FAIL_ACTION:-}" = "${1:-}" ]; then exit 1; fi
exit 0
MOCK

  cat > "$CASE/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$MOCK_LOG/timeout"
printf '\n' >> "$MOCK_LOG/timeout"
shift 3
exec "$@"
MOCK

  cat > "$CASE/bin/claude" <<'MOCK'
#!/usr/bin/env bash
n=$(($(cat "$MOCK_LOG/claude.count") + 1))
printf '%s\n' "$n" > "$MOCK_LOG/claude.count"
printf '%q ' "$@" > "$MOCK_LOG/claude-$n.args"
printf '\n' >> "$MOCK_LOG/claude-$n.args"
pwd > "$MOCK_LOG/claude-$n.cwd"
prev=""
for arg in "$@"; do
  if [ "$prev" = --json-schema ]; then printf '%s\n' "$arg" > "$MOCK_LOG/claude-$n.schema"; fi
  prev="$arg"
done
cat > "$MOCK_LOG/claude-$n.prompt"
rc=0
[ ! -f "$MOCK_OPUS/$n.rc" ] || rc=$(cat "$MOCK_OPUS/$n.rc")
[ ! -f "$MOCK_OPUS/$n.out" ] || cat "$MOCK_OPUS/$n.out"
exit "$rc"
MOCK

  cat > "$CASE/bin/codex" <<'MOCK'
#!/usr/bin/env bash
n=$(($(cat "$MOCK_LOG/codex.count") + 1))
printf '%s\n' "$n" > "$MOCK_LOG/codex.count"
printf '%q ' "$@" > "$MOCK_LOG/codex-$n.args"
printf '\n' >> "$MOCK_LOG/codex-$n.args"
pwd > "$MOCK_LOG/codex-$n.cwd"
prev=""
last=""
for arg in "$@"; do
  if [ "$prev" = --output-last-message ]; then last="$arg"; fi
  if [ "$prev" = --output-schema ]; then printf '%s\n' "$arg" > "$MOCK_LOG/codex-$n.schema"; fi
  prev="$arg"
done
cat > "$MOCK_LOG/codex-$n.prompt"
rc=0
[ ! -f "$MOCK_SOL/$n.rc" ] || rc=$(cat "$MOCK_SOL/$n.rc")
if [ "$rc" -eq 0 ] && [ -f "$MOCK_SOL/$n.out" ]; then cp "$MOCK_SOL/$n.out" "$last"; fi
exit "$rc"
MOCK
  chmod 700 "$CASE/bin/lesson-review" "$CASE/bin/timeout" "$CASE/bin/claude" "$CASE/bin/codex"
  candidates "$CASE/candidates.json" 1
  RUN_RC=0
  RUN_OUT="$CASE/output"
}

run_auto() {
  RUN_RC=0
  PATH="$CASE/bin:$PATH" \
    TMPDIR="$CASE/tmp" \
    MOCK_LOG="$CASE/log" \
    MOCK_OPUS="$CASE/opus" \
    MOCK_SOL="$CASE/sol" \
    MOCK_CANDIDATES="$CASE/candidates.json" \
    MOCK_LIST_RC="${MOCK_LIST_RC:-0}" \
    MOCK_MUTATION_FAIL_ACTION="${MOCK_MUTATION_FAIL_ACTION:-}" \
    LESSON_AUTO_REVIEW_HELPER="$CASE/bin/lesson-review" \
    SAAS_PLUGIN_REPO='' \
    bash "$AUTO" --repo "$REPO" "$@" > "$RUN_OUT" 2>&1 || RUN_RC=$?
}

test_opus_decisive_and_limits() {
  assert_contains "design documents decisive Opus" "$DESIGN" \
    'high-confidence Opus approval or rejection is decisive without a second model'
  assert_contains "design documents conditional Sol arbitration" "$DESIGN" \
    'Sol/xhigh runs independently only when the Opus verdict is unresolved or structurally'
  assert_not_contains "design does not require redundant flagship agreement" "$DESIGN" \
    'High-confidence agreement approves or rejects'
  setup_auto
  candidates "$CASE/candidates.json" 4
  verdict "$CASE/opus/1.out" approve 0.90
  jq '{structured_output:.}' "$CASE/opus/1.out" > "$CASE/opus/1.wrapper"
  mv "$CASE/opus/1.wrapper" "$CASE/opus/1.out"
  verdict "$CASE/opus/2.out" reject 0.90 false false false false
  verdict "$CASE/opus/3.out" approve 1
  run_auto
  assert_eq "default limit succeeds" "$RUN_RC" 0
  assert_count "at most three fresh Opus calls" "$CASE/log" 'claude-*.args' 3
  assert_count "decisive Opus skips Sol" "$CASE/log" 'codex-*.args' 0
  assert_contains "list delegates with JSON" "$CASE/log/helper" '--list --json'
  assert_contains "list delegates default max" "$CASE/log/helper" '--limit 3'
  assert_contains "Claude JSON wrapper is extracted and approved" "$CASE/log/helper" '--approve 1'
  assert_contains "rejection invokes candidate-only helper" "$CASE/log/helper" '--auto-reject 2'
  expected_digest="$(jq -c '.[0]' "$CASE/candidates.json")"
  expected_digest="$(lesson_review_digest_json "$expected_digest")"
  assert_contains "mutation binds exact reviewed digest" "$CASE/log/helper" "--review-digest $expected_digest"
  assert_contains "every Opus call pins model" "$CASE/log/claude-1.args" '--model opus'
  assert_contains "every Opus call pins effort" "$CASE/log/claude-1.args" '--effort xhigh'
  assert_contains "Opus uses safe mode" "$CASE/log/claude-1.args" '--safe-mode'
  assert_contains "Opus has empty tools" "$CASE/log/claude-1.args" "--tools ''"
  assert_contains "Opus uses dontAsk" "$CASE/log/claude-1.args" '--permission-mode dontAsk'
  assert_contains "Opus is nonpersistent" "$CASE/log/claude-1.args" '--no-session-persistence'
  assert_contains "Opus bare mode disables ambient context" "$CASE/log/claude-1.args" '--bare'
  assert_contains "Opus disables project settings" "$CASE/log/claude-1.args" "--setting-sources ''"
  assert_contains "Opus has empty MCP config" "$CASE/log/claude-1.args" '--strict-mcp-config'
  assert_not_contains "Opus never resumes" "$CASE/log/claude-1.args" '--resume'
  assert_not_contains "Opus never continues" "$CASE/log/claude-1.args" '--continue'
  compact="$CASE/schema.compact"; jq -c . "$SCHEMA" > "$compact"
  cmp -s "$compact" "$CASE/log/claude-1.schema" && pass "Opus receives checked-in schema" || fail "Opus receives checked-in schema"
  assert_contains "fixed timeout wraps Opus" "$CASE/log/timeout" '180 claude'

  for invalid in 0 4 nope; do
    setup_auto
    run_auto --limit "$invalid"
    assert_eq "limit $invalid is rejected" "$RUN_RC" 2
    assert_count "limit $invalid launches no model" "$CASE/log" 'claude-*.args' 0
  done
}

test_sol_routes_and_flags() {
  setup_auto
  verdict "$CASE/opus/1.out" uncertain 0.95
  verdict "$CASE/sol/1.out" approve 0.90
  run_auto
  assert_eq "Sol approval succeeds" "$RUN_RC" 0
  assert_contains "Sol approval invokes approve" "$CASE/log/helper" '--approve 1'
  assert_contains "Sol skips git check" "$CASE/log/codex-1.args" '--skip-git-repo-check'
  assert_contains "Sol ignores user config" "$CASE/log/codex-1.args" '--ignore-user-config'
  assert_contains "Sol ignores rules" "$CASE/log/codex-1.args" '--ignore-rules'
  assert_contains "Sol is ephemeral" "$CASE/log/codex-1.args" '--ephemeral'
  assert_contains "Sol is read-only" "$CASE/log/codex-1.args" '--sandbox read-only'
  assert_contains "Sol model is exact" "$CASE/log/codex-1.args" '-m gpt-5.6-sol'
  assert_contains "Sol effort is exact" "$CASE/log/codex-1.args" 'model_reasoning_effort=\"xhigh\"'
  assert_contains "Sol shell tool is disabled" "$CASE/log/codex-1.args" '--disable shell_tool'
  assert_contains "Sol is in isolated temp cwd" "$CASE/log/codex-1.cwd" "$CASE/tmp/lesson-auto-review."
  assert_contains "fixed timeout wraps Sol" "$CASE/log/timeout" '180 codex'
  assert_eq "Sol receives schema path" "$(cat "$CASE/log/codex-1.schema")" "$SCHEMA"
  cmp -s "$CASE/log/claude-1.prompt" "$CASE/log/codex-1.prompt" \
    && pass "both providers receive the exact same prompt" || fail "both providers receive the exact same prompt"

  setup_auto
  verdict "$CASE/opus/1.out" approve 0.89
  verdict "$CASE/sol/1.out" reject 0.90 false false false false
  run_auto
  assert_eq "low-confidence Opus falls back to Sol reject" "$RUN_RC" 0
  assert_contains "valid Sol reject uses candidate-only transition" "$CASE/log/helper" '--auto-reject 1'

  setup_auto
  verdict "$CASE/opus/1.out" uncertain 1
  verdict "$CASE/sol/1.out" uncertain 1
  run_auto
  assert_eq "valid unresolved pair succeeds" "$RUN_RC" 0
  assert_contains "valid unresolved pair quarantines" "$CASE/log/helper" '--quarantine 1'
}

test_boolean_and_confidence_gates() {
  local field
  for field in generic actionable safe acceptance_testable; do
    setup_auto
    verdict "$CASE/opus/1.out" approve 0.99
    jq --arg field "$field" '.[$field] = false' "$CASE/opus/1.out" > "$CASE/opus/1.tmp"
    mv "$CASE/opus/1.tmp" "$CASE/opus/1.out"
    verdict "$CASE/sol/1.out" uncertain 0.5
    run_auto
    assert_count "$field=false invokes Sol" "$CASE/log" 'codex-*.args' 1
    assert_contains "$field=false cannot approve" "$CASE/log/helper" '--quarantine 1'
  done

  setup_auto
  verdict "$CASE/opus/1.out" approve 0.899999
  verdict "$CASE/sol/1.out" uncertain 0.5
  run_auto
  assert_count "confidence below .90 invokes Sol" "$CASE/log" 'codex-*.args' 1

  setup_auto
  verdict "$CASE/opus/1.out" approve 0.90
  run_auto
  assert_count "confidence exactly .90 is decisive" "$CASE/log" 'codex-*.args' 0
  assert_contains "exact threshold approves" "$CASE/log/helper" '--approve 1'
}

test_transport_and_malformed_fail_closed() {
  for rc in 7 124; do
    setup_auto
    printf '%s\n' "$rc" > "$CASE/opus/1.rc"
    run_auto
    [ "$RUN_RC" -ne 0 ] && pass "Opus rc=$rc reports nonzero retry" || fail "Opus rc=$rc reports nonzero retry"
    assert_count "Opus rc=$rc never invokes Sol" "$CASE/log" 'codex-*.args' 0
    assert_count "Opus rc=$rc never mutates" "$CASE/log" 'claude-*.args' 1
    assert_not_contains "Opus rc=$rc has no mutation helper" "$CASE/log/helper" '--approve'
    assert_contains "Opus rc=$rc reports retry" "$RUN_OUT" 'retry'
  done

  setup_auto
  candidates "$CASE/candidates.json" 2
  printf '7\n' > "$CASE/opus/1.rc"
  verdict "$CASE/opus/2.out" approve 1
  run_auto
  [ "$RUN_RC" -ne 0 ] && pass "batch with retry remains nonzero" || fail "batch with retry remains nonzero"
  assert_count "batch continues after per-candidate retry" "$CASE/log" 'claude-*.args' 2
  assert_contains "later candidate still mutates" "$CASE/log/helper" '--approve 2'

  setup_auto
  printf 'not-json\n' > "$CASE/opus/1.out"
  verdict "$CASE/sol/1.out" approve 0.99
  run_auto
  assert_eq "malformed successful Opus falls back" "$RUN_RC" 0
  assert_count "malformed successful Opus invokes Sol" "$CASE/log" 'codex-*.args' 1
  assert_contains "Sol can approve malformed Opus fallback" "$CASE/log/helper" '--approve 1'

  setup_auto
  verdict "$CASE/opus/1.out" uncertain 0.5
  printf 'bad-final\n' > "$CASE/sol/1.out"
  run_auto
  assert_eq "malformed successful Sol is resolved by quarantine" "$RUN_RC" 0
  assert_contains "malformed successful Sol quarantines" "$CASE/log/helper" '--quarantine 1'
  assert_not_contains "malformed successful Sol is not a transport retry" "$RUN_OUT" 'retry'

  setup_auto
  verdict "$CASE/opus/1.out" uncertain 0.5
  run_auto
  assert_eq "missing successful Sol result is resolved by quarantine" "$RUN_RC" 0
  assert_contains "missing successful Sol result quarantines" "$CASE/log/helper" '--quarantine 1'

  setup_auto
  verdict "$CASE/opus/1.out" uncertain 0.5
  printf '9\n' > "$CASE/sol/1.rc"
  run_auto
  [ "$RUN_RC" -ne 0 ] && pass "nonzero Sol is nonzero" || fail "nonzero Sol is nonzero"
  assert_not_contains "nonzero Sol leaves candidate unchanged" "$CASE/log/helper" '--quarantine'

  setup_auto
  jq -n '{schema_version:1,decision:"approve",confidence:1,generic:true,actionable:true,safe:true,acceptance_testable:true,rationale:"ok",extra:true}' > "$CASE/opus/1.out"
  verdict "$CASE/sol/1.out" reject 1
  run_auto
  assert_contains "extra Opus field is malformed and falls back" "$CASE/log/helper" '--auto-reject 1'

  setup_auto
  jq -n '{schema_version:1,decision:"approve",confidence:"1",generic:true,actionable:true,safe:true,acceptance_testable:true,rationale:"ok"}' > "$CASE/opus/1.out"
  printf 'also bad\n' > "$CASE/sol/1.out"
  run_auto
  assert_eq "wrong Opus type plus malformed successful Sol quarantines" "$RUN_RC" 0
  assert_contains "wrong types never approve and quarantine instead" "$CASE/log/helper" '--quarantine 1'

  setup_auto
  jq -n '{schema_version:1,decision:"approve",confidence:1,generic:true,actionable:true,safe:true,rationale:"missing acceptance_testable"}' > "$CASE/opus/1.out"
  verdict "$CASE/sol/1.out" reject 1
  run_auto
  assert_contains "missing Opus field is malformed and falls back" "$CASE/log/helper" '--auto-reject 1'

  setup_auto
  verdict "$CASE/opus/1.out" uncertain 0.5
  verdict "$CASE/sol/1.out" approve 1
  jq '.rationale = ("x" * 513)' "$CASE/sol/1.out" > "$CASE/sol/1.tmp"
  mv "$CASE/sol/1.tmp" "$CASE/sol/1.out"
  run_auto
  assert_eq "overlong successful Sol result quarantines fail-closed" "$RUN_RC" 0
  assert_contains "overlong final rationale never approves" "$CASE/log/helper" '--quarantine 1'
}

test_nonblocking_local_lock() {
  setup_auto
  verdict "$CASE/opus/1.out" approve 0.99
  local lock_dir lock_key lock_file
  lock_dir="$CASE/tmp/saas-lesson-auto-review-$(id -u)"
  mkdir -m 700 -- "$lock_dir"
  lock_key="$(printf '%s' "$REPO" | sha256sum | awk '{print $1}')"
  lock_file="$lock_dir/$lock_key.lock"
  exec 7>>"$lock_file"
  flock -n 7 || { fail "test fixture acquires auto-review lock"; return; }
  run_auto
  assert_eq "concurrent local review exits successfully without waiting" "$RUN_RC" 0
  assert_count "concurrent local review launches no model" "$CASE/log" 'claude-*.args' 0
  assert_not_contains "concurrent local review does not list or mutate" "$CASE/log/helper" '--list'
  assert_contains "concurrent local review reports skip" "$RUN_OUT" 'is active; skipped'
  flock -u 7
  exec 7>&-
  run_auto
  assert_count "released local lock permits review" "$CASE/log" 'claude-*.args' 1
  assert_contains "released local lock permits mutation" "$CASE/log/helper" '--approve 1'
}

test_dry_run_hostile_bounds_and_cleanup() {
  setup_auto
  marker="$CASE/SHOULD_NOT_EXIST"
  jq -n --arg marker "$marker" '[{
    number: 7,
    title: "--resume hostile",
    body: ("$(touch " + $marker + ") --model evil RAW_SECRET " + ("x" * 20000) + " TRUNCATED_TAIL"),
    updatedAt: "2026-07-17T00:00:00Z",
    comments: [{body:"COMMENT_SECRET"}],
    url: "URL_SECRET"
  }]' > "$CASE/candidates.json"
  verdict "$CASE/opus/1.out" uncertain 0.5
  verdict "$CASE/sol/1.out" approve 0.99
  run_auto --dry-run
  assert_eq "dry-run succeeds" "$RUN_RC" 0
  assert_count "dry-run still calls Opus" "$CASE/log" 'claude-*.args' 1
  assert_count "dry-run still calls Sol" "$CASE/log" 'codex-*.args' 1
  assert_not_contains "dry-run performs no mutation" "$CASE/log/helper" '--approve'
  [ ! -e "$marker" ] && pass "hostile issue text cannot execute" || fail "hostile issue text cannot execute"
  assert_not_contains "hostile issue is not an Opus CLI arg" "$CASE/log/claude-1.args" '--model evil'
  assert_not_contains "hostile issue is not a Sol CLI arg" "$CASE/log/codex-1.args" '--model evil'
  assert_not_contains "comments are excluded from prompt" "$CASE/log/claude-1.prompt" 'COMMENT_SECRET'
  assert_not_contains "URLs are excluded from prompt" "$CASE/log/claude-1.prompt" 'URL_SECRET'
  assert_contains "complete body tail reaches the model" "$CASE/log/claude-1.prompt" 'TRUNCATED_TAIL'
  envelope_bytes="$(sed -n '/BEGIN UNTRUSTED ISSUE JSON DATA/{n;p;q;}' "$CASE/log/claude-1.prompt" | wc -c | tr -d ' ')"
  [ "$envelope_bytes" -le 131072 ] && pass "complete issue envelope stays bounded" || fail "complete issue envelope stays bounded ($envelope_bytes)"
  assert_not_contains "raw issue text is absent from logs" "$RUN_OUT" 'RAW_SECRET'
  assert_not_contains "raw model rationale is absent from logs" "$RUN_OUT" 'bounded rationale'
  assert_count "private workspace is cleaned" "$CASE/tmp" 'lesson-auto-review.*' 0

  setup_auto
  jq -n '[{number:8,title:"oversized",body:("x" * 131072),updatedAt:"2026-07-17T00:00:00Z"}]' \
    > "$CASE/candidates.json"
  run_auto
  [ "$RUN_RC" -ne 0 ] && pass "oversized complete content remains queued" || fail "oversized complete content remains queued"
  assert_count "oversized content launches no partial review" "$CASE/log" 'claude-*.args' 0
}

test_mutation_failure_and_strict_schema() {
  setup_auto
  verdict "$CASE/opus/1.out" approve 0.99
  MOCK_MUTATION_FAIL_ACTION=--approve
  run_auto
  unset MOCK_MUTATION_FAIL_ACTION
  [ "$RUN_RC" -ne 0 ] && pass "helper mutation failure is nonzero" || fail "helper mutation failure is nonzero"
  assert_contains "helper mutation failure is reported" "$RUN_OUT" 'mutation failed'

  setup_auto
  MOCK_LIST_RC=1
  run_auto
  unset MOCK_LIST_RC
  [ "$RUN_RC" -ne 0 ] && pass "listing helper failure is nonzero" || fail "listing helper failure is nonzero"
  assert_count "listing helper failure launches no models" "$CASE/log" 'claude-*.args' 0

  jq -e '
    .additionalProperties == false
    and (.required | length == 8)
    and .properties.rationale.maxLength == 512
    and .properties.decision.enum == ["approve", "reject", "uncertain"]
    and .properties.confidence.minimum == 0
    and .properties.confidence.maximum == 1
  ' "$SCHEMA" >/dev/null \
    && pass "checked-in schema is strict and bounded" || fail "checked-in schema is strict and bounded"
  schema_refs="$(grep -c -- 'SCHEMA_FILE' "$AUTO")"
  [ "$schema_refs" -ge 3 ] && pass "one schema source is shared by both providers" || fail "one schema source is shared by both providers"
}

setup_gh() {
  GH_CASE="$(mktemp -d)"
  WORKS+=("$GH_CASE")
  mkdir -p "$GH_CASE/bin"
  : > "$GH_CASE/gh.log"
  cat > "$GH_CASE/bin/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$GH_LOG"
printf '\n' >> "$GH_LOG"
if [ "${1:-} ${2:-}" = 'issue view' ]; then
  if [ -f "$GH_CLOSE_MARKER" ] && [ -n "${GH_VIEW_AFTER_JSON:-}" ]; then
    printf '%s\n' "$GH_VIEW_AFTER_JSON"
  else
    printf '%s\n' "$GH_VIEW_JSON"
  fi
fi
if [ "${1:-} ${2:-}" = 'issue close' ]; then : > "$GH_CLOSE_MARKER"; fi
if [ "${GH_FAIL_ON:-}" = "${1:-} ${2:-}" ]; then exit 1; fi
exit 0
MOCK
  chmod 700 "$GH_CASE/bin/gh"
}

review_issue() {
  local state="$1" labels="$2" comments="${3:-[]}"
  jq -cn --arg state "$state" --argjson labels "$labels" --argjson comments "$comments" \
    '{state:$state,labels:$labels,title:"candidate",body:"body",updatedAt:"2026-07-17T00:00:00Z",comments:$comments}'
}

run_review() {
  REVIEW_RC=0
  PATH="$GH_CASE/bin:$PATH" GH_LOG="$GH_CASE/gh.log" GH_CLOSE_MARKER="$GH_CASE/closed" \
    GH_VIEW_JSON="$GH_VIEW_JSON" GH_VIEW_AFTER_JSON="${GH_VIEW_AFTER_JSON:-}" \
    GH_FAIL_ON="${GH_FAIL_ON:-}" \
    bash "$REVIEW" "$@" --repo "$REPO" > "$GH_CASE/output" 2>&1 || REVIEW_RC=$?
}

test_review_quarantine_state_machine() {
  setup_gh
  GH_VIEW_JSON="$(review_issue OPEN '[{"name":"lesson-candidate"},{"name":"lessons:blocked"}]')"
  run_review --approve 5
  [ "$REVIEW_RC" -ne 0 ] && pass "approve refuses blocked mixed labels" || fail "approve refuses blocked mixed labels"
  assert_not_contains "blocked approve performs no edit" "$GH_CASE/gh.log" 'issue edit'

  setup_gh
  GH_VIEW_JSON="$(review_issue OPEN '[{"name":"lesson-candidate"},{"name":"lesson-approved"}]')"
  run_review --quarantine 6 --note auto
  assert_eq "candidate quarantine succeeds" "$REVIEW_RC" 0
  assert_contains "quarantine adds blocked atomically" "$GH_CASE/gh.log" 'issue edit 6 --repo owner/repo --add-label lessons:blocked --remove-label lesson-candidate --remove-label lesson-approved'
  assert_eq "quarantine uses one edit" "$(grep -c 'issue edit' "$GH_CASE/gh.log")" 1

  setup_gh
  GH_VIEW_JSON="$(review_issue OPEN '[{"name":"lessons:blocked"}]')"
  run_review --quarantine 6
  assert_eq "open blocked without candidate is idempotent" "$REVIEW_RC" 0
  assert_not_contains "idempotent quarantine performs no edit" "$GH_CASE/gh.log" 'issue edit'

  local json label
  for label in unrelated approved-only closed; do
    setup_gh
    case "$label" in
      unrelated) json="$(review_issue OPEN '[{"name":"bug"}]')" ;;
      approved-only) json="$(review_issue OPEN '[{"name":"lesson-approved"}]')" ;;
      closed) json="$(review_issue CLOSED '[{"name":"lesson-candidate"}]')" ;;
    esac
    GH_VIEW_JSON="$json"
    run_review --quarantine 8
    [ "$REVIEW_RC" -ne 0 ] && pass "quarantine refuses $label" || fail "quarantine refuses $label"
    assert_not_contains "quarantine $label guard prevents edit" "$GH_CASE/gh.log" 'issue edit'
  done
}

test_review_auto_reject_state_machine() {
  setup_gh
  GH_VIEW_JSON="$(review_issue OPEN '[{"name":"lesson-candidate"}]')"
  digest="$(lesson_review_digest_json "$GH_VIEW_JSON")"
  run_review --auto-reject 9 --note auto --review-digest "$digest"
  assert_eq "candidate-only automated rejection succeeds" "$REVIEW_RC" 0
  assert_contains "automated rejection closes one candidate" "$GH_CASE/gh.log" \
    'issue close 9 --repo owner/repo --reason not planned'
  assert_contains "automated rejection records exact binding" "$GH_CASE/gh.log" \
    "saas-lesson-review:v1:reject:$digest"

  local json state
  for state in approved blocked unrelated closed; do
    setup_gh
    case "$state" in
      approved) json="$(review_issue OPEN '[{"name":"lesson-candidate"},{"name":"lesson-approved"}]')" ;;
      blocked) json="$(review_issue OPEN '[{"name":"lesson-candidate"},{"name":"lessons:blocked"}]')" ;;
      unrelated) json="$(review_issue OPEN '[{"name":"bug"}]')" ;;
      closed) json="$(review_issue CLOSED '[{"name":"lesson-candidate"}]')" ;;
    esac
    GH_VIEW_JSON="$json"
    digest="$(lesson_review_digest_json "$GH_VIEW_JSON")"
    run_review --auto-reject 9 --review-digest "$digest"
    [ "$REVIEW_RC" -ne 0 ] && pass "automated rejection refuses $state state" \
      || fail "automated rejection refuses $state state"
    assert_not_contains "automated rejection $state guard prevents close" "$GH_CASE/gh.log" 'issue close'
  done
}

test_review_content_binding() {
  local digest
  setup_gh
  GH_VIEW_JSON="$(review_issue OPEN '[{"name":"lesson-candidate"}]')"
  digest="$(lesson_review_digest_json "$GH_VIEW_JSON")"
  run_review --approve 12 --review-digest "$(printf stale | sha256sum | awk '{print $1}')"
  [ "$REVIEW_RC" -ne 0 ] && pass "changed content refuses stale automated approval" \
    || fail "changed content refuses stale automated approval"
  assert_not_contains "stale approval records no binding" "$GH_CASE/gh.log" 'issue comment'
  assert_not_contains "stale approval performs no edit" "$GH_CASE/gh.log" 'issue edit'

  setup_gh
  GH_VIEW_JSON="$(review_issue OPEN '[{"name":"lesson-candidate"}]')"
  digest="$(lesson_review_digest_json "$GH_VIEW_JSON")"
  GH_VIEW_AFTER_JSON="$(jq '.body = "edited during rejection"' <<<"$GH_VIEW_JSON")"
  run_review --auto-reject 12 --review-digest "$digest"
  unset GH_VIEW_AFTER_JSON
  [ "$REVIEW_RC" -ne 0 ] && pass "mid-rejection edit fails closed" \
    || fail "mid-rejection edit fails closed"
  assert_contains "mid-rejection edit reopens the issue" "$GH_CASE/gh.log" 'issue reopen 12'

  setup_gh
  GH_VIEW_JSON="$(review_issue OPEN '[{"name":"lesson-approved"}]')"
  run_review --approve 12
  [ "$REVIEW_RC" -ne 0 ] && pass "unbound approved state is not a valid no-op" \
    || fail "unbound approved state is not a valid no-op"
}

test_opus_decisive_and_limits
test_sol_routes_and_flags
test_boolean_and_confidence_gates
test_transport_and_malformed_fail_closed
test_nonblocking_local_lock
test_dry_run_hostile_bounds_and_cleanup
test_mutation_failure_and_strict_schema
test_review_quarantine_state_machine
test_review_auto_reject_state_machine
test_review_content_binding

printf '\nlesson-auto-review: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
