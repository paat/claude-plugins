#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.


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
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/muse"; chmod +x "$fake/muse"
  preflight_json="$(cd "$work" && PATH="$fake:$PATH" TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF="$base" \
    TRIBUNAL_CODEX=on TRIBUNAL_MUSE=on TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
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
    TRIBUNAL_CODEX=on TRIBUNAL_MUSE=on TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
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
    TRIBUNAL_CODEX=on TRIBUNAL_MUSE=on TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
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
    "$PLUGIN_ROOT/scripts/collector-validate.sh")

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

test_deleted_policy_paths() {
  local work fake base deleted_json preflight_json clean_json clean_rc custom_json dirty_json
  local gitignore_base gitignore_json empty_globs_json head_only_json custom_base helper_rc=0
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  git -C "$work" init -q -b main
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name "Test User"
  mkdir -p "$work/docs/policies" "$work/rules"
  printf 'policy\n' > "$work/docs/policies/foo.md"
  printf 'keep\n' > "$work/docs/policies/keep.md"
  printf 'rule\n' > "$work/rules/bar.md"
  printf 'readme\n' > "$work/README.md"
  git -C "$work" add docs/policies/foo.md docs/policies/keep.md rules/bar.md README.md
  git -C "$work" commit -q -m base
  base="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q -b feature
  git -C "$work" rm -q docs/policies/foo.md README.md
  git -C "$work" commit -q -m 'delete policy and readme'

  deleted_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_deleted_policy_paths "$base" 2>/dev/null)" || true
  if printf '%s' "$deleted_json" | jq -e '
      length == 1 and .[0] == {path:"docs/policies/foo.md",glob:"docs/policies/**"}
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} deleted policy path reports path and glob"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} deleted policy path reports path and glob"; FAIL=$((FAIL+1)); FAILURES+=("deleted policy path details")
  fi
  if printf '%s' "$deleted_json" | jq -e 'all(.[]; .path != "README.md")' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} non-matching deleted path is not reported"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} non-matching deleted path is not reported"; FAIL=$((FAIL+1)); FAILURES+=("non-matching deleted path exclusion")
  fi

  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/codex"; chmod +x "$fake/codex"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/muse"; chmod +x "$fake/muse"
  preflight_json="$(cd "$work" && PATH="$fake:$PATH" TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF="$base" \
    TRIBUNAL_CODEX=on TRIBUNAL_MUSE=on TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
    bash "$PLUGIN_ROOT/scripts/preflight.sh" 2>/dev/null)" || true
  if printf '%s' "$preflight_json" | jq -e '
      any(.warnings[]; .name == "deleted-policy-paths"
        and (.note | contains("docs/policies/foo.md"))
        and (.note | contains("docs/policies/**")))
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} preflight warns about deleted policy paths"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} preflight warns about deleted policy paths"; FAIL=$((FAIL+1)); FAILURES+=("preflight deleted policy warning")
  fi

  git -C "$work" checkout -q -b clean "$base"
  printf 'clean\n' > "$work/clean.md"
  git -C "$work" add clean.md
  git -C "$work" commit -q -m clean
  clean_rc=0
  clean_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_deleted_policy_paths "$base" 2>/dev/null)" || clean_rc=$?
  preflight_json="$(cd "$work" && PATH="$fake:$PATH" TRIBUNAL_BASE_BRANCH=main TRIBUNAL_BASE_REF="$base" \
    TRIBUNAL_CODEX=on TRIBUNAL_MUSE=on TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off \
    bash "$PLUGIN_ROOT/scripts/preflight.sh" 2>/dev/null)" || true
  if [ "$clean_rc" -eq 0 ] && [ "$clean_json" = '[]' ] \
    && printf '%s' "$preflight_json" | jq -e 'all(.warnings[]; .name != "deleted-policy-paths")' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} no matching deletions produce empty deleted-path signal"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} no matching deletions produce empty deleted-path signal"; FAIL=$((FAIL+1)); FAILURES+=("clean deleted policy check")
  fi

  # Custom globs apply only when .tribunal-deleted-globs exists on base.
  git -C "$work" checkout -q -b custom-globs-base "$base"
  printf '# custom list\nREADME.md\n' > "$work/.tribunal-deleted-globs"
  git -C "$work" add .tribunal-deleted-globs
  git -C "$work" commit -q -m 'custom globs on base'
  custom_base="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q -b custom-globs
  git -C "$work" rm -q docs/policies/foo.md README.md
  git -C "$work" commit -q -m 'custom globs deletions'
  custom_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_deleted_policy_paths "$custom_base" 2>/dev/null)" || true
  if printf '%s' "$custom_json" | jq -e '
      . == [{path:"README.md",glob:"README.md"}]
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} repo .tribunal-deleted-globs on base replaces defaults"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} repo .tribunal-deleted-globs on base replaces defaults"; FAIL=$((FAIL+1)); FAILURES+=("custom deleted globs")
  fi

  # Dirty worktree must not change base-based glob selection.
  printf 'docs/policies/**\n' > "$work/.tribunal-deleted-globs"
  dirty_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_deleted_policy_paths "$custom_base" 2>/dev/null)" || true
  if printf '%s' "$dirty_json" | jq -e '
      . == [{path:"README.md",glob:"README.md"}]
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} dirty .tribunal-deleted-globs cannot replace base list"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} dirty .tribunal-deleted-globs cannot replace base list"; FAIL=$((FAIL+1)); FAILURES+=("dirty deleted globs")
  fi
  git -C "$work" checkout -q -- .tribunal-deleted-globs

  # HEAD-only comment/empty .tribunal-deleted-globs must not disable defaults.
  git -C "$work" checkout -q -b head-only-empty "$base"
  printf '# no globs\n\n# still empty\n' > "$work/.tribunal-deleted-globs"
  git -C "$work" add .tribunal-deleted-globs
  git -C "$work" rm -q docs/policies/keep.md
  git -C "$work" commit -q -m 'HEAD-only empty globs and keep.md deletion'
  head_only_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_deleted_policy_paths "$base" 2>/dev/null)" || true
  if printf '%s' "$head_only_json" | jq -e '
      . == [{path:"docs/policies/keep.md",glob:"docs/policies/**"}]
    ' >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} HEAD-only empty .tribunal-deleted-globs keeps defaults"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} HEAD-only empty .tribunal-deleted-globs keeps defaults"; FAIL=$((FAIL+1)); FAILURES+=("HEAD-only empty deleted globs")
  fi

  # Tracked deletion under .gitignore must not use ignore rules for this signal.
  git -C "$work" checkout -q -b gitignore-vendor "$base"
  mkdir -p "$work/vendor"
  printf 'vendored\n' > "$work/vendor/lib.js"
  printf 'vendor/\n' > "$work/.gitignore"
  git -C "$work" add -f vendor/lib.js .gitignore
  git -C "$work" commit -q -m 'track vendor despite gitignore'
  gitignore_base="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" rm -q vendor/lib.js
  git -C "$work" commit -q -m 'delete gitignored-tracked vendor path'
  gitignore_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_deleted_policy_paths "$gitignore_base" 2>/dev/null)" || true
  if [ "$gitignore_json" = '[]' ]; then
    echo -e "  ${GREEN}PASS${NC} .gitignore-only deletion is not reported as deleted policy path"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} .gitignore-only deletion is not reported as deleted policy path"; FAIL=$((FAIL+1)); FAILURES+=("gitignore deletion exclusion")
  fi

  # Empty .tribunal-deleted-globs on base ⇒ [] (repo opted out on the base branch).
  git -C "$work" checkout -q "$gitignore_base"
  printf '# no globs\n\n# still empty\n' > "$work/.tribunal-deleted-globs"
  git -C "$work" add .tribunal-deleted-globs
  git -C "$work" commit -q -m 'empty deleted-globs on base'
  gitignore_base="$(git -C "$work" rev-parse HEAD)"
  git -C "$work" checkout -q -b empty-globs
  git -C "$work" rm -q vendor/lib.js
  git -C "$work" commit -q -m 'vendor deletion with empty base globs'
  empty_globs_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" && tribunal_deleted_policy_paths "$gitignore_base" 2>/dev/null)" || true
  if [ "$empty_globs_json" = '[]' ]; then
    echo -e "  ${GREEN}PASS${NC} empty .tribunal-deleted-globs on base yields []"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} empty .tribunal-deleted-globs on base yields []"; FAIL=$((FAIL+1)); FAILURES+=("empty deleted globs")
  fi

  helper_rc=0
  deleted_json="$(cd "$work" && . "$PLUGIN_ROOT/scripts/lib.sh" \
    && tribunal_deleted_policy_paths no-such-ref-xyz 2>/dev/null)" || helper_rc=$?
  if [ "$helper_rc" -ne 0 ] && [ "$deleted_json" != '[]' ]; then
    echo -e "  ${GREEN}PASS${NC} deleted-policy inspection fails for an unresolvable base ref"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} deleted-policy inspection fails for an unresolvable base ref"; FAIL=$((FAIL+1)); FAILURES+=("deleted-policy diff failure")
  fi
  rm -rf "$work"
}

