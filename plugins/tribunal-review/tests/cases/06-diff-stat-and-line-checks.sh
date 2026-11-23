#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_codex_vacuous_guard() {
  local verdict="$1" quality="$2" label="$3"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/codex.args"
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"default","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":$quality,"verdict":"$verdict"}}
JSON
EOF
  chmod +x "$fake/codex"

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
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="codex" and (.error | test("vacuous"))' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  if [ "$verdict" = "BLOCK" ] && [ "$quality" = "0.0" ]; then
    local label2="codex reviewer always uses the exact unrestricted launch flag"
    if awk '
      $0 == "--dangerously-bypass-approvals-and-sandbox" { bypass_count++ }
      $0 == "-s" { sandbox_selector_seen = 1 }
      END { exit !(bypass_count == 1 && !sandbox_selector_seen) }
    ' "$work/codex.args" 2>/dev/null; then
      echo -e "  ${GREEN}PASS${NC} $label2"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $label2"; FAIL=$((FAIL+1)); FAILURES+=("$label2")
    fi
  fi
  rm -rf "$work"
}

# A provider can return structurally valid JSON whose line numbers are
# diff-global/prompt positions that cannot exist in the named file (issue #259).
# The runner must mark such findings (and findings on files outside the diff)
# instead of silently accepting them, while leaving valid positions untouched.
test_codex_line_bounds_guard() {
  local label="codex out-of-bounds finding positions are marked, valid ones untouched"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"default","files_examined":["file.txt"],"findings":[
  {"severity":"high","category":"logic","file":"file.txt","line":1,"title":"valid position","description":"d","suggestion":"s","confidence":0.9},
  {"severity":"high","category":"logic","file":"file.txt","line":9333,"title":"diff-global position","description":"d","suggestion":"s","confidence":0.9},
  {"severity":"medium","category":"logic","file":"other.py","line":12,"title":"file outside diff","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"file.txt","line":"9333","title":"string-typed line","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","line":7,"title":"missing file field","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"gone.txt","line":4,"title":"positioned finding in deleted file","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"empty.txt","line":3,"title":"line in emptied file","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"nowhere.py","title":"line-less finding outside diff","description":"d","suggestion":"s","confidence":0.8},
  {"severity":"medium","category":"logic","file":"dots..txt","line":9999,"title":"double-dot filename still bounded","description":"d","suggestion":"s","confidence":0.8}
],"summary":{"total_findings":9,"critical":0,"high":2,"medium":7,"low":0,"quality_score":5.0,"verdict":"NEEDS_WORK"}}
JSON
EOF
  chmod +x "$fake/codex"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    printf 'x = 1\n' > other.py
    printf 'bye\n' > gone.txt
    printf 'x\n' > empty.txt
    git add file.txt other.py gone.txt empty.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git rm -q gone.txt
    : > empty.txt
    printf 'dotted\n' > dots..txt
    git add empty.txt dots..txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '
      (.findings[0] | has("line_check") | not)
      and (.findings[1].line_check | test("out of bounds"))
      and (.findings[2].line_check == "file not in reviewed diff")
      and (.findings[3].line_check == "invalid line number")
      and (.findings[4].line_check == "malformed finding coordinates")
      and (.findings[5].line_check == "file missing at reviewed head")
      and (.findings[6].line_check == "line out of bounds: file has 0 lines")
      and (.findings[7].line_check == "file not in reviewed diff")
      and (.findings[8].line_check == "line out of bounds: file has 1 lines")
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

