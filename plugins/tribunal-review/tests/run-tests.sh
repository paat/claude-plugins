#!/bin/bash
# Test runner for tribunal-review plugin.
# Usage: bash plugins/tribunal-review/tests/run-tests.sh
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0; FAILURES=()
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

# Pin product defaults so host shell exports cannot flip panel membership mid-suite.
# Per-test prefixes still override (e.g. TRIBUNAL_GROK=off for disabled-marker cases).
export TRIBUNAL_GROK=on
export TRIBUNAL_GEMINI=off
export TRIBUNAL_QWEN=off
export TRIBUNAL_GLM=off
export TRIBUNAL_DEEPSEEK=off
# Smoke is opt-in; never inherit a host-on probe into default preflight checks.
export TRIBUNAL_SMOKE_PROBE=off

assert_grep() {
  local label="$1" file="$2" pat="$3"
  if grep -q -- "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_no_grep() {
  local label="$1" file="$2" pat="$3"
  if grep -q -- "$pat" "$PLUGIN_ROOT/$file"; then
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  else
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  fi
}

assert_file() {
  local label="$1" file="$2"
  if [ -f "$PLUGIN_ROOT/$file" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_executable() {
  local label="$1" file="$2"
  if [ -x "$PLUGIN_ROOT/$file" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_bash_n() {
  local label="$1" file="$2"
  if bash -n "$PLUGIN_ROOT/$file"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

assert_json_field() {
  local label="$1" command="$2"
  if eval "$command" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
}

test_ignored_path_additions() {
  local work fake base ignored_json preflight_json clean_json clean_rc rename_json copy_json clean_rename_json
  local dirty_added_json dirty_removed_json subdir_preflight_json
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  git -C "$work" init -q -b main
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf '# never commit\nscratch/\n*.log\n!keep.log\n' > "$work/.gitignore"
  printf 'tracked secret\n' > "$work/secret.env"
  mkdir -p "$work/scratch"
  printf 'already tracked\n' > "$work/scratch/already.md"
  git -C "$work" add .gitignore secret.env
  git -C "$work" add -f scratch/already.md
  git -C "$work" commit -q -m base
  base="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q -b feature
  printf 'normal\n' > "$work/normal.md"
  printf 're-included addition\n' > "$work/keep.log"
  printf 'ignored addition\n' > "$work/scratch/note.md"
  git -C "$work" add normal.md keep.log
  git -C "$work" add -f scratch/note.md
  git -C "$work" commit -q -m feature

  ignored_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_ignored_additions "$base" 2>/dev/null)" || true
  if printf '%s' "$ignored_json" | jq -e '
      length == 1 and .[0] == {path:"scratch/note.md",pattern:"scratch/",source:".gitignore",line:2}
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} ignored addition reports path, pattern, and ignore source line"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} ignored addition reports path, pattern, and ignore source line"; FAIL=$((FAIL+1)); FAILURES+=("ignored addition details")
  fi
  if printf '%s' "$ignored_json" | jq -e 'all(.[]; .path != "scratch/already.md")' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} ignored path tracked before reviewed range is not reported"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} ignored path tracked before reviewed range is not reported"; FAIL=$((FAIL+1)); FAILURES+=("pre-existing ignored path exclusion")
  fi

  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/codex"; chmod +x "$fake/codex"
  preflight_json="$(cd "$work" && PATH="$fake:$PATH" TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF="$base" \
    TRIBUNAL_CODEX=on TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
    bash "$PLUGIN_ROOT/scripts/preflight.sh" 2>/dev/null)" || true
  if printf '%s' "$preflight_json" | jq -e '
      any(.warnings[]; .name == "ignored-path-additions"
        and (.note | contains("scratch/note.md"))
        and (.note | contains("scratch/"))
        and (.note | contains(".gitignore:2")))
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} preflight warns about ignored path additions"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} preflight warns about ignored path additions"; FAIL=$((FAIL+1)); FAILURES+=("preflight ignored addition warning")
  fi

  subdir_preflight_json="$(cd "$work/scratch" && PATH="$fake:$PATH" TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF="$base" \
    TRIBUNAL_CODEX=on TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
    bash "$PLUGIN_ROOT/scripts/preflight.sh" 2>/dev/null)" || true
  if printf '%s' "$subdir_preflight_json" | jq -e '
      any(.warnings[]; .name == "ignored-path-additions" and (.note | contains("scratch/note.md")))
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} preflight from a subdirectory finds ignored additions"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} preflight from a subdirectory finds ignored additions"; FAIL=$((FAIL+1)); FAILURES+=("subdirectory preflight ignored addition")
  fi

  printf '# never commit\n*.log\n!keep.log\n' > "$work/.gitignore"
  dirty_removed_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_ignored_additions "$base" 2>/dev/null)" || true
  if printf '%s' "$dirty_removed_json" | jq -e '
      . == [{path:"scratch/note.md",pattern:"scratch/",source:".gitignore",line:2}]
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} uncommitted ignore-rule removal cannot hide a committed force-add"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} uncommitted ignore-rule removal cannot hide a committed force-add"; FAIL=$((FAIL+1)); FAILURES+=("dirty ignore-rule removal")
  fi
  git -C "$work" checkout -q -- .gitignore

  git -C "$work" checkout -q -b clean "$base"
  printf 'clean\n' > "$work/clean.md"
  git -C "$work" add clean.md
  git -C "$work" commit -q -m clean
  clean_rc=0
  clean_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_ignored_additions "$base" 2>/dev/null)" || clean_rc=$?
  preflight_json="$(cd "$work" && PATH="$fake:$PATH" TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF="$base" \
    TRIBUNAL_CODEX=on TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
    bash "$PLUGIN_ROOT/scripts/preflight.sh" 2>/dev/null)" || true
  if [ "$clean_rc" -eq 0 ] && [ "$clean_json" = '[]' ] \
    && printf '%s' "$preflight_json" | jq -e 'all(.warnings[]; .name != "ignored-path-additions")' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} normal additions produce no ignored-path warning"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} normal additions produce no ignored-path warning"; FAIL=$((FAIL+1)); FAILURES+=("clean ignored addition check")
  fi

  printf '\nclean.md\n' >> "$work/.gitignore"
  dirty_added_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_ignored_additions "$base" 2>/dev/null)" || true
  if [ "$dirty_added_json" = '[]' ]; then
    echo -e "  ${GREEN}PASS${NC} uncommitted ignore rule cannot create an ignored-path finding"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} uncommitted ignore rule cannot create an ignored-path finding"; FAIL=$((FAIL+1)); FAILURES+=("dirty ignore-rule addition")
  fi
  git -C "$work" checkout -q -- .gitignore

  git -C "$work" checkout -q -b ignored-rename "$base"
  git -C "$work" mv secret.env scratch/secret.env
  git -C "$work" commit -q -m 'rename into ignored path'
  rename_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_ignored_additions "$base" 2>/dev/null)" || true
  if printf '%s' "$rename_json" | jq -e '
      . == [{path:"scratch/secret.env",pattern:"scratch/",source:".gitignore",line:2}]
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} rename into ignored path is reported"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} rename into ignored path is reported"; FAIL=$((FAIL+1)); FAILURES+=("ignored destination rename")
  fi

  git -C "$work" checkout -q -b ignored-copy "$base"
  git -C "$work" config diff.renames copies
  cp "$work/secret.env" "$work/scratch/copy.env"
  printf 'source changed after copy\n' >> "$work/secret.env"
  git -C "$work" add secret.env
  git -C "$work" add -f scratch/copy.env
  git -C "$work" commit -q -m 'copy into ignored path'
  copy_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_ignored_additions "$base" 2>/dev/null)" || true
  if printf '%s' "$copy_json" | jq -e '
      . == [{path:"scratch/copy.env",pattern:"scratch/",source:".gitignore",line:2}]
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} copy into ignored path is reported"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} copy into ignored path is reported"; FAIL=$((FAIL+1)); FAILURES+=("ignored destination copy")
  fi

  git -C "$work" checkout -q -b clean-rename "$base"
  git -C "$work" mv secret.env public.env
  git -C "$work" commit -q -m 'rename outside ignored paths'
  clean_rename_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_ignored_additions "$base" 2>/dev/null)" || true
  if printf '%s' "$clean_rename_json" | jq -e 'length == 0' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} rename between non-ignored paths is not reported"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} rename between non-ignored paths is not reported"; FAIL=$((FAIL+1)); FAILURES+=("non-ignored rename exclusion")
  fi
  rm -rf "$work"
}

test_ignored_path_diff_failures() {
  local work fake base real_git helper_out helper_rc=0 preflight_rc=0
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  real_git="$(command -v git)"
  git -C "$work" init -q -b main
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf 'base\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m base
  base="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q -b feature
  printf 'feature\n' > "$work/feature.txt"
  git -C "$work" add feature.txt
  git -C "$work" commit -q -m feature

  helper_out="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" \
    && tribunal_ignored_additions no-such-ref-xyz 2>/dev/null)" || helper_rc=$?
  if [ "$helper_rc" -ne 0 ] && [ "$helper_out" != '[]' ]; then
    echo -e "  ${GREEN}PASS${NC} ignored-addition inspection fails for an unresolvable base ref"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} ignored-addition inspection fails for an unresolvable base ref"; FAIL=$((FAIL+1)); FAILURES+=("ignored-addition diff failure")
  fi

  cat > "$fake/git" <<'EOF'
#!/usr/bin/env bash
saw_diff=0
for arg in "$@"; do
  [ "$arg" != diff ] || saw_diff=1
  [ "$saw_diff" -eq 0 ] || [ "$arg" != --name-only ] || exit 128
done
exec "$TRIBUNAL_TEST_REAL_GIT" "$@"
EOF
  chmod +x "$fake/git"
  (
    cd "$work"
    PATH="$fake:$PATH" TRIBUNAL_TEST_REAL_GIT="$real_git" \
      TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF="$base" \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/preflight.out" 2> "$work/preflight.err"
  ) || preflight_rc=$?
  if [ "$preflight_rc" -ne 0 ] \
    && grep -Fxq 'PREFLIGHT FAIL: cannot inspect ignored path additions.' "$work/preflight.err"; then
    echo -e "  ${GREEN}PASS${NC} preflight surfaces ignored-addition diff failure"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} preflight surfaces ignored-addition diff failure"; FAIL=$((FAIL+1)); FAILURES+=("preflight ignored-addition diff failure")
  fi
  rm -rf "$work"
}

test_ignored_path_validation() {
  local work artifact value label
  work="$(mktemp -d)"; artifact="$work/ignored-paths.json"
  source <(sed -n '/^validate_ignored_paths() {/,/^}/p' \
    "$PLUGIN_ROOT/scripts/collect-review-evidence.sh")

  for value in '""' null 5; do
    jq -n --argjson path "$value" '[{line:2,path:$path,pattern:"scratch/",source:".gitignore"}]' > "$artifact"
    label="ignored-path validator rejects path: $value"
    if validate_ignored_paths "$artifact"; then
      echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    else
      echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
    fi
  done

  jq -n '[{line:2,path:"scratch/note.md",pattern:"scratch/",source:".gitignore"}]' > "$artifact"
  if validate_ignored_paths "$artifact"; then
    echo -e "  ${GREEN}PASS${NC} ignored-path validator accepts a relative path"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} ignored-path validator accepts a relative path"; FAIL=$((FAIL+1)); FAILURES+=("relative ignored-path validation")
  fi

  jq -n '[{line:2,path:"/scratch/note.md",pattern:"scratch/",source:".gitignore"}]' > "$artifact"
  if validate_ignored_paths "$artifact"; then
    echo -e "  ${RED}FAIL${NC} ignored-path validator rejects an absolute path"; FAIL=$((FAIL+1)); FAILURES+=("absolute ignored-path validation")
  else
    echo -e "  ${GREEN}PASS${NC} ignored-path validator rejects an absolute path"; PASS=$((PASS+1))
  fi
  rm -rf "$work"
}

