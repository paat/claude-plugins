#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

# ---------------------------------------------------------------------------
# Suite K: /maintain command
# ---------------------------------------------------------------------------

test_maintain() {
  echo -e "\n${CYAN}== /maintain command (v3 + legacy-drain) ==${NC}"
  local cmd="$PLUGIN_ROOT/references/workflows/maintain.md"
  local entry="$PLUGIN_ROOT/commands/maintain.md"
  local v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  local drain="$PLUGIN_ROOT/scripts/legacy-drain.sh"
  local skill="$PLUGIN_ROOT/skills/maintain/SKILL.md"
  local contract="$PLUGIN_ROOT/references/workflows/maintain-policy.md"
  local goal="$PLUGIN_ROOT/references/delivery-playbook.md"
  local codex_cmd="$PLUGIN_ROOT/skills/saas-startup-team-maintain-workflow/SKILL.md"

  assert_file_exists "M1: maintain.md exists" "$cmd"
  assert_file_exists "M2: maintain-v3 engine" "$v3"
  assert_file_exists "M3: legacy-drain" "$drain"
  assert_file_exists "M4: maintain skill" "$skill"
  assert_file_exists "M5: maintain command" "$entry"
  assert_file_contains "M6: command loads skill" "$entry" 'skills/maintain'
  assert_file_contains "M7: shadow default" "$skill" '--shadow'
  assert_file_contains "M8: no claims" "$skill" 'No claims'
  assert_file_contains "M9: short locks" "$contract" 'scheduler'
  assert_file_contains "M10: worktree preferred" "$contract" 'git worktree'
  assert_file_contains "M11: no primary reset on cancel" "$contract" 'never hard-reset'
  assert_file_contains "M12: tribunal hard dep" "$goal" "tribunal-review"
  assert_file_contains "M13: human-tasks for unresolved" "$cmd" "human-tasks.md"
  assert_file_contains "M14: legacy drain inventory" "$cmd" "legacy-drain.sh"
  assert_file_contains "M15: source intact until verify" "$cmd" "stay intact until verify"
  assert_file_not_contains "M16: no maintain-leases on normal path" "$cmd" "maintain-leases.sh"
  assert_file_not_contains "M17: no single-flight on normal path" "$cmd" "single-flight.sh"
  assert_file_not_contains "M18: no lease-guardian" "$cmd" "lease-guardian.sh"
  assert_file_not_exists "M19: maintain-delivery deleted" "$PLUGIN_ROOT/scripts/maintain-delivery.sh"
  assert_file_not_exists "M20: maintain-leases deleted" "$PLUGIN_ROOT/scripts/maintain-leases.sh"
  assert_file_not_exists "M21: single-flight deleted" "$PLUGIN_ROOT/scripts/single-flight.sh"
  assert_file_not_exists "M22: lease-guardian deleted" "$PLUGIN_ROOT/scripts/lease-guardian.sh"
  assert_file_not_exists "M23: maintain-attempt deleted" "$PLUGIN_ROOT/scripts/maintain-attempt.sh"
  assert_file_not_exists "M24: maintain-self-heal deleted" "$PLUGIN_ROOT/scripts/maintain-self-heal.sh"
  assert_file_not_exists "M25: maintain-escalation deleted" "$PLUGIN_ROOT/scripts/maintain-escalation.sh"
  assert_file_not_exists "M26: trace-containment deleted" "$PLUGIN_ROOT/scripts/trace-containment.py"
  assert_file_exists "M27: Codex maintain workflow exists" "$codex_cmd"
  assert_file_contains "M28: maintain uses queue builder" "$PLUGIN_ROOT/scripts/maintain-v3.sh" "maintain-queue.sh"
  assert_file_contains "M29: WIP-first" "$contract" "WIP"
  assert_file_contains "M30: release-facts" "$contract" "release-facts"
  assert_file_contains "M31: empty claims array" "$v3" 'claims:\[\]'
  assert_file_contains "M32: only three lock kinds" "$v3" 'scheduler|issue|release'
  assert_file_contains "M45a41: WIP-first contract rejects claim ownership" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" 'claim comments as ownership'
  assert_file_contains "M45a42: auto-merge when gates pass" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" 'exact-head merge'
  assert_file_contains "M45a10: resume re-proves current-head gates" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" \
    'Do not trust an earlier green check'
  assert_file_contains "M45a11: resume never creates a replacement PR" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" \
    'Never open a replacement PR'
  assert_file_contains "M45a27: active merge atomically pins the reviewed PR head" \
    "$PLUGIN_ROOT/references/workflows/maintain-policy.md" \
    'gh pr merge --match-head-commit'

  # Queue builder regression: no-dependency issues must survive dependency parsing.
  local queue_script issues_file prs_file resume_candidate_file race_issues_file race_prs_file blocked_file active_blocked_file expired_blocked_file legacy_blocked_file bad_blocked_file bad_blocked_err dep_issues_file dep_status_file serial_dep_issues_file serial_dep_status_file closed_issues_file fake_bin live_out repo_live_out closed_status closed_err missing_status missing_err fixture_closed_status fixture_closed_err zero_status zero_err bad_blocked_status resume_status out race_out filtered single_issue cooled active_blocked expired_blocked dual_blocked dep_out serial_dep_out queue_numbers live_repo gh_calls unbound_dir unbound_status unbound_err
  queue_script="$PLUGIN_ROOT/scripts/maintain-queue.sh"
  assert_file_exists "M45b: queue builder script exists" "$queue_script"
  assert_file_contains "M45b1: queue builder fetches linked PR refs" "$queue_script" "closedByPullRequestsReferences"
  workdir=$(mktemp -d)
  issues_file="$workdir/issues.json"
  prs_file="$workdir/open-prs.json"
  cat > "$issues_file" <<'JSON'
[
  {
    "number": 101,
    "title": "Unlabelled no-dependency issue",
    "body": "No dependency markers here.",
    "labels": [],
    "createdAt": "2026-01-05T00:00:00Z",
    "updatedAt": "2026-01-05T00:00:00Z"
  },
  {
    "number": 102,
    "title": "Critical no-dependency issue",
    "body": "No dependency markers here either.",
    "labels": [{"name": "critical"}, {"name": "release"}],
    "createdAt": "2026-01-04T00:00:00Z",
    "updatedAt": "2026-01-04T00:00:00Z"
  },
  {
    "number": 103,
    "title": "Already has PR",
    "body": "Fix is in flight.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-01T00:00:00Z",
    "updatedAt": "2026-01-01T00:00:00Z"
  },
  {
    "number": 104,
    "title": "Depends on queued work",
    "body": "Blocked by #101, #102; context from #110.",
    "labels": [{"name": "medium"}],
    "createdAt": "2026-01-03T00:00:00Z",
    "updatedAt": "2026-01-03T00:00:00Z"
  },
  {
    "number": 105,
    "title": "Human decision",
    "body": "Needs a product call.",
    "labels": [{"name": "needs-human"}],
    "createdAt": "2026-01-06T00:00:00Z",
    "updatedAt": "2026-01-06T00:00:00Z"
  },
  {
    "number": 106,
    "title": "Temporarily blocked",
    "body": "External dependency.",
    "labels": [{"name": "maintain:blocked"}],
    "createdAt": "2026-01-07T00:00:00Z",
    "updatedAt": "2026-01-07T00:00:00Z"
  },
  {
    "number": 107,
    "title": "Umbrella epic",
    "body": "Tracking issue.",
    "labels": [{"name": "epic"}],
    "createdAt": "2026-01-08T00:00:00Z",
    "updatedAt": "2026-01-08T00:00:00Z"
  },
  {
    "number": 108,
    "title": "Low no-dependency issue",
    "body": "No dependency markers.",
    "labels": [{"name": "low"}],
    "createdAt": "2026-01-02T00:00:00Z",
    "updatedAt": "2026-01-02T00:00:00Z"
  },
  {
    "number": 109,
    "title": "Mentioned by in-flight PR",
    "body": "No dependency markers.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-08T00:00:00Z",
    "updatedAt": "2026-01-08T00:00:00Z"
  },
  {
    "number": 110,
    "title": "High no-dependency issue",
    "body": "No dependency markers.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-09T00:00:00Z",
    "updatedAt": "2026-01-09T00:00:00Z"
  },
  {
    "number": 111,
    "title": "Medium no-dependency issue",
    "body": "No dependency markers.",
    "labels": [{"name": "medium"}],
    "createdAt": "2026-01-10T00:00:00Z",
    "updatedAt": "2026-01-10T00:00:00Z"
  },
  {
    "number": 112,
    "title": "Linked by GitHub closing reference",
    "body": "No dependency markers.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-11T00:00:00Z",
    "updatedAt": "2026-01-11T00:00:00Z"
  },
  {
    "number": 113,
    "state": "OPEN",
    "title": "Claimed PR interrupted after push",
    "body": "Resume the existing delivery.",
    "labels": [{"name": "maintain:claimed"}, {"name": "high"}],
    "assignees": [],
    "closedByPullRequestsReferences": [],
    "createdAt": "2026-01-12T00:00:00Z",
    "updatedAt": "2026-01-12T00:00:00Z"
  },
  {
    "number": 114,
    "title": "Ambiguous claimed PRs",
    "body": "Two PRs claim this issue.",
    "labels": [{"name": "maintain:claimed"}],
    "createdAt": "2026-01-13T00:00:00Z",
    "updatedAt": "2026-01-13T00:00:00Z"
  },
  {
    "number": 115,
    "title": "Claimed PR needs a human",
    "body": "Do not resume automatically.",
    "labels": [{"name": "maintain:claimed"}, {"name": "needs-human"}],
    "createdAt": "2026-01-14T00:00:00Z",
    "updatedAt": "2026-01-14T00:00:00Z"
  },
  {
    "number": 116,
    "title": "Claimed PR waits for dependency",
    "body": "Blocked by #101.",
    "labels": [{"name": "maintain:claimed"}],
    "createdAt": "2026-01-15T00:00:00Z",
    "updatedAt": "2026-01-15T00:00:00Z"
  }
]
JSON
  cat > "$prs_file" <<'JSON'
[
  {
    "number": 20,
    "title": "Fix linked issue",
    "body": "Closes #103",
    "closingIssuesReferences": []
  },
  {
    "number": 21,
    "title": "WIP for #109",
    "body": "Implementation notes only; no closing keyword.",
    "closingIssuesReferences": []
  },
  {
    "number": 22,
    "title": "Fix through GitHub reference",
    "body": "No textual issue reference.",
    "closingIssuesReferences": [{"number": 112}]
  },
  {
    "number": 23,
    "title": "Resume claimed work",
    "body": "Fixes #113",
    "closingIssuesReferences": []
  },
  {
    "number": 24,
    "title": "First ambiguous claim",
    "body": "Fixes #114",
    "closingIssuesReferences": []
  },
  {
    "number": 25,
    "title": "Second ambiguous claim",
    "body": "Resolves #114",
    "closingIssuesReferences": []
  },
  {
    "number": 26,
    "title": "Human-gated claim",
    "body": "Fixes #115",
    "closingIssuesReferences": []
  },
  {
    "number": 27,
    "title": "Dependency-gated claim",
    "body": "Fixes #116",
    "closingIssuesReferences": []
  }
]
JSON
  out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file")
  queue_numbers=$(jq -r '.queue[].number' <<<"$out")
  assert_equals "M45c: queue preserves no-dependency issues and orders by severity" \
    "$queue_numbers" $'102\n109\n110\n111\n108\n101\n106'
  assert_equals "M45d: no-dependency issue has empty deps" \
    "$(jq -r '.queue[] | select(.number == 101) | (.deps | length)' <<<"$out")" "0"
  assert_equals "M45e: explicit closing keyword makes open PR resumable (no claim needed)" \
    "$(jq -r '.resumable[] | select(.number == 103) | .pr_number' <<<"$out")" "20"
  assert_equals "M45e1: GitHub closing reference makes open PR resumable" \
    "$(jq -r '.resumable[] | select(.number == 112) | .pr_number' <<<"$out")" "22"
  assert_equals "M45e2: bare open PR mention remains eligible" \
    "$(jq -r '.queue | map(.number) | index(109) != null' <<<"$out")" "true"
  assert_equals "M45e3: bare open PR mention is not a linked PR" \
    "$(jq -r '.excluded.linked_pr | index(109) == null' <<<"$out")" "true"
  assert_equals "M45e4: one linked PR is resumable without requiring claim label" \
    "$(jq -r '.resumable[] | select(.number == 113) | .pr_number' <<<"$out")" "23"
  assert_equals "M45e4a: resumable row retains the triaged issue version" \
    "$(jq -r '.resumable[] | select(.number == 113) | .updatedAt' <<<"$out")" \
    "2026-01-12T00:00:00Z"
  assert_equals "M45e5: resumable work is not also excluded" \
    "$(jq -r '.excluded.linked_pr | index(113) == null' <<<"$out")" "true"
  resume_candidate_file="$workdir/resume-candidate.json"
  jq '.resumable[] | select(.number == 113)' <<<"$out" > "$resume_candidate_file"
  resume_status=0
  race_out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file") || resume_status=$?
  assert_exit_code "M45e5a: exact unchanged resume candidate passes its live guard" \
    "$resume_status" 0
  assert_equals "M45e5b: successful guard returns the exact queued PR" \
    "$(jq -r .pr_number <<<"$race_out")" "23"
  assert_equals "M45e6: unclaimed linked PR is resumable (WIP-first, no claims)" \
    "$(jq -r '.resumable | map(.number) | index(103) != null' <<<"$out")" "true"
  assert_equals "M45e7: multiple claimed PRs fail closed as ambiguous" \
    "$(jq -r '.excluded.linked_pr | index(114) != null' <<<"$out")" "true"
  assert_equals "M45e8: needs-human still excludes a claimed PR" \
    "$(jq -r '.excluded.needs_human | index(115) != null' <<<"$out")" "true"
  assert_equals "M45e9: claimed PR waits for unmet dependencies" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 116) | (.deps | join(","))' <<<"$out")" "101"
  race_issues_file="$workdir/race-issues.json"
  jq 'map(if .number == 113 then
      .updatedAt = "2026-01-16T00:00:00Z"
    else . end)' "$issues_file" > "$race_issues_file"
  resume_status=0
  bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file" >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45e10: changed issue version fails the exact resume guard" \
    "$resume_status" 3
  jq 'map(if .number == 113 then
      .assignees = [{"login":"investor"}]
    else . end)' "$issues_file" > "$race_issues_file"
  race_out=$(bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file")
  assert_equals "M45e11a: rebuilt queue explicitly excludes assigned work" \
    "$(jq -r '.excluded.assigned | index(113) != null' <<<"$race_out")" "true"
  resume_status=0
  bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file" >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45e11: later assignment fails the exact resume guard" \
    "$resume_status" 3
  jq 'map(if .number == 113 then
      .updatedAt = "2026-01-16T00:00:00Z"
      | .labels += [{"name":"needs-human"}]
    else . end)' "$issues_file" > "$race_issues_file"
  race_out=$(bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file")
  assert_equals "M45e12: later needs-human drift removes a resumable candidate" \
    "$(jq -r '.resumable | map(.number) | index(113) == null' <<<"$race_out")" "true"
  assert_equals "M45e13: rebuilt queue parks the drifted candidate" \
    "$(jq -r '.excluded.needs_human | index(113) != null' <<<"$race_out")" "true"
  resume_status=0
  bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file" >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45e14: later needs-human drift fails the exact resume guard" \
    "$resume_status" 3
  race_prs_file="$workdir/race-prs.json"
  jq '. + [{"number":28,"title":"Competing claim","body":"Fixes #113","closingIssuesReferences":[]}]' \
    "$prs_file" > "$race_prs_file"
  race_out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$race_prs_file")
  assert_equals "M45e15: later second linked PR invalidates resumable identity" \
    "$(jq -r '.resumable | map(.number) | index(113) == null' <<<"$race_out")" "true"
  assert_equals "M45e16: ambiguous replacement stays excluded" \
    "$(jq -r '.excluded.linked_pr | index(113) != null' <<<"$race_out")" "true"
  resume_status=0
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$race_prs_file" \
    --resume-candidate-file "$resume_candidate_file" >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45e17: later second linked PR fails the exact resume guard" \
    "$resume_status" 3
  jq 'map(if .number == 113 then .assignees = "invalid" else . end)' \
    "$issues_file" > "$race_issues_file"
  resume_status=0
  race_out=$(bash "$queue_script" --issues-file "$race_issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$resume_candidate_file" 2>&1) || resume_status=$?
  assert_exit_code "M45e18: malformed live assignees fail the resume guard" \
    "$resume_status" 3
  assert_output_contains "M45e19: malformed issue data has a precise guard diagnostic" \
    "$race_out" 'live resume issue data is malformed'
  jq 'map(if .number == 23 then .closingIssuesReferences = "invalid" else . end)' \
    "$prs_file" > "$race_prs_file"
  resume_status=0
  race_out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$race_prs_file" \
    --resume-candidate-file "$resume_candidate_file" 2>&1) || resume_status=$?
  assert_exit_code "M45e20: malformed live PR schema fails the resume guard" \
    "$resume_status" 3
  assert_output_contains "M45e21: malformed PR data has a precise guard diagnostic" \
    "$race_out" 'live resume PR data is malformed'
  printf '%s\n' '{"number":113,"updatedAt":7,"pr_number":23}' \
    > "$workdir/malformed-resume-candidate.json"
  resume_status=0
  race_out=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --resume-candidate-file "$workdir/malformed-resume-candidate.json" 2>&1) || resume_status=$?
  assert_exit_code "M45e22: malformed candidate schema fails closed" "$resume_status" 3
  assert_output_contains "M45e23: malformed candidate has a precise diagnostic" \
    "$race_out" 'resume candidate is malformed'
  assert_equals "M45f: explicit dependencies defer dependent issue" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 104) | (.deps | join(","))' <<<"$out")" "101,102"
  assert_equals "M45g: needs-human label is excluded" \
    "$(jq -r '.excluded.needs_human | index(105) != null' <<<"$out")" "true"
  assert_equals "M45h: blocked label without durable cooldown remains eligible" \
    "$(jq -r '.queue | map(.number) | index(106) != null' <<<"$out")" "true"
  assert_equals "M45h1: blocked label without durable cooldown requests cleanup" \
    "$(jq -r '.cleanup.stale_maintain_blocked | index(106) != null' <<<"$out")" "true"
  assert_equals "M45i: epic label is excluded" \
    "$(jq -r '.excluded.epic | index(107) != null' <<<"$out")" "true"
  assert_equals "M45j: all open issues are accounted for" \
    "$(jq -r '.unaccounted | length' <<<"$out")" "0"
  filtered=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --label release)
  assert_equals "M45k: label filter keeps matching eligible issue" \
    "$(jq -r '.queue[].number' <<<"$filtered")" "102"
  assert_equals "M45l: label filter accounts for nonmatching issues" \
    "$(jq -r '.excluded.label_filter | index(101) != null' <<<"$filtered")" "true"
  single_issue=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --issue 101 --label release)
  assert_equals "M45m: explicit issue bypasses label filter" \
    "$(jq -r '.queue[].number' <<<"$single_issue")" "101"
  missing_err="$workdir/missing-issue.err"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --issue 999 > /dev/null 2> "$missing_err"
  missing_status=$?
  set -e
  assert_exit_code "M45m1: missing fixture issue fails loudly" "$missing_status" 3
  assert_file_contains "M45m1b: missing fixture issue is named" "$missing_err" "issue #999 was not found in fixture"
  zero_err="$workdir/leading-zero.err"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --issue 007 > /dev/null 2> "$zero_err"
  zero_status=$?
  set -e
  assert_exit_code "M45m2: leading-zero issue is rejected before jq" "$zero_status" 2
  assert_file_contains "M45m3: leading-zero issue error is clear" "$zero_err" "without leading zeros"
  closed_issues_file="$workdir/closed-issues.json"
  cat > "$closed_issues_file" <<'JSON'