test_deleted_policy_paths_gate() {
  local work repo fake plugin collection manifest_sha base head ec=0 mutated
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
printf '%s\n' "{\"provider\":\"codex\",\"model\":\"fixture\",\"files_examined\":[\"app.txt\"],\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10,\"verdict\":\"APPROVE\",\"note\":\"native review (codex exec review) fed the verdict pass\"},\"diff_stat\":{\"files_changed\":1,\"insertions\":0,\"deletions\":1,\"base\":\"$TRIBUNAL_BASE_REF\",\"base_oid\":\"$base\",\"head_oid\":\"$head\",\"truncated\":false}}"
EOF
  sed 's/"provider":"codex"/"provider":"claude"/' "$plugin/scripts/run-codex-review.sh" > "$plugin/scripts/run-claude-review.sh"
  for provider in gemini qwen grok muse; do
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
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/codex"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
printf '%s\n' '{"loggedIn":true}'
EOF
  chmod +x "$fake/codex" "$fake/claude"
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null

  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    mkdir -p docs/policies
    printf 'policy\n' > docs/policies/foo.md
    printf 'one\n' > app.txt
    printf 'readme\n' > README.md
    git add docs/policies/foo.md app.txt README.md
    git commit -q -m base
    git rm -q docs/policies/foo.md
    printf 'two\n' > app.txt
    git add app.txt
    git commit -q -m 'delete policy path'
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

  cat > "$work/arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"Two valid reviewers found no defects."},
  "findings":[],"scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "muse":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"}
  },
  "conflicts_resolved":[],"summary":"No blocking findings."
}
EOF

  collection="$work/deleted"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$collection" > "$work/deleted.json"; then
    echo -e "  ${RED}FAIL${NC} merge-gate collection seals deleted-path evidence (collect)"; FAIL=$((FAIL+1)); FAILURES+=("sealed deleted-path evidence")
    rm -rf "$work"; return
  fi
  manifest_sha="$(jq -r .manifest_sha256 "$work/deleted.json")"
  if jq -e '. == [{glob:"docs/policies/**",path:"docs/policies/foo.md"}]' \
      "$collection/deleted-paths.json" >/dev/null 2>&1 \
    && jq -e '.deleted_paths.path == "deleted-paths.json" and (.deleted_paths.sha256 | test("^[0-9a-f]{64}$"))
      and (.deleted_paths.bytes > 0)' "$collection/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} merge-gate collection seals deleted-path evidence"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} merge-gate collection seals deleted-path evidence"; FAIL=$((FAIL+1)); FAILURES+=("sealed deleted-path evidence")
  fi

  ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
      >/dev/null 2>"$work/forgotten.err" || ec=$?
  if [ "$ec" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${NC} finalize rejects a forgotten deleted-path signal"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} finalize rejects a forgotten deleted-path signal"; FAIL=$((FAIL+1)); FAILURES+=("forgotten deleted-path signal")
  fi

  # Mutation RED: strip only the deleted_paths finding requirement in a copy.
  # Without that gate, forgotten-signal finalize must succeed (exit 0).
  mutated="$work/mutated-plugin"
  cp -a "$plugin" "$mutated"
  python3 - "$mutated/scripts/collector-validate.sh" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = """    and (.findings as $findings | $deleted_paths | all(.[]; .path as $path
      | any($findings[]; .file == $path and (.providers | index(\"repository-policy\")))))
"""
if needle not in text:
    raise SystemExit("deleted_paths finding requirement needle missing")
path.write_text(text.replace(needle, "", 1))
PY
  "$mutated/scripts/generate-runner-bundle.sh" >/dev/null
  cp -a "$collection" "$work/deleted-mutated"
  # Re-seal collection against mutated runner digests by re-collecting.
  rm -rf "$work/deleted-mutated"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$mutated/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/deleted-mutated" > "$work/deleted-mutated.json"; then
    echo -e "  ${RED}FAIL${NC} mutated deleted-path gate collect"; FAIL=$((FAIL+1)); FAILURES+=("mutated deleted-path RED")
    rm -rf "$work"; return
  fi
  ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$mutated/scripts/collect-review-evidence.sh" finalize --collection "$work/deleted-mutated" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/deleted-mutated.json")" \
      --arbitration "$work/arbitration.json" >/dev/null 2>"$work/mutated.err" || ec=$?
  if [ "$ec" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC} mutated copy accepts forgotten deleted-path (RED anchor)"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} mutated copy accepts forgotten deleted-path (RED anchor)"; FAIL=$((FAIL+1)); FAILURES+=("mutated deleted-path RED")
    cat "$work/mutated.err" >&2 || true
    rm -rf "$work"; return
  fi

  jq '.findings=[{
      id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
      category:"quality",file:"docs/policies/foo.md",line:1,title:"Deleted policy path",
      description:"The reviewed diff deletes docs/policies/foo.md matched by docs/policies/**.",
      suggestion:"Restore the policy file or document the intentional deletion.",confidence:1,
      arbiter_notes:"Deterministic repository-policy signal; default medium severity."
    }] | .summary="One deterministic medium repository-policy finding remains non-blocking."' \
    "$work/arbitration.json" > "$work/deleted-arbitration.json"
  cp -a "$collection" "$work/deleted-accept"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/deleted-accept" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/deleted-arbitration.json" \
      >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} finalize accepts medium deleted-path repository-policy finding"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} finalize accepts medium deleted-path repository-policy finding"; FAIL=$((FAIL+1)); FAILURES+=("accepted deleted-path finding")
  fi

  # Non-matching deletion only: unaffected APPROVE with no repository-policy findings.
  git -C "$repo" checkout -q -b nonmatch "$base"
  git -C "$repo" rm -q README.md
  printf 'two\n' > "$repo/app.txt"
  git -C "$repo" add app.txt
  git -C "$repo" commit -q -m 'delete non-matching path'
  head="$(git -C "$repo" rev-parse HEAD)"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/nonmatch" > "$work/nonmatch.json"; then
    echo -e "  ${RED}FAIL${NC} non-matching deletion collection"; FAIL=$((FAIL+1)); FAILURES+=("non-matching deletion unaffected")
    rm -rf "$work"; return
  fi
  if [ ! -e "$work/nonmatch/deleted-paths.json" ] \
    && jq -e 'has("deleted_paths") | not' "$work/nonmatch/manifest.json" >/dev/null \
    && PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/nonmatch" \
        --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/nonmatch.json")" \
        --arbitration "$work/arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} non-matching deletion finalizes APPROVE without repository-policy findings"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} non-matching deletion finalizes APPROVE without repository-policy findings"; FAIL=$((FAIL+1)); FAILURES+=("non-matching deletion unaffected")
  fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