test_empty_staged_diff_with_real_changes_fails_closed() {
  local label="empty staged diff with real changes is a leg error" work base_oid head_oid
  work="$(mktemp -d)"
  git -C "$work" init -q
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf 'base\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m base
  base_oid="$(git -C "$work" rev-parse HEAD)"
  printf 'changed\n' > "$work/file.txt"
  git -C "$work" commit -q -am change
  head_oid="$(git -C "$work" rev-parse HEAD)"

  (
    cd "$work"
    . "$PLUGIN_ROOT/scripts/lib.sh"
    tribunal_empty fixture fixture-model HEAD~1
  ) > "$work/out.json"

  if jq -e --arg base "$base_oid" --arg head "$head_oid" '
      .provider == "fixture"
      and has("error")
      and (.error | contains("resolved base ref HEAD~1"))
      and (.error | contains($base))
      and (.error | contains($head))
      and (.error | contains("a non-empty diff exists"))
    ' "$work/out.json" >/dev/null \
    && ! grep -q '"verdict":"APPROVE"' "$work/out.json"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_genuine_empty_diff_is_reverified_and_unchanged() {
  local label="genuine empty diff is reverified before unchanged approval" work
  work="$(mktemp -d)"
  git -C "$work" init -q
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf 'base\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m base

  (
    cd "$work"
    . "$PLUGIN_ROOT/scripts/lib.sh"
    GIT_TRACE="$work/git.trace" tribunal_empty fixture fixture-model HEAD
  ) > "$work/out.json"

  if jq -e '
      .provider == "fixture"
      and .model == "fixture-model"
      and .findings == []
      and .summary.total_findings == 0
      and .summary.critical == 0
      and .summary.high == 0
      and .summary.medium == 0
      and .summary.low == 0
      and (.summary.quality_score | type == "number" and . == 10)
      and .summary.verdict == "APPROVE"
      and .summary.note == "No changes detected vs HEAD"
    ' "$work/out.json" >/dev/null \
    && grep -Fq 'rev-parse' "$work/git.trace" \
    && grep -Fq 'diff --quiet' "$work/git.trace"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_unresolvable_base_during_empty_verification_fails_closed() {
  local label="unresolvable base during empty verification is a leg error" work
  work="$(mktemp -d)"
  git -C "$work" init -q
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  printf 'base\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -q -m base

  (
    cd "$work"
    . "$PLUGIN_ROOT/scripts/lib.sh"
    tribunal_empty fixture fixture-model refs/heads/missing
  ) > "$work/out.json"

  if jq -e '
      .provider == "fixture"
      and has("error")
      and (.error | contains("base ref refs/heads/missing did not resolve to a commit"))
    ' "$work/out.json" >/dev/null \
    && ! grep -q '"verdict":"APPROVE"' "$work/out.json"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_qwen_envelope_parser() {
  local label="qwen result envelope parsed" work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/qwen" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"type":"assistant","message":{"model":"qwen-envelope-test","content":null}},
  {"type":"result","model":"qwen-envelope-test","result":"{\"provider\":\"qwen\",\"model\":\"placeholder\",\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10.0,\"verdict\":\"APPROVE\"}}"}
]
JSON
EOF
  chmod +x "$fake/qwen"

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
    PATH="$fake:$PATH" TRIBUNAL_QWEN=on TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-qwen-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="qwen" and .model=="qwen-envelope-test" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

test_claude_auth_guard() {
  local label="expired Claude auth is skipped before provider execution" work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ] && [ "${3:-}" = "--json" ]; then
  printf '%s\n' '{"loggedIn":false,"authMethod":"none"}'
  exit 1
fi
: > "${CLAUDE_RUN_MARKER:?}"
exit 99
EOF
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fake/claude" "$fake/codex"

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
    export PATH="$fake:$PATH" CLAUDE_RUN_MARKER="$work/provider-ran"
    TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_CODEX=on TRIBUNAL_CLAUDE=on \
      TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=off \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/preflight.json"
    bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$work/review.json"
  ) && jq -e 'any(.providers[]; .name=="claude" and .status=="skipped" and .note=="CLI not authenticated")' "$work/preflight.json" >/dev/null \
    && jq -e '.provider=="claude" and .error=="Claude CLI is not authenticated"' "$work/review.json" >/dev/null \
    && [ ! -e "$work/provider-ran" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_preflight_smoke_probe() {
  local label="opt-in preflight smoke verifies every enabled transport" work fake ec=0
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
[ "${SMOKE_CODEX_EMPTY:-off}" = on ] && exit 0
printf '%s\n' '{"provider":"codex","model":"smoke","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
printf '%s\n' '{"structured_output":{"provider":"claude","model":"smoke","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}}'
EOF
  cat > "$fake/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  printf '%s\n' opencode-go/deepseek-v4-pro opencode-go/glm-5.1
  exit 0
fi
printf '%s\n' '{"provider":"deepseek","model":"smoke","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  chmod +x "$fake/codex" "$fake/claude" "$fake/opencode"

  (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    git checkout -qb feature
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
      TRIBUNAL_DEEPSEEK=on TRIBUNAL_SMOKE_PROBE=on bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/preflight.json"
  )
  if jq -e '
      [.providers[] | select(.name=="codex" or .name=="claude" or .name=="deepseek")]
      | length==3 and all(.[]; .status=="usable" and .note=="non-interactive smoke passed")
    ' "$work/preflight.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi

  (
    cd "$work"
    # Only codex remains eligible; empty smoke must zero the usable quorum.
    PATH="$fake:$PATH" SMOKE_CODEX_EMPTY=on TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF=HEAD~1 \
      TRIBUNAL_SMOKE_PROBE=on TRIBUNAL_CLAUDE=off TRIBUNAL_DEEPSEEK=off \
      TRIBUNAL_GROK=off TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_GLM=off \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > /dev/null 2> "$work/preflight-failed.err"
  ) || ec=$?
  label="failed smoke removes the provider from usable quorum"
  if [ "$ec" -eq 1 ] \
    && grep -q 'zero active reviewer legs are usable' "$work/preflight-failed.err" \
    && grep -q 'non-interactive smoke failed:' "$work/preflight-failed.err" \
    && grep -q 'phase=parse; exit=0; stdout_bytes=0' "$work/preflight-failed.err" \
    && grep -q 'stderr_bytes=0' "$work/preflight-failed.err"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_claude_tmpdir_cleanup() {
  local label="Claude auth and review residue stays in the cleaned runner tempdir"
  local work fake parent_tmp used_tmpdir
  work="$(mktemp -d)"
  fake="$work/bin"
  parent_tmp="$work/parent-tmp"
  mkdir -p "$fake" "$parent_tmp"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-review}" "${TMPDIR:-}" >> "${CLAUDE_TMPDIR_MARKER:?}"
: > "${TMPDIR:?}/claude-native-residue.so"
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
cat <<'JSON'
{"result":"{\"provider\":\"claude\",\"model\":\"fixture\",\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10.0,\"verdict\":\"APPROVE\"}}"}
JSON
EOF
  chmod +x "$fake/claude"

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
    TMPDIR="$parent_tmp" PATH="$fake:$PATH" CLAUDE_TMPDIR_MARKER="$work/tmpdirs" \
      TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" \
      > "$work/out.json"
  ) && jq -e '.provider=="claude" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null \
    && [ "$(wc -l < "$work/tmpdirs")" -eq 2 ] \
    && [ "$(cut -f2 "$work/tmpdirs" | sort -u | wc -l)" -eq 1 ] \
    && used_tmpdir="$(cut -f2 "$work/tmpdirs" | head -1)" \
    && [ "$used_tmpdir" != "$parent_tmp" ] \
    && [ ! -e "$used_tmpdir" ] \
    && [ -z "$(find "$parent_tmp" -mindepth 1 -print -quit)" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_opencode_wal_isolation() {
  local label="DeepSeek bypasses a stale shared OpenCode WAL" work fake shared_data stale_db
  work="$(mktemp -d)"
  fake="$work/bin"
  shared_data="$work/shared-data"
  stale_db="$shared_data/opencode/opencode.db"
  mkdir -p "$fake" "$shared_data/opencode"
  printf '%s\n' '{"fixture_auth":true}' > "$shared_data/opencode/auth.json"
  : > "$stale_db"
  printf '%s\n' stale > "$stale_db-wal"
  : > "$stale_db-shm"
  cat > "$fake/opencode" <<'EOF'
#!/usr/bin/env bash
data_home="${XDG_DATA_HOME:-${HOME:-}/.local/share}"
db="${OPENCODE_DB:-$data_home/opencode/opencode.db}"
printf '%s\n' "$db" > "${FIXTURE_OPENCODE_DB_FILE:?}"
[ "$data_home" != "${FIXTURE_SHARED_DATA_HOME:?}" ] \
  && grep -qx '{"fixture_auth":true}' "$data_home/opencode/auth.json" || exit 1
if [ -e "$db-wal" ]; then
  printf '%s\n' 'Failed query: PRAGMA wal_checkpoint(PASSIVE)' >&2
  exit 1
fi
printf '%s\n' '{"provider":"deepseek","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  chmod +x "$fake/opencode"

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
    OPENCODE_DB="$stale_db" PATH="$fake:$PATH" XDG_DATA_HOME="$shared_data" \
      FIXTURE_OPENCODE_DB_FILE="$work/opencode-db" FIXTURE_SHARED_DATA_HOME="$shared_data" \
      TRIBUNAL_GLM=off \
      TRIBUNAL_DEEPSEEK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-opencode-review.sh" > "$work/out.json"
  ) && jq -s -e '
      length == 2
      and .[0].provider == "glm" and .[0].status == "disabled"
      and .[1].provider == "deepseek" and .[1].summary.verdict == "APPROVE"
    ' "$work/out.json" >/dev/null \
    && [ "$(cat "$work/opencode-db")" != "$stale_db" ] \
    && [ -f "$stale_db-wal" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

run_opencode_failure_fixture() {
  local label="$1" exit_code="$2" stderr_text="$3" assertion="$4"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  printf '%s\n' "$stderr_text" > "$work/opencode.stderr"
  cat > "$fake/opencode" <<'EOF'
#!/usr/bin/env bash
cat "${FIXTURE_OPENCODE_STDERR:?}" >&2
exit "${FIXTURE_OPENCODE_EXIT:?}"
EOF
  chmod +x "$fake/opencode"

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
    PATH="$fake:$PATH" FIXTURE_OPENCODE_STDERR="$work/opencode.stderr" \
      FIXTURE_OPENCODE_EXIT="$exit_code" TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=on \
      TRIBUNAL_BASE_REF=HEAD~1 bash "$PLUGIN_ROOT/scripts/run-opencode-review.sh" \
      > "$work/out.json"
  ) && jq -s -e \
      'length == 2 and .[0].status == "disabled" and (.[1] | has("error"))' \
      "$work/out.json" >/dev/null \
    && eval "$assertion"; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_opencode_timeout_error() {
  run_opencode_failure_fixture \
    "OpenCode timeout is an error and names its timeout duration" 124 "" \
    "jq -s -e '.[1].error | contains(\"OpenCode execution timed out after 720s\")' \"\$work/out.json\" >/dev/null"
}

test_opencode_killed_error() {
  run_opencode_failure_fixture \
    "OpenCode kill is ambiguous and names its elapsed budget" 137 "" \
    "jq -s -e '.[1].error | contains(\"OpenCode execution timed out or was killed after 720s\")' \"\$work/out.json\" >/dev/null"
}

test_opencode_gated_model_error() {
  run_opencode_failure_fixture \
    "OpenCode gated model error is classified without leaking stderr" 1 \
    "Error: The latest version of this model is only available hosted in China and requires explicit opt in DECOY_SECRET_TOKEN" \
    "jq -s -e '.[1].error | contains(\"deepseek leg unavailable: provider rejected model '\''opencode-go/deepseek-v4-pro'\'' (requires explicit opt-in)\") and (contains(\"timed out\") | not) and (contains(\"DECOY_SECRET_TOKEN\") | not)' \"\$work/out.json\" >/dev/null"
}

test_opencode_gated_tool_trace_is_generic_error() {
  run_opencode_failure_fixture \
    "OpenCode gated tool trace is not classified at a non-timeout exit" 1 \
    '✱ Grep "requires explicit opt-in" in . · 2 matches' \
    "jq -s -e '((.[1].error | split(\";\")[0]) == \"OpenCode execution failed (exit=1)\") and (.[1].error | contains(\"leg unavailable\") | not)' \"\$work/out.json\" >/dev/null"
}

test_opencode_gated_tool_trace_timeout_is_pure_timeout() {
  run_opencode_failure_fixture \
    "OpenCode gated tool trace timeout is not classified" 124 \
    '✱ Grep "requires explicit opt-in" in . · 2 matches' \
    "jq -s -e '((.[1].error | split(\";\")[0]) == \"OpenCode execution timed out after 720s\") and (.[1].error | contains(\"leg unavailable\") | not)' \"\$work/out.json\" >/dev/null"
}

