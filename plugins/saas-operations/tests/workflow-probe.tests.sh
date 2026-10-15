# Host scheduling remains usable with only this plugin installed.
test_workflow_probe() {
  local script="$PLUGIN_ROOT/scripts/workflow-probe.sh" work linked ec out
  work=$(make_workdir)
  mkdir -p "$work/.claude" "$work/legacy-markers" "$work/new-markers"
  printf 'failure\n' > "$work/legacy-markers/service-last-failure.txt"
  cat > "$work/.claude/saas-startup-team.local.md" <<'CFG'
monitor:
  marker_dir: legacy-markers
  custom_checks: legacy-checks.sh
  state_file: legacy/state.json
CFG
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP1: old config alone detects legacy marker' "$ec" 0
  assert_output_contains 'WP1: ready message' "$out" 'work available'

  cat > "$work/.claude/saas-operations.local.md" <<'CFG'
monitor:
  marker_dir: new-markers
  custom_checks: new-checks.sh
  state_file: new/state.json
CFG
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP2: new config wins over legacy marker' "$ec" 3
  assert_output_contains 'WP2: clean no-op message' "$out" 'no work to do'
  printf 'failure\n' > "$work/new-markers/service-last-failure.txt"
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP3: new marker detected' "$ec" 0
  rm "$work/new-markers/service-last-failure.txt"

  cat > "$work/new-checks.sh" <<'CHECK'
#!/usr/bin/env bash
[ "$MONITOR_SINCE_MINUTES" -eq 1440 ] || exit 9
printf '%s\n' '{"pattern_key":"service:error","severity":"high","entity":null,"title":"Failure","body":"Probe failed"}'
CHECK
  chmod +x "$work/new-checks.sh"
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP4: configured custom checks signal ready' "$ec" 0
  assert_json_field 'WP4: findings cached under new state path' "$work/new/state.json.probe-findings" '.pattern_key' 'service:error'
  assert_file_not_exists 'WP4: old state not used' "$work/legacy/state.json.probe-findings"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$work/new-checks.sh"
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP5: recent cache remains ready' "$ec" 0
  assert_json_field 'WP5: recent cache is reused' "$work/new/state.json.probe-findings" '.pattern_key' 'service:error'
  touch -d '2 hours ago' "$work/new/state.json.probe-findings"
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP6: failing check is actionable' "$ec" 0
  assert_json_field 'WP6: failed check generates finding' "$work/new/state.json.probe-findings" '.pattern_key' 'ops:monitor-checks:failure'
  assert_json_field 'WP6: finding preserves failing status' "$work/new/state.json.probe-findings" '.body' 'custom-checks exited 7'
  rm "$work/new/state.json.probe-findings"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$work/new-checks.sh"
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP7: healthy custom check is no-op' "$ec" 3
  assert_file_not_exists 'WP7: no empty findings cache remains' "$work/new/state.json.probe-findings"

  # No merging: even a new config without monitor settings supersedes the old file.
  printf 'operate:\n  logs: []\n' > "$work/.claude/saas-operations.local.md"
  ec=0; out=$(cd "$work" && bash "$script" monitor-nightly 2>&1) || ec=$?
  assert_exit_code 'WP8: new file without monitor block uses defaults' "$ec" 3
  ec=0; out=$(bash "$script" digest --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP9: delivery-only mode rejected' "$ec" 2

  git -C "$work" -c user.name=Test -c user.email=test@example.test commit -qm init --allow-empty
  linked="$TEST_TMP/linked"
  git -C "$work" worktree add --detach -q "$linked"
  mkdir -p "$work/.monitor"
  printf 'failure\n' > "$work/.monitor/service-last-failure.txt"
  ec=0; out=$(cd "$linked" && bash "$script" monitor-nightly 2>&1) || ec=$?
  assert_exit_code 'WP10: linked checkout ignores primary marker' "$ec" 3
  mkdir -p "$linked/.monitor"
  printf 'failure\n' > "$linked/.monitor/service-last-failure.txt"
  ec=0; out=$(cd "$linked" && bash "$script" monitor-nightly 2>&1) || ec=$?
  assert_exit_code 'WP11: linked checkout reads its own marker' "$ec" 0

  # Inline YAML comments (and quotes) on values resolve like the skill's cfg().
  rm -rf "$work/.monitor"
  mkdir -p "$work/cm-markers"
  printf 'failure\n' > "$work/cm-markers/service-last-failure.txt"
  cat > "$work/.claude/saas-operations.local.md" <<'CFG'
monitor:
  marker_dir: cm-markers   # commented marker dir
  custom_checks: cm-checks.sh  # commented checks
  state_file: cm/state.json # commented state
CFG
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP12: commented marker_dir finds marker' "$ec" 0
  rm "$work/cm-markers/service-last-failure.txt"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" '"'"'{"pattern_key":"cm:error","severity":"high","entity":null,"title":"F","body":"b"}'"'"'\n' > "$work/cm-checks.sh"
  chmod +x "$work/cm-checks.sh"
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP13: commented custom_checks runs' "$ec" 0
  assert_json_field 'WP13: cache beside commented state_file' "$work/cm/state.json.probe-findings" '.pattern_key' 'cm:error'

  # Parity: probe monitor_value and skill cfg() resolve every value form identically.
  skill="$PLUGIN_ROOT/skills/monitor-nightly/SKILL.md"
  eval "$(sed -n '/^monitor_value() {/,/^}/p' "$script")"
  eval "$(sed -n '/^cfg() {/,/^}/p' "$skill")"
  while IFS= read -r line; do
    raw="${line%@@*}"; want="${line##*@@}"
    block="  k: $raw"; mon_block="$block"
    assert_equals "WP14: probe resolves [$raw]" "$(monitor_value k)" "$want"
    assert_equals "WP14: skill resolves [$raw]" "$(cfg k)" "$want"
  done <<'TBL'
".monitor" # x@@.monitor
'a b' # it's@@a b
x.sh # customer's checks@@x.sh
a#b@@a#b
# note@@
|@@
.monitor@@.monitor
"ssh h \\"x\\""@@ssh h \\"x\\"
"ssh h \\"x\\"" # c@@ssh h \\"x\\"
'it''s' # c@@it''s
|   @@
TBL

  # Quoted value followed by a comment still resolves the configured marker_dir.
  rm -rf "$work/cm-markers"; mkdir -p "$work/qm"
  printf 'failure\n' > "$work/qm/service-last-failure.txt"
  printf 'monitor:\n  marker_dir: "qm" # quoted\n' > "$work/.claude/saas-operations.local.md"
  ec=0; out=$(bash "$script" monitor-nightly --root "$work" 2>&1) || ec=$?
  assert_exit_code 'WP15: quoted+comment marker_dir finds marker' "$ec" 0
}

test_workflow_probe