test_mutation_gate() {
  local work repo fake plugin collection manifest_sha base head ec=0 mutated
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
  sed 's/"provider":"codex"/"provider":"claude"/' "$plugin/scripts/run-codex-review.sh" > "$plugin/scripts/run-claude-review.sh"
  for provider in gemini qwen grok muse; do
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
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/codex"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
printf '%s\n' '{"loggedIn":true}'
EOF
  chmod +x "$fake/codex" "$fake/claude"
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null

  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > app.txt
    git add app.txt
    git commit -q -m base
    mkdir -p tests
    printf 'fixture\n' > tests/foo_test.sh
    printf 'two\n' > app.txt
    git add app.txt tests/foo_test.sh
    git commit -q -m 'add test path'
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

  cat > "$work/arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"Two valid reviewers found no defects."},
  "findings":[],"scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "muse":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"}
  },
  "conflicts_resolved":[],"summary":"No blocking findings."
}
EOF

  # 1) Default-off: no .tribunal-mutation-gate ⇒ no mutation artifact / key.
  collection="$work/off"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$collection" > "$work/off.json"; then
    echo -e "  ${RED}FAIL${NC} mutation-gate default-off collect"; FAIL=$((FAIL+1)); FAILURES+=("mutation-gate default-off")
    rm -rf "$work"; return
  fi
  if [ ! -e "$collection/mutation-gate.json" ] \
    && jq -e 'has("mutation_gate") | not' "$collection/manifest.json" >/dev/null \
    && PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
        --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/off.json")" \
        --arbitration "$work/arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} mutation-gate default-off leaves no artifact"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} mutation-gate default-off leaves no artifact"; FAIL=$((FAIL+1)); FAILURES+=("mutation-gate default-off")
  fi

  # 2) RED-on-base: command exit 1 ⇒ sealed RED ⇒ finalize APPROVE when otherwise clean.
  git -C "$repo" checkout -q -B feature "$base"
  printf 'exit 1\n' > "$repo/.tribunal-mutation-gate"
  mkdir -p "$repo/tests"
  printf 'fixture\n' > "$repo/tests/foo_test.sh"
  printf 'two\n' > "$repo/app.txt"
  git -C "$repo" add .tribunal-mutation-gate app.txt tests/foo_test.sh
  git -C "$repo" commit -q -m 'enable mutation gate RED'
  head="$(git -C "$repo" rev-parse HEAD)"
  collection="$work/red"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$collection" > "$work/red.json"; then
    echo -e "  ${RED}FAIL${NC} mutation-gate RED collect"; FAIL=$((FAIL+1)); FAILURES+=("mutation-gate RED")
    rm -rf "$work"; return
  fi
  manifest_sha="$(jq -r .manifest_sha256 "$work/red.json")"
  if jq -e '. == [{command:"exit 1",exit_code:1,path:"tests/foo_test.sh",result:"RED"}]' \
      "$collection/mutation-gate.json" >/dev/null 2>&1 \
    && jq -e '.mutation_gate.path == "mutation-gate.json" and (.mutation_gate.sha256 | test("^[0-9a-f]{64}$"))
      and (.mutation_gate.bytes > 0)' "$collection/manifest.json" >/dev/null \
    && PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
        --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} mutation-gate RED seals and finalizes APPROVE"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} mutation-gate RED seals and finalizes APPROVE"; FAIL=$((FAIL+1)); FAILURES+=("mutation-gate RED")
  fi

  # 3) Vacuous: exit 0 ⇒ forgotten finding rejects; covering repository-policy finding accepts.
  git -C "$repo" checkout -q -B feature "$base"
  printf 'exit 0\n' > "$repo/.tribunal-mutation-gate"
  mkdir -p "$repo/tests"
  printf 'fixture\n' > "$repo/tests/foo_test.sh"
  printf 'two\n' > "$repo/app.txt"
  git -C "$repo" add .tribunal-mutation-gate app.txt tests/foo_test.sh
  git -C "$repo" commit -q -m 'enable mutation gate vacuous'
  head="$(git -C "$repo" rev-parse HEAD)"
  collection="$work/vacuous"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$collection" > "$work/vacuous.json"; then
    echo -e "  ${RED}FAIL${NC} mutation-gate vacuous collect"; FAIL=$((FAIL+1)); FAILURES+=("mutation-gate vacuous")
    rm -rf "$work"; return
  fi
  manifest_sha="$(jq -r .manifest_sha256 "$work/vacuous.json")"
  if ! jq -e '. == [{command:"exit 0",exit_code:0,path:"tests/foo_test.sh",result:"vacuous"}]' \
      "$collection/mutation-gate.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} mutation-gate vacuous seals expected artifact"; FAIL=$((FAIL+1)); FAILURES+=("mutation-gate vacuous")
    rm -rf "$work"; return
  fi
  ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
      >/dev/null 2>"$work/forgotten.err" || ec=$?
  if [ "$ec" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${NC} finalize rejects forgotten vacuous mutation-gate signal"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} finalize rejects forgotten vacuous mutation-gate signal"; FAIL=$((FAIL+1)); FAILURES+=("forgotten vacuous mutation-gate")
  fi

  jq '.findings=[{
      id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
      category:"testing",file:"tests/foo_test.sh",line:1,title:"Vacuous mutation-gate result",
      description:"The sealed mutation gate reported vacuous for tests/foo_test.sh on base.",
      suggestion:"Strengthen the added or changed test so it fails against unmodified base.",confidence:1,
      arbiter_notes:"Deterministic repository-policy signal for sealed vacuous mutation-gate result."
    }] | .summary="One deterministic medium repository-policy finding remains non-blocking."' \
    "$work/arbitration.json" > "$work/vacuous-arbitration.json"
  cp -a "$collection" "$work/vacuous-accept"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/vacuous-accept" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/vacuous-arbitration.json" \
      >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} finalize accepts covering vacuous mutation-gate finding"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} finalize accepts covering vacuous mutation-gate finding"; FAIL=$((FAIL+1)); FAILURES+=("accepted vacuous mutation-gate finding")
  fi

  # 4) Mutation RED: strip only the vacuous-finding finalize requirement in a copy.
  mutated="$work/mutated-plugin"
  cp -a "$plugin" "$mutated"
  python3 - "$mutated/scripts/collector-validate.sh" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = """    and (.findings as $findings | [$mutation_gate[] | select(.result == \"vacuous\")] | all(.[]; .path as $path
      | any($findings[]; .file == $path and (.providers | index(\"repository-policy\")))))
"""
if needle not in text:
    raise SystemExit("mutation_gate vacuous finding requirement needle missing")
path.write_text(text.replace(needle, "", 1))
PY
  "$mutated/scripts/generate-runner-bundle.sh" >/dev/null
  rm -rf "$work/vacuous-mutated"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$mutated/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/vacuous-mutated" > "$work/vacuous-mutated.json"; then
    echo -e "  ${RED}FAIL${NC} mutated mutation-gate vacuous collect"; FAIL=$((FAIL+1)); FAILURES+=("mutated mutation-gate RED")
    rm -rf "$work"; return
  fi
  ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$mutated/scripts/collect-review-evidence.sh" finalize --collection "$work/vacuous-mutated" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/vacuous-mutated.json")" \
      --arbitration "$work/arbitration.json" >/dev/null 2>"$work/mutated.err" || ec=$?
  if [ "$ec" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC} mutated copy accepts forgotten vacuous mutation-gate (RED anchor)"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} mutated copy accepts forgotten vacuous mutation-gate (RED anchor)"; FAIL=$((FAIL+1)); FAILURES+=("mutated mutation-gate RED")
    cat "$work/mutated.err" >&2 || true
  fi

  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}


test_ignored_path_additions
test_ignored_path_diff_failures
test_ignored_path_validation
test_deleted_policy_paths
test_deleted_policy_paths_gate
test_mutation_gate