test_opencode_provider_gated_error_is_classified() {
  run_opencode_failure_fixture \
    "OpenCode provider gated error is classified" 1 \
    'Error: The latest version of this model is only available hosted in China and requires explicit opt in: https://opencode.ai/workspace/wrk_TESTID/go' \
    "jq -s -e '.[1].error | contains(\"deepseek leg unavailable\") and contains(\"opencode-go/deepseek-v4-pro\")' \"\$work/out.json\" >/dev/null"
}

test_opencode_provider_gated_timeout_is_pure_timeout() {
  run_opencode_failure_fixture \
    "OpenCode provider gated timeout is pure timeout" 124 \
    'Error: The latest version of this model is only available hosted in China and requires explicit opt in: https://opencode.ai/workspace/wrk_TESTID/go' \
    "jq -s -e '((.[1].error | split(\";\")[0]) == \"OpenCode execution timed out after 720s\") and (.[1].error | contains(\"leg unavailable\") | not)' \"\$work/out.json\" >/dev/null"
}

test_opencode_generic_failure_error() {
  run_opencode_failure_fixture \
    "OpenCode unclassified failure is not reported as a timeout" 1 "unrecognized provider failure" \
    "jq -s -e '.[1].error | contains(\"OpenCode execution failed (exit=1)\") and (contains(\"timed out\") | not)' \"\$work/out.json\" >/dev/null"
}

test_opencode_timeout_tool_output_is_not_auth_error() {
  run_opencode_failure_fixture \
    "OpenCode timeout tool output is not classified as an authentication error" 124 \
    '> plan · deepseek-v4-pro
✱ Grep "unauthorized|forbidden" in . · 3 matches' \
    "jq -s -e '((.[1].error | split(\";\")[0]) == \"OpenCode execution timed out after 720s\") and (.[1].error | contains(\"authentication rejected\") | not) and (.[1].error | contains(\"leg unavailable\") | not)' \"\$work/out.json\" >/dev/null"
}

test_opencode_filename_tool_output_is_generic_error() {
  run_opencode_failure_fixture \
    "OpenCode filename tool output is not classified as an authentication error" 1 \
    '✱ Glob "**/forbidden_test.go" 1 match' \
    "jq -s -e '((.[1].error | split(\";\")[0]) == \"OpenCode execution failed (exit=1)\") and (.[1].error | contains(\"authentication rejected\") | not) and (.[1].error | contains(\"leg unavailable\") | not)' \"\$work/out.json\" >/dev/null"
}

test_codex_pins() {
  local expected_model="$1" expected_effort="$2" overrides="$3" label="$4"
  local work fake
  work="$(mktemp -d)"
  fake="$work/bin"
  mkdir -p "$fake"
  cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/codex.args"
cat >/dev/null
cat <<'JSON'
{"provider":"codex","model":"fake","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10.0,"verdict":"APPROVE"}}
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
    export PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1
    unset TRIBUNAL_CODEX_MODEL TRIBUNAL_CODEX_EFFORT
    if [ "$overrides" = "yes" ]; then
      export TRIBUNAL_CODEX_MODEL="$expected_model" TRIBUNAL_CODEX_EFFORT="$expected_effort"
    fi
    bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="codex" and .summary.verdict=="APPROVE"' "$work/out.json" >/dev/null &&
    awk -v model="$expected_model" -v effort="model_reasoning_effort=\"$expected_effort\"" '
      previous == "-m" && $0 == model { model_seen = 1 }
      previous == "-c" && $0 == effort { effort_seen = 1 }
      $0 == "--dangerously-bypass-approvals-and-sandbox" { bypass_count++ }
      $0 == "-s" { sandbox_selector_seen = 1 }
      $0 == "--ignore-user-config" { isolated_seen = 1 }
      $0 == "mcp_servers={}" { mcp_disabled = 1 }
      previous == "--output-schema" && $0 ~ /schemas\/review-output.json$/ { schema_seen = 1 }
      $0 == "--output-last-message" { last_message_seen = 1 }
      $0 == "--ephemeral" { ephemeral_seen = 1 }
      { previous = $0 }
      END { exit !(model_seen && effort_seen && bypass_count == 1 && !sandbox_selector_seen &&
        isolated_seen && mcp_disabled && schema_seen && last_message_seen && ephemeral_seen) }
    ' "$work/codex.args"
  then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_codex_parse_diagnostics() {
  local label="exit-zero malformed Codex output retains bounded diagnostics" work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex-prefix-'
head -c 4096 /dev/zero | tr '\0' x
printf '%s\n' '-codex-tail-marker'
printf '%s\n' 'codex-stderr-marker' >&2
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
    PATH="$fake:$PATH" TRIBUNAL_DIAGNOSTIC_TAILS=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '
      .provider == "codex"
      and (.error | contains("unparseable codex output"))
      and (.error | contains("phase=parse; exit=0"))
      and (.error | contains("stdout_truncated=true"))
      and (.error | contains("codex-tail-marker"))
      and (.error | contains("codex-stderr-marker"))
      and ((.error | length) < 5000)
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_codex_empty_output() {
  local label="exit-zero empty Codex output is a diagnosed parse failure" work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
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
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/out.json"
  ) && jq -e '
      .provider=="codex"
      and (.error | contains("no review JSON object found"))
      and (.error | contains("phase=parse; exit=0; stdout_bytes=0"))
      and (.error | contains("stderr_bytes=0"))
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

test_claude_execution_diagnostics() {
  local label="immediate Claude failure retains safe diagnostics by default" work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
printf '%s\n' 'claude-partial-output API_KEY=fixture-secret-value'
printf '%s\n' 'claude-immediate-failure bearer fixture-secret-token' >&2
exit 7
EOF
  chmod +x "$fake/claude"

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
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$work/out.json"
  ) && jq -e '
      .provider == "claude"
      and (.error | contains("Claude execution failed or timed out"))
      and (.error | contains("phase=execution; exit=7"))
      and (.error | contains("stdout_bytes="))
      and (.error | contains("stderr_bytes="))
      and (.error | contains("stdout_truncated=false"))
      and (.error | contains("stderr_truncated=false"))
      and (.error | contains("[omitted; set TRIBUNAL_DIAGNOSTIC_TAILS=on]"))
      and (.error | contains("fixture-secret-value") | not)
      and (.error | contains("fixture-secret-token") | not)
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

# Fixture OIDC session for Grok runner/preflight tests (issue #374).
install_grok_auth_fixture() {
  local dest="$1" refresh="${2:-refresh-fixture}" expires="${3:-2099-01-01T00:00:00Z}"
  mkdir -p "$dest"
  jq -nc --arg r "$refresh" --arg e "$expires" \
    '{"https://auth.x.ai::fixture":{key:"access-fixture",refresh_token:$r,expires_at:$e,auth_mode:"oidc"}}' \
    > "$dest/auth.json"
  chmod 600 "$dest/auth.json"
}

# Grok leg (#331): progress-only / timeout must not report success; tools-off
# resume of the same session must produce a schema verdict or a blocked error.
test_grok_deterministic_completion() {
  local work fake state host_grok
  work="$(mktemp -d)"
  fake="$work/bin"
  state="$work/state"
  host_grok="$work/host-grok"
  mkdir -p "$fake" "$state"
  install_grok_auth_fixture "$host_grok"

  # Scenario A: inspect progress-only → finalize resume yields structured review
  cat > "$fake/grok" <<EOF
#!/usr/bin/env bash
# Record phase + tools value for later assertions (NUL-separated fields).
phase=inspect
tools_val=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--tools" ]; then tools_val="\$a"; fi
  if [ "\$a" = "--resume" ]; then phase=finalize; fi
  prev="\$a"
done
printf '%s\t%s\n' "\$phase" "\$tools_val" >> "$state/phases.log"
printf '%s\n' "\$@" >> "$state/args.log"
if [ "\$phase" = finalize ]; then
  cat <<'JSON'
{"text":"done","stopReason":"EndTurn","sessionId":"11111111-1111-1111-1111-111111111111","structuredOutput":{"provider":"grok","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":9,"verdict":"APPROVE"}},"modelUsage":{"fixture-model":{"inputTokens":1,"outputTokens":1}}}
JSON
  exit 0
fi
# Inspect phase: progress-only (no structured review)
cat <<'JSON'
{"text":"I'll review this PR as a read-only senior reviewer...","stopReason":"EndTurn","sessionId":"11111111-1111-1111-1111-111111111111","num_turns":1}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

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
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-a.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="APPROVE"
      and .model=="fixture-model"
      and ((.findings|length)==0)
      and (has("error")|not)
    ' "$work/out-a.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok progress-only inspect resumes tools-off for verdict"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok progress-only inspect resumes tools-off for verdict"; FAIL=$((FAIL+1))
    FAILURES+=("grok progress-only inspect resumes tools-off for verdict")
    echo "    out: $(cat "$work/out-a.json" 2>/dev/null || true)" >&2
  fi

  # Resume must use --resume; inspect allowlist vs finalize tools-off; pin session/max-turns
  # Default sandbox none + bypassPermissions (issue #378).
  if [ -f "$state/args.log" ] \
    && grep -q -- '--session-id' "$state/args.log" \
    && grep -q -- '--max-turns' "$state/args.log" \
    && grep -q -- '--resume' "$state/args.log" \
    && grep -q -- '--permission-mode' "$state/args.log" \
    && grep -q -- 'bypassPermissions' "$state/args.log" \
    && grep -q -- '--sandbox' "$state/args.log" \
    && grep -qE '(^|[[:space:]])none([[:space:]]|$)' "$state/args.log" \
    && grep -qx $'inspect\tread_file,list_dir,grep' "$state/phases.log" \
    && grep -qx $'finalize\t' "$state/phases.log"; then
    echo -e "  ${GREEN}PASS${NC} grok inspect/finalize use session, max-turns, tools split"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok inspect/finalize use session, max-turns, tools split"; FAIL=$((FAIL+1))
    FAILURES+=("grok inspect/finalize use session, max-turns, tools split")
    echo "    phases: $(cat "$state/phases.log" 2>/dev/null | tr '\n' '|')" >&2
    echo "    args: $(tr '\n' ' ' < "$state/args.log" 2>/dev/null | head -c 400)" >&2
  fi

  # Scenario B: both phases incomplete → progress_only / incomplete error with session_id
  rm -f "$state/args.log" "$state/phases.log"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q -- '--resume'; then
  cat <<'JSON'
{"text":"Still gathering context...","stopReason":"EndTurn","sessionId":"22222222-2222-2222-2222-222222222222"}
JSON
  exit 0
fi
cat <<'JSON'
{"text":"I'll start by reading the diff...","stopReason":"EndTurn","sessionId":"22222222-2222-2222-2222-222222222222"}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-b.json"
  ) && jq -e '
      .provider=="grok"
      and (.error | test("incomplete|progress_only"))
      and (.error | test("session_id="))
      and (.error | test("phase=incomplete"))
    ' "$work/out-b.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok double progress-only reports incomplete not success"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok double progress-only reports incomplete not success"; FAIL=$((FAIL+1))
    FAILURES+=("grok double progress-only reports incomplete not success")
    echo "    out: $(cat "$work/out-b.json" 2>/dev/null || true)" >&2
  fi

  # Scenario C: first-pass structuredOutput (camelCase) completes without resume
  rm -f "$state/args.log" "$state/calls"
  cat > "$fake/grok" <<EOF
#!/usr/bin/env bash
count_file="$state/calls"
n=0
[ -f "\$count_file" ] && n="\$(cat "\$count_file")"
n=\$((n+1))
printf '%s\\n' "\$n" > "\$count_file"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","findings":[{"severity":"medium","category":"logic","file":"file.txt","line":1,"title":"t","description":"d","suggestion":"s","confidence":0.9}],"summary":{"total_findings":1,"critical":0,"high":0,"medium":1,"low":0,"quality_score":7,"verdict":"NEEDS_WORK"}},"sessionId":"33333333-3333-3333-3333-333333333333","modelUsage":{"fixture-model":{"inputTokens":1}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"
  : > "$state/calls"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-c.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="NEEDS_WORK"
      and (.findings|length)==1
      and .model=="fixture-model"
    ' "$work/out-c.json" >/dev/null \
    && [ "$(cat "$state/calls")" = "1" ]; then
    echo -e "  ${GREEN}PASS${NC} grok camelCase structuredOutput completes in one pass"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok camelCase structuredOutput completes in one pass"; FAIL=$((FAIL+1))
    FAILURES+=("grok camelCase structuredOutput completes in one pass")
    echo "    out: $(cat "$work/out-c.json" 2>/dev/null || true) calls=$(cat "$state/calls" 2>/dev/null)" >&2
  fi

  # Scenario D: inspect times out (124) → finalize recovers verdict
  rm -f "$state/args.log" "$state/calls"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q -- '--resume'; then
  cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":8,"verdict":"APPROVE"}},"sessionId":"44444444-4444-4444-4444-444444444444","modelUsage":{"fixture-model":{}}}
JSON
  exit 0
fi
# Partial envelope before timeout so session_id is known
cat <<'JSON'
{"text":"still reading files...","sessionId":"44444444-4444-4444-4444-444444444444"}
JSON
exit 124
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-d.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="APPROVE"
      and (has("error")|not)
    ' "$work/out-d.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok inspect timeout recovers via tools-off resume"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok inspect timeout recovers via tools-off resume"; FAIL=$((FAIL+1))
    FAILURES+=("grok inspect timeout recovers via tools-off resume")
    echo "    out: $(cat "$work/out-d.json" 2>/dev/null || true)" >&2
  fi

  # Lib helper: camelCase + snake_case extract, payload complete check
  complete_ok='{"provider":"grok","model":"m","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
  if printf '%s' "{\"structuredOutput\":$complete_ok}" \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_extract_grok_result" \
      | jq -e '.summary.verdict=="APPROVE"' >/dev/null \
    && printf '%s' '{"structured_output":{"findings":[],"summary":{"verdict":"BLOCK"}}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_extract_grok_result" \
      | jq -e '.summary.verdict=="BLOCK"' >/dev/null \
    && printf '%s' "$complete_ok" \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' 'I will review this next.' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' '{"findings":[],"summary":{"verdict":"pending"}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' '{"findings":[],"summary":{"verdict":"APPROVE"}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete"; then
    echo -e "  ${GREEN}PASS${NC} grok envelope helpers accept camel/snake and reject weak payloads"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok envelope helpers accept camel/snake and reject weak payloads"; FAIL=$((FAIL+1))
    FAILURES+=("grok envelope helpers accept camel/snake and reject weak payloads")
  fi

  # Scenario E (issue #378): TRIBUNAL_GROK_SANDBOX override reaches the CLI.
  rm -f "$state/args.log" "$state/phases.log"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ARGS_LOG:?}"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":9,"verdict":"APPROVE"}},"sessionId":"77777777-7777-7777-7777-777777777777","modelUsage":{"fixture-model":{}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" ARGS_LOG="$state/args.log" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK_SANDBOX=read-only \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-e.json"
  ) && jq -e '.provider=="grok" and .summary.verdict=="APPROVE"' "$work/out-e.json" >/dev/null \
    && grep -q -- '--sandbox' "$state/args.log" \
    && grep -qE '(^|[[:space:]])read-only([[:space:]]|$)' "$state/args.log"; then
    echo -e "  ${GREEN}PASS${NC} grok TRIBUNAL_GROK_SANDBOX override reaches CLI"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok TRIBUNAL_GROK_SANDBOX override reaches CLI"; FAIL=$((FAIL+1))
    FAILURES+=("grok TRIBUNAL_GROK_SANDBOX override reaches CLI")
    echo "    out: $(cat "$work/out-e.json" 2>/dev/null || true)" >&2
    echo "    args: $(tr '\n' ' ' < "$state/args.log" 2>/dev/null)" >&2
  fi

  # Scenario F (issue #378): Cancelled stopReason + no verdict is dead_leg, not quiet success.
  rm -f "$state/args.log"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q -- '--resume'; then
  cat <<'JSON'
{"text":"","stopReason":"Cancelled","sessionId":"88888888-8888-8888-8888-888888888888"}
JSON
  exit 0
fi
cat <<'JSON'
{"text":"","stopReason":"Cancelled","sessionId":"88888888-8888-8888-8888-888888888888"}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-f.json"
  ) && jq -e '
      .provider=="grok"
      and (.error | test("stopReason=Cancelled"))
      and (.error | test("dead_leg|progress_only"))
      and (has("summary")|not)
    ' "$work/out-f.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok Cancelled stopReason reports dead leg not success"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok Cancelled stopReason reports dead leg not success"; FAIL=$((FAIL+1))
    FAILURES+=("grok Cancelled stopReason reports dead leg not success")
    echo "    out: $(cat "$work/out-f.json" 2>/dev/null || true)" >&2
  fi

  # Scenario G (issue #378): orphaned script copy (no sibling schemas/) still
  # resolves schema when CLAUDE_PLUGIN_ROOT points at the real plugin.
  local orphan="$work/orphan-plugin/scripts"
  mkdir -p "$orphan"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$orphan/lib.sh"
  cp "$PLUGIN_ROOT/scripts/run-grok-review.sh" "$orphan/run-grok-review.sh"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":8,"verdict":"APPROVE"}},"sessionId":"99999999-9999-9999-9999-999999999999","modelUsage":{"fixture-model":{}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY -u TRIBUNAL_PLUGIN_ROOT \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$orphan/run-grok-review.sh" > "$work/out-g.json"
  ) && jq -e '.provider=="grok" and .summary.verdict=="APPROVE" and (has("error")|not)' \
      "$work/out-g.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok schema resolves via CLAUDE_PLUGIN_ROOT"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok schema resolves via CLAUDE_PLUGIN_ROOT"; FAIL=$((FAIL+1))
    FAILURES+=("grok schema resolves via CLAUDE_PLUGIN_ROOT")
    echo "    out: $(cat "$work/out-g.json" 2>/dev/null || true)" >&2
  fi

  # Scenario H: missing schema file fails before provider run (no silent empty schema).
  local bare="$work/bare-plugin"
  mkdir -p "$bare/scripts" "$bare/schemas"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$bare/scripts/lib.sh"
  cp "$PLUGIN_ROOT/scripts/run-grok-review.sh" "$bare/scripts/run-grok-review.sh"
  # Intentionally omit schemas/review-output.json
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RAN:?}"
exit 99
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RAN="$work/provider-ran-h" env -u XAI_API_KEY \
      env -u CLAUDE_PLUGIN_ROOT -u TRIBUNAL_PLUGIN_ROOT \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$bare/scripts/run-grok-review.sh" > "$work/out-h.json"
  ) && jq -e '.provider=="grok" and (.error|test("schema missing|cannot load review schema"))' \
      "$work/out-h.json" >/dev/null \
    && [ ! -e "$work/provider-ran-h" ]; then
    echo -e "  ${GREEN}PASS${NC} grok missing schema fails before provider run"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok missing schema fails before provider run"; FAIL=$((FAIL+1))
    FAILURES+=("grok missing schema fails before provider run")
    echo "    out: $(cat "$work/out-h.json" 2>/dev/null || true)" >&2
  fi

  # Scenario I: explicit TRIBUNAL_PLUGIN_ROOT without schema is authoritative —
  # must not fall back to the real install's schema (Codex review / #378).
  local empty_root="$work/empty-root"
  mkdir -p "$empty_root"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RAN:?}"
