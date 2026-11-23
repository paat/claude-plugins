#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_blind_approve_guard() {
  local work stat base head out label

  # (b1) findings:[] + APPROVE + files_examined:[] → failed
  label="blind APPROVE with empty files_examined is a provider error"
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    printf '%s\n' '{"provider":"codex","model":"m","files_examined":[],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
      | tribunal_stamp_diff_stat "$stat" > "$work/out.json"
    jq -e '.provider=="codex" and (.error|test("blind APPROVE")) and (has("diff_stat")|not)' "$work/out.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  # (b2) findings:[] + APPROVE + files_examined lists only unchanged paths → failed
  label="blind APPROVE listing only unchanged paths is a provider error"
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    printf 'keep\n' > other.txt
    git add file.txt other.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    printf '%s\n' '{"provider":"codex","model":"m","files_examined":["other.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
      | tribunal_stamp_diff_stat "$stat" > "$work/out.json"
    jq -e '.provider=="codex" and (.error|test("blind APPROVE")) and (has("diff_stat")|not)' "$work/out.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  # (b3) findings:[] + APPROVE + files_examined contains a changed path → ok
  label="empty-findings APPROVE with examined changed path stamps ok"
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    printf '%s\n' '{"provider":"codex","model":"m","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
      | tribunal_stamp_diff_stat "$stat" > "$work/out.json"
    jq -e '.provider=="codex" and (has("error")|not) and .diff_stat.files_changed==1 and .files_examined==["file.txt"]' \
      "$work/out.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  # (b4) missing files_examined → failed
  label="missing files_examined is a provider error"
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    printf '%s\n' '{"provider":"codex","model":"m","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
      | tribunal_stamp_diff_stat "$stat" > "$work/out.json"
    jq -e '.provider=="codex" and (.error|test("files_examined")) and (has("diff_stat")|not)' "$work/out.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  # (b5) empty-range tribunal_empty leg remains ok
  label="empty-range tribunal_empty leg remains ok with files_examined:[]"
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD tribunal_prepare_diff "$work/d.diff"
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    tribunal_empty fixture fixture-model HEAD "$stat" > "$work/empty.json"
    jq -e '.files_examined==[] and .summary.verdict=="APPROVE" and .diff_stat.files_changed==0' \
      "$work/empty.json" >/dev/null
    tribunal_stamp_diff_stat "$stat" < "$work/empty.json" > "$work/stamped.json"
    jq -e '(has("error")|not) and .files_examined==[] and .diff_stat.files_changed==0' \
      "$work/stamped.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  # (b6) collector rejects absolute or ../ files_examined entries
  label="collector validate_provider rejects absolute or ../ files_examined"
  work="$(mktemp -d)"
  if (
    set -euo pipefail
    base="$(printf 'a%.0s' {1..40})"; head="$(printf 'b%.0s' {1..40})"
    stat_json="$(jq -nc --arg b "$base" --arg h "$head" \
      '{files_changed:1,insertions:1,deletions:0,base:"HEAD~1",base_oid:$b,head_oid:$h,truncated:false}')"
    mk_leg() {
      jq -nc --argjson examined "$1" --argjson ds "$stat_json" \
        '{provider:"codex",model:"m",files_examined:$examined,findings:[],
          summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"},
          diff_stat:$ds}'
    }
    mk_leg '["file.txt"]' > "$work/ok.json"
    mk_leg '["/abs/file.txt"]' > "$work/abs.json"
    mk_leg '["../escape.txt"]' > "$work/dotdot.json"
    eval "$(sed -n '/^validate_provider()/,/^}/p' "$PLUGIN_ROOT/scripts/collector-validate.sh")"
    validate_provider codex "$work/ok.json"
    if validate_provider codex "$work/abs.json"; then exit 1; fi
    if validate_provider codex "$work/dotdot.json"; then exit 1; fi
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  # (b7) zero-findings APPROVE 0.95 shortcut unreachable when one of three legs is blind
  label="blind APPROVE among three legs blocks zero-findings APPROVE 0.95 shortcut"
  work="$(mktemp -d)"
  local repo fake plugin collection manifest_sha base head ec=0
  repo="$work/repo"; fake="$work/bin"; plugin="$work/plugin"
  mkdir -p "$repo" "$fake" "$plugin/scripts" "$plugin/schemas" "$plugin/.claude-plugin" "$plugin/integrity"
  cp "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" "$PLUGIN_ROOT/scripts/"collector-*.sh "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$PLUGIN_ROOT/scripts/"lib-*.sh "$PLUGIN_ROOT/scripts/review-panel.tsv" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/check-runner-bundle.sh" "$PLUGIN_ROOT/scripts/generate-runner-bundle.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/dsh-review.patch.yml" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/schemas/review-output.json" "$plugin/schemas/"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$plugin/.claude-plugin/plugin.json"
  cat > "$plugin/scripts/run-codex-review.sh" <<'EOF'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$(tribunal_repo_root)"