[
  {
    "number": 112,
    "state": "CLOSED",
    "title": "Closed fixture issue",
    "body": "Already done.",
    "labels": [],
    "createdAt": "2026-01-12T00:00:00Z",
    "updatedAt": "2026-01-12T00:00:00Z"
  }
]
JSON
  fixture_closed_err="$workdir/fixture-closed.err"
  set +e
  bash "$queue_script" --issues-file "$closed_issues_file" --open-prs-file "$prs_file" --issue 112 > /dev/null 2> "$fixture_closed_err"
  fixture_closed_status=$?
  set -e
  assert_exit_code "M45m4: closed fixture issue fails loudly" "$fixture_closed_status" 3
  assert_file_contains "M45m5: closed fixture issue names state problem" "$fixture_closed_err" "issue #112 is not open"
  blocked_file="$workdir/blocked.jsonl"
  printf '%s\n' \
    '{"number":101,"reason":"cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' \
    '{"number":113,"reason":"resume race","cooldown_until":"2099-01-01T00:00:00Z"}' \
    > "$blocked_file"
  cooled=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$blocked_file")
  assert_equals "M45n: blocked-file cooldown excludes issue" \
    "$(jq -r '.excluded.cooldown | index(101) != null' <<<"$cooled")" "true"
  assert_equals "M45n0a: later cooldown removes a resumable candidate" \
    "$(jq -r '.resumable | map(.number) | index(113) == null' <<<"$cooled")" "true"
  assert_equals "M45n0b: rebuilt queue records the resumable cooldown" \
    "$(jq -r '.excluded.cooldown | index(113) != null' <<<"$cooled")" "true"
  resume_status=0
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --blocked-file "$blocked_file" --resume-candidate-file "$resume_candidate_file" \
    >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45n0c: later cooldown fails the exact resume guard" \
    "$resume_status" 3
  active_blocked_file="$workdir/active-blocked.jsonl"
  printf '%s\n' '{"number":106,"reason":"cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' > "$active_blocked_file"
  active_blocked=$(bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$active_blocked_file")
  assert_equals "M45n1: active durable cooldown excludes blocked-labelled issue" \
    "$(jq -r '.excluded.cooldown | index(106) != null' <<<"$active_blocked")" "true"
  assert_equals "M45n2: active blocked label is not stale" \
    "$(jq -r '.cleanup.stale_maintain_blocked | index(106) == null' <<<"$active_blocked")" "true"
  expired_blocked_file="$workdir/expired-blocked.jsonl"
  printf '%s\n' '{"number":106,"reason":"cooldown","cooldown_until":"2026-01-01T00:00:00Z"}' > "$expired_blocked_file"
  expired_blocked=$(MAINTAIN_QUEUE_NOW=2026-01-02T00:00:00Z bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$expired_blocked_file")
  assert_equals "M45n3: expired durable cooldown restores eligibility" \
    "$(jq -r '.queue | map(.number) | index(106) != null' <<<"$expired_blocked")" "true"
  assert_equals "M45n4: expired durable cooldown requests blocked-label cleanup" \
    "$(jq -r '.cleanup.stale_maintain_blocked | index(106) != null' <<<"$expired_blocked")" "true"
  legacy_blocked_file="$workdir/legacy-blocked.jsonl"
  printf '%s\n' '{"number":106,"reason":"legacy cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' > "$legacy_blocked_file"
  dual_blocked=$(MAINTAIN_QUEUE_NOW=2026-01-02T00:00:00Z bash "$queue_script" \
    --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --blocked-file "$expired_blocked_file" --blocked-file "$legacy_blocked_file")
  assert_equals "M45n5: active legacy cooldown survives dual-read migration" \
    "$(jq -r '.excluded.cooldown | index(106) != null' <<<"$dual_blocked")" "true"
  assert_equals "M45n6: active legacy cooldown prevents stale-label cleanup" \
    "$(jq -r '.cleanup.stale_maintain_blocked | index(106) == null' <<<"$dual_blocked")" "true"
  bad_blocked_file="$workdir/bad-blocked.jsonl"
  bad_blocked_err="$workdir/bad-blocked.err"
  printf '%s\n' '{"number":101,"reason":"cooldown","cooldown_until":"2099-01-01T00:00:00Z"}' 'not-json' > "$bad_blocked_file"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" --blocked-file "$bad_blocked_file" > /dev/null 2> "$bad_blocked_err"
  bad_blocked_status=$?
  set -e
  assert_exit_code "M45n7: malformed blocked-file fails loudly" "$bad_blocked_status" 3
  assert_file_contains "M45n8: malformed blocked-file names file" "$bad_blocked_err" "invalid blocked file: $bad_blocked_file"
  printf '%s\n' '{"number":101,"cooldown_until":"2099-01-01T00:00:00Z"}' > "$bad_blocked_file"
  set +e
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --blocked-file "$bad_blocked_file" > /dev/null 2> "$bad_blocked_err"
  bad_blocked_status=$?
  set -e
  assert_exit_code "M45n9: parseable but invalid cooldown schema fails before queue cleanup" \
    "$bad_blocked_status" 3
  resume_status=0
  bash "$queue_script" --issues-file "$issues_file" --open-prs-file "$prs_file" \
    --blocked-file "$bad_blocked_file" --resume-candidate-file "$resume_candidate_file" \
    >/dev/null 2>&1 || resume_status=$?
  assert_exit_code "M45n9a: malformed cooldown also fails the exact resume guard" \
    "$resume_status" 3
  dep_issues_file="$workdir/dependency-issues.json"
  dep_status_file="$workdir/dependency-status.json"
  cat > "$dep_issues_file" <<'JSON'
[
  {
    "number": 201,
    "title": "Depends on completed prerequisite",
    "body": "Depends on #200; context from #999.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-11T00:00:00Z",
    "updatedAt": "2026-01-11T00:00:00Z"
  }
]
JSON
  cat > "$dep_status_file" <<'JSON'
[
  {
    "number": 200,
    "state": "CLOSED",
    "closedByPullRequestsReferences": [
      {"number": 77, "mergedAt": "2026-01-11T00:00:00Z", "baseRefName": "main"}
    ]
  }
]
JSON
  dep_out=$(bash "$queue_script" --issues-file "$dep_issues_file" --open-prs-file "$prs_file" --dependency-status-file "$dep_status_file" --default-branch main)
  assert_equals "M45o: dependency status fixture marks closed PR-backed prerequisite satisfied" \
    "$(jq -r '.queue[].number' <<<"$dep_out")" "201"
  serial_dep_issues_file="$workdir/serial-dependency-issues.json"
  serial_dep_status_file="$workdir/serial-dependency-status.json"
  cat > "$serial_dep_issues_file" <<'JSON'
[
  {
    "number": 203,
    "title": "Depends on completed and pending prerequisites",
    "body": "Depends on #200, and #202; context from #999.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-12T00:00:00Z",
    "updatedAt": "2026-01-12T00:00:00Z"
  },
  {
    "number": 204,
    "title": "Depends on: #205",
    "body": "**Blocked by:** #200\n\nDepends on:\n- #202\nContext from #999.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-13T00:00:00Z",
    "updatedAt": "2026-01-13T00:00:00Z"
  }
]
JSON
  cat > "$serial_dep_status_file" <<'JSON'
[
  {
    "number": 200,
    "state": "CLOSED",
    "closedByPullRequestsReferences": [
      {"number": 77, "mergedAt": "2026-01-11T00:00:00Z", "baseRefName": "main"}
    ]
  }
]
JSON
  serial_dep_out=$(bash "$queue_script" --issues-file "$serial_dep_issues_file" --open-prs-file "$prs_file" --dependency-status-file "$serial_dep_status_file" --default-branch main)
  assert_equals "M45o1: serial-comma dependency keeps pending prerequisite blocked" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 203) | (.deps | join(","))' <<<"$serial_dep_out")" "202"
  assert_equals "M45o2: markdown dependency syntax keeps pending prerequisites blocked" \
    "$(jq -r '.excluded.dependency_wait[] | select(.number == 204) | (.deps | join(","))' <<<"$serial_dep_out")" "202,205"
  fake_bin="$workdir/bin"
  mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for name in GH_REPO GH_HOST GH_CONFIG_DIR; do
  [ "${!name+x}" != x ] || { printf 'poisoned queue gh environment: %s\n' "$name" >&2; exit 90; }
done
printf '%s\n' "$*" >> "$GH_QUEUE_CALLS"
case "$1 $2" in
  "issue list")
    cat <<'JSON'
