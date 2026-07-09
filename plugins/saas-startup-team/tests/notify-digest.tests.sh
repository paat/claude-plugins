# Sourced by run-tests.sh — needs-human digest + push notifications (lesson #194).
# Uses the harness assert_* helpers and make_workdir.
test_notify_digest() {
  echo -e "\n${CYAN}Suite: notify.sh + digest.sh (#194)${NC}"
  local notify="$PLUGIN_ROOT/scripts/notify.sh"
  local digest="$PLUGIN_ROOT/scripts/digest.sh"
  local wd bindir ec out log

  # Mock curl on PATH: records argv to $CURL_LOG, dumps any -K config file to $CURL_KFILE
  # (so tests inspect header lines that are kept OUT of argv), and honours $CURL_MOCK_EXIT.
  install_mock_curl() {
    bindir="$1/bin"; mkdir -p "$bindir"
    cat > "$bindir/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$CURL_LOG"
prev=""
for a in "$@"; do
  [ -n "${CURL_KFILE:-}" ] && [ "$prev" = "-K" ] && [ -f "$a" ] && cat "$a" >> "$CURL_KFILE"
  prev="$a"
done
exit "${CURL_MOCK_EXIT:-0}"
EOF
    chmod +x "$bindir/curl"
  }

  # N1: unconfigured → exit 3 (clean no-op contract), no curl call.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" PATH="$bindir:$PATH" \
        env -u SAAS_NOTIFY_KIND -u SAAS_NOTIFY_URL -u SAAS_NOTIFY_TOKEN_ENV \
        bash "$notify" --blocker --title t --body b --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N1: unconfigured exits 3 (no-op)" "$ec" 3
  assert_output_contains "N1b: prints no-op note" "$out" "clean no-op"
  assert_file_not_exists "N1c: no curl invocation recorded" "$wd/curl.log"

  # N1d: the /digest gate (`if notify.sh; then mark-sent; fi`) does NOT advance the cursor
  # on the unconfigured no-op — parked activity must re-appear in a later digest.
  mkdir -p "$wd/.startup/maintain/runs"
  printf '# r\n- Shipped: PR #9\n' > "$wd/.startup/maintain/runs/run-1.md"
  bash "$digest" assemble --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  if CURL_LOG="$wd/curl.log" PATH="$bindir:$PATH" \
       env -u SAAS_NOTIFY_KIND -u SAAS_NOTIFY_URL -u SAAS_NOTIFY_TOKEN_ENV \
       bash "$notify" --digest --title t --file "$wd/.startup/digests/2026-07-09.md" --root "$wd" >/dev/null 2>&1; then
    bash "$digest" mark-sent --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  fi
  local sent_after
  sent_after=$(jq -r '.sent_runs | length' "$wd/.startup/digest-state.json" 2>/dev/null || echo X)
  assert_equals "N1d: cursor unadvanced when unconfigured" "$sent_after" "0"

  # N1e: explicit kind:none is a clean no-op (exit 3), distinct from the unconfigured path.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"none","url":"https://x.example/y"}' > "$wd/.startup/notify.json"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" PATH="$bindir:$PATH" \
        bash "$notify" --digest --title t --body b --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N1e: kind:none exits 3 (no-op)" "$ec" 3
  assert_output_contains "N1f: kind:none prints no-op note" "$out" "clean no-op"
  assert_file_not_exists "N1g: kind:none makes no curl call" "$wd/curl.log"

  # N1h: --file pointing at a missing file is a usage error (exit 2), not an empty send.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/e"}' > "$wd/.startup/notify.json"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" PATH="$bindir:$PATH" \
        bash "$notify" --digest --title t --file "$wd/nonexistent.md" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N1h: missing --file exits 2" "$ec" 2
  assert_file_not_exists "N1i: missing --file makes no curl call" "$wd/curl.log"

  # N2: ntfy config → correct URL/title/body; blocker → high priority.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/topic","token_env":"NOTIFY_TOK"}' \
    > "$wd/.startup/notify.json"
  ec=0
  CURL_LOG="$wd/curl.log" CURL_KFILE="$wd/curl.kfile" NOTIFY_TOK=secret123 PATH="$bindir:$PATH" \
    bash "$notify" --blocker --title "Blk" --body "boom" --root "$wd" >/dev/null 2>&1 || ec=$?
  assert_exit_code "N2: ntfy blocker exits 0" "$ec" 0
  log="$(cat "$wd/curl.log" 2>/dev/null || true)"
  local kfile; kfile="$(cat "$wd/curl.kfile" 2>/dev/null || true)"
  assert_output_contains "N2b: sends to configured URL" "$log" "https://ntfy.example/topic"
  assert_output_contains "N2c: carries title" "$log" "Title: Blk"
  assert_output_contains "N2d: carries body" "$log" "boom"
  assert_output_contains "N2e: blocker → high priority" "$log" "Priority: high"
  # token travels in the -K config file (read from the named env var), never in argv
  assert_output_contains "N2f: token passed via -K config file" "$kfile" "Authorization: Bearer secret123"
  assert_output_not_contains "N2g: token absent from curl argv" "$log" "secret123"
  assert_output_not_contains "N2h: env var name never leaks" "$log" "NOTIFY_TOK"

  # N3: digest level → default priority.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/d"}' > "$wd/.startup/notify.json"
  CURL_LOG="$wd/curl.log" PATH="$bindir:$PATH" \
    bash "$notify" --digest --title "D" --body "x" --root "$wd" >/dev/null 2>&1 || true
  log="$(cat "$wd/curl.log" 2>/dev/null || true)"
  assert_output_contains "N3: digest → default priority" "$log" "Priority: default"

  # N3b: send failure → fixed exit 10 (never curl's raw code, which could collide with the
  # 0–3 sentinels) and no success line. Use curl exit 3 (URL malformed) as the trap case.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/e"}' > "$wd/.startup/notify.json"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" CURL_MOCK_EXIT=3 PATH="$bindir:$PATH" \
        bash "$notify" --digest --title "D" --body "x" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N3b: send failure maps to fixed code 10" "$ec" 10
  assert_output_not_contains "N3c: no success line on failure" "$out" "sent via"

  # N3d: unknown non-empty kind is a config error → exit 1 (none/unset stays exit 3).
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"bogus","url":"https://x.example/y"}' > "$wd/.startup/notify.json"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" PATH="$bindir:$PATH" \
        bash "$notify" --digest --title "D" --body "x" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N3d: unknown kind exits 1 (config error)" "$ec" 1
  assert_output_contains "N3e: unknown kind reports config error" "$out" "config error"

  # N3f: malformed notify.json is a config error (exit 1), NOT the clean-no-op path.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy", "url":' > "$wd/.startup/notify.json"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" PATH="$bindir:$PATH" \
        bash "$notify" --digest --title "D" --body "x" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N3f: malformed notify.json exits 1" "$ec" 1
  assert_output_contains "N3g: malformed config reported" "$out" "malformed"

  # N3h: missing --body/--file is a usage error (exit 2).
  wd="$(make_workdir)"
  ec=0
  out=$(env -u SAAS_NOTIFY_KIND -u SAAS_NOTIFY_URL \
        bash "$notify" --digest --title "D" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N3h: missing body/file exits 2" "$ec" 2
  assert_output_contains "N3i: usage error reported" "$out" "body or --file required"

  # N3j: a real kind with empty URL is a config error (exit 1), not a clean no-op.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" SAAS_NOTIFY_KIND=ntfy PATH="$bindir:$PATH" \
        env -u SAAS_NOTIFY_URL \
        bash "$notify" --digest --title "D" --body "x" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N3j: kind-set-but-empty-url exits 1" "$ec" 1
  assert_output_contains "N3k: half-configured reported as config error" "$out" "config error"
  assert_file_not_exists "N3l: no curl call on config error" "$wd/curl.log"

  # N3m: webhook backend → POST + JSON payload + -K auth config (parallels N2).
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"webhook","url":"https://hook.example/in","token_env":"HOOK_TOK"}' \
    > "$wd/.startup/notify.json"
  ec=0
  CURL_LOG="$wd/curl.log" CURL_KFILE="$wd/curl.kfile" HOOK_TOK=hooksecret PATH="$bindir:$PATH" \
    bash "$notify" --digest --title "WH" --body "hello" --root "$wd" >/dev/null 2>&1 || ec=$?
  assert_exit_code "N3m: webhook send exits 0" "$ec" 0
  log="$(cat "$wd/curl.log" 2>/dev/null || true)"
  local wkfile; wkfile="$(cat "$wd/curl.kfile" 2>/dev/null || true)"
  assert_output_contains "N3n: webhook uses POST" "$log" "POST"
  assert_output_contains "N3o: webhook posts to configured URL" "$log" "https://hook.example/in"
  assert_output_contains "N3p: webhook sets JSON content type" "$log" "Content-Type: application/json"
  assert_output_contains "N3q: webhook body is jq-built JSON" "$log" '"title":"WH"'
  assert_output_contains "N3r: webhook auth via -K config file" "$wkfile" "Authorization: Bearer hooksecret"
  assert_output_not_contains "N3s: webhook token absent from argv" "$log" "hooksecret"

  # N3t: a token containing a double-quote is escaped in the -K config file so curl parses
  # it intact (mock dumps the raw file; assert the backslash-escaped form is present).
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/q","token_env":"QTOK"}' \
    > "$wd/.startup/notify.json"
  CURL_LOG="$wd/curl.log" CURL_KFILE="$wd/curl.kfile" QTOK='ab"cd' PATH="$bindir:$PATH" \
    bash "$notify" --digest --title "D" --body "x" --root "$wd" >/dev/null 2>&1 || true
  local qkfile; qkfile="$(cat "$wd/curl.kfile" 2>/dev/null || true)"
  assert_output_contains "N3t: quote in token escaped in -K file" "$qkfile" 'Bearer ab\"cd'

  # N3u: a token with an embedded newline must NOT inject a second -K directive line.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/n","token_env":"NTOK"}' \
    > "$wd/.startup/notify.json"
  CURL_LOG="$wd/curl.log" CURL_KFILE="$wd/curl.kfile" NTOK=$'tok\ninsecure' PATH="$bindir:$PATH" \
    bash "$notify" --digest --title "D" --body "x" --root "$wd" >/dev/null 2>&1 || true
  local nlines
  nlines=$(wc -l < "$wd/curl.kfile" 2>/dev/null | tr -d ' ' || echo X)
  assert_equals "N3u: token newline does not add a -K directive line" "$nlines" "1"

  # N3w: token_env naming an UNSET var is a half-configured channel (config error, exit 1),
  # not a silent unauthenticated send. An empty token_env stays a valid no-auth send (N3).
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/a","token_env":"MISSING_TOK_XYZ"}' \
    > "$wd/.startup/notify.json"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" PATH="$bindir:$PATH" env -u MISSING_TOK_XYZ \
        bash "$notify" --digest --title "D" --body "x" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N3w: unresolvable token_env exits 1" "$ec" 1
  assert_output_contains "N3x: names the missing env var" "$out" "MISSING_TOK_XYZ"
  assert_file_not_exists "N3y: no unauthenticated send on unresolvable token_env" "$wd/curl.log"

  # N3z: token_env naming a set-but-EMPTY var is also a config error (no silent no-auth send).
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/a","token_env":"EMPTY_TOK"}' \
    > "$wd/.startup/notify.json"
  ec=0
  out=$(CURL_LOG="$wd/curl.log" EMPTY_TOK="" PATH="$bindir:$PATH" \
        bash "$notify" --digest --title "D" --body "x" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "N3z: empty token_env var exits 1" "$ec" 1
  assert_file_not_exists "N3aa: no send when token_env var is empty" "$wd/curl.log"

  # N3ab: a value-taking flag with no following value is a usage error (exit 2), not a
  # set -e shift abort.
  wd="$(make_workdir)"
  ec=0
  out=$(bash "$notify" --digest --title 2>&1) || ec=$?
  assert_exit_code "N3ab: valueless --title exits 2" "$ec" 2
  assert_output_contains "N3ac: names the flag needing a value" "$out" "requires a value"

  # N4: digest assembly from fixtures → one file, parked item + shipped PR line.
  wd="$(make_workdir)"
  mkdir -p "$wd/docs" "$wd/.startup/maintain/runs"
  cat > "$wd/docs/human-tasks.md" <<'EOF'
# Human Tasks

## Pending

- [ ] **Provide API token** — needed for: billing
  - Notes: copy the key and run: gh secret set BILLING_KEY

## Completed
EOF
  printf '# run\n- Shipped: PR #42 https://github.com/x/y/pull/42\n' \
    > "$wd/.startup/maintain/runs/run-1.md"
  ec=0
  out=$(bash "$digest" assemble --root "$wd" --date 2026-07-09 2>&1) || ec=$?
  assert_exit_code "N4: assemble exits 0" "$ec" 0
  assert_file_exists "N4b: digest file written" "$wd/.startup/digests/2026-07-09.md"
  assert_file_contains "N4c: contains parked (credential) item" \
    "$wd/.startup/digests/2026-07-09.md" "Provide API token"
  assert_file_contains "N4d: contains shipped PR line" \
    "$wd/.startup/digests/2026-07-09.md" "PR #42"
  assert_file_contains "N4e: spend/pass-summary placeholder present" \
    "$wd/.startup/digests/2026-07-09.md" "Spend & pass summary"
  local nfiles
  nfiles=$(find "$wd/.startup/digests" -name '*.md' | wc -l | tr -d ' ')
  assert_equals "N4f: exactly one digest file" "$nfiles" "1"

  # N5: second same-day assemble does not duplicate.
  bash "$digest" assemble --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  local dupes
  dupes=$(grep -c 'PR #42' "$wd/.startup/digests/2026-07-09.md" 2>/dev/null | tr -d ' ' || echo 0)
  assert_equals "N5: shipped line not duplicated on re-run" "$dupes" "1"

  # N5b: --date is validated (path-traversal guard) — a traversal value exits 2 and
  # writes nothing outside .startup/digests.
  wd="$(make_workdir)"
  mkdir -p "$wd/docs"
  printf 'original\n' > "$wd/docs/human-tasks.md"
  ec=0
  out=$(bash "$digest" assemble --root "$wd" --date "../../docs/human-tasks" 2>&1) || ec=$?
  assert_exit_code "N5b: traversal --date exits 2" "$ec" 2
  assert_file_contains "N5c: traversal target (docs/human-tasks.md) untouched" \
    "$wd/docs/human-tasks.md" "original"

  # N6: mark-sent marks only the runs assemble included — a run created in the
  # assemble→send window must NOT be marked sent (else it never reaches any digest).
  wd="$(make_workdir)"
  mkdir -p "$wd/.startup/maintain/runs"
  printf '# r1\n- Shipped: PR #1\n' > "$wd/.startup/maintain/runs/run-1.md"
  bash "$digest" assemble --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  # a new run lands after assembly, before mark-sent
  printf '# r2\n- Shipped: PR #2\n' > "$wd/.startup/maintain/runs/run-2.md"
  bash "$digest" mark-sent --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  local sent_list
  sent_list=$(jq -r '.sent_runs | join(",")' "$wd/.startup/digest-state.json" 2>/dev/null || echo "")
  assert_equals "N6: only the assembled run is marked sent" "$sent_list" ".startup/maintain/runs/run-1.md"
  # run-2 therefore still appears in the next digest
  out=$(bash "$digest" assemble --root "$wd" --date 2026-07-10 2>&1) || true
  assert_file_contains "N6b: post-assemble run reaches next digest" \
    "$wd/.startup/digests/2026-07-10.md" "PR #2"

  # N7: same basename in two different .startup/<loop>/runs dirs must NOT collide — both
  # appear in the digest and both get marked sent (cursor keyed by ROOT-relative path).
  wd="$(make_workdir)"
  mkdir -p "$wd/.startup/maintain/runs" "$wd/.startup/monitor/runs"
  printf '# m\n- Shipped: PR #11\n' > "$wd/.startup/maintain/runs/run-1.md"
  printf '# n\n- Shipped: PR #22\n' > "$wd/.startup/monitor/runs/run-1.md"
  out=$(bash "$digest" assemble --root "$wd" --date 2026-07-09 2>&1) || true
  assert_file_contains "N7: first same-name run in digest" \
    "$wd/.startup/digests/2026-07-09.md" "PR #11"
  assert_file_contains "N7b: second same-name run in digest (no collision)" \
    "$wd/.startup/digests/2026-07-09.md" "PR #22"
  bash "$digest" mark-sent --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  local n7_sent
  n7_sent=$(jq -r '.sent_runs | sort | join(",")' "$wd/.startup/digest-state.json" 2>/dev/null || echo "")
  assert_equals "N7c: both same-name runs marked sent" "$n7_sent" \
    ".startup/maintain/runs/run-1.md,.startup/monitor/runs/run-1.md"

  # N8: the stock human-tasks template (its placeholder task lives in an HTML comment)
  # must NOT surface as a live needs-human item.
  wd="$(make_workdir)"
  mkdir -p "$wd/docs"
  cp "$PLUGIN_ROOT/templates/human-tasks.md" "$wd/docs/human-tasks.md"
  out=$(bash "$digest" assemble --root "$wd" --date 2026-07-09 2>&1) || true
  assert_file_not_contains "N8: template placeholder not parsed as a task" \
    "$wd/.startup/digests/2026-07-09.md" "Task name"

  # N9: multiple Pending tasks with continuation lines — the comment-skip flag must not
  # clobber classification, so BOTH tasks and a continuation line survive to the digest.
  wd="$(make_workdir)"
  mkdir -p "$wd/docs"
  cat > "$wd/docs/human-tasks.md" <<'EOF'
# Human Tasks

## Pending

- [ ] **Provide Stripe API key** — needed for: billing
  - Notes: copy sk_live_... and run: gh secret set STRIPE_KEY
- [ ] **Approve ad budget** — needed for: growth
  - Priority: HIGH

## Completed
EOF
  local dg="$wd/.startup/digests/2026-07-09.md"
  out=$(bash "$digest" assemble --root "$wd" --date 2026-07-09 2>&1) || true
  assert_file_contains "N9: first task (credentials) present" "$dg" "Provide Stripe API key"
  assert_file_contains "N9b: first task continuation line present" "$dg" "gh secret set STRIPE_KEY"
  assert_file_contains "N9c: second task (approvals) present" "$dg" "Approve ad budget"
  assert_file_contains "N9d: second task continuation line present" "$dg" "Priority: HIGH"

  # N10: "sign" no longer over-matches — a "Redesign" task lands in FYI, not approvals.
  wd="$(make_workdir)"
  mkdir -p "$wd/docs"
  cat > "$wd/docs/human-tasks.md" <<'EOF'
# Human Tasks

## Pending

- [ ] **Redesign the landing page** — needed for: conversion

## Completed
EOF
  dg="$wd/.startup/digests/2026-07-09.md"
  out=$(bash "$digest" assemble --root "$wd" --date 2026-07-09 2>&1) || true
  local appr_sec fyi_sec
  appr_sec=$(awk '/^## .*approvals/{f=1;next} /^## /{f=0} f' "$dg")
  fyi_sec=$(awk '/^## .*FYI/{f=1;next} /^## /{f=0} f' "$dg")
  assert_output_not_contains "N10: Redesign not misfiled to approvals" "$appr_sec" "Redesign"
  assert_output_contains "N10b: Redesign lands in FYI" "$fyi_sec" "Redesign"

  # N11: idempotent per day — a second same-day /digest after a successful send does not
  # resend (mock curl records zero calls on the second run). Mirrors the digest.md flow.
  wd="$(make_workdir)"; install_mock_curl "$wd"
  mkdir -p "$wd/.startup/maintain/runs"
  printf '%s' '{"kind":"ntfy","url":"https://ntfy.example/day"}' > "$wd/.startup/notify.json"
  printf '# r\n- Shipped: PR #7\n' > "$wd/.startup/maintain/runs/run-1.md"
  digest_flow() {  # $1=date  $2=curl log path for this run
    if bash "$digest" already-sent --root "$wd" --date "$1"; then return 0; fi
    local o r=0
    o=$(bash "$digest" assemble --root "$wd" --date "$1")
    CURL_LOG="$2" PATH="$bindir:$PATH" \
      bash "$notify" --digest --file "$o" --title T --root "$wd" >/dev/null 2>&1 || r=$?
    [ "$r" -eq 0 ] && bash "$digest" mark-sent --root "$wd" --date "$1" >/dev/null 2>&1
    return 0
  }
  digest_flow 2026-07-09 "$wd/c1.log"
  assert_file_exists "N11: first same-day run sends" "$wd/c1.log"
  digest_flow 2026-07-09 "$wd/c2.log"
  assert_file_not_exists "N11b: second same-day run does not resend" "$wd/c2.log"

  # N12: cross-date backfill — assemble D1 then D2 (which clobbers the shared snapshot);
  # mark-sent D1 must mark only D1's runs (date-tag guard re-derives from D1's digest),
  # and D2's later run must still reach a subsequent digest.
  wd="$(make_workdir)"
  mkdir -p "$wd/.startup/maintain/runs"
  printf '# a\n- Shipped: PR #1\n' > "$wd/.startup/maintain/runs/run-a.md"
  bash "$digest" assemble --root "$wd" --date 2026-07-01 >/dev/null 2>&1 || true
  printf '# b\n- Shipped: PR #2\n' > "$wd/.startup/maintain/runs/run-b.md"
  bash "$digest" assemble --root "$wd" --date 2026-07-02 >/dev/null 2>&1 || true
  bash "$digest" mark-sent --root "$wd" --date 2026-07-01 >/dev/null 2>&1 || true
  local d1_sent
  d1_sent=$(jq -r '.sent_runs | sort | join(",")' "$wd/.startup/digest-state.json" 2>/dev/null || echo "")
  assert_equals "N12: mark-sent D1 marks only D1's run" "$d1_sent" ".startup/maintain/runs/run-a.md"
  bash "$digest" assemble --root "$wd" --date 2026-07-03 >/dev/null 2>&1 || true
  assert_file_contains "N12b: D2's run still reaches a later digest" \
    "$wd/.startup/digests/2026-07-03.md" "PR #2"

  # N13: nested per-issue run artifacts (runs/<rid>/issue-N.md, as maintain-loop writes)
  # reach the digest and are marked sent — the scan is not limited to direct runs/ children.
  wd="$(make_workdir)"
  mkdir -p "$wd/.startup/maintain-loop/runs/rid7"
  printf '# issue\n- Shipped: PR #99\n' > "$wd/.startup/maintain-loop/runs/rid7/issue-1.md"
  bash "$digest" assemble --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  assert_file_contains "N13: nested run artifact reaches digest" \
    "$wd/.startup/digests/2026-07-09.md" "PR #99"
  bash "$digest" mark-sent --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  local n13_sent
  n13_sent=$(jq -r '.sent_runs | join(",")' "$wd/.startup/digest-state.json" 2>/dev/null || echo "")
  assert_equals "N13b: nested artifact marked sent (root-relative path)" "$n13_sent" \
    ".startup/maintain-loop/runs/rid7/issue-1.md"
}
test_notify_digest