DIFF_FILE="$(mktemp)"
trap 'rm -f "$DIFF_FILE"' EXIT
BASE_REF="$(tribunal_base_ref)"
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error codex "cannot diff"; exit 0; }
DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
printf '%s\n' '{"provider":"codex","model":"fixture","files_examined":["app.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
  | tribunal_stamp_diff_stat "$DIFF_STAT"
EOF
  cat > "$plugin/scripts/run-claude-review.sh" <<'EOF'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
DIFF_FILE="$(mktemp)"
trap 'rm -f "$DIFF_FILE"' EXIT
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error claude "cannot diff"; exit 0; }
DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
printf '%s\n' '{"provider":"claude","model":"fixture","files_examined":["app.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
  | tribunal_stamp_diff_stat "$DIFF_STAT"
EOF
  # Blind Grok APPROVE: empty files_examined.
  cat > "$plugin/scripts/run-grok-review.sh" <<'EOF'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
DIFF_FILE="$(mktemp)"
trap 'rm -f "$DIFF_FILE"' EXIT
tribunal_prepare_diff "$DIFF_FILE" || { tribunal_error grok "cannot diff"; exit 0; }
DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"
printf '%s\n' '{"provider":"grok","model":"fixture","files_examined":[],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
  | tribunal_stamp_diff_stat "$DIFF_STAT"
EOF
  for provider in gemini qwen muse; do
    cat > "$plugin/scripts/run-$provider-review.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '{"provider":"$provider","status":"disabled","note":"fixture disabled"}'
EOF
  done
  cat > "$plugin/scripts/run-deepseek-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"provider":"deepseek","status":"disabled","note":"fixture disabled"}'
EOF
  chmod +x "$plugin/scripts/"*.sh
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > app.txt
    git add app.txt
    git commit -q -m base
    printf 'two\n' > app.txt
    git commit -q -am change
    git remote add origin https://github.com/example/fixture.git
  )
  base="$(git -C "$repo" rev-parse HEAD~1)"; head="$(git -C "$repo" rev-parse HEAD)"
  printf 'Bound PR body' > "$work/pr-body"
  cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = repo ] && [ "$2" = view ]; then
  jq -nc '{nameWithOwner:"example/fixture",url:"https://github.com/example/fixture"}'
elif [ "$1" = pr ] && [ "$2" = view ]; then
  jq -nc --argjson number "$3" --arg base "$FIXTURE_BASE" --arg head "$FIXTURE_HEAD" \
    --rawfile body "$FIXTURE_BODY_FILE" \
    '{number:$number,url:("https://github.com/example/fixture/pull/"+($number|tostring)),state:"OPEN",
      baseRefName:"main",baseRefOid:$base,headRefName:"feature",headRefOid:$head,body:$body}'