# Capture once, then change both refs and the worktree while the reviewer runs (#489).
test_line_check_pinned_range() {
  local scenario="$1" label="$2" work paths_absent=true
  work="$(mktemp -d)"
  if (
    set -e
    cd "$work"
    git init -q -b main
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'base\n' > file.txt
    printf 'gone\n' > gone.txt
    printf 'kept\n' > removed-later.txt
    git add file.txt gone.txt removed-later.txt
    git commit -q -m base
    git branch reviewed-base
    unusual=$'quoted"\\\t\n.txt'
    printf 'one\ntwo\nthree\n' > file.txt
    printf 'one\ntwo\n' > "$unusual"
    printf 'kept\nchanged\n' > removed-later.txt
    git rm -q gone.txt
    git add file.txt "$unusual" removed-later.txt
    git commit -q -m captured
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=reviewed-base tribunal_prepare_diff "$work/d.diff"
    [ ! -e "$work/d.diff.paths" ] || paths_absent=false
    stat="$(tribunal_take_diff_stat "$work/d.diff")"
    if [ "$scenario" = moving ]; then
      printf 'short\n' > file.txt
      printf 'short\n' > "$unusual"
      printf 'added later\n' > later.txt
      printf 'restored later\n' > gone.txt
      git rm -q removed-later.txt
      git add file.txt "$unusual" later.txt gone.txt
      git commit -q -m later
      git branch -f reviewed-base HEAD
      printf 'ambient\n%.0s' {1..8} > file.txt
    fi
    jq -n --arg unusual "$unusual" '{findings:[
      {file:"file.txt",line:3}, {file:"file.txt",line:4},
      {file:"later.txt",line:0}, {file:$unusual,line:2},
      {file:"gone.txt",line:1}, {file:"removed-later.txt",line:2}
    ]}' | tribunal_line_check "$work" "$stat" > "$work/out.json"
    if [ "$scenario" = sibling ]; then
      test "$paths_absent" = true || exit 1
    fi
    jq -e '
      (.findings[0] | has("line_check") | not)
      and .findings[1].line_check == "line out of bounds: file has 3 lines"
      and .findings[2].line_check == "file not in reviewed diff"
      and (.findings[3] | has("line_check") | not)
      and .findings[4].line_check == "file missing at reviewed head"
      and (.findings[5] | has("line_check") | not)
    ' "$work/out.json" >/dev/null
  ); then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    cat "$work/out.json" >&2
    if [ -e "$work/d.diff.paths" ]; then echo 'capture left d.diff.paths on disk' >&2; fi
  fi
  rm -rf "$work"
}

test_line_check_unavailable_range() {
  local label="line check leaves unparseable provenance to the stamping stage"
  local stat output ok=true
  local input='{"provider":"codex","findings":[{"line":0},{"file":"outside.txt","line":-1}]}'
  for stat in '' 'not-json' 'null' '{}' '[]' \
    '{"base_oid":42,"head_oid":"HEAD"}' \
    '{"base_oid":"HEAD~1","head_oid":"HEAD"}'; do
    if ! output="$(printf '%s' "$input" | bash -euo pipefail -c \
      '. "$1"; tribunal_line_check "$2" "$3"' _ "$PLUGIN_ROOT/scripts/lib.sh" "$PLUGIN_ROOT" "$stat")" \
      || [ "$output" != "$input" ]; then
      ok=false
      break
    fi
  done
  if [ "$ok" = true ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

# A wrapper agent can hand back a well-formed but fabricated leg envelope, which
# the arbiter cannot distinguish from a genuine clean pass (issue #487). Only a
# runner script can stamp .diff_stat: the provider output schema forbids the
# field and tribunal_emit_review strips any model-authored one.
test_wrapper_stamped_diff_stat() {
  local label="review leg carries the wrapper-stamped diff stat"
  local work fake head
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"provider":"codex","model":"default","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"},"diff_stat":{"files_changed":99}}'
EOF
  chmod +x "$fake/codex"
  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\nthree\n' > file.txt
    printf 'new\n' > added.txt
    git add added.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_DIFF_LIMIT_BYTES=16 \
      bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/capped.json"
  ); then
    head="$(git -C "$work" rev-parse HEAD)"
    if jq -e --arg head "$head" '
        .diff_stat.files_changed == 2 and .diff_stat.insertions == 3
        and .diff_stat.deletions == 1 and .diff_stat.truncated == false
        and .diff_stat.base == "HEAD~1" and .diff_stat.head_oid == $head
      ' "$work/out.json" >/dev/null \
      && jq -e '.diff_stat.truncated == true and .diff_stat.files_changed == 2' "$work/capped.json" >/dev/null; then
      echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    fi
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"

  local label2="model-authored diff_stat is stripped before the wrapper stamps"
  if printf '%s\n' '{"provider":"claude","model":"fixture","files_examined":["file.txt"],"diff_stat":{"files_changed":99},"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
    | bash -c '. "$1"; tribunal_emit_review codex' _ "$PLUGIN_ROOT/scripts/lib.sh" \
    | jq -e 'has("diff_stat") | not' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label2"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label2"; FAIL=$((FAIL+1)); FAILURES+=("$label2")
  fi

  local label_q="pinned range survives a base ref name containing a quote"
  local qwork; qwork="$(mktemp -d)"
  if (
    set -e
    cd "$qwork"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > f.txt
    git add f.txt
    git commit -q -m base
    git branch 'we"ird'
    printf 'two\n' > f.txt
    git commit -q -am change
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF='we"ird' tribunal_prepare_diff "$qwork/d.diff"
  ) && jq -e '.base == "we\"ird" and .files_changed == 1 and .insertions == 1 and .deletions == 1' \
      "$qwork/d.diff.stat" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label_q"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label_q"; FAIL=$((FAIL+1)); FAILURES+=("$label_q")
  fi
  rm -rf "$qwork"

  local label_r="pinned range is taken off disk before the provider runs"
  local rwork; rwork="$(mktemp -d)"
  cat > "$rwork/fake-codex" <<EOF
