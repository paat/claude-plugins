# Legacy drain inventory/drain/verify + multi-worktree coexistence (#389).
declare -F assert_file_exists >/dev/null 2>&1 || {
  echo "legacy-drain.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_legacy_drain() {
  echo -e "\n${CYAN}Suite LD: legacy-drain + multi-worktree (#389)${NC}"
  local drain="$PLUGIN_ROOT/scripts/legacy-drain.sh"
  local v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  local repo common state_root issue_dir inv out ec head path wt1 wt2 state

  assert_file_exists "LD1: legacy-drain exists" "$drain"
  assert_file_not_exists "LD2: maintain-leases gone" "$PLUGIN_ROOT/scripts/maintain-leases.sh"
  assert_file_not_exists "LD3: single-flight gone" "$PLUGIN_ROOT/scripts/single-flight.sh"
  assert_file_not_exists "LD4: maintain-delivery gone" "$PLUGIN_ROOT/scripts/maintain-delivery.sh"

  repo=$(mktemp -d)
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  echo base > "$repo/app.txt"
  git -C "$repo" add app.txt
  git -C "$repo" commit -qm base
  head=$(git -C "$repo" rev-parse HEAD)
  common=$(git -C "$repo" rev-parse --git-common-dir)
  case "$common" in /*) ;; *) common="$repo/$common" ;; esac
  common=$(cd "$common" && pwd -P)
  state_root="$common/saas-startup-team/maintain-runtime/deliveries"
  issue_dir="$state_root/issue-42"
  mkdir -p "$issue_dir"

  # Abandoned claimed receipt (recoverable offline)
  cat >"$issue_dir/current.json" <<'JSON'
{
  "schema_version": 1,
  "delivery_id": "run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "origin_run_id": "run-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "generation": 1,
  "issue_number": 42,
  "issue_updated_at": "2026-01-01T00:00:00Z",
  "origin_issue_digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "state": "claimed",
  "updated_at": "2026-01-01T00:00:00Z",
  "reopened_event": null,
  "normal": null,
  "rollback": null,
  "release": null,
  "close": null,
  "final": null
}
JSON

  # Unresolved mid-flight with PR number
  mkdir -p "$state_root/issue-99"
  cat >"$state_root/issue-99/current.json" <<'JSON'
{
  "schema_version": 1,
  "delivery_id": "run-cccccccccccccccccccccccccccccccc",
  "origin_run_id": "run-dddddddddddddddddddddddddddddddd",
  "generation": 1,
  "issue_number": 99,
  "issue_updated_at": "2026-01-01T00:00:00Z",
  "origin_issue_digest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "state": "normal_open",
  "updated_at": "2026-01-01T00:00:00Z",
  "reopened_event": null,
  "normal": {
    "action_id": "act1",
    "base_branch": "main",
    "base_sha": "1111111111111111111111111111111111111111",
    "body_digest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "branch": "fix/x",
    "head_sha": "2222222222222222222222222222222222222222",
    "merge": null,
    "merge_method": null,
    "pr_number": 7,
    "premerge": null,
    "state": "open"
  },
  "rollback": null,
  "release": null,
  "close": null,
  "final": null
}
JSON

  inv=$(bash "$drain" inventory --repo-root "$repo" --json)
  assert_equals "LD5: inventory engine" "$(jq -r .engine <<<"$inv")" "legacy-drain"
  assert_equals "LD6: source_intact flag" "$(jq -r .source_intact <<<"$inv")" "true"
  assert_equals "LD7: recoverable count" "$(jq -r .summary.recoverable <<<"$inv")" "1"
  assert_equals "LD8: unresolved count" "$(jq -r .summary.unresolved <<<"$inv")" "1"
  assert_equals "LD9: no secrets field true" "$(jq -r '[.items[].secrets]|all(not)' <<<"$inv")" "true"

  # Dry-run does not mutate
  bash "$drain" drain --repo-root "$repo" --json >/dev/null
  [ -f "$issue_dir/current.json" ]
  assert_exit_code "LD10: source still present after dry-run" "$?" 0
  [ ! -d "$common/saas-startup-team/legacy-drain/markers" ] \
    || [ -z "$(ls -A "$common/saas-startup-team/legacy-drain/markers" 2>/dev/null || true)" ]
  assert_exit_code "LD11: dry-run wrote no markers (or empty)" "$?" 0

  # Apply: marker + human task; sources intact
  out=$(bash "$drain" drain --repo-root "$repo" --apply --json) || true
  assert_equals "LD12: markers written" "$(jq -r .markers_written <<<"$out")" "1"
  assert_file_exists "LD13: drain marker for 42" \
    "$common/saas-startup-team/legacy-drain/markers/issue-42.json"
  assert_file_exists "LD14: source 42 intact" "$issue_dir/current.json"
  assert_file_exists "LD15: source 99 intact" "$state_root/issue-99/current.json"
  assert_file_contains "LD16: human task for 99" "$repo/docs/human-tasks.md" \
    'Legacy maintain receipt #99'
  assert_file_not_contains "LD17: human task has no body/secret shapes" \
    "$repo/docs/human-tasks.md" 'origin_issue_digest'
  assert_file_not_contains "LD18: no absolute paths in task" \
    "$repo/docs/human-tasks.md" "$repo"

  # Idempotent re-apply
  out=$(bash "$drain" drain --repo-root "$repo" --apply --json) || true
  assert_equals "LD19: second apply markers 0" "$(jq -r .markers_written <<<"$out")" "0"
  assert_equals "LD20: issue 42 drained" \
    "$(jq -r '.items[]|select(.issue==42)|.kind' <<<"$out")" "drained"

  # Multi native worktrees coexist
  wt1=$(mktemp -d)
  wt2=$(mktemp -d)
  git -C "$repo" worktree add --detach "$wt1" HEAD >/dev/null
  git -C "$repo" worktree add --detach "$wt2" HEAD >/dev/null
  state=$(mktemp -d)
  out=$(bash "$v3" isolate prepare --repo-root "$repo" --issue 7 --state-dir "$state")
  assert_equals "LD21: isolation while extras exist" "$(jq -r .prepared <<<"$out")" "true"
  assert_equals "LD22: isolation not primary" "$(jq -r .mutates_primary <<<"$out")" "false"
  path=$(jq -r .path <<<"$out")
  [ "$path" != "$repo" ]
  assert_exit_code "LD23: isolate path != primary" "$?" 0

  # Cancel/cleanup must not reset primary
  printf 'dirty\n' > "$repo/app.txt"
  bash "$v3" isolate cleanup --repo-root "$repo" --issue 7 --state-dir "$state" >/dev/null
  assert_equals "LD24: primary still dirty after isolate cleanup" \
    "$(cat "$repo/app.txt")" "dirty"
  assert_equals "LD25: primary HEAD unchanged" \
    "$(git -C "$repo" rev-parse HEAD)" "$head"
  # Explicit: no reset/clean helper remains
  assert_file_not_exists "LD26: no maintain-attempt reset" \
    "$PLUGIN_ROOT/scripts/maintain-attempt.sh"

  # Only short lock kinds in maintain-v3
  assert_file_contains "LD27: scheduler lock" "$v3" 'scheduler'
  assert_file_contains "LD28: issue lock" "$v3" 'issue'
  assert_file_contains "LD29: release lock" "$v3" 'release'
  assert_file_not_contains "LD30: no maintain-pass lease" "$v3" 'maintain-pass'

  # legacy-import still read-only and leaves .startup
  mkdir -p "$repo/.startup"
  printf '{"status":"running"}\n' > "$repo/.startup/state.json"
  bash "$PLUGIN_ROOT/scripts/legacy-import.sh" --root "$repo" --json >/dev/null
  assert_file_exists "LD31: import left state.json" "$repo/.startup/state.json"
  assert_equals "LD32: import did not mutate state" \
    "$(cat "$repo/.startup/state.json")" '{"status":"running"}'

  git -C "$repo" worktree remove --force "$wt1" 2>/dev/null || rm -rf "$wt1"
  git -C "$repo" worktree remove --force "$wt2" 2>/dev/null || rm -rf "$wt2"
  rm -rf -- "$repo" "$state" "$wt1" "$wt2"
}

test_legacy_drain