else
  printf 'unexpected gh invocation: %s\n' "$*" >&2
  exit 2
fi
EOF
  chmod +x "$fake/gh"
  collection="$work/collection"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    TRIBUNAL_CODEX=on TRIBUNAL_CLAUDE=on TRIBUNAL_GROK=on \
    TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_DEEPSEEK=off \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$collection" > "$work/collect.json" \
    && jq -e '
        any(.providers[]; .provider=="codex" and .status=="ok")
        and any(.providers[]; .provider=="claude" and .status=="ok")
        and any(.providers[]; .provider=="grok" and .status=="failed")
      ' "$collection/manifest.json" >/dev/null \
    && jq -e 'has("error") and (.error|test("blind APPROVE"))' "$collection/providers/grok.json" >/dev/null; then
    manifest_sha="$(jq -r .manifest_sha256 "$work/collect.json")"
    cat > "$work/arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"Zero findings across usable legs."},
  "findings":[],"scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"failed"},
    "muse":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"}
  },
  "conflicts_resolved":[],"summary":"Blind leg must block the 0.95 shortcut."
}
EOF
    ec=0
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
        --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
        >/dev/null 2>"$work/finalize.err" || ec=$?
    if [ "$ec" -ne 0 ]; then
      echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $label (finalize accepted APPROVE 0.95)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    fi
  else
    echo -e "  ${RED}FAIL${NC} $label (collection/status setup)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    cat "$work/collect.json" 2>/dev/null || true
    cat "$collection/providers/grok.json" 2>/dev/null || true
  fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"

  # (b8) large changed-path list must not blow argv when verifying files_examined
  label="empty-findings APPROVE over a large changed-path list stamps ok"
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'base\n' > README
    git add README
    git commit -q -m base
    mkdir -p bulk
    i=1
    while [ "$i" -le 3000 ]; do
      # ~70-byte paths so --name-only -z exceeds 200 KiB (argv-limit regression).
      printf 'x\n' > "bulk/padded-name-$(printf '%05d' "$i")-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.txt"
      i=$((i + 1))
    done
    git add bulk
    git commit -q -m change
    examined="bulk/padded-name-00001-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.txt"
    # Guard the fixture size: --name-only -z output must exceed 200 KiB.
    git diff --name-only -z HEAD~1...HEAD --no-ext-diff --no-textconv > "$work/names.z"
    size="$(wc -c < "$work/names.z" | tr -d ' ')"
    [ "$size" -gt 204800 ]
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    jq -nc --arg f "$examined" \
      '{provider:"codex",model:"m",files_examined:[$f],findings:[],
        summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"}}' \
      | tribunal_stamp_diff_stat "$stat" > "$work/out.json"
    jq -e --arg f "$examined" '
        .provider=="codex"
        and (has("error")|not)
        and (.diff_stat|type)=="object"
        and .files_examined==[$f]
      ' "$work/out.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  # (b9) rename source path counts as changed: empty-findings APPROVE listing
  # only the rename-from path must stamp ok (default rename detection would omit it).
  label="empty-findings APPROVE listing rename source path stamps ok"
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'content\n' > old.txt
    git add old.txt
    git commit -q -m base
    git mv old.txt new.txt
    git commit -q -m rename
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    printf '%s\n' '{"provider":"codex","model":"m","files_examined":["old.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
      | tribunal_stamp_diff_stat "$stat" > "$work/out.json"
    jq -e '.provider=="codex" and (has("error")|not) and (.diff_stat|type)=="object" and .files_examined==["old.txt"]' \
      "$work/out.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  # (b10) ./ prefix on a changed path must still overlap: empty-findings APPROVE
  # with files_examined:["./<changed>"] stamps ok (exact-string match would miss it).
  label="empty-findings APPROVE with ./prefixed examined changed path stamps ok"
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    printf '%s\n' '{"provider":"codex","model":"m","files_examined":["./file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
      | tribunal_stamp_diff_stat "$stat" > "$work/out.json"
    jq -e '.provider=="codex" and (has("error")|not) and .diff_stat.files_changed==1 and .files_examined==["./file.txt"]' \
      "$work/out.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