#!/usr/bin/env bash
cat >/dev/null
find "$rwork" -name '*.stat' > "$rwork/stat-visible" 2>/dev/null
printf '%s\\n' '{"provider":"codex","model":"m","files_examined":["f.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  chmod +x "$rwork/fake-codex"
  if (
    set -e
    cd "$rwork"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > f.txt
    git add f.txt
    git commit -q -m base
    printf 'two\n' > f.txt
    git commit -q -am change
    mkdir -p bin && ln -sf "$rwork/fake-codex" bin/codex
    PATH="$rwork/bin:$PATH" TMPDIR="$rwork" TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$rwork/out.json"
  ) && jq -e '.diff_stat.files_changed == 1' "$rwork/out.json" >/dev/null \
    && [ ! -s "$rwork/stat-visible" ]; then
    echo -e "  ${GREEN}PASS${NC} $label_r"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label_r"; FAIL=$((FAIL+1)); FAILURES+=("$label_r")
  fi
  rm -rf "$rwork"

  local label_s="sha256 repositories stamp 64-hex object ids"
  local swork; swork="$(mktemp -d)"
  if (
    set -e
    cd "$swork"
    git init -q --object-format=sha256
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > f.txt
    git add f.txt
    git commit -q -m base
    . "$PLUGIN_ROOT/scripts/lib.sh"
    TRIBUNAL_BASE_REF=HEAD tribunal_prepare_diff "$swork/d.diff"
  ) && jq -e '(.base_oid | test("^[0-9a-f]{64}$")) and (.head_oid | test("^[0-9a-f]{64}$"))' \
      "$swork/d.diff.stat" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label_s"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label_s"; FAIL=$((FAIL+1)); FAILURES+=("$label_s")
  fi
  rm -rf "$swork"

  local label_u="uncaptured reviewed range becomes an explicit leg error"
  if printf '%s\n' '{"provider":"codex","model":"m","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
    | bash -c '. "$1"; tribunal_stamp_diff_stat ""' _ "$PLUGIN_ROOT/scripts/lib.sh" \
    | jq -e '.provider == "codex" and (.error | test("reviewed range was not captured")) and (has("diff_stat") | not)' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label_u"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label_u"; FAIL=$((FAIL+1)); FAILURES+=("$label_u")
  fi

  local label3="stamp leaves error and disabled legs untouched"
  if printf '%s\n' '{"provider":"codex","error":"boom"}' \
    | bash -c '. "$1"; tribunal_stamp_diff_stat ""' _ "$PLUGIN_ROOT/scripts/lib.sh" \
    | jq -e 'has("diff_stat") | not' >/dev/null \
    && printf '%s\n' '{"provider":"codex","status":"disabled","note":"off"}' \
    | bash -c '. "$1"; tribunal_stamp_diff_stat ""' _ "$PLUGIN_ROOT/scripts/lib.sh" \
    | jq -e 'has("diff_stat") | not' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label3"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label3"; FAIL=$((FAIL+1)); FAILURES+=("$label3")
  fi
}

test_wrapper_owned_provider_envelope() {
  local out
  out="$(printf '%s\n' '{"provider":"claude","status":"disabled","error":"spoof","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
    | bash -c '. "$1"; tribunal_emit_review codex' _ "$PLUGIN_ROOT/scripts/lib.sh")"
  if printf '%s' "$out" | jq -e '.provider=="codex" and (has("status")|not) and (has("error")|not)' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} wrapper owns provider identity and review status"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} wrapper owns provider identity and review status"; FAIL=$((FAIL+1)); FAILURES+=("wrapper-owned provider envelope")
  fi
}


test_codex_vacuous_guard BLOCK 0.0 "codex vacuous empty-BLOCK downgraded to leg error"
test_codex_vacuous_guard NEEDS_WORK 7.5 "codex vacuous empty-NEEDS_WORK (nonzero quality) downgraded to leg error"
test_codex_vacuous_guard " BLOCK " 0.0 "codex vacuous verdict tolerates surrounding whitespace"
test_codex_line_bounds_guard
test_line_check_pinned_range moving "line check uses captured tree after branch and worktree move"
test_line_check_pinned_range sibling "line check rejects outside files without a writable paths sibling"
test_line_check_unavailable_range
test_wrapper_owned_provider_envelope
test_wrapper_stamped_diff_stat