exit 99
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RAN="$work/provider-ran-i" env -u XAI_API_KEY \
      env -u CLAUDE_PLUGIN_ROOT \
      TRIBUNAL_PLUGIN_ROOT="$empty_root" \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-i.json"
  ) && jq -e '.provider=="grok" and (.error|test("schema missing|cannot load review schema"))' \
      "$work/out-i.json" >/dev/null \
    && [ ! -e "$work/provider-ran-i" ]; then
    echo -e "  ${GREEN}PASS${NC} grok explicit empty plugin root does not fall back"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok explicit empty plugin root does not fall back"; FAIL=$((FAIL+1))
    FAILURES+=("grok explicit empty plugin root does not fall back")
    echo "    out: $(cat "$work/out-i.json" 2>/dev/null || true)" >&2
  fi

  # Scenario J: invalid sandbox / permission overrides fail loud (no silent remap).
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RAN:?}"
exit 99
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RAN="$work/provider-ran-j1" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK_SANDBOX=read_only \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-j1.json"
  ) && jq -e '.provider=="grok" and (.error|test("invalid Grok sandbox profile"))' \
      "$work/out-j1.json" >/dev/null \
    && [ ! -e "$work/provider-ran-j1" ]; then
    echo -e "  ${GREEN}PASS${NC} grok invalid sandbox fails loud"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok invalid sandbox fails loud"; FAIL=$((FAIL+1))
    FAILURES+=("grok invalid sandbox fails loud")
    echo "    out: $(cat "$work/out-j1.json" 2>/dev/null || true)" >&2
  fi

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RAN="$work/provider-ran-j2" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK_PERMISSION_MODE=yolo \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-j2.json"
  ) && jq -e '.provider=="grok" and (.error|test("invalid Grok permission mode"))' \
      "$work/out-j2.json" >/dev/null \
    && [ ! -e "$work/provider-ran-j2" ]; then
    echo -e "  ${GREEN}PASS${NC} grok invalid permission mode fails loud"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok invalid permission mode fails loud"; FAIL=$((FAIL+1))
    FAILURES+=("grok invalid permission mode fails loud")
    echo "    out: $(cat "$work/out-j2.json" 2>/dev/null || true)" >&2
  fi

  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

# Issue #374: copy auth into isolation (not symlink); write back rotated tokens under flock.
test_grok_auth_copy_writeback() {
  local label="grok copies auth and write-backs rotated OIDC tokens" work fake host_grok
  work="$(mktemp -d)"
  fake="$work/bin"
  host_grok="$work/host-grok"
  mkdir -p "$fake"
  install_grok_auth_fixture "$host_grok" "refresh-old" "2026-01-01T00:00:00Z"

  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
auth="${GROK_HOME:?}/auth.json"
# Isolation must present a regular file, not a host symlink (atomic replace severs host).
if [ -L "$auth" ]; then
  printf '%s\n' "auth is symlink" >&2
  exit 97
fi
if [ ! -f "$auth" ]; then
  printf '%s\n' "auth missing under isolation" >&2
  exit 98
fi
# Simulate OIDC refresh_token rotation under the scratch home.
jq '
  walk(
    if type == "object" and has("refresh_token") then
      .refresh_token = "refresh-rotated"
      | .key = "access-rotated"
      | .expires_at = "2099-06-01T00:00:00Z"
    else . end
  )
' "$auth" > "$auth.tmp" && mv "$auth.tmp" "$auth"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":9,"verdict":"APPROVE"}},"sessionId":"55555555-5555-5555-5555-555555555555","modelUsage":{"fixture-model":{}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

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
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="grok" and .summary.verdict=="APPROVE" and (has("error")|not)' "$work/out.json" >/dev/null \
    && jq -e '
        .["https://auth.x.ai::fixture"].refresh_token == "refresh-rotated"
        and .["https://auth.x.ai::fixture"].key == "access-rotated"
      ' "$host_grok/auth.json" >/dev/null \
    && [ ! -L "$host_grok/auth.json" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    echo "    out: $(cat "$work/out.json" 2>/dev/null || true)" >&2
    echo "    host auth: $(cat "$host_grok/auth.json" 2>/dev/null || true)" >&2
  fi

  # Stale isolated write-back must not clobber a host session with newer expires_at.
  install_grok_auth_fixture "$host_grok" "refresh-host-fresh" "2099-12-01T00:00:00Z"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
auth="${GROK_HOME:?}/auth.json"
jq '
  walk(
    if type == "object" and has("refresh_token") then
      .refresh_token = "refresh-stale"
      | .key = "access-stale"
      | .expires_at = "2020-01-01T00:00:00Z"
    else . end
  )
' "$auth" > "$auth.tmp" && mv "$auth.tmp" "$auth"
# Concurrent host refresh lands a fresher session while this leg still holds stale tokens.
printf '%s\n' '{"https://auth.x.ai::fixture":{"key":"access-host-fresh","refresh_token":"refresh-host-fresh","expires_at":"2099-12-01T00:00:00Z","auth_mode":"oidc"}}' \
  > "${AUTH_HOST_PATH:?}"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":8,"verdict":"APPROVE"}},"sessionId":"66666666-6666-6666-6666-666666666666","modelUsage":{"fixture-model":{}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" AUTH_HOST_PATH="$host_grok/auth.json" \
      env -u XAI_API_KEY TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-stale.json"
  ) && jq -e '.["https://auth.x.ai::fixture"].refresh_token == "refresh-host-fresh"' \
      "$host_grok/auth.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok write-back refuses to clobber fresher host auth"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok write-back refuses to clobber fresher host auth"; FAIL=$((FAIL+1))
    FAILURES+=("grok write-back refuses to clobber fresher host auth")
    echo "    host auth: $(cat "$host_grok/auth.json" 2>/dev/null || true)" >&2
  fi

  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