# Issue #671: every examined path must exist in at least one pinned tree.
test_examined_paths_pinned() {
  local work scenario label stat examined findings expectation git_bin path name
  work="$(mktemp -d)"
  git_bin="$(command -v git)"
  (
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    mkdir -p directory
    printf 'base\n' > changed.txt
    printf 'deleted\n' > deleted.txt
    printf 'tree child\n' > directory/child.txt
    git add .
    git commit -q -m base
    printf 'head\n' > changed.txt
    rm deleted.txt
    printf 'added\n' > added.txt
    printf 'invalid UTF-8 filename\n' > $'bad-\377.txt'
    for name in 'space name.txt' $'line\nbreak.txt' $'tab\tname.txt' 'colon:name.txt' 'back\slash.txt'; do
      printf 'unusual\n' > "$name"
    done
    git add .
    git commit -q -m head
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD~1 tribunal_prepare_diff "$work/d.diff"
    tribunal_take_diff_stat "$work/d.diff" > "$work/stat.json"
    # A tracked ambient revision must not rescue a path absent from pinned trees.
    printf 'ambient\n' > ambient.txt
    git add ambient.txt
    git commit -q -m ambient
  )
  (
    mkdir "$work/merge-base"
    cd "$work/merge-base"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'gone\n' > gone.txt
    git add gone.txt
    git commit -q -m base
    git branch main-fixture
    git checkout -q -b feature-fixture
    git rm -q gone.txt
    git commit -q -m feature-delete
    git checkout -q main-fixture
    git rm -q gone.txt
    git commit -q -m main-delete
    git commit -q --allow-empty -m main-advance
    git checkout -q feature-fixture
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=main-fixture tribunal_prepare_diff "$work/merge-base.diff"
    tribunal_take_diff_stat "$work/merge-base.diff" > "$work/merge-base-stat.json"
  )
  mkdir "$work/bin"
  cat > "$work/bin/git" <<'GIT'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    merge-base)
      [ "${FAIL_MERGE_BASE:-0}" != 1 ] || exit 1
      ;;
    ls-tree|cat-file)
      printf '%s\n' "$arg" >> "$LOOKUP_LOG"
      [ "${FAIL_LOOKUP:-0}" != 1 ] || exit 1
      ;;
  esac