[
  {
    "number": 201,
    "title": "Depends on completed prerequisite",
    "body": "Depends on #200; context from #999.",
    "labels": [{"name": "high"}],
    "createdAt": "2026-01-11T00:00:00Z",
    "updatedAt": "2026-01-11T00:00:00Z",
    "closedByPullRequestsReferences": []
  }
]
JSON
    ;;
  "pr list")
    printf '[]\n'
    ;;
  "repo view")
    printf 'main\n'
    ;;
  "issue view")
    if [ "${3:-}" = "200" ]; then
      cat <<'JSON'
{"number":200,"state":"CLOSED","closedByPullRequestsReferences":[{"number":77}]}
JSON
    elif [ "${3:-}" = "202" ]; then
      cat <<'JSON'
{"number":202,"state":"CLOSED","closedByPullRequestsReferences":[]}
JSON
    else
      exit 1
    fi
    ;;
  "pr view")
    [ "${3:-}" = "77" ] || exit 1
    cat <<'JSON'
{"number":77,"state":"MERGED","mergedAt":"2026-01-11T00:00:00Z","baseRefName":"main"}
JSON
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 1
    ;;
esac
SH
  chmod 755 "$fake_bin/gh"
  live_repo="$workdir/live-repo"; gh_calls="$workdir/queue-gh-calls"
  unbound_dir="$workdir/unbound"; unbound_err="$workdir/unbound.err"; mkdir "$unbound_dir"
  : > "$gh_calls"; unbound_status=0
  (cd "$unbound_dir" && GH_QUEUE_CALLS="$gh_calls" PATH="$fake_bin:$PATH" \
    bash "$queue_script" > /dev/null 2> "$unbound_err") || unbound_status=$?
  assert_exit_code "M45o3: an implicit live query without canonical origin fails closed" \
    "$unbound_status" 3
  assert_file_contains "M45o4: unbound live query requests an explicit repository" \
    "$unbound_err" 'pass --repo OWNER/REPO'
  assert_equals "M45o5: repository resolution fails before any gh query" \
    "$(wc -l < "$gh_calls" | tr -d ' ')" 0
  git -C "$workdir" init -q -b main live-repo
  git -C "$live_repo" remote add origin git@github.com:owner/implicit-repo.git
  live_out=$(cd "$live_repo" && GH_QUEUE_CALLS="$gh_calls" GH_REPO=attacker/wrong \
    GH_HOST=attacker.invalid GH_CONFIG_DIR="$workdir/attacker-config" \
    PATH="$fake_bin:$PATH" bash "$queue_script")
  assert_equals "M45p: live gh dependency lookup marks closed PR-backed prerequisite satisfied" \
    "$(jq -r '.queue[].number' <<<"$live_out")" "201"
  assert_equals "M45p1: implicit live queries bind every gh call to canonical remote.origin" \
    "$(awk '$1=="repo" && $2=="view" {if ($3!="owner/implicit-repo") bad=1; next}
      index($0,"--repo github.com/owner/implicit-repo")==0 {bad=1}
      END {print (NR>0 && !bad ? "true" : "false")}' "$gh_calls")" true
  : > "$gh_calls"
  repo_live_out=$(GH_QUEUE_CALLS="$gh_calls" GH_REPO=attacker/wrong GH_HOST=attacker.invalid \
    PATH="$fake_bin:$PATH" bash "$queue_script" --repo owner/repo)
  assert_equals "M45p2: live --repo default-branch lookup uses gh repo view owner/repo" \
    "$(jq -r '.queue[].number' <<<"$repo_live_out")" "201"
  assert_equals "M45p3: explicit live queries bind every gh call to --repo" \
    "$(awk '$1=="repo" && $2=="view" {if ($3!="owner/repo") bad=1; next}
      index($0,"--repo github.com/owner/repo")==0 {bad=1}
      END {print (NR>0 && !bad ? "true" : "false")}' "$gh_calls")" true
  closed_err="$workdir/closed.err"
  set +e
  GH_QUEUE_CALLS="$gh_calls" PATH="$fake_bin:$PATH" bash "$queue_script" \
    --repo owner/repo --issue 202 > /dev/null 2> "$closed_err"
  closed_status=$?
  set -e
  assert_exit_code "M45q: explicit closed issue fails loudly" "$closed_status" 3
  assert_file_contains "M45r: explicit closed issue names state problem" "$closed_err" "issue #202 is not open"
  rm -rf "$workdir"

  # Regression for fast no-op: open>0, new=0, cached agent-fixable => no fast no-op.
  local workdir cache open_json open new cached_deliverable fast_noop
  workdir=$(mktemp -d)
  mkdir -p "$workdir/.startup/maintain"
  cache="$workdir/.startup/maintain/triage-cache.jsonl"
  open_json='[{"number":1350,"updatedAt":"2026-07-04T00:00:00Z","labels":[]},{"number":1351,"updatedAt":"2026-07-04T00:01:00Z","labels":[]}]'
  printf '%s\n' \
    '{"number":1350,"updatedAt":"2026-07-04T00:00:00Z","verdict":"agent-fixable"}' \
    '{"number":1351,"updatedAt":"2026-07-04T00:01:00Z","verdict":"needs-human"}' \
    > "$cache"
  open=$(jq length <<<"$open_json")
  new=$(jq --slurpfile seen <(jq -c '{number, updatedAt}' "$cache") \
    '[.[] | select({number, updatedAt} as $k | ($seen | index($k)) | not)] | length' <<<"$open_json")
  cached_deliverable=$(jq -s --slurpfile open <(printf '%s\n' "$open_json") '
    def matching_open($c):
      any($open[0][]; .number == $c.number and .updatedAt == $c.updatedAt);
    def nonfinal($c):
      (($c.final_state // $c.finalState // "") as $s
       | ($s == "" or ($s | test("^(fixed:|needs-human:|escalated:|skipped:|split:)") | not)));
    [ .[]
      | select(matching_open(.))
      | select(.verdict == "agent-fixable" or .verdict == "partially-fixable")
      | select(nonfinal(.))
    ] | length' "$cache")
  fast_noop=false
  if [ "$open" -eq 0 ] || { [ "$new" -eq 0 ] && [ "$cached_deliverable" -eq 0 ]; }; then
    fast_noop=true
  fi
  assert_equals "M46: cached agent-fixable has no cache miss" "$new" "0"
  assert_equals "M47: cached agent-fixable counted deliverable" "$cached_deliverable" "1"
  assert_equals "M48: cached agent-fixable prevents fast no-op" "$fast_noop" "false"

  printf '%s\n' \
    '{"number":1350,"updatedAt":"2026-07-04T00:00:00Z","verdict":"agent-fixable","final_state":"fixed:PR#12"}' \
    '{"number":1351,"updatedAt":"2026-07-04T00:01:00Z","verdict":"needs-human"}' \
    > "$cache"
  cached_deliverable=$(jq -s --slurpfile open <(printf '%s\n' "$open_json") '
    def matching_open($c):
      any($open[0][]; .number == $c.number and .updatedAt == $c.updatedAt);
    def nonfinal($c):
      (($c.final_state // $c.finalState // "") as $s
       | ($s == "" or ($s | test("^(fixed:|needs-human:|escalated:|skipped:|split:)") | not)));
    [ .[]
      | select(matching_open(.))
      | select(.verdict == "agent-fixable" or .verdict == "partially-fixable")
      | select(nonfinal(.))
    ] | length' "$cache")
  fast_noop=false
  if [ "$open" -eq 0 ] || { [ "$new" -eq 0 ] && [ "$cached_deliverable" -eq 0 ]; }; then
    fast_noop=true
  fi
  assert_equals "M49: cached final state removes deliverability" "$cached_deliverable" "0"
  assert_equals "M50: cached final state permits fast no-op" "$fast_noop" "true"
  rm -rf "$workdir"
}

test_maintain_loop() {
  echo -e "\n${CYAN}== /maintain-loop command ==${NC}"
  local command="$PLUGIN_ROOT/skills/maintain-loop/SKILL.md"
  local cmd_alias="$PLUGIN_ROOT/commands/maintain-loop.md"
  local coordinator="$PLUGIN_ROOT/references/workflows/maintain-policy.md"
  local v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  local codex_cmd="$PLUGIN_ROOT/skills/maintain-loop/SKILL.md"
  local old_codex_cmd="$PLUGIN_ROOT/skills/saas-startup-team-maintain-loop-workflow/SKILL.md"

  assert_file_exists "ML1: maintain-loop command exists" "$cmd_alias"
  assert_file_contains "ML2: command is user invocable" "$cmd_alias" "user_invocable: true"
  assert_file_contains "ML3: concise Codex skill name" "$command" "name: maintain-loop"
  assert_file_exists "ML3b: maintain-v3 engine exists" "$v3"
  assert_file_contains "ML4: parent stays context-thin" "$command" "never read issue bodies"
  assert_file_contains "ML5: parent probes maintain model-free" "$command" 'workflow-probe.sh maintain'
  assert_file_not_contains "ML6: old maintain-loop probe is unused" "$command" \
    'workflow-probe.sh maintain-loop'
  assert_file_contains "ML7: each child runs a bounded maintain pass" "$command" \
    '/saas-startup-team:maintain --once'
  assert_file_contains "ML7b: v3 tick preferred" "$command" 'maintain-v3.sh'
  assert_file_contains "ML8: maintain keeps its own policy" "$command" \
    'Normal triage, ordering, batching, limits, implementation'
  assert_file_contains "ML9: dispatch is exactly one fresh subagent" "$command" \
    'launch exactly one fresh isolated subagent'
  assert_file_contains "ML10: passes are sequential" "$command" \
    'never run two passes concurrently'
  assert_file_contains "ML10a: coordinator forbids noisy wait polling" "$command" \
    'Empty timeouts are not progress'
  assert_file_contains "ML10b: empty waits do not produce status noise" "$command" \
    'or immediately retry them'
  assert_file_contains "ML11: completed subagents are not reused" "$command" \
    'Completed subagent'
  assert_file_contains "ML12: inline fallback is forbidden" "$command" \
    'no inline as a fallback'
  assert_file_contains "ML13: result is compact" "$command" \
    "Keep only the child's compact terminal result"
  assert_file_contains "ML14: no-work exits before dispatch" "$coordinator" \
    'exit 3 is `no-op`'
  assert_file_contains "ML15: outer once bounds child count" "$coordinator" \
    '`--once` launches at most one child'
  assert_file_contains "ML16: dry-run is bounded" "$command" '--dry-run'
  if [ -f "$codex_cmd" ]; then
    assert_file_contains "ML19: Codex requires fresh subagent" "$codex_cmd" \
      'fresh Codex subagents'
  fi
  assert_file_exists "ML30: generated Codex maintain workflow alias exists" \
    "$PLUGIN_ROOT/skills/saas-startup-team-maintain-workflow/SKILL.md"
  assert_file_exists "ML30b: maintain-loop skill exists" "$codex_cmd"
}

test_maintain
test_maintain_loop