test_grok_auth_guard() {
  local label="unsigned Grok session is skipped before provider execution" work fake host_grok
  work="$(mktemp -d)"
  fake="$work/bin"
  host_grok="$work/host-grok"
  mkdir -p "$fake" "$host_grok"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RUN_MARKER:?}"
exit 99
EOF
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
exit 0
EOF
  chmod +x "$fake/grok" "$fake/codex" "$fake/claude"
  # Empty/missing auth.json — not signed in.
  : > "$host_grok/auth.json"

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
    export PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RUN_MARKER="$work/provider-ran"
    env -u XAI_API_KEY \
      TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_CODEX=on TRIBUNAL_CLAUDE=off \
      TRIBUNAL_GROK=on TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=off \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/preflight.json"
    env -u XAI_API_KEY GROK_HOME="$host_grok" PATH="$fake:$PATH" \
      TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK=on \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/review.json"
  ) && jq -e 'any(.providers[]; .name=="grok" and .status=="skipped" and (.note|test("not signed in")))' \
      "$work/preflight.json" >/dev/null \
    && jq -e '.provider=="grok" and (.error|test("not signed in"))' "$work/review.json" >/dev/null \
    && [ ! -e "$work/provider-ran" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    echo "    preflight: $(cat "$work/preflight.json" 2>/dev/null || true)" >&2
    echo "    review: $(cat "$work/review.json" 2>/dev/null || true)" >&2
  fi
  rm -rf "$work"
}

test_claude_non_json_output() {
  local label="exit-zero non-JSON Claude result is a diagnosed parse failure" work fake
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
cat >/dev/null
printf '%s\n' '{"result":"The change looks good, but this is prose rather than review JSON."}'
EOF
  chmod +x "$fake/claude"

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
    PATH="$fake:$PATH" TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-claude-review.sh" > "$work/out.json"
  ) && jq -e '
      .provider=="claude"
      and (.error | contains("no review JSON object found"))
      and (.error | contains("phase=parse; exit=0"))
    ' "$work/out.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  rm -rf "$work"
}

# Vacuous verdict = zero findings + a blocking verdict. Both the reported BLOCK
# shape (quality 0.0) and the broader NEEDS_WORK / nonzero-quality shape must be
# downgraded to a leg error, never passed through as a real review (issue #171).
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
{"provider":"codex","model":"default","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":$quality,"verdict":"$verdict"}}
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
{"provider":"codex","model":"default","findings":[
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
      and (.findings[5].line_check == "file missing at HEAD")
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
printf '%s\n' '{"provider":"codex","model":"default","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"},"diff_stat":{"files_changed":99}}'
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
  if printf '%s\n' '{"provider":"claude","model":"fixture","diff_stat":{"files_changed":99},"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
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

  local label_u="uncaptured reviewed range becomes an explicit leg error"
  if printf '%s\n' '{"provider":"codex","model":"m","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
    | bash -c '. "$1"; tribunal_stamp_diff_stat "$2/absent.diff"' _ "$PLUGIN_ROOT/scripts/lib.sh" "$(mktemp -d)" \
    | jq -e '.provider == "codex" and (.error | test("reviewed range was not captured")) and (has("diff_stat") | not)' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label_u"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label_u"; FAIL=$((FAIL+1)); FAILURES+=("$label_u")
  fi

  local label3="stamp leaves error and disabled legs untouched"
  if printf '%s\n' '{"provider":"codex","error":"boom"}' \
    | bash -c '. "$1"; tribunal_stamp_diff_stat "$2/absent.diff"' _ "$PLUGIN_ROOT/scripts/lib.sh" "$(mktemp -d)" \
    | jq -e 'has("diff_stat") | not' >/dev/null \
    && printf '%s\n' '{"provider":"codex","status":"disabled","note":"off"}' \
    | bash -c '. "$1"; tribunal_stamp_diff_stat "$2/absent.diff"' _ "$PLUGIN_ROOT/scripts/lib.sh" "$(mktemp -d)" \
    | jq -e 'has("diff_stat") | not' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label3"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label3"; FAIL=$((FAIL+1)); FAILURES+=("$label3")
  fi
}

test_wrapper_owned_provider_envelope() {
  local out
  out="$(printf '%s\n' '{"provider":"claude","status":"disabled","error":"spoof","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' \
    | bash -c '. "$1"; tribunal_emit_review codex' _ "$PLUGIN_ROOT/scripts/lib.sh")"
  if printf '%s' "$out" | jq -e '.provider=="codex" and (has("status")|not) and (has("error")|not)' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} wrapper owns provider identity and review status"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} wrapper owns provider identity and review status"; FAIL=$((FAIL+1)); FAILURES+=("wrapper-owned provider envelope")
  fi
}

test_trusted_evidence_collection() {
  local label="trusted evidence collection binds PR, providers, arbitration, and proof"
  local work repo fake plugin collection manifest_sha proof_sha base head host_codex real_git
  work="$(mktemp -d)"; repo="$work/repo"; fake="$work/bin"; plugin="$work/plugin"
  mkdir -p "$repo" "$fake" "$work/tmp" "$plugin/scripts" "$plugin/schemas" "$plugin/.claude-plugin" "$plugin/integrity"
  cp "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/check-runner-bundle.sh" "$PLUGIN_ROOT/scripts/generate-runner-bundle.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/schemas/review-output.json" "$plugin/schemas/"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$plugin/.claude-plugin/plugin.json"

  cat > "$plugin/scripts/run-codex-review.sh" <<'EOF'
#!/usr/bin/env bash
fixture_stat() {
  local base head
  base="$(git rev-parse --verify "${FIXTURE_STAT_BASE:-${TRIBUNAL_BASE_REF}}^{commit}")"
  head="$(git rev-parse --verify "${FIXTURE_STAT_HEAD:-HEAD}^{commit}")"
  printf '"diff_stat":{"files_changed":1,"insertions":1,"deletions":0,"base":"%s","base_oid":"%s","head_oid":"%s","truncated":false}' \
    "$TRIBUNAL_BASE_REF" "$base" "$head"
}
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"codex","error":"fixture Codex transport failure"}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = malformed ]; then
  printf '%s\n' '{"provider":"claude","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"},"caller_owned":true}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = diagnostic ]; then
  printf '%s\n' '{"provider":"claude","error":"unparseable codex output: no review JSON object found; phase=parse; exit=0; stdout_bytes=12; stdout_truncated=false; stdout_tail=omitted; stderr_bytes=0; stderr_truncated=false; stderr_tail=omitted"}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = finding ]; then
  printf '%s\n' '{"provider":"claude","model":"fixture","findings":[{"severity":"medium","category":"logic","file":"app.txt","line":1,"title":"Fixture finding","description":"A concrete fixture defect.","suggestion":"Apply the fixture fix.","confidence":0.9}],"summary":{"total_findings":1,"critical":0,"high":0,"medium":1,"low":0,"quality_score":7,"verdict":"NEEDS_WORK"},'"$(fixture_stat)"'}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = nostat ]; then
  printf '%s\n' '{"provider":"claude","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
else
  printf '%s\n' '{"provider":"claude","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"},'"$(fixture_stat)"'}'
fi
EOF
  for provider in gemini qwen grok; do
    cat > "$plugin/scripts/run-$provider-review.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '{"provider":"$provider","status":"disabled","note":"fixture disabled"}'
EOF
  done
  cat > "$plugin/scripts/run-claude-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"claude","error":"fixture Claude transport failure"}'
else
  printf '%s\n' '{"provider":"claude","status":"disabled","note":"fixture disabled"}'
fi
EOF
  cat > "$plugin/scripts/run-qwen-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_MUTATE_WORKTREE:-off}" = on ]; then printf 'provider mutation\n' >> app.txt; fi
printf '%s\n' '{"provider":"qwen","status":"disabled","note":"fixture disabled"}'
EOF
  cat > "$plugin/scripts/run-grok-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"grok","error":"fixture Grok transport failure"}'
else
  printf '%s\n' '{"provider":"grok","status":"disabled","note":"fixture disabled"}'
fi
EOF
  cat > "$plugin/scripts/run-opencode-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"provider":"glm","status":"disabled","note":"fixture disabled"}'
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

  cat > "$fake/mv" <<'EOF'