done
exec "$REAL_GIT" "$@"
GIT
  chmod +x "$work/bin/git"
  for scenario in absent_empty absent_findings empty_path dot_path valid_findings ambient deleted added prefixed unusual directory \
    missing_base missing_head omitted_base omitted_head lookup_failure empty_range large_list bounded_error \
    invalid_utf8_alias nul_path merge_base_empty merge_base_findings merge_base_failure; do
    label="pinned examined paths: $scenario"
    if (
      cd "$work"
      . "$PLUGIN_ROOT/scripts/lib.sh"
      export REAL_GIT="$git_bin" LOOKUP_LOG="$work/lookups" PATH="$work/bin:$PATH" FAIL_LOOKUP=0 FAIL_MERGE_BASE=0
      : > "$LOOKUP_LOG"
      stat="$(cat "$work/stat.json")"
      examined='["changed.txt"]'
      findings='[]'
      expectation=ok
      case "$scenario" in
        absent_empty|absent_findings)
          examined='["changed.txt","invented.txt"]'; expectation=absent ;;
        empty_path) examined='["changed.txt",""]'; expectation=malformed_path ;;
        dot_path) examined='["changed.txt","./"]'; expectation=empty_path ;;
        ambient) examined='["changed.txt","ambient.txt"]'; expectation=ambient ;;
        merge_base_empty|merge_base_findings)
          cd "$work/merge-base"
          stat="$(cat "$work/merge-base-stat.json")"
          examined='["gone.txt"]' ;;
        deleted) examined='["deleted.txt"]' ;;
        added) examined='["added.txt"]' ;;
        prefixed) examined='["././changed.txt"]' ;;
        unusual) examined='["changed.txt","space name.txt","line\nbreak.txt","tab\tname.txt","colon:name.txt","back\\slash.txt"]' ;;
        directory) examined='["changed.txt","directory"]' ;;
        invalid_utf8_alias) examined='["changed.txt","bad-\ufffd.txt"]'; expectation=utf8_alias ;;
        nul_path) examined='["changed.txt","changed.txt\u0000"]'; expectation=unavailable ;;
        missing_base|missing_head)
          stat="$(printf '%s' "$stat" | jq --arg key "${scenario#missing_}_oid" '.[$key] = ("0" * 40)')"
          expectation=unavailable ;;
        omitted_base|omitted_head)
          stat="$(printf '%s' "$stat" | jq --arg key "${scenario#omitted_}_oid" 'del(.[$key])')"
          expectation=unavailable ;;
        merge_base_failure) export FAIL_MERGE_BASE=1; expectation=unavailable ;;
        lookup_failure) export FAIL_LOOKUP=1; expectation=unavailable ;;
        empty_range)
          stat="$(printf '%s' "$stat" | jq '.files_changed = 0 | .head_oid = .base_oid')"
          examined='[]' ;;
        large_list) examined='["changed.txt"]' ;;
        bounded_error) expectation=bounded ;;
      esac
      case "$scenario" in
        absent_findings|empty_path|dot_path|valid_findings|missing_*|omitted_*|lookup_failure|merge_base_findings)
          findings='[{"severity":"medium","category":"logic","file":"changed.txt","line":1,"title":"fixture","description":"fixture defect","suggestion":"fix fixture","confidence":0.9}]' ;;
      esac
      if [ "$scenario" = merge_base_findings ]; then
        findings="$(printf '%s' "$findings" | jq '.[0].file = "gone.txt"')"
      fi
      jq -nc --argjson examined "$examined" --argjson findings "$findings" \
        '{provider:"codex",model:"fixture",files_examined:$examined,findings:$findings,
          summary:{total_findings:($findings|length),critical:0,high:0,medium:($findings|length),low:0,
                   quality_score:8,verdict:(if ($findings|length)==0 then "APPROVE" else "NEEDS_WORK" end)}}' > review.json
      if [ "$scenario" = large_list ]; then
        jq '.files_examined = [range(20000) | "changed.txt"]' review.json > large.json
        mv large.json review.json
        [ "$(wc -c < review.json)" -gt 131072 ] || exit 1
      elif [ "$scenario" = bounded_error ]; then
        jq '.files_examined += [range(100) | "invented-\(.).txt"]' review.json > many.json
        mv many.json review.json
      fi
      tribunal_stamp_diff_stat "$stat" < review.json > out.json
      case "$expectation" in
        ok)
          jq -e --argjson stat "$stat" --slurpfile review review.json \
            '.provider=="codex" and (has("error")|not) and .diff_stat==$stat
             and .files_examined==$review[0].files_examined' out.json >/dev/null || exit 1 ;;
        absent|ambient|bounded|utf8_alias)
          case "$expectation" in
            absent) path=invented.txt ;; ambient) path=ambient.txt ;;
            bounded) path=invented-0.txt ;; utf8_alias) path=$'bad-\xef\xbf\xbd.txt' ;;
          esac
          jq -e --arg path "$path" '.provider=="codex" and (.error|contains($path))
            and (has("diff_stat")|not)' out.json >/dev/null || exit 1
          if [ "$expectation" = bounded ]; then
            jq -e '(.error|length)<2000 and (.error|contains("invented-99.txt")|not)' out.json >/dev/null || exit 1
          fi ;;
        malformed_path)
          jq -e '.provider=="codex" and (.error|contains("not an array of non-empty strings"))
            and (has("diff_stat")|not)' out.json >/dev/null || exit 1 ;;
        empty_path)
          jq -e '.provider=="codex" and (.error|contains("paths absent from pinned"))
            and (.error|contains("[\"\"]")) and (has("diff_stat")|not)' out.json >/dev/null || exit 1 ;;
        unavailable)
          jq -e '.provider=="codex" and (.error|type)=="string" and (has("diff_stat")|not)' out.json >/dev/null || exit 1 ;;
      esac
      if [ "$scenario" = merge_base_failure ]; then
        jq -e '.error | contains("merge-base unavailable")' out.json >/dev/null || exit 1
        [ ! -s "$LOOKUP_LOG" ] || exit 1
      elif [ "$scenario" = large_list ] || [[ "$scenario" = merge_base_* ]]; then
        # All three trees share one batch, independent of examined-list size.
        [ "$(cat "$LOOKUP_LOG")" = cat-file ] || exit 1
      elif [ "$scenario" = empty_range ]; then
        [ ! -s "$LOOKUP_LOG" ] || exit 1
      fi
    ); then
      echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    fi
  done
  rm -rf "$work"
}