#!/usr/bin/env bash
target=${!#}
if [ -n "${FIXTURE_KILL_PUBLISH:-}" ] && [ "$target" = "$FIXTURE_KILL_PUBLISH" ]; then
  kill -KILL "$PPID"
  exit 137
fi
/usr/bin/mv "$@"
if [ -n "${FIXTURE_KILL_FINALIZE:-}" ] && [ "$target" = "$FIXTURE_KILL_FINALIZE" ]; then
  kill -KILL "$PPID"
fi
EOF
  chmod +x "$fake/mv"

  real_git="$(command -v git)"
  mkdir -p "$work/diff-fail-bin"
  cat > "$work/diff-fail-bin/git" <<'EOF'
#!/usr/bin/env bash
saw_diff=0
for arg in "$@"; do
  [ "$arg" != diff ] || saw_diff=1
  [ "$saw_diff" -eq 0 ] || [ "$arg" != --name-only ] || exit 128
done
exec "$TRIBUNAL_TEST_REAL_GIT" "$@"
EOF
  chmod +x "$work/diff-fail-bin/git"
  local diff_failed_collection="$work/diff-failed-collection" diff_failure_rc=0
  PATH="$work/diff-fail-bin:$fake:$PATH" TRIBUNAL_TEST_REAL_GIT="$real_git" \
    FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$diff_failed_collection" >/dev/null 2>&1 || diff_failure_rc=$?
  if [ "$diff_failure_rc" -ne 0 ] && [ ! -e "$diff_failed_collection" ]; then
    echo -e "  ${GREEN}PASS${NC} collection fails closed when ignored-addition diff fails"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} collection fails closed when ignored-addition diff fails"; FAIL=$((FAIL+1)); FAILURES+=("collection ignored-addition diff failure")
  fi

  if FIXTURE_MUTATE_WORKTREE=on PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/mutated" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} trusted evidence runner rejects provider worktree mutation"; FAIL=$((FAIL+1)); FAILURES+=("provider worktree mutation")
    rm -rf "$work"; return
  else
    echo -e "  ${GREEN}PASS${NC} trusted evidence runner rejects provider worktree mutation"; PASS=$((PASS+1))
  fi

  local killed_collection="$work/killed-collection" interrupted_ec=0
  TMPDIR="$work/tmp" FIXTURE_KILL_PUBLISH="$killed_collection" \
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$killed_collection" >/dev/null 2>&1 || interrupted_ec=$?
  if [ "$interrupted_ec" -ne 0 ] && [ ! -e "$killed_collection" ]; then
    echo -e "  ${GREEN}PASS${NC} killed publication leaves no partial collection"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} killed publication leaves no partial collection"; FAIL=$((FAIL+1)); FAILURES+=("atomic collection publication")
    rm -rf "$work"; return
  fi

  collection="$work/collection"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$collection" > "$work/collect.json"; then
    echo -e "  ${RED}FAIL${NC} $label (collection failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  manifest_sha="$(jq -r .manifest_sha256 "$work/collect.json")"

  if [ ! -e "$collection/ignored-paths.json" ] \
    && jq -e 'has("ignored_paths") | not' "$collection/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} clean collection has no ignored-path artifact noise"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} clean collection has no ignored-path artifact noise"; FAIL=$((FAIL+1)); FAILURES+=("clean collection artifact noise")
  fi

  # The codex fixture claims to be Claude; the aggregate runner owns and
  # rewrites identity before sealing the artifact.
  if ! jq -e '.provider=="codex" and (has("caller_owned")|not)' "$collection/providers/codex.json" >/dev/null; then
    echo -e "  ${RED}FAIL${NC} $label (provider identity/schema not owned by runner)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi

  chmod u+w "$collection/providers/codex.json"
  cp "$collection/providers/codex.json" "$work/codex.saved"
  printf '\n' >> "$collection/providers/codex.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (artifact tamper accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  cp "$work/codex.saved" "$collection/providers/codex.json"; chmod 0444 "$collection/providers/codex.json"

  cp "$plugin/scripts/lib.sh" "$work/lib.saved"
  printf '\n# drift\n' >> "$plugin/scripts/lib.sh"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (runner provenance drift accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  cp "$work/lib.saved" "$plugin/scripts/lib.sh"

  printf 'Changed PR body' > "$work/pr-body"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (PR body drift accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  printf 'Bound PR body' > "$work/pr-body"

  cat > "$work/arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"One valid reviewer found no defects."},
  "findings":[],"scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "glm":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"}
  },
  "conflicts_resolved":[],"summary":"No blocking findings."
}
EOF
  jq '.provider_assessment.codex.status="failed"' "$work/arbitration.json" > "$work/bad-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/bad-arbitration.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (caller-authored provider status accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi

  interrupted_ec=0
  TMPDIR="$work/tmp" FIXTURE_KILL_FINALIZE="$collection/arbitration.json" \
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
      >/dev/null 2>&1 || interrupted_ec=$?
  if [ "$interrupted_ec" -ne 0 ] && [ -f "$collection/arbitration.json" ] \
    && [ ! -e "$collection/proof.json" ] && [ -f "$collection/.finalize.lock" ]; then
    echo -e "  ${GREEN}PASS${NC} killed finalization releases its process lock"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} killed finalization releases its process lock"; FAIL=$((FAIL+1)); FAILURES+=("crash-releasing finalization lock")
    rm -rf "$work"; return
  fi

  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" > "$work/finalize.json"; then
    echo -e "  ${RED}FAIL${NC} $label (finalization failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  proof_sha="$(jq -r .proof_sha256 "$work/finalize.json")"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-proof --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --expected-proof-sha256 "$proof_sha" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label (proof verification failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" > "$work/finalize-repeat.json" \
    && cmp -s "$work/finalize.json" "$work/finalize-repeat.json"; then
    echo -e "  ${GREEN}PASS${NC} identical finalize retry returns the retained proof"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} identical finalize retry returns the retained proof"; FAIL=$((FAIL+1)); FAILURES+=("idempotent finalize retry")
  fi
  jq '.tribunal_verdict.rationale="Conflicting repeat."' "$work/arbitration.json" > "$work/conflicting-repeat.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/conflicting-repeat.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} conflicting finalize retry is rejected"; FAIL=$((FAIL+1)); FAILURES+=("conflicting finalize retry")
  else
    echo -e "  ${GREEN}PASS${NC} conflicting finalize retry is rejected"; PASS=$((PASS+1))
  fi

  FIXTURE_CODEX_MODE=malformed PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/malformed" > "$work/malformed.json"
  if jq -e '.provider=="codex" and has("error")' "$work/malformed/providers/codex.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} strict provider schema rejects caller/model extras"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} strict provider schema rejects caller/model extras"; FAIL=$((FAIL+1)); FAILURES+=("strict provider schema")
  fi
  FIXTURE_CODEX_MODE=nostat PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/nostat" > "$work/nostat.json"
  if jq -e '.provider=="codex" and has("error")' "$work/nostat/providers/codex.json" >/dev/null \
    && jq -e 'any(.providers[]; .provider=="codex" and .status=="failed")' "$work/nostat/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} review leg without wrapper diff_stat is a provider failure"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} review leg without wrapper diff_stat is a provider failure"; FAIL=$((FAIL+1)); FAILURES+=("missing diff_stat rejection")
  fi
  FIXTURE_STAT_HEAD="$base" PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/wrongrev" > "$work/wrongrev.json"
  if jq -e '.provider=="codex" and has("error")' "$work/wrongrev/providers/codex.json" >/dev/null \
    && jq -e 'any(.providers[]; .provider=="codex" and .status=="failed")' "$work/wrongrev/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} review leg stamped over another revision is a provider failure"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} review leg stamped over another revision is a provider failure"; FAIL=$((FAIL+1)); FAILURES+=("wrong-revision diff_stat rejection")
  fi
  jq '.provider_assessment.codex.status="failed"' "$work/arbitration.json" > "$work/no-quorum-approve.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/malformed" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/malformed.json")" \
      --arbitration "$work/no-quorum-approve.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} no successful provider cannot approve"; FAIL=$((FAIL+1)); FAILURES+=("no-quorum approval")
  else
    echo -e "  ${GREEN}PASS${NC} no successful provider cannot approve"; PASS=$((PASS+1))
  fi

  FIXTURE_ZERO_SUCCESS=on PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/zero-success" > "$work/zero-success.json"
  if jq -e '
      [.providers[] | select(.status != "disabled")]
      | length==3
        and ([.[].provider] | sort == ["claude", "codex", "grok"])
        and all(.[]; .status=="failed")
    ' "$work/zero-success/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} aggregate collection retains zero-success default panel"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} aggregate collection retains zero-success default panel"; FAIL=$((FAIL+1)); FAILURES+=("zero-success default panel")
  fi
  jq '
    .tribunal_verdict={"decision":"NEEDS_WORK","confidence":0,"rationale":"No default reviewer completed successfully."}
    | .summary="No usable reviewer evidence; merge remains blocked."
    | .provider_assessment.codex.status="failed"
    | .provider_assessment.grok.status="failed"
    | .provider_assessment.claude.status="failed"
  ' "$work/arbitration.json" > "$work/zero-success-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/zero-success" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/zero-success.json")" \
      --arbitration "$work/zero-success-arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} zero-success default panel fails closed at confidence zero"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} zero-success default panel fails closed at confidence zero"; FAIL=$((FAIL+1)); FAILURES+=("zero-success fail closed")
  fi

  FIXTURE_CODEX_MODE=diagnostic PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/diagnostic" > "$work/diagnostic.json"
  if jq -e '.provider=="codex" and (.error | contains("phase=parse; exit=0"))' \
      "$work/diagnostic/providers/codex.json" >/dev/null \
    && PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$work/diagnostic" \
        --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/diagnostic.json")" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} aggregate evidence retains provider diagnostics"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} aggregate evidence retains provider diagnostics"; FAIL=$((FAIL+1)); FAILURES+=("aggregate diagnostics")
  fi

  FIXTURE_CODEX_MODE=finding PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/finding" > "$work/finding.json"
  cat > "$work/finding-arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"The medium finding is non-blocking."},
  "findings":[{"id":"T-001","consensus":"SINGLE_PROVIDER","providers":["codex"],"severity":"medium",
    "category":"logic","file":"app.txt","line":1,"title":"Fixture finding","description":"A concrete fixture defect.",
    "suggestion":"Apply the fixture fix.","confidence":0.9,"arbiter_notes":"Verified and non-blocking."}],
  "scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":1,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "glm":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"}
  },
  "conflicts_resolved":[],"summary":"One medium finding remains non-blocking."
}
EOF
  jq '.findings[0].severity="high"' "$work/finding-arbitration.json" > "$work/missing-blocking-proof.json"
  local finding_manifest
  finding_manifest="$(jq -r .manifest_sha256 "$work/finding.json")"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/finding" \
      --expected-manifest-sha256 "$finding_manifest" --arbitration "$work/missing-blocking-proof.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} strict arbitration requires blocking proof"; FAIL=$((FAIL+1)); FAILURES+=("strict arbitration blocking proof")
  else
    jq -S . "$work/finding-arbitration.json" > "$work/finding/arbitration.json"
    chmod 0444 "$work/finding/arbitration.json"
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/finding" \
      --expected-manifest-sha256 "$finding_manifest" --arbitration "$work/finding-arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} interrupted finalize resumes from identical retained arbitration"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} interrupted finalize resumes from identical retained arbitration"; FAIL=$((FAIL+1)); FAILURES+=("interrupted finalize recovery")
  fi

  printf '# never commit\nscratch/\n' > "$repo/.gitignore"
  mkdir -p "$repo/scratch"
  printf 'ignored addition\n' > "$repo/scratch/note.md"
  git -C "$repo" add .gitignore
  git -C "$repo" add -f scratch/note.md
  git -C "$repo" commit -q -m 'force-add ignored path'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/ignored" > "$work/ignored.json"
  local ignored_manifest
  ignored_manifest="$(jq -r .manifest_sha256 "$work/ignored.json")"
  if jq -e '. == [{path:"scratch/note.md",pattern:"scratch/",source:".gitignore",line:2}]' \
      "$work/ignored/ignored-paths.json" >/dev/null 2>&1 \
    && jq -e '.ignored_paths.path == "ignored-paths.json" and (.ignored_paths.sha256 | test("^[0-9a-f]{64}$"))
      and (.ignored_paths.bytes > 0)' "$work/ignored/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} merge-gate collection seals ignored-path evidence"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} merge-gate collection seals ignored-path evidence"; FAIL=$((FAIL+1)); FAILURES+=("sealed ignored-path evidence")
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/ignored" \
      --expected-manifest-sha256 "$ignored_manifest" --arbitration "$work/arbitration.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} finalize rejects a forgotten ignored-path signal"; FAIL=$((FAIL+1)); FAILURES+=("forgotten ignored-path signal")
  else
    echo -e "  ${GREEN}PASS${NC} finalize rejects a forgotten ignored-path signal"; PASS=$((PASS+1))
  fi
  jq '.findings=[{
      id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
      category:"security",file:"scratch/note.md",line:1,title:"Force-added ignored path",
      description:"The reviewed diff adds a path matched by scratch/ at .gitignore:2.",
      suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
      arbiter_notes:"Deterministic repository-policy signal; default medium severity."
    }] | .summary="One deterministic medium repository-policy finding remains non-blocking."' \
    "$work/arbitration.json" > "$work/ignored-arbitration.json"
  cp -a "$work/ignored" "$work/ignored-high"
  jq '
    .tribunal_verdict={decision:"NEEDS_WORK",confidence:1,rationale:"The repository policy finding blocks approval."}
    | .findings[0].severity="high"
    | .findings[0].blocking_proof={
        reachable_path:"The reviewed diff force-adds the sealed ignored path.",
        material_impact:"The ignore policy marks the path as never commit.",
        caused_by_change:"The path is newly added in the reviewed range."
      }
    | .findings[0].arbiter_notes="Deterministic repository-policy signal escalated by a sensitive ignore comment."
    | .summary="One high repository-policy finding blocks approval."
  ' "$work/ignored-arbitration.json" > "$work/ignored-high-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/ignored-high" \
      --expected-manifest-sha256 "$ignored_manifest" --arbitration "$work/ignored-high-arbitration.json" \
      >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} high repository-policy finding overrides vacuous approval"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} high repository-policy finding overrides vacuous approval"; FAIL=$((FAIL+1)); FAILURES+=("repository-policy vacuous approval exemption")
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/ignored" \
      --expected-manifest-sha256 "$ignored_manifest" --arbitration "$work/ignored-arbitration.json" \
      >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} sensitive ignored-path finding cannot be downgraded to medium"; FAIL=$((FAIL+1)); FAILURES+=("sensitive ignored-path severity floor")
  else
    echo -e "  ${GREEN}PASS${NC} sensitive ignored-path finding cannot be downgraded to medium"; PASS=$((PASS+1))
  fi

  local initial_base="$base"
  base="$(git -C "$repo" rev-parse HEAD)"
  printf '# never commit\nscratch/\n*.log\n' > "$repo/.gitignore"
  printf 'ignored log addition\n' > "$repo/audit.log"
  git -C "$repo" add .gitignore
  git -C "$repo" add -f audit.log
  git -C "$repo" commit -q -m 'add second sensitive ignored pattern'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/second-sensitive" > "$work/second-sensitive.json"
  local second_sensitive_manifest
  second_sensitive_manifest="$(jq -r .manifest_sha256 "$work/second-sensitive.json")"
  jq '.findings=[{
      id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
      category:"security",file:"audit.log",line:1,title:"Force-added ignored log",
      description:"The reviewed diff adds a path matched by *.log at .gitignore:3.",
      suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
      arbiter_notes:"Deterministic repository-policy signal; default medium severity."
    }] | .summary="One deterministic medium repository-policy finding remains non-blocking."' \
    "$work/arbitration.json" > "$work/second-sensitive-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/second-sensitive" \
      --expected-manifest-sha256 "$second_sensitive_manifest" --arbitration "$work/second-sensitive-arbitration.json" \
      >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} second sensitive ignored pattern cannot be downgraded to medium"; FAIL=$((FAIL+1)); FAILURES+=("second sensitive ignored-path severity floor")
  else
    echo -e "  ${GREEN}PASS${NC} second sensitive ignored pattern cannot be downgraded to medium"; PASS=$((PASS+1))
  fi

  base="$(git -C "$repo" rev-parse HEAD)"
  printf '# keyboard build artifacts\n*.tmp\n# secretary exports\n*.csv\n' > "$repo/.gitignore"
  printf 'temporary artifact\n' > "$repo/cache.tmp"
  printf 'export artifact\n' > "$repo/report.csv"
  git -C "$repo" add .gitignore
  git -C "$repo" add -f cache.tmp report.csv
  git -C "$repo" commit -q -m 'add non-sensitive keyword-like ignore comments'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/keyword-like" > "$work/keyword-like.json"
  local keyword_like_manifest
  keyword_like_manifest="$(jq -r .manifest_sha256 "$work/keyword-like.json")"
  jq '.findings=[
      {id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
       category:"security",file:"cache.tmp",line:1,title:"Force-added ignored temporary artifact",
       description:"The reviewed diff adds a path matched by *.tmp at .gitignore:2.",
       suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
       arbiter_notes:"Deterministic repository-policy signal; default medium severity."},
      {id:"T-002",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
       category:"security",file:"report.csv",line:1,title:"Force-added ignored export artifact",
       description:"The reviewed diff adds a path matched by *.csv at .gitignore:4.",
       suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
       arbiter_notes:"Deterministic repository-policy signal; default medium severity."}
    ] | .summary="Two deterministic medium repository-policy findings remain non-blocking."' \
    "$work/arbitration.json" > "$work/keyword-like-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/keyword-like" \
      --expected-manifest-sha256 "$keyword_like_manifest" --arbitration "$work/keyword-like-arbitration.json" \
      >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} keyboard and secretary ignore comments stay non-sensitive"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} keyboard and secretary ignore comments stay non-sensitive"; FAIL=$((FAIL+1)); FAILURES+=("keyword-like ignore comments")
  fi
  base="$initial_base"

  printf '# ordinary scratch files\nscratch/\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m 'make ignored path non-sensitive'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/non-sensitive" > "$work/non-sensitive.json"
  local non_sensitive_manifest
  non_sensitive_manifest="$(jq -r .manifest_sha256 "$work/non-sensitive.json")"
  # The ambient worktree is deliberately more sensitive than HEAD. Finalization must use HEAD.
  printf '# never commit\nscratch/\n' > "$repo/.gitignore"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/non-sensitive" \
      --expected-manifest-sha256 "$non_sensitive_manifest" --arbitration "$work/ignored-arbitration.json" \
      > "$work/non-sensitive-finalize.json" \
    && jq -e '.proof_sha256 | test("^[0-9a-f]{64}$")' "$work/non-sensitive-finalize.json" >/dev/null \
    && jq -e '.schema == "tribunal-proof/v1" and .arbitration.decision == "APPROVE"' \
      "$work/non-sensitive/proof.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} non-sensitive ignored path accepts medium severity from HEAD"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} non-sensitive ignored path accepts medium severity from HEAD"; FAIL=$((FAIL+1)); FAILURES+=("non-sensitive ignored-path medium severity")
  fi
  jq '.tribunal_verdict.confidence=0' "$work/ignored-arbitration.json" > "$work/non-sensitive-low-confidence.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/non-sensitive" \
      --expected-manifest-sha256 "$non_sensitive_manifest" --arbitration "$work/non-sensitive-low-confidence.json" \
      >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} APPROVE requires confidence 0.95 with repository policy findings"; FAIL=$((FAIL+1)); FAILURES+=("APPROVE confidence pin")
  else
    echo -e "  ${GREEN}PASS${NC} APPROVE requires confidence 0.95 with repository policy findings"; PASS=$((PASS+1))
  fi

  # The sealed wrapper's 64 MiB file limit must not apply to inherited Codex state.
  cp "$PLUGIN_ROOT/scripts/run-codex-review.sh" "$plugin/scripts/"
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
  host_codex="$work/normal-codex-home"
  mkdir -p "$host_codex"
  printf '%s\n' '{"fixture_auth":true}' > "$host_codex/auth.json"
  dd if=/dev/zero of="$host_codex/state_5.sqlite" bs=1 count=1 seek=67108864 2>/dev/null
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "${CODEX_HOME:?}" > "${FIXTURE_CODEX_HOME_FILE:?}"
grep -qx '{"fixture_auth":true}' "$CODEX_HOME/auth.json" || exit 1
if [ "$(ulimit -f)" = 65536 ] && [ -f "$CODEX_HOME/state_5.sqlite" ] \
  && [ "$(wc -c < "$CODEX_HOME/state_5.sqlite")" -gt 67108864 ]; then
  exit 0