test_sealed_panel_quorum() {
  local work repo fake plugin collection manifest_sha base head ec=0
  work="$(mktemp -d)"; repo="$work/repo"; fake="$work/bin"; plugin="$work/plugin"
  mkdir -p "$repo" "$fake" "$plugin/scripts" "$plugin/schemas" "$plugin/.claude-plugin" "$plugin/integrity"
  cp "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" "$PLUGIN_ROOT/scripts/"collector-*.sh "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$PLUGIN_ROOT/scripts/"lib-*.sh "$PLUGIN_ROOT/scripts/review-panel.tsv" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/check-runner-bundle.sh" "$PLUGIN_ROOT/scripts/generate-runner-bundle.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/dsh-review.patch.yml" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/schemas/review-output.json" "$plugin/schemas/"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$plugin/.claude-plugin/plugin.json"

  cat > "$plugin/scripts/run-codex-review.sh" <<'EOF'
#!/usr/bin/env bash
base="$(git rev-parse --verify "${TRIBUNAL_BASE_REF}^{commit}")"
head="$(git rev-parse --verify 'HEAD^{commit}')"
printf '%s\n' "{\"provider\":\"codex\",\"model\":\"fixture\",\"files_examined\":[\"app.txt\"],\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10,\"verdict\":\"APPROVE\"},\"diff_stat\":{\"files_changed\":1,\"insertions\":1,\"deletions\":0,\"base\":\"$TRIBUNAL_BASE_REF\",\"base_oid\":\"$base\",\"head_oid\":\"$head\",\"truncated\":false}}"
EOF
  for provider in gemini qwen grok muse claude; do
    cat > "$plugin/scripts/run-$provider-review.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '{"provider":"$provider","status":"disabled","note":"fixture disabled"}'
EOF
  done
  cat > "$plugin/scripts/run-deepseek-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"provider":"deepseek","status":"disabled","note":"fixture disabled"}'
EOF
  chmod +x "$plugin/scripts/"*.sh
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null

  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > app.txt
    git add app.txt
    git commit -q -m base
    printf 'two\n' > app.txt
    git commit -q -am change
    git remote add origin https://github.com/example/fixture.git
  )
  base="$(git -C "$repo" rev-parse HEAD~1)"; head="$(git -C "$repo" rev-parse HEAD)"
  printf 'Bound PR body' > "$work/pr-body"
  cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = repo ] && [ "$2" = view ]; then
  jq -nc '{nameWithOwner:"example/fixture",url:"https://github.com/example/fixture"}'