fi
printf '%s\n' '{"provider":"codex","model":"fixture","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  chmod +x "$fake/codex"
  if CODEX_HOME="$host_codex" FIXTURE_CODEX_HOME_FILE="$work/codex-home-used" \
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    TRIBUNAL_CODEX=on TRIBUNAL_GEMINI=off TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=off \
    TRIBUNAL_QWEN=off TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/oversized-codex-state" > "$work/oversized-codex-state.json" \
    && jq -e '.provider=="codex" and .summary.verdict=="APPROVE"' \
      "$work/oversized-codex-state/providers/codex.json" >/dev/null \
    && jq -e 'any(.providers[]; .provider=="codex" and .status=="ok")' \
      "$work/oversized-codex-state/manifest.json" >/dev/null \
    && [ "$(cat "$work/codex-home-used")" != "$host_codex" ]; then
    echo -e "  ${GREEN}PASS${NC} sealed Codex leg isolates oversized inherited state"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} sealed Codex leg isolates oversized inherited state"; FAIL=$((FAIL+1)); FAILURES+=("sealed Codex state isolation")
  fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

SK=skills/tribunal-loop/SKILL.md
CL=skills/closing-tribunal-loop/SKILL.md
LIB=scripts/lib.sh
PF=scripts/preflight.sh

echo "Extracted script surface:"
for script in \
  scripts/lib.sh \
  scripts/preflight.sh \
  scripts/run-codex-review.sh \
  scripts/run-gemini-review.sh \
  scripts/run-opencode-review.sh \
  scripts/run-qwen-review.sh \
  scripts/run-grok-review.sh \
  scripts/run-claude-review.sh \
  scripts/collect-review-evidence.sh \
  scripts/check-runner-bundle.sh \
  scripts/generate-runner-bundle.sh
do
  assert_file "$script exists" "$script"
  assert_executable "$script executable" "$script"
  assert_bash_n "$script parses" "$script"
done
assert_file "structured review schema exists" "schemas/review-output.json"
assert_json_field "structured review schema is valid JSON" "jq -e '.type==\"object\" and .additionalProperties==false' '$PLUGIN_ROOT/schemas/review-output.json'"
assert_file "static runner bundle manifest exists" "integrity/runner-bundle.json"
assert_json_field "static runner bundle validates" "bash '$PLUGIN_ROOT/scripts/check-runner-bundle.sh' | jq -e '.status==\"valid\" and (.version|not)'"
assert_json_field "static runner bundle is current" "bash '$PLUGIN_ROOT/scripts/generate-runner-bundle.sh' --check"

echo "Skill is orchestration-focused:"
line_count="$(wc -l < "$PLUGIN_ROOT/$SK" | tr -d ' ')"
if [ "$line_count" -le 260 ]; then
  echo -e "  ${GREEN}PASS${NC} compact tribunal skill ($line_count<=260)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} compact tribunal skill ($line_count>260)"; FAIL=$((FAIL+1)); FAILURES+=("compact tribunal skill")
fi
assert_grep "skill references preflight script" "$SK" "scripts/preflight.sh"
assert_grep "skill references codex runner" "$SK" "scripts/run-codex-review.sh"
assert_grep "skill references opencode runner" "$SK" "scripts/run-opencode-review.sh"
assert_grep "skill references grok runner" "$SK" "scripts/run-grok-review.sh"
assert_grep "skill references claude runner" "$SK" "scripts/run-claude-review.sh"
assert_grep "merge gate uses trusted aggregate runner" "$SK" "scripts/collect-review-evidence.sh"
assert_grep "caller provider JSON is not merge evidence" "$SK" "caller-created provider JSON as merge evidence"
assert_no_grep "skill no inline provider command bloat" "$SK" "timeout -k 10 600 codex exec"
assert_grep "skill default panel lists DeepSeek with opt-in providers" "$SK" "Gemini, DeepSeek,"
assert_grep "skill default panel marks complete opt-in provider set" "$SK" "GLM, and Qwen are opt-in."
assert_no_grep "skill default panel does not include DeepSeek" "$SK" "DeepSeek through OpenCode Go (repo-walking)"

echo "Preflight/base-ref behavior:"
assert_grep "resolves GitHub default branch" "$LIB" "defaultBranchRef"
assert_grep "supports base-ref override" "$LIB" "TRIBUNAL_BASE_REF"
assert_grep "resolves the base ref before diffing" "$LIB" 'git rev-parse --verify "$base_ref^{commit}"'
assert_grep "diffs the pinned range" "$LIB" 'git diff "$base_oid...$head_oid"'
assert_grep "pinned range JSON is built by jq, not string interpolation" "$LIB" 'jq -Rn --arg base "$base_ref"'
assert_grep "numstat failure is fail-closed" "$LIB" 'git diff --numstat "$base_oid...$head_oid" --no-ext-diff --no-textconv > "$out.numstat" || return 1'
assert_grep "tracks active reviewer legs" "$PF" "zero active reviewer legs"
assert_grep "warms OpenCode model registry" "$PF" "opencode models"
assert_grep "Claude auth probe is bounded" "$LIB" "timeout -k 1 10 claude auth status --json"
assert_grep "preflight checks Claude auth" "$PF" "tribunal_claude_authenticated"
assert_grep "preflight checks Grok auth" "$PF" "tribunal_grok_authenticated"
assert_grep "lib defines Grok auth write-back" "$LIB" "tribunal_grok_auth_writeback"
assert_grep "preflight discloses invocation limitation" "$PF" "non-interactive invocation not probed"
assert_grep "preflight offers bounded non-interactive smoke" "$PF" "TRIBUNAL_SMOKE_PROBE"
assert_no_grep "skill has no hardcoded origin/main" "$SK" "origin/main"
assert_no_grep "lib has no hardcoded origin/main" "$LIB" "origin/main"

echo "Context and large-diff guards:"
assert_grep "AGENTS.md capped" "$LIB" "head -c 4096"
assert_grep "reachability.md capped" "$LIB" "head -c 8192"
assert_no_grep "reviewer prompt has no DRY instruction" "$LIB" "DRY: flag meaningful duplication"
assert_grep "diff limit env" "$LIB" "TRIBUNAL_DIFF_LIMIT_BYTES"
assert_grep "large diff uses head -c" "$LIB" 'head -c "$max"'
assert_grep "OpenCode uses file attachment" "scripts/run-opencode-review.sh" '-f "$diff_attach"'
assert_grep "OpenCode prompt positional precedes -f (array flag swallows positionals, issue #170)" "scripts/run-opencode-review.sh" '"$(cat "$prompt")" -f "$diff_attach"'
assert_no_grep "OpenCode -f does not precede prompt positional" "scripts/run-opencode-review.sh" '-f "$diff_attach" "$(cat'
assert_grep "OpenCode stages diff in cwd" "scripts/run-opencode-review.sh" ".tribunal-review-"
assert_grep "OpenCode isolates external plugins" "scripts/run-opencode-review.sh" "--pure"
assert_grep "OpenCode non-interactive run bypasses permission prompts" "scripts/run-opencode-review.sh" "--dangerously-skip-permissions"
assert_grep "Codex writes its final response independently of stdout" "scripts/run-codex-review.sh" "--output-last-message"
assert_grep "Codex requests the shared output schema" "scripts/run-codex-review.sh" "--output-schema"
assert_grep "Claude requests the shared output schema" "scripts/run-claude-review.sh" "--json-schema"
assert_grep "Claude disables the complete tool surface" "scripts/run-claude-review.sh" '--tools ""'
assert_grep "Grok requests the shared output schema" "scripts/run-grok-review.sh" "--json-schema"
assert_grep "Grok tools allowlist is read-only" "scripts/run-grok-review.sh" "read_file,list_dir,grep"
assert_grep "Grok sandbox profile is configurable" "scripts/run-grok-review.sh" 'GROK_SANDBOX_PROFILE='
assert_grep "Grok defaults sandbox to none (container boundary)" "scripts/run-grok-review.sh" 'GROK_SANDBOX_PROFILE=none'
assert_grep "Grok honors TRIBUNAL_GROK_SANDBOX" "scripts/run-grok-review.sh" 'TRIBUNAL_GROK_SANDBOX'
assert_grep "Grok rejects invalid sandbox profile" "scripts/run-grok-review.sh" "invalid Grok sandbox profile"
assert_grep "Grok rejects invalid permission mode" "scripts/run-grok-review.sh" "invalid Grok permission mode"
assert_no_grep "Grok does not unset host GROK_SANDBOX" "scripts/run-grok-review.sh" "env -u GROK_SANDBOX"
assert_grep "Grok propagates GROK_SANDBOX into child" "scripts/run-grok-review.sh" 'GROK_SANDBOX="$GROK_SANDBOX_PROFILE"'
assert_grep "Grok isolates host HOME" "scripts/run-grok-review.sh" 'HOME="$ISOLATED_HOME"'
assert_grep "Grok isolates host GROK_HOME" "scripts/run-grok-review.sh" 'GROK_HOME="$ISOLATED_HOME/.grok"'
assert_grep "Grok copies auth into isolation" "scripts/run-grok-review.sh" 'cp -a "$AUTH_SRC" "$AUTH_ISOLATED"'
assert_no_grep "Grok does not symlink auth into isolation" "scripts/run-grok-review.sh" 'ln -s "$AUTH_SRC"'
assert_grep "Grok write-backs auth on cleanup" "scripts/run-grok-review.sh" "tribunal_grok_auth_writeback"
assert_grep "Grok requires signed-in session" "scripts/run-grok-review.sh" "tribunal_grok_authenticated"
assert_grep "Grok disables web search" "scripts/run-grok-review.sh" "--disable-web-search"
assert_grep "Grok pins a session id for resume" "scripts/run-grok-review.sh" "--session-id"
assert_grep "Grok finalize resumes the same session" "scripts/run-grok-review.sh" "--resume"
assert_grep "Grok bounds inspect turns" "scripts/run-grok-review.sh" "--max-turns"
assert_grep "Grok uses bypassPermissions for headless multi-turn" "scripts/run-grok-review.sh" "bypassPermissions"
assert_no_grep "Grok does not hardcode dontAsk" "scripts/run-grok-review.sh" "--permission-mode dontAsk"
assert_grep "Grok rejects progress-only as incomplete" "scripts/run-grok-review.sh" "completion_state=progress_only"
assert_grep "Grok marks non-EndTurn stop as dead_leg" "scripts/run-grok-review.sh" "completion_state=dead_leg"
assert_grep "Grok fails loud on missing schema" "scripts/run-grok-review.sh" "review schema missing"
assert_grep "Grok resolves schema via plugin root helper" "scripts/lib.sh" "tribunal_plugin_root"
assert_grep "Grok finalize re-inlines the authoritative diff" "scripts/run-grok-review.sh" "Base the verdict on the unified diff"
assert_grep "Grok clamps inspect timeout upper bound" "scripts/run-grok-review.sh" "INSPECT_TIMEOUT=1800"
assert_grep "Grok extracts camelCase structuredOutput" "scripts/lib.sh" "structuredOutput"
assert_grep "Grok payload completeness helper" "scripts/lib.sh" "tribunal_review_payload_complete"
assert_grep "Grok payload requires enum verdict" "scripts/lib.sh" 'APPROVE" or $v == "NEEDS_WORK" or $v == "BLOCK"'

echo "Disabled-provider markers:"
assert_json_field "codex disabled JSON" "TRIBUNAL_CODEX=off bash '$PLUGIN_ROOT/scripts/run-codex-review.sh' | jq -e '.provider==\"codex\" and .status==\"disabled\"'"
assert_json_field "gemini disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-gemini-review.sh' | jq -e '.provider==\"gemini\" and .status==\"disabled\"'"
assert_json_field "qwen disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-qwen-review.sh' | jq -e '.provider==\"qwen\" and .status==\"disabled\"'"
assert_json_field "grok disabled JSON" "TRIBUNAL_GROK=off bash '$PLUGIN_ROOT/scripts/run-grok-review.sh' | jq -e '.provider==\"grok\" and .status==\"disabled\"'"
assert_json_field "claude disabled JSON" "TRIBUNAL_CLAUDE=off bash '$PLUGIN_ROOT/scripts/run-claude-review.sh' | jq -e '.provider==\"claude\" and .status==\"disabled\"'"
assert_json_field "deepseek defaults to disabled JSON" "env -u TRIBUNAL_DEEPSEEK TRIBUNAL_GLM=off bash '$PLUGIN_ROOT/scripts/run-opencode-review.sh' | jq -s -e 'length==2 and .[1].provider==\"deepseek\" and .[1].status==\"disabled\"'"
assert_json_field "opencode disabled JSONL" "TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=off bash '$PLUGIN_ROOT/scripts/run-opencode-review.sh' | jq -s -e 'length==2 and all(.[]; .status==\"disabled\")'"
assert_json_field "opencode usage error preserves disabled markers" "TRIBUNAL_GLM=off TRIBUNAL_DEEPSEEK=on bash '$PLUGIN_ROOT/scripts/run-opencode-review.sh' --bad-flag | jq -s -e 'length==2 and .[0].provider==\"glm\" and .[0].status==\"disabled\" and (.[1] | .provider==\"deepseek\" and has(\"error\"))'"
test_empty_staged_diff_with_real_changes_fails_closed
test_genuine_empty_diff_is_reverified_and_unchanged
test_unresolvable_base_during_empty_verification_fails_closed
test_qwen_envelope_parser
test_claude_auth_guard
test_grok_auth_guard
test_preflight_smoke_probe
test_claude_tmpdir_cleanup
test_opencode_wal_isolation
test_opencode_timeout_error
test_opencode_killed_error
test_opencode_gated_model_error
test_opencode_gated_tool_trace_is_generic_error
test_opencode_gated_tool_trace_timeout_is_pure_timeout
test_opencode_provider_gated_error_is_classified
test_opencode_provider_gated_timeout_is_pure_timeout
test_opencode_generic_failure_error
test_opencode_timeout_tool_output_is_not_auth_error
test_opencode_filename_tool_output_is_generic_error
test_codex_pins gpt-5.6-sol medium no "codex defaults pin Sol and medium in argv"
test_codex_pins test-model high yes "codex model and effort environment overrides stay explicit"
test_codex_parse_diagnostics
test_codex_empty_output
test_claude_execution_diagnostics
test_claude_non_json_output
test_grok_deterministic_completion
test_grok_auth_copy_writeback
test_codex_vacuous_guard BLOCK 0.0 "codex vacuous empty-BLOCK downgraded to leg error"
test_codex_vacuous_guard NEEDS_WORK 7.5 "codex vacuous empty-NEEDS_WORK (nonzero quality) downgraded to leg error"
test_codex_vacuous_guard " BLOCK " 0.0 "codex vacuous verdict tolerates surrounding whitespace"
test_codex_line_bounds_guard
test_wrapper_owned_provider_envelope
test_wrapper_stamped_diff_stat
test_ignored_path_additions
test_ignored_path_diff_failures
test_ignored_path_validation
test_trusted_evidence_collection

echo "Finding position validation:"
assert_grep "lib defines line-bounds validator" "$LIB" "tribunal_line_check()"
assert_grep "prepare_diff records NUL-delimited changed paths" "$LIB" 'git diff --name-only -z "$base_oid...$head_oid"'
for runner in run-codex-review.sh run-claude-review.sh run-gemini-review.sh run-qwen-review.sh run-grok-review.sh run-opencode-review.sh; do
  assert_grep "$runner pipes through line check" "scripts/$runner" "tribunal_line_check"
  assert_grep "$runner stamps the reviewed range" "scripts/$runner" "tribunal_stamp_diff_stat"
done
assert_grep "arbiter told to distrust marked positions" "$SK" "line_check"
assert_grep "ignored-path signal must become a finding" "$SK" "must become a finding"
assert_grep "ignored-path finding defaults medium" "$SK" "default.*medium"
assert_grep "sensitive ignore comments escalate high" "$SK" "secret.*PII.*credential.*key.*never commit"
assert_grep "high ignored-path finding blocks gate" "$SK" "high.*blocks the gate"
assert_grep "zero-finding approval excludes ignored-path signals" "$SK" "sealed ignored-path signals"

echo "Arbitration contract:"
assert_grep "3b-0 in SKILL" "$SK" "3b-0: Blocking-Finding Standard"
assert_grep "standard overrides highest-severity" "$SK" "never override 3b-0"
assert_grep "same-class merge" "$SK" "Same-Class Merge (Every Round)"
assert_grep "reachability read by arbiter" "$SK" "Also read .reachability.md"
assert_grep "blocking_proof schema" "$SK" '"blocking_proof"'
assert_grep "arbiter applies KISS/YAGNI filter" "$SK" "3c: KISS / YAGNI Filter (Arbiter)"
assert_grep "arbiter rewrites over-engineered suggestions" "$SK" "smallest sufficient fix"
assert_grep "KISS/YAGNI alone cannot block" "$SK" "Never promote to critical/high for a KISS/YAGNI violation alone"
assert_grep "scope lens switch" "$SK" "TRIBUNAL_SCOPE_LENS"
assert_grep "scope findings schema" "$SK" "scope_findings"
assert_grep "calling context arbitrates" "$SK" "calling context arbitrates"
assert_grep "caller provider metadata optional" "$SK" "TRIBUNAL_CALLER_PROVIDER"
assert_grep "caller model metadata optional" "$SK" "TRIBUNAL_CALLER_MODEL"
assert_grep "caller effort metadata optional" "$SK" "TRIBUNAL_CALLER_EFFORT"
assert_grep "sealed proof rechecks live PR drift" "$SK" "rechecks live PR drift"
assert_grep "standalone caller identity is optional" "$SK" "standalone runs may leave all three unset"
assert_no_grep "tribunal skill has no Opus authority claim" "$SK" "Opus"
assert_no_grep "closing skill has no Opus authority claim" "$CL" "Opus"
assert_no_grep "README has no Opus authority claim" "README.md" "Opus"
assert_no_grep "Claude reviewer has no Opus authority claim" "agents/claude-reviewer.md" "Opus"

echo "Closing loop governor:"
assert_grep "stop on no crit/high" "$CL" "zero .critical. and"
assert_grep "YAGNI triage" "$CL" "YAGNI triage"
assert_grep "closing loop freezes delivery scope" "$CL" "Frozen Delivery Contract"
assert_grep "scope comes from explicit task text" "$CL" "using only explicit user, issue, PR, or plan text"
assert_grep "missing scope is not invented" "$CL" "Never invent missing"
assert_grep "findings do not redefine task" "$CL" "do not redefine the task"
assert_grep "fixes remain causal and minimal" "$CL" "smallest causal fix"
assert_grep "adjacent concerns do not expand investigation" "$CL" "beyond evidence already present"
assert_grep "step-back preserves architecture" "$CL" "existing architecture"
assert_grep "step-back workflow" "$CL" "Step-back workflow (anti-spiral)"
assert_grep "no-net-increase guard" "$CL" "no-net-increase"
assert_grep "round 3 checkpoint" "$CL" "Round 3 — checkpoint"
assert_grep "round 5 ceiling" "$CL" "Round 5 — hard ceiling"
assert_grep "closing loop is PR-only" "$CL" "PR prerequisite (hard)"
assert_grep "closing loop requires open PR" "$CL" "requires an open GitHub PR"
assert_grep "each round posts a PR comment" "$CL" "the round PR comment"
assert_grep "round comments use stable marker" "$CL" "<!-- tribunal-round:N -->"
assert_grep "round comments post via body-file" "$CL" "gh pr comment"
assert_grep "YAGNI drops land on PR comment" "$CL" "closing round PR comment"
assert_grep "HEAD must match PR headRefOid" "$CL" 'LOCAL_HEAD'
assert_grep "resume derives round from existing markers" "$CL" "PRIOR_MAX"
assert_grep "ceiling is cumulative on the PR" "$CL" "cumulative on the PR"
assert_grep "post comment before applying fixes" "$CL" "applying code fixes for that verdict"
assert_file "round comment template exists" "skills/closing-tribunal-loop/references/round-comment.md"
assert_file "follow-up issue template exists" "skills/closing-tribunal-loop/references/follow-up-issue.md"
assert_grep "round comment template has marker" "skills/closing-tribunal-loop/references/round-comment.md" "<!-- tribunal-round:N -->"
assert_grep "round comment posts with body-file" "skills/closing-tribunal-loop/references/round-comment.md" "gh pr comment"
assert_grep "round comment uses will-fix before commits" "skills/closing-tribunal-loop/references/round-comment.md" "Will-fix"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