elif [ "$1" = pr ] && [ "$2" = view ]; then
  jq -nc --argjson number "$3" --arg base "$FIXTURE_BASE" --arg head "$FIXTURE_HEAD" \
    --rawfile body "$FIXTURE_BODY_FILE" \
    '{number:$number,url:("https://github.com/example/fixture/pull/"+($number|tostring)),state:"OPEN",
      baseRefName:"main",baseRefOid:$base,headRefName:"feature",headRefOid:$head,body:$body}'
else
  printf 'unexpected gh invocation: %s\n' "$*" >&2
  exit 2
fi
EOF
  chmod +x "$fake/gh"

  collection="$work/collection"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    TRIBUNAL_MIN_OK_LEGS=2 \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$collection" > "$work/collect.json"; then
    echo -e "  ${RED}FAIL${NC} collect seals panel_policy under TRIBUNAL_MIN_OK_LEGS=2"; FAIL=$((FAIL+1))
    FAILURES+=("collect seals panel_policy"); rm -rf "$work"; return
  fi
  manifest_sha="$(jq -r .manifest_sha256 "$work/collect.json")"
  if jq -e '.panel_policy.min_ok_legs == 2 and .panel_policy.panel_size == 3 and (.panel_policy.panel | type == "array") and .panel_policy.source == "env"' "$collection/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} collect seals panel_policy from TRIBUNAL_MIN_OK_LEGS"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} collect seals panel_policy from TRIBUNAL_MIN_OK_LEGS"; FAIL=$((FAIL+1))
    FAILURES+=("collect seals panel_policy")
  fi

  cat > "$work/arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"One valid reviewer found no defects."},
  "findings":[],"scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "muse":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"}
  },
  "conflicts_resolved":[],"summary":"No blocking findings."
}
EOF
  # Ambient floor lowered to 1 must not weaken the sealed floor of 2.
  ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    TRIBUNAL_MIN_OK_LEGS=1 \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
      >/dev/null 2>&1 || ec=$?
  if [ "$ec" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${NC} sealed panel_policy floor beats ambient TRIBUNAL_MIN_OK_LEGS"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} sealed panel_policy floor beats ambient TRIBUNAL_MIN_OK_LEGS"; FAIL=$((FAIL+1))
    FAILURES+=("sealed panel_policy integrity")
  fi

  # Recovery policy is fixed at collection, including when ambient settings change.
  cat > "$plugin/scripts/run-grok-review.sh" <<'EOF_GROK'
#!/usr/bin/env bash
bash "$(dirname "$0")/run-codex-review.sh" | jq '.provider="grok" | .grok_execution={verdict_phase:"finalize",inspect_exit_code:124,requested_effort:"high",verdict_effort:"low"}'
EOF_GROK
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
  local recovery_policy recovery_status opposite
  for recovery_policy in permit reject; do
    collection="$work/recovery-$recovery_policy"
    recovery_status=ok; opposite=reject
    if [ "$recovery_policy" = reject ]; then recovery_status=failed; opposite=permit; fi
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      TRIBUNAL_MIN_OK_LEGS=2 TRIBUNAL_GROK_RECOVERY="$recovery_policy" \
      "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
        --output "$collection" > "$work/collect-recovery.json"
    manifest_sha="$(jq -r .manifest_sha256 "$work/collect-recovery.json")"
    if jq -e --arg policy "$recovery_policy" --arg status "$recovery_status" '
      .grok_recovery==$policy and .panel_policy.min_ok_legs==2 and (.providers|length)==7
      and any(.providers[]; .provider=="grok" and .status==$status)' "$collection/manifest.json" >/dev/null \
      && { [ "$recovery_policy" = permit ] || jq -e '.error|contains("grok_recovery_rejected")' "$collection/providers/grok.json" >/dev/null; }; then
      echo -e "  ${GREEN}PASS${NC} collector seals $recovery_policy recovery policy, named status and unchanged panel floor"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} collector seals $recovery_policy recovery policy, named status and unchanged panel floor"; FAIL=$((FAIL+1))
      FAILURES+=("sealed $recovery_policy recovery policy")
    fi
    jq '{tribunal_verdict:{decision:"APPROVE",confidence:(if any(.providers[];.status=="failed") then 0.9 else 0.95 end),rationale:"Fixture review."},
      findings:[],scope_findings:[],conflicts_resolved:[],summary:"Fixture review.",
      provider_assessment:(.providers|map({key:.provider,value:{status:.status,findings_accepted:0,findings_rejected:0,false_positives:[]}})|from_entries)}' \
      "$collection/manifest.json" > "$work/arbitration-recovery.json"
    ec=0
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      TRIBUNAL_MIN_OK_LEGS=1 TRIBUNAL_GROK_RECOVERY="$opposite" \
      "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
        --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration-recovery.json" \
        > "$work/finalize-recovery.json" 2> "$work/finalize-recovery.err" || ec=$?
    if { [ "$recovery_policy" = permit ] && [ "$ec" -eq 0 ]; } \
      || { [ "$recovery_policy" = reject ] && [ "$ec" -ne 0 ] && grep -q 'arbitration' "$work/finalize-recovery.err"; }; then
      echo -e "  ${GREEN}PASS${NC} sealed $recovery_policy recovery and quorum survive opposite finalize environment"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} sealed $recovery_policy recovery and quorum survive opposite finalize environment"; FAIL=$((FAIL+1))
      FAILURES+=("sealed $recovery_policy recovery finalize")
    fi
  done

  # Substitute a valid recovered verdict and reseal it to reach policy verification.
  collection="$work/recovery-reject"
  chmod u+w "$collection/providers/grok.json" "$collection/manifest.json"
  cp "$work/recovery-permit/providers/grok.json" "$collection/providers/grok.json"
  jq --arg digest "$(sha256sum "$collection/providers/grok.json" | awk '{print $1}')" \
    --argjson bytes "$(wc -c < "$collection/providers/grok.json")" '
    (.providers[]|select(.provider=="grok")) |=
      (.status="ok" | .artifact.sha256=$digest | .artifact.bytes=$bytes)
    ' "$collection/manifest.json" > "$work/resealed-manifest.json"
  cat "$work/resealed-manifest.json" > "$collection/manifest.json"
  chmod 0444 "$collection/providers/grok.json" "$collection/manifest.json"
  manifest_sha="$(sha256sum "$collection/manifest.json" | awk '{print $1}')"
  local command
  for command in verify-collection finalize; do
    local recovery_args=()
    [ "$command" != finalize ] || recovery_args=(--arbitration "$work/arbitration-recovery.json")
    ec=0
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      TRIBUNAL_GROK_RECOVERY=permit \
      "$plugin/scripts/collect-review-evidence.sh" "$command" --collection "$collection" \
        --expected-manifest-sha256 "$manifest_sha" "${recovery_args[@]}" \
        >/dev/null 2> "$work/substituted-recovery.err" || ec=$?
    if [ "$ec" -ne 0 ] && grep -Fq 'grok_recovery_rejected: artifact violates sealed recovery policy' "$work/substituted-recovery.err"; then
      echo -e "  ${GREEN}PASS${NC} $command rejects resealed recovery despite ambient permit"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $command rejects resealed recovery despite ambient permit"; FAIL=$((FAIL+1))
      FAILURES+=("$command sealed recovery policy verification")
    fi
  done

  if bash "$PLUGIN_ROOT/scripts/check-runner-bundle.sh" | jq -e '.status=="valid"' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} runner bundle valid after panel quorum changes"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} runner bundle valid after panel quorum changes"; FAIL=$((FAIL+1))
    FAILURES+=("runner bundle after panel quorum")
  fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}


test_blind_approve_guard
test_examined_paths_pinned
test_sealed_panel_quorum
