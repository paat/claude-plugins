#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_backup_leg_collection() {
  local work repo fake plugin state base head n scenario ec expected mutator mode manifest_sha
  local wrapper command worktree_config_message muse_status
  local -a verify_args
  work="$(mktemp -d)"; repo="$work/repo"; fake="$work/bin"; plugin="$work/plugin"; state="$work/state"
  mkdir -p "$repo" "$fake" "$state" "$plugin/scripts" "$plugin/schemas" "$plugin/.claude-plugin" "$plugin/integrity"
  cp "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" "$PLUGIN_ROOT/scripts/lib.sh" "$PLUGIN_ROOT/scripts/review-panel.tsv" \
    "$PLUGIN_ROOT/scripts/check-runner-bundle.sh" "$PLUGIN_ROOT/scripts/generate-runner-bundle.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/dsh-review.patch.yml" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/schemas/review-output.json" "$plugin/schemas/"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$plugin/.claude-plugin/plugin.json"
  cat > "$state/plant-commondir.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
common="$1"; evil="$FIXTURE_STATE/evil-common"
mkdir -p "$evil/info" "$evil/worktrees"
cp "$common/config" "$evil/config"
cat > "$FIXTURE_STATE/driver" <<'DRIVER'
#!/usr/bin/env bash
printf 'executed\n' >> "$FIXTURE_STATE/driver.executed"
if [[ "${FIXTURE_MUTATION:-}" == worktree-* ]]; then
  staging=("$FIXTURE_WORK"/.tribunal-collection.*)
  evidence="${staging[0]}/providers/claude.json"
  jq '.model = "forged"' "$evidence" > "$FIXTURE_STATE/forged.json"
  cp "$FIXTURE_STATE/forged.json" "$evidence"
fi
cat
DRIVER
chmod +x "$FIXTURE_STATE/driver"
git config --file "$evil/config" filter.evil.clean "$FIXTURE_STATE/driver"
git config --file "$evil/config" filter.evil.smudge "$FIXTURE_STATE/driver"
git config --file "$evil/config" filter.evil.required true
printf '* filter=evil\n' > "$evil/info/attributes"
for entry in objects refs; do
  ln -sfn "$common/$entry" "$evil/$entry"
done
for entry in "$common"/worktrees/*; do
  [ ! -d "$entry" ] || ln -sfn "$entry" "$evil/worktrees/${entry##*/}"
done
case "${2:-commondir}" in
  worktree-commondir) printf '%s\n' "$evil" > "$(git rev-parse --absolute-git-dir)/commondir" ;;
  worktree-gitfile)
    admin="$(git rev-parse --absolute-git-dir)"
    cp "$admin/HEAD" "$admin/index" "$evil/"
    printf 'gitdir: %s\n' "$evil" > .git ;;
  *) touch "$FIXTURE_STATE/git.watch"; printf '%s\n' "$evil" > "$common/commondir" ;;
esac
EOF
  cat > "$plugin/scripts/fixture-review.sh" <<'EOF'
#!/usr/bin/env bash
ulimit -c > "${FIXTURE_STATE:?}/$1.core-limit"
base="$(git rev-parse --verify "${TRIBUNAL_BASE_REF}^{commit}")"; head="$(git rev-parse --verify 'HEAD^{commit}')"
if [ "${FIXTURE_MUTATOR:-}" = "$1" ]; then
  case "${FIXTURE_MUTATION:-dirty}" in
    root-gitfile|root-commondir)
      if [ "$1" = codex ]; then
        read -r ready < "$FIXTURE_STATE/claude.ready"
        rm "$FIXTURE_STATE/claude.ready"
      fi
      touch "$FIXTURE_STATE/git.watch"
      if [ "$FIXTURE_MUTATION" = root-gitfile ]; then
        printf 'gitdir: /missing-tribunal-admin\n' > "$FIXTURE_ROOT/.git"
      else
        printf '/missing-tribunal-common\n' > "$FIXTURE_ROOT_GITDIR/commondir"
      fi ;;
    dirty) printf 'scratch\n' > scratch.txt ;;
    commit)
      printf 'scratch\n' > scratch.txt
      git add scratch.txt && git commit -q -m 'reviewer mutation' ;;
    orphan) git symbolic-ref HEAD refs/heads/scratch-unborn ;;
    commondir|worktree-commondir|worktree-gitfile)
      if [ "$1" = codex ]; then
        read -r ready < "$FIXTURE_STATE/claude.ready"
        rm "$FIXTURE_STATE/claude.ready"
      fi
      if [ "$FIXTURE_MUTATION" != commondir ]; then
        printf 'bad\n' > app.txt
        touch -t 200001010000 app.txt
      fi
      bash "$FIXTURE_STATE/plant-commondir.sh" "$(git rev-parse --git-common-dir)" "$FIXTURE_MUTATION" ;;
    fsmonitor|hooks|filter|filter-equals|filter-info|filter-info-equals|filter-attrfile|filter-global)
      printf 'scratch\n' > scratch.txt
      cat > "$FIXTURE_STATE/fsmonitor" <<'HOOK'
#!/usr/bin/env bash
printf 'executed\n' > "$FIXTURE_STATE/fsmonitor.executed"
rm -f scratch.txt
case "$FIXTURE_MUTATION" in
  filter*)
    staging=("$FIXTURE_WORK"/.tribunal-collection.*)
    evidence="${staging[0]}/providers/claude.json"
    jq '.model = "forged"' "$evidence" > "$FIXTURE_STATE/forged.json"
    cp "$FIXTURE_STATE/forged.json" "$evidence"
    driver=fixture; case "$FIXTURE_MUTATION" in *equals) driver='a=b' ;; esac
    if [ "$FIXTURE_MUTATION" = filter-global ]; then
      git config --global --remove-section "filter.$driver"
      rm -f "$HOME/.config/git/attributes"
    else
      git config --remove-section "filter.$driver"
      git config --unset core.attributesFile || true
      rm -f "$(git rev-parse --git-common-dir)/info/attributes"
    fi ;;
esac
printf 'token\0'
HOOK
      chmod +x "$FIXTURE_STATE/fsmonitor"
      case "$FIXTURE_MUTATION" in
        fsmonitor) git config core.fsmonitor "$FIXTURE_STATE/fsmonitor" ;;
        hooks)
          mkdir -p "$FIXTURE_STATE/hooks"
          cp "$FIXTURE_STATE/fsmonitor" "$FIXTURE_STATE/hooks/post-checkout"
          git config core.hooksPath "$FIXTURE_STATE/hooks"
          git worktree lock "$PWD" ;;
        filter*)
          driver=fixture; case "$FIXTURE_MUTATION" in *equals) driver='a=b' ;; esac
          case "$FIXTURE_MUTATION" in
            filter-info*) attributes="$(git rev-parse --git-common-dir)/info/attributes" ;;
            filter-attrfile)
              attributes="$FIXTURE_STATE/attributes"
              git config core.attributesFile "$attributes" ;;
            filter-global) attributes="$HOME/.config/git/attributes" ;;
            *) attributes=.gitattributes ;;
          esac
          mkdir -p "$(dirname "$attributes")"
          printf 'app.txt filter=%s\n' "$driver" > "$attributes"
          printf 'bad\n' > app.txt
          touch -t 200001010000 app.txt
          scope=--local; [ "$FIXTURE_MUTATION" != filter-global ] || scope=--global
          git config "$scope" "filter.$driver.clean" "$FIXTURE_STATE/fsmonitor"
          git config "$scope" "filter.$driver.required" true ;;
      esac ;;
    config-fifo|config-fifo-race)
      config="$(git rev-parse --git-common-dir)/config"
      staging=("$FIXTURE_WORK"/.tribunal-collection.*)
      if [ "$FIXTURE_MUTATION" = config-fifo ]; then
        # The collector has reaped this sibling; no provider still needs Git.
        until [ -f "${staging[0]}/wrappers/claude.finished" ]; do sleep 0.01; done
      else
        read -r ready < "$FIXTURE_STATE/claude.ready"
        rm "$FIXTURE_STATE/claude.ready"
        touch "$FIXTURE_STATE/config-race.ready"
        read -r ready < "$FIXTURE_STATE/config-race.go"
        # Alternate at the read boundary while the collector reaps the sibling.
        for i in 1 2 3; do
          rm "$config"; mkfifo "$config"
          cp "$FIXTURE_STATE/config.before" "$FIXTURE_STATE/config.regular"
          mv -fT "$FIXTURE_STATE/config.regular" "$config"
        done
      fi
      rm "$config"
      mkfifo "$config"
      if [ "$FIXTURE_MUTATION" = config-fifo-race ]; then
        printf 'swapped\n' > "$FIXTURE_STATE/config-race.done"
      fi ;;
    config-symlink)
      config="$(git rev-parse --git-common-dir)/config"
      cp "$config" "$FIXTURE_STATE/config.target"
      touch -t 200001010000 "$FIXTURE_STATE/config.target"
      touch -r "$FIXTURE_STATE/config.target" "$FIXTURE_STATE/config.target.timestamp"
      rm "$config"
      ln -s "$FIXTURE_STATE/config.target" "$config" ;;
    config-token)
      git config remote.origin.url https://fixture-secret-token@github.com/example/fixture.git
      chmod 0400 "$(git rev-parse --git-common-dir)/config" ;;
    config-branch)
      git config branch.concurrent.remote origin
      git config branch.concurrent.merge refs/heads/concurrent ;;
    lock) git worktree lock "$PWD" ;;
    background)
      staging=("$FIXTURE_WORK"/.tribunal-collection.*)
      mkfifo "$FIXTURE_STATE/ready"
      # timeout creates a nested group, as the real reviewer wrappers do.
      timeout 10 bash -c '
        trap "" TERM
        read -r host_pid rest < /proc/self/stat
        printf "%s\n" "$host_pid" > "$FIXTURE_STATE/child.pid"
        printf "ready\n" > "$FIXTURE_STATE/ready"
        sleep 0.3
        printf "forged\n" > "$1/wrappers/$2.raw"
        touch "$FIXTURE_STATE/background.executed"
      ' _ "${staging[0]}" "$1" >/dev/null 2>&1 &
      read -r ready < "$FIXTURE_STATE/ready"
      rm "$FIXTURE_STATE/ready"
      ;;
    many) for i in {01..25}; do printf 'scratch\n' > "scratch-$i.txt"; done ;;
  esac
fi
printf '%s\n' "{\"provider\":\"$1\",\"model\":\"fixture\",\"files_examined\":[\"app.txt\"],\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10,\"verdict\":\"APPROVE\"},\"diff_stat\":{\"files_changed\":1,\"insertions\":1,\"deletions\":0,\"base\":\"$TRIBUNAL_BASE_REF\",\"base_oid\":\"$base\",\"head_oid\":\"$head\",\"truncated\":false}}" | jq --arg provider "$1" 'if $provider == "grok" then .grok_execution={verdict_phase:"inspect",inspect_exit_code:0,requested_effort:null,verdict_effort:null} else . end'
if [ "$1" = claude ]; then
  case "${FIXTURE_MUTATION:-}" in
    config-fifo-race)
      printf 'ready\n' > "$FIXTURE_STATE/claude.ready"
      until [ -f "$FIXTURE_STATE/config-race.ready" ] || [ -f "$FIXTURE_STATE/config-race.exercised" ]; do sleep 0.01; done ;;
    commondir|worktree-commondir|worktree-gitfile|root-gitfile|root-commondir) printf 'ready\n' > "$FIXTURE_STATE/claude.ready" ;;
  esac
fi
EOF
  cat > "$plugin/scripts/run-codex-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FIXTURE_CODEX_ERROR:-}" ]; then
  jq -nc --arg e "$FIXTURE_CODEX_ERROR" '{provider:"codex",error:$e}'
else
  bash "$(dirname "$0")/fixture-review.sh" codex
fi
EOF
  cat > "$plugin/scripts/run-claude-review.sh" <<'EOF'
#!/usr/bin/env bash
bash "$(dirname "$0")/fixture-review.sh" claude
EOF
  cat > "$plugin/scripts/run-muse-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${TRIBUNAL_MUSE:-off}" = off ]; then
  printf '%s\n' '{"provider":"muse","status":"disabled","note":"fixture disabled"}'
elif [ -n "${FIXTURE_MUSE_ERROR:-}" ]; then
  jq -nc --arg e "$FIXTURE_MUSE_ERROR" '{provider:"muse",error:$e}'
else
  bash "$(dirname "$0")/fixture-review.sh" muse
fi
EOF
  for provider in gemini qwen grok; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' \
      "'{\"provider\":\"$provider\",\"status\":\"disabled\",\"note\":\"fixture disabled\"}'" > "$plugin/scripts/run-$provider-review.sh"
  done
  cat > "$plugin/scripts/run-deepseek-review.sh" <<'EOF'
#!/usr/bin/env bash
printf 'run\n' >> "${FIXTURE_STATE:?}/deepseek.runs"
if [ "${TRIBUNAL_DEEPSEEK:-off}" = on ]; then bash "$(dirname "$0")/fixture-review.sh" deepseek
else printf '%s\n' '{"provider":"deepseek","status":"disabled","note":"fixture disabled"}'; fi
EOF
  for wrapper in "$plugin/scripts"/run-*-review.sh; do
    sed '1a printf "started\\n" >> "${FIXTURE_STATE:?}/wrappers.started"' "$wrapper" > "$work/wrapper"
    mv "$work/wrapper" "$wrapper"
  done
  chmod +x "$plugin/scripts/"*.sh
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
  for cli in codex muse dsh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/$cli"
    chmod +x "$fake/$cli"
  done
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
printf '%s\n' '{"loggedIn":true}'
EOF
  chmod +x "$fake/claude"
  cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = repo ] && [ "$2" = view ]; then
  jq -nc '{nameWithOwner:"example/fixture",url:"https://github.com/example/fixture"}'
elif [ "$1" = pr ] && [ "$2" = view ]; then
  jq -nc --argjson number "$3" --arg base "$FIXTURE_BASE" --arg head "$FIXTURE_HEAD" \
    '{number:$number,url:("https://github.com/example/fixture/pull/"+($number|tostring)),state:"OPEN",
      baseRefName:"main",baseRefOid:$base,headRefName:"feature",headRefOid:$head,body:"Bound PR body"}'
else
  exit 2
fi
EOF
  chmod +x "$fake/dsh" "$fake/gh"
  cat > "$fake/git" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FIXTURE_STATE:-}" ] && [ -e "$FIXTURE_STATE/git.watch" ]; then
  printf '%s\n' "$*" >> "$FIXTURE_STATE/git.calls"
fi
EOF
  printf 'exec %q "$@"\n' "$(command -v git)" >> "$fake/git"
  chmod +x "$fake/git"
  # Force the old live-config cmp to open after the type check and FIFO swap.
  # Fixed collectors compare a private copy, then reject the FIFO on the next check.
  cat > "$fake/cmp" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_MUTATION:-}" = config-fifo-race ] && [ -f "$FIXTURE_STATE/config-race.ready" ]; then
  rm "$FIXTURE_STATE/config-race.ready"
  printf 'swap\n' > "$FIXTURE_STATE/config-race.go"
  read -r ready < "$FIXTURE_STATE/config-race.done"
  touch "$FIXTURE_STATE/config-race.exercised"
fi
EOF
  printf 'exec %q "$@"\n' "$(command -v cmp)" >> "$fake/cmp"
  chmod +x "$fake/cmp"
  # Hold normalization past the delayed write; no timing race with a fast collector.
  cat > "$fake/jq" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_MUTATION:-}" = background ] && [ "$*" != "${*%.raw}" ]; then
  sleep 0.5
fi
EOF
  printf 'exec %q "$@"\n' "$(command -v jq)" >> "$fake/jq"
  chmod +x "$fake/jq"
  # Retain evidence even when config rejection precedes normalization.
  cat > "$fake/rm" <<'EOF'
#!/usr/bin/env bash
staging="${@: -1}"; staging="${staging%/wrappers}"
case "${staging##*/}" in
  .tribunal-collection.*)
    if [ -f "$staging/wrappers/claude.raw" ]; then
      jq -S . "$staging/wrappers/claude.raw" > "$FIXTURE_STATE/claude.expected.json"
    fi
    if [ -f "$staging/providers/claude.json" ]; then
      cp "$staging/providers/claude.json" "$FIXTURE_STATE/claude.evidence.json"
    else
      cp "$FIXTURE_STATE/claude.expected.json" "$FIXTURE_STATE/claude.evidence.json"
    fi ;;
esac
EOF
  printf 'exec %q "$@"\n' "$(command -v rm)" >> "$fake/rm"
  chmod +x "$fake/rm"
  (
    cd "$repo" && git init -q && git config user.email t@t && git config user.name t
    printf 'one\n' > app.txt && git add app.txt && git commit -q -m base
    printf 'two\n' > app.txt && git commit -q -am change
    git remote add origin https://github.com/example/fixture.git
  )
  base="$(git -C "$repo" rev-parse HEAD~1)"; head="$(git -C "$repo" rev-parse HEAD)"
  n=0
  collect() {  # collect ENV... -> sets $collection, returns collect's exit
    n=$((n + 1)); collection="$work/collection-$n"; rm -f "$state/deepseek.runs"
    (ulimit -S -c 1
    env -u TRIBUNAL_BACKUP_LEGS -u TRIBUNAL_RISK -u TRIBUNAL_DEEPSEEK -u TRIBUNAL_DEEPSEEK_MODEL -u TRIBUNAL_MUSE \
      TRIBUNAL_GROK=off PATH="$fake:$PATH" DEEPSEEK_API_KEY=fixture DSH_HOME="$work/dsh-home" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_STATE="$state" \
      FIXTURE_WORK="$work" FIXTURE_ROOT="$repo" FIXTURE_ROOT_GITDIR="${root_gitdir:-}" \
      FIXTURE_CODEX_ERROR="plan limit: Codex execution failed or timed out; phase=execution; exit=1" "$@" \
      timeout -k 1 30 "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$collection" > "$work/collect-$n.json" 2> "$work/collect-$n.err")
  }
  status_of() { jq -r --arg p "$1" '.providers[] | select(.provider == $p) | .status' "$collection/manifest.json"; }
  runs() { [ -f "$state/deepseek.runs" ] && wc -l < "$state/deepseek.runs" | tr -d ' ' || printf 0; }

  cat > "$fake/unshare" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_STATE/unshare.calls"
if [ "${1:-}" = --help ]; then printf '%s\n' --map-current-user; exit 0; fi
printf 'fixture namespaces denied\n' >&2
exit 1
EOF
  chmod +x "$fake/unshare"
  ec=0; collect || ec=$?
  namespace_fallback_sealed() {
    [ "$ec" -eq 0 ] && [ "$(status_of deepseek)" = ok ] || return 1
    [ "$(grep -c '^tribunal evidence: containment degraded:' "$work/collect-$n.err")" -eq 1 ] \
      && grep -Fq 'fixture namespaces denied' "$work/collect-$n.err" \
      && [ "$(grep -c -- '--user --map-current-user --pid --fork --kill-child true' "$state/unshare.calls")" -eq 1 ] \
      && jq -e '.containment == "session" and all(.providers[]; .containment == "session")' "$collection/manifest.json" >/dev/null
  }
  tr_check "unavailable namespaces degrade once, seal session containment and keep backup legs" namespace_fallback_sealed
  rm "$fake/unshare"
  if unshare --user --map-current-user --pid --fork --kill-child true 2>/dev/null; then
    cp "$plugin/scripts/run-grok-review.sh" "$work/grok.disabled"
    sed 's/claude/grok/g' "$plugin/scripts/run-claude-review.sh" > "$plugin/scripts/run-grok-review.sh"
    "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
    ec=0; collect TRIBUNAL_GROK_SANDBOX=read-only || ec=$?
    grok_namespace_fallback_sealed() {
      [ "$ec" -eq 0 ] && [ "$(status_of deepseek)" = ok ] && [ "$(status_of grok)" = ok ] || return 1
      grep -Fq 'tribunal evidence: containment degraded: grok:' "$work/collect-$n.err" \
        && jq -e '.containment == "session" and all(.providers[];
          if .provider == "grok" then .containment == "session" else .containment == "pid-namespace" end)' "$collection/manifest.json" >/dev/null
    }
    tr_check "Grok read-only fallback is named and sealed per leg without disabling other namespaces" grok_namespace_fallback_sealed
    mv "$work/grok.disabled" "$plugin/scripts/run-grok-review.sh"
    "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
  fi
  rm -f "$state/wrappers.started"

  worktree_config_message='sealed collection does not support extensions.worktreeConfig (per-worktree config cannot be contained); disable it or run tribunal from a clone without it'
  worktree_config_rejected() {
    [ "$ec" -eq 1 ] && grep -Fq "$worktree_config_message" "$1" || return 1
    [ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
  }
  collect_worktree_config_rejected() {
    worktree_config_rejected "$work/collect-$n.err" \
      && [ ! -e "$state/wrappers.started" ] && [ ! -e "$collection" ]
  }
  git -C "$repo" config extensions.worktreeConfig true
  ec=0; collect FIXTURE_CODEX_ERROR= TRIBUNAL_BACKUP_LEGS=off || ec=$?
  tr_check "collect rejects extensions.worktreeConfig before any wrapper starts" collect_worktree_config_rejected
  git -C "$repo" config extensions.worktreeConfig false

  printf '.\n' > "$repo/.git/commondir"
  ec=0; collect FIXTURE_CODEX_ERROR= TRIBUNAL_BACKUP_LEGS=off || ec=$?
  preexisting_commondir_preserved() {
    [ "$ec" -eq 0 ] && [ -e "$collection/manifest.json" ] && [ -e "$state/wrappers.started" ] \
      && [ -f "$repo/.git/commondir" ] && [ "$(cat "$repo/.git/commondir")" = . ]
  }
  tr_check "round 2 T-001: legitimate pre-leg commondir is pinned without deletion" preexisting_commondir_preserved
  rm -f "$repo/.git/commondir"

  mkdir -p "$work/home" "$work/tmp"
  # The simulation marks even new clones/worktrees foreign; trust them in this fixture HOME.
  git config --file "$work/home/.gitconfig" --add safe.directory '*'
  ec=0; collect HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" TMPDIR="$work/tmp" \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1 FIXTURE_CODEX_ERROR= TRIBUNAL_BACKUP_LEGS=off || ec=$?
  safe_directory_collected() {
    [ "$ec" -eq 0 ] && [ "$(status_of codex) $(status_of claude)" = 'ok ok' ]
  }
  tr_check "T-003: protected safe.directory permits different-owner collection" safe_directory_collected
  git -C "$repo" config branch.verification.remote origin
  git config --file "$work/home/.gitconfig" --unset-all safe.directory
  git config --file "$work/home/.gitconfig" "includeIf.gitdir:$repo/.git.path" "$work/home/trusted-config"
  git config --file "$work/home/trusted-config" safe.directory '*'
  tr_check "different-owner verification accepts branch drift with conditional safe.directory" \
    env HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
      PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" \
      bash -c '"$1/scripts/collect-review-evidence.sh" verify-collection --collection "$2" --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$3")" >/dev/null' \
      _ "$plugin" "$collection" "$work/collect-$n.json"
  sed '/^require_tools$/,$d' "$plugin/scripts/collect-review-evidence.sh" > "$plugin/scripts/verify-functions.sh"
  tr_check "explicit-file config parsing in a different-owner repo needs no loaded safe.directory" \
    env HOME="$work/empty-home" XDG_CONFIG_HOME="$work/empty-home/.config" GIT_CONFIG_NOSYSTEM=1 \
      GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
    bash -c '
      . "$1/scripts/verify-functions.sh"
      SURFACE_GITDIR="$2/.git"; SURFACE_COMMON="$SURFACE_GITDIR"
      [ "$SAFE_DIRECTORY_COUNT" -eq 0 ]
      config_entries "$SURFACE_COMMON/config" | jq -e "length > 0" >/dev/null
    ' _ "$plugin" "$repo"
  rm -rf "$work/home"

  cp "$repo/.git/config" "$state/config.before"
  ec=0; collect FIXTURE_CODEX_ERROR= FIXTURE_MUTATOR=codex FIXTURE_MUTATION=config-branch \
    TRIBUNAL_BACKUP_LEGS=off || ec=$?
  branch_config_preserved() {
    [ "$ec" -eq 0 ] && [ -f "$collection/manifest.json" ] \
      && [ "$(git -C "$repo" config branch.concurrent.remote)" = origin ] \
      && [ "$(git -C "$repo" config branch.concurrent.merge)" = refs/heads/concurrent ]
  }
  tr_check "T-002: concurrent branch config changes survive collection" branch_config_preserved
  cp "$state/config.before" "$repo/.git/config"
  for mode in 0664 0644; do
    chmod "$mode" "$repo/.git/config"
    ec=0; collect FIXTURE_CODEX_ERROR= FIXTURE_MUTATOR=codex FIXTURE_MUTATION=config-token \
      TRIBUNAL_BACKUP_LEGS=off || ec=$?
    config_token_redacted() {
      [ "$ec" -eq 1 ] && [ ! -e "$collection" ] \
        && grep -Fxq remote.origin.url "$work/collect-$n.err" \
        && ! grep -Eq 'fixture-secret-token|https://|^(@@|---|\+\+\+)' "$work/collect-$n.err"
    }
    config_mode_restored() {
      [ "$ec" -eq 1 ] && cmp -s "$state/config.before" "$repo/.git/config" \
        && [ "$(stat -c '%a' "$repo/.git/config")" = "${mode#0}" ]
    }
    tr_check "T-001: config change reports key without token ($mode)" config_token_redacted
    tr_check "T-002: non-branch config restore keeps mode $mode" config_mode_restored
  done

  collect
  tr_check "main and backup legs inherit disabled core dumps" \
    test "$(cat "$state/claude.core-limit") $(cat "$state/deepseek.core-limit")" = "0 0"
  tr_check "a plan-limited Codex leg brings in the DeepSeek backup" \
    test "$(status_of codex) $(status_of deepseek) $(status_of claude) $(runs)" = "failed ok ok 2"
  tr_check "the backup run is announced on stderr" grep -q 'running backup legs for plan-limited legs: deepseek' "$work/collect-$n.err"
  tr_check "a collection with a backup leg still verifies" env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" \
    bash -c '"$1/scripts/collect-review-evidence.sh" verify-collection --collection "$2" --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$3")" >/dev/null' \
    _ "$plugin" "$collection" "$work/collect-$n.json"

  collect TRIBUNAL_BACKUP_LEGS=off
  tr_check "TRIBUNAL_BACKUP_LEGS=off runs no backup" test "$(status_of deepseek) $(runs)" = "disabled 1"
  collect FIXTURE_CODEX_ERROR="Codex execution failed or timed out; phase=execution; exit=1"
  tr_check "an ordinary failure with quorum intact runs no backup" test "$(status_of codex) $(status_of deepseek) $(runs)" = "failed disabled 1"
  collect FIXTURE_CODEX_ERROR="Codex execution failed or timed out; phase=execution; exit=1" \
    FIXTURE_MUSE_ERROR="Muse execution failed; phase=execution; exit=1"
  tr_check "a failed leg below the quorum floor pulls the next selected backup" \
    test "$(status_of codex) $(status_of claude) $(status_of deepseek) $(runs)" = "failed ok ok 2"
  tr_check "the quorum backup run is announced on stderr" \
    grep -q 'running backup legs for quorum: deepseek' "$work/collect-$n.err"
  collect FIXTURE_CODEX_ERROR="Codex execution failed or timed out; phase=execution; exit=1" \
    FIXTURE_MUSE_ERROR="Muse execution failed; phase=execution; exit=1" TRIBUNAL_BACKUP_LEGS=off
  tr_check "three selected legs can finish with only one ok leg" \
    jqe '([.providers[]|select(.provider=="codex" or .provider=="claude" or .provider=="muse")|.status]
      | sort == ["failed","failed","ok"])' "$collection/manifest.json"
  jq '{tribunal_verdict:{decision:"APPROVE",confidence:0.9,rationale:"One valid reviewer found no defects."},
    findings:[],scope_findings:[],conflicts_resolved:[],summary:"Fixture review.",
    provider_assessment:(.providers|map({key:.provider,value:{status:.status,
      findings_accepted:0,findings_rejected:0,false_positives:[]}})|from_entries)}' \
    "$collection/manifest.json" > "$work/one-ok-arbitration.json"
  manifest_sha="$(jq -r .manifest_sha256 "$work/collect-$n.json")"
  ec=0
  env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_STATE="$state" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
    --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/one-ok-arbitration.json" \
    > /dev/null 2> "$work/one-ok.err" || ec=$?
  tr_check "one ok leg out of three cannot APPROVE" \
    bash -c '[ "$1" -ne 0 ] && grep -q arbitration "$2"' _ "$ec" "$work/one-ok.err"
  collect DEEPSEEK_API_KEY=
  tr_check "a backup without credentials is not run" test "$(status_of deepseek) $(runs)" = "disabled 1"
  collect TRIBUNAL_DEEPSEEK=on
  tr_check "a backup never reruns a wrapper that already ran" test "$(status_of deepseek) $(runs)" = "ok 1"
  collect TRIBUNAL_BACKUP_LEGS=deepseek,qwen
  tr_check "one backup per plan-limited leg, in list order" test "$(status_of deepseek) $(status_of qwen) $(runs)" = "ok disabled 2"
  collect TRIBUNAL_BACKUP_LEGS=unknown || true
  tr_check "an invalid backup list fails collection before any leg runs" test "$(runs)" -eq 0
  collect TRIBUNAL_RISK=T5 || true
  tr_check "an invalid TRIBUNAL_RISK fails collection before any leg runs" test "$(runs)" -eq 0
  # Mutation fixtures print valid reviews bound to the original HEAD, even after committing.
  for scenario in dirty commit clean deepseek disabled backup backup-commit many orphan; do
    mutator=codex; mode="$scenario"; expected='{"codex":"failed","claude":"ok","deepseek":"ok"}'; muse_status=ok
    case "$scenario" in
      clean) mutator=none; expected='{"codex":"ok","claude":"ok","deepseek":"ok"}' ;;
      deepseek) mutator=deepseek; mode=dirty; expected='{"codex":"ok","claude":"ok","deepseek":"failed"}' ;;
      disabled) mutator=codex; mode=dirty; expected='{"codex":"failed","claude":"ok","deepseek":"disabled"}' ;;
      backup*) mutator=deepseek; mode=dirty; [ "$scenario" != backup-commit ] || mode=commit
        expected='{"codex":"failed","claude":"ok","deepseek":"failed"}' ;;
    esac
    ec=0
    case "$scenario" in
      backup*) collect FIXTURE_MUTATOR="$mutator" FIXTURE_MUTATION="$mode" || ec=$? ;;
      *) [ "$scenario" = disabled ] || muse_status=disabled
        collect FIXTURE_CODEX_ERROR= FIXTURE_MUTATOR="$mutator" FIXTURE_MUTATION="$mode" \
           TRIBUNAL_MIN_OK_LEGS="$([ "$scenario" = many ] && echo 4 || echo 2)" \
           TRIBUNAL_BACKUP_LEGS=off TRIBUNAL_DEEPSEEK="$([ "$scenario" = disabled ] && echo off || echo on)" || ec=$? ;;
    esac
    mutation_case_ok() {
      [ "$ec" -eq 0 ] || return 1
      jq -e --argjson expected "$expected" --arg muse "$muse_status" '
        ([.providers[] | {key:.provider,value:.status}] | from_entries) as $actual
        | $actual == ({gemini:"disabled",qwen:"disabled",grok:"disabled",muse:$muse} + $expected)
      ' "$collection/manifest.json" >/dev/null || return 1
      manifest_sha="$(jq -r .manifest_sha256 "$work/collect-$n.json")"
      fixture_finalize() {
        env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" \
          "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
          --expected-manifest-sha256 "$manifest_sha" --arbitration "$1" \
          > "$work/finalize.json" 2> "$work/finalize.err"
      }
      jq '{tribunal_verdict:{decision:"APPROVE",
          confidence:(if any(.providers[]; .status == "failed") then 0.9 else 0.95 end),rationale:"Fixture review."},
        findings:[],scope_findings:[],conflicts_resolved:[],summary:"Fixture review.",
        provider_assessment:(.providers | map({key:.provider,value:{status:.status,
          findings_accepted:0,findings_rejected:0,false_positives:[]}}) | from_entries)}' \
        "$collection/manifest.json" > "$work/arbitration.json"
      if [ "$scenario" = dirty ]; then
        jq '.provider_assessment.codex.status="ok"' "$work/arbitration.json" > "$work/false-ok.json"
        if fixture_finalize "$work/false-ok.json"; then return 1; fi
      fi
      if [ "$scenario" = many ]; then
        if fixture_finalize "$work/arbitration.json"; then return 1; fi
        jq '.tribunal_verdict.decision="NEEDS_WORK"' "$work/arbitration.json" > "$work/below-floor.json"
        fixture_finalize "$work/below-floor.json" || return 1
      else
        fixture_finalize "$work/arbitration.json" || return 1
      fi
      if [ "$scenario" = clean ]; then
        ! grep -q 'mutated its review worktree' "$work/collect-$n.err"
        return
      fi
      jq -e '.error | contains("mutated its review worktree") and (contains("scratch") or contains("unresolvable"))' \
        "$collection/providers/$mutator.json" >/dev/null || return 1
      if [ "$scenario" = orphan ]; then
        jq -e '.error | contains("unresolvable")' "$collection/providers/$mutator.json" >/dev/null || return 1
      fi
      if [ "$mode" = commit ]; then
        jq -e '.error | contains("HEAD moved")' "$collection/providers/$mutator.json" >/dev/null || return 1
      fi
      if [ "$scenario" = many ]; then
        jq -e '.error | (split("\n") | length) <= 21' "$collection/providers/$mutator.json" >/dev/null || return 1
      fi
      [ "$(grep -c "tribunal evidence: $mutator: provider mutated its review worktree" "$work/collect-$n.err")" -eq 1 ] || return 1
      ! grep -q 'tribunal evidence: gemini: provider mutated' "$work/collect-$n.err"
    }
    tr_check "review worktree mutation: $scenario preserves collection and provider statuses" mutation_case_ok
  done
  # Include a verification-time worktree add, which must not run a planted hook.
  printf 'false\n' > "$repo/.tribunal-mutation-gate"
  printf 'fixture\n' > "$repo/test_fixture.sh"
  git -C "$repo" add .tribunal-mutation-gate test_fixture.sh
  git -C "$repo" commit -qm 'mutation-gate fixture'
  head="$(git -C "$repo" rev-parse HEAD)"
  cp "$repo/.git/config" "$state/config.before"
  for scenario in fsmonitor hooks filter filter-equals filter-info filter-info-equals filter-attrfile filter-global \
    config-symlink config-fifo config-fifo-race backup-hooks lock backup-lock background backup-background; do
    mode="${scenario#backup-}"; ec=0; mutator=codex
    rm -f "$state/fsmonitor.executed" "$state/background.executed" "$state/child.pid" "$state/claude.evidence.json"
    if [ "$mode" = config-fifo-race ]; then
      mkfifo "$state/claude.ready" "$state/config-race.go" "$state/config-race.done"
    fi
    case "$scenario" in
      backup-*) mutator=deepseek; collect FIXTURE_MUTATOR="$mutator" FIXTURE_MUTATION="$mode" || ec=$? ;;
      filter-global)
        mkdir -p "$work/home"
        collect HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" FIXTURE_CODEX_ERROR= \
          FIXTURE_MUTATOR="$mutator" FIXTURE_MUTATION="$mode" TRIBUNAL_BACKUP_LEGS=off || ec=$? ;;
      *) collect FIXTURE_CODEX_ERROR= FIXTURE_MUTATOR="$mutator" FIXTURE_MUTATION="$mode" TRIBUNAL_BACKUP_LEGS=off || ec=$? ;;
    esac
    containment_case_ok() {
      case "$mode" in
        fsmonitor|hooks|filter|filter-equals|filter-info|filter-info-equals|filter-attrfile)
          [ "$ec" -eq 1 ] && [ ! -e "$collection" ] || return 1
          grep -q "shared git config changed: $repo/.git/config" "$work/collect-$n.err" || return 1
          case "$mode" in
            filter*) expected='^filter\..*\.clean$' ;;
            hooks) expected='^core\.hookspath$' ;;
            *) expected='^core\.fsmonitor$' ;;
          esac
          grep -Eq "$expected" "$work/collect-$n.err" || return 1
          cmp -s "$repo/.git/config" "$state/config.before" || return 1 ;;
        filter-global)
          [ "$ec" -eq 0 ] || return 1
          cmp -s "$repo/.git/config" "$state/config.before" || return 1 ;;
        config-fifo|config-fifo-race)
          [ "$ec" -eq 1 ] && [ ! -e "$collection" ] || return 1
          grep -q "shared git config changed: $repo/.git/config" "$work/collect-$n.err" || return 1
          [ -f "$repo/.git/config" ] && [ ! -L "$repo/.git/config" ] || return 1
          cmp -s "$repo/.git/config" "$state/config.before" || return 1
          [ "$mode" != config-fifo-race ] || [ -f "$state/config-race.exercised" ] ;;
        config-symlink)
          [ "$ec" -eq 1 ] && [ ! -e "$collection" ] || return 1
          grep -q "shared git config changed: $repo/.git/config" "$work/collect-$n.err" || return 1
          [ -f "$repo/.git/config" ] && [ ! -L "$repo/.git/config" ] || return 1
          cmp -s "$repo/.git/config" "$state/config.before" || return 1
          cmp -s "$state/config.target" "$state/config.before" || return 1
          [ ! "$state/config.target" -nt "$state/config.target.timestamp" ] \
            && [ ! "$state/config.target" -ot "$state/config.target.timestamp" ] || return 1 ;;
        lock|background)
          [ "$ec" -eq 0 ] || return 1
          [ "$(status_of "$mutator")" = ok ] || return 1
          jq -e '.model == "fixture"' "$collection/providers/$mutator.json" >/dev/null || return 1
          [ ! -e "$state/background.executed" ] || return 1
          if [ "$mode" = background ]; then
            [ -s "$state/child.pid" ] || return 1
            case "$(ps -o stat= -p "$(cat "$state/child.pid")")" in ''|Z*) ;; *) return 1 ;; esac
          fi ;;
      esac
      [ ! -e "$state/fsmonitor.executed" ] || return 1
      jq -e '.model == "fixture" and .summary.verdict == "APPROVE"' "$state/claude.evidence.json" >/dev/null || return 1
      cmp -s "$state/claude.evidence.json" "$state/claude.expected.json" || return 1
      [ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
    }
    tr_check "leg containment: $scenario" containment_case_ok
    # Restore baseline and remove locked worktrees even when exercising the unfixed runner.
    rm -f "$repo/.git/config"
    cp "$state/config.before" "$repo/.git/config"
    rm -f "$repo/.git/info/attributes"
    rm -rf "$work/home"
    while IFS= read -r wt; do
      [ "$wt" = "$repo" ] || git -C "$repo" worktree remove -f -f "$wt"
    done < <(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p')
  done
  for scenario in worktree-commondir worktree-gitfile; do
    rm -f "$state/driver.executed" "$state/claude.evidence.json" "$state/claude.expected.json"
    mkfifo "$state/claude.ready"
    ec=0
    collect FIXTURE_CODEX_ERROR= FIXTURE_MUTATOR=codex FIXTURE_MUTATION="$scenario" TRIBUNAL_BACKUP_LEGS=off || ec=$?
    worktree_redirect_reported() {
      grep -Fq 'codex: provider mutated its review worktree' "$work/collect-$n.err" || return 1
      if [ "$ec" -eq 0 ]; then
        [ "$(status_of codex)" = failed ] && jqe '.error | contains("app.txt")' "$collection/providers/codex.json"
      else
        [ "$ec" -eq 128 ] && [ ! -e "$collection" ] && grep -Fq 'fatal: validation failed' "$work/collect-$n.err"
      fi
    }
    tr_check "leg containment: $scenario never runs the redirected filter driver" test ! -e "$state/driver.executed"
    tr_check "leg containment: $scenario preserves sibling evidence" cmp -s "$state/claude.evidence.json" "$state/claude.expected.json"
    tr_check "leg containment: $scenario reports the mutated leg" worktree_redirect_reported
    if [ "$scenario" = worktree-gitfile ]; then
      tr_check "redirected gitfile cleanup names leftover worktrees and prune hint" \
        bash -c 'grep -q "leftover review worktree:" "$1" && grep -q "git worktree prune" "$1"' _ "$work/collect-$n.err"
    fi
    while IFS= read -r wt; do
      [ "$wt" = "$repo" ] || { rm -rf -- "$wt"; git -C "$repo" worktree remove -f -f "$wt"; }
    done < <(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p')
  done
  for scenario in commondir backup-commondir; do
    rm -f "$state/git.watch" "$state/git.calls" "$state/driver.executed"
    ec=0
    if [ "$scenario" = commondir ]; then
      mkfifo "$state/claude.ready"
      collect FIXTURE_CODEX_ERROR= FIXTURE_MUTATOR=codex FIXTURE_MUTATION=commondir TRIBUNAL_BACKUP_LEGS=off || ec=$?
    else
      collect FIXTURE_MUTATOR=deepseek FIXTURE_MUTATION=commondir || ec=$?
    fi
    commondir_collect_rejected() {
      [ "$ec" -eq 1 ] && [ ! -e "$collection" ] || return 1
      grep -Fq "git surface changed: $repo/.git/commondir" "$work/collect-$n.err" || return 1
      [ ! -e "$repo/.git/commondir" ] && [ ! -e "$state/driver.executed" ] && [ ! -e "$state/git.calls" ]
    }
    tr_check "leg containment: $scenario refuses before Git and removes commondir" commondir_collect_rejected
    rm -f "$repo/.git/commondir" "$state/git.watch" "$state/claude.ready"
    while IFS= read -r wt; do
      [ "$wt" = "$repo" ] || git -C "$repo" worktree remove -f -f "$wt"
    done < <(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p')
  done
  collect FIXTURE_CODEX_ERROR= TRIBUNAL_BACKUP_LEGS=off
  manifest_sha="$(jq -r .manifest_sha256 "$work/collect-$n.json")"
  tr_check "collection records resolved Git paths and directory identity" \
    jqe --arg gitdir "$repo/.git" --arg identity "$(stat -c '%d:%i' "$repo/.git")" \
    '.git_surface | .schema == "tribunal-git-surface/v2" and .git_dir == $gitdir and .common_dir == $gitdir and .git_dir_identity == $identity and .common_dir_identity == $identity and .root_git == {kind:"directory",identity:$identity,file:null} and .commondir == null and (.config.sha256|length) == 64' "$collection/manifest.json"
  jq '{tribunal_verdict:{decision:"APPROVE",confidence:0.95,rationale:"Fixture review."},
    findings:[],scope_findings:[],conflicts_resolved:[],summary:"Fixture review.",
    provider_assessment:(.providers | map({key:.provider,value:{status:.status,
      findings_accepted:0,findings_rejected:0,false_positives:[]}}) | from_entries)}' \
    "$collection/manifest.json" > "$work/arbitration.json"
  git -C "$repo" config extensions.worktreeConfig true
  for command in verify-collection finalize; do
    verify_args=("$command")
    [ "$command" != finalize ] || verify_args+=(--arbitration "$work/arbitration.json")
    ec=0
    env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_STATE="$state" \
      "$plugin/scripts/collect-review-evidence.sh" "${verify_args[@]}" --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" \
      > "$work/$command.json" 2> "$work/$command.err" || ec=$?
    tr_check "$command rejects changed extensions.worktreeConfig and restores config" \
      bash -c '[ "$1" = 1 ] && grep -Fxq extensions.worktreeconfig "$2" && cmp -s "$3" "$4"' \
      _ "$ec" "$work/$command.err" "$repo/.git/config" "$collection/git-surface/config"
    git -C "$repo" config extensions.worktreeConfig true
  done
  cp "$collection/git-surface/config" "$repo/.git/config"
  for command in verify-collection finalize; do
    rm -f "$state/git.calls" "$state/driver.executed"
    FIXTURE_STATE="$state" bash "$state/plant-commondir.sh" "$repo/.git"
    verify_args=("$command")
    [ "$command" != finalize ] || verify_args+=(--arbitration "$work/arbitration.json")
    ec=0
    env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_STATE="$state" \
      "$plugin/scripts/collect-review-evidence.sh" "${verify_args[@]}" --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" \
      > "$work/$command.json" 2> "$work/$command.err" || ec=$?
    commondir_verify_rejected() {
      [ "$ec" -eq 1 ] || return 1
      grep -Fq "git surface changed: $repo/.git/commondir" "$work/$command.err" || return 1
      [ ! -e "$repo/.git/commondir" ] && [ ! -e "$state/driver.executed" ] && [ ! -e "$state/git.calls" ]
    }
    tr_check "$command refuses post-collect commondir before any Git call" commondir_verify_rejected
    tr_check "$command never runs the redirected filter driver" test ! -e "$state/driver.executed"
    chmod u+w "$collection"
    rm -f "$repo/.git/commondir" "$state/git.watch" "$collection/proof.json" "$collection/arbitration.json"
  done
  cp "$collection/manifest.json" "$state/manifest.before"
  chmod u+w "$collection/manifest.json"
  for mode in gitfile symlink replacement legacy legacy-surface; do
    if [[ "$mode" == legacy* ]]; then
      if [ "$mode" = legacy ]; then
        jq 'del(.git_surface)' "$state/manifest.before" > "$collection/manifest.json"
      else
        jq '.git_surface |= {git_dir,common_dir,git_dir_identity}' "$state/manifest.before" > "$collection/manifest.json"
      fi
      manifest_sha="$(sha256sum "$collection/manifest.json" | awk '{print $1}')"
      expected='collection manifest lacks git_surface identity; recollect'
    else
      mv "$repo/.git" "$repo/.git.saved"
      case "$mode" in
        gitfile) printf 'gitdir: %s\n' "$repo/.git.saved" > "$repo/.git" ;;
        symlink) ln -s "$repo/.git.saved" "$repo/.git" ;;
        replacement) cp -a "$repo/.git.saved" "$repo/.git" ;;
      esac
      expected="git surface changed: $repo/.git"
    fi
    for command in verify-collection finalize; do
      rm -f "$state/git.calls"
      touch "$state/git.watch"
      verify_args=("$command")
      # An invalid arbitration path must not mask a changed Git surface.
      [ "$command" != finalize ] || verify_args+=(--arbitration "$work/missing-arbitration.json")
      ec=0
      env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_STATE="$state" \
        "$plugin/scripts/collect-review-evidence.sh" "${verify_args[@]}" --collection "$collection" \
        --expected-manifest-sha256 "$manifest_sha" \
        > "$work/$command.json" 2> "$work/$command.err" || ec=$?
      surface_verify_rejected() {
        [ "$ec" -eq 1 ] && grep -Fq "$expected" "$work/$command.err" && [ ! -e "$state/git.calls" ]
      }
      tr_check "$command rejects $mode before Git or arbitration" surface_verify_rejected
      rm -f "$state/git.watch"
    done
    if [[ "$mode" != legacy* ]]; then
      rm -rf "$repo/.git"
      mv "$repo/.git.saved" "$repo/.git"
    fi
  done
  cp "$state/manifest.before" "$collection/manifest.json"
  chmod 0444 "$collection/manifest.json"
  manifest_sha="$(sha256sum "$collection/manifest.json" | awk '{print $1}')"
  rm -f "$state/fsmonitor.executed"
  verify_config_containment() {
    git -C "$repo" config core.hooksPath "$state/hooks"
    git -C "$repo" config core.fsmonitor "$state/fsmonitor"
    local config_mode rc=0
    config_mode="$(jq -r .git_surface.config.mode "$collection/manifest.json")"
    jq -e 'has("mutation_gate")' "$collection/manifest.json" >/dev/null || return 1
    env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_STATE="$state" \
      "$plugin/scripts/collect-review-evidence.sh" "$@" --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" > "$work/verify.json" 2> "$work/verify.err" || rc=$?
    [ "$rc" -eq 1 ] && grep -Fxq core.hookspath "$work/verify.err" && grep -Fxq core.fsmonitor "$work/verify.err" || return 1
    cmp -s "$repo/.git/config" "$collection/git-surface/config" && [ "$(stat -c '%a' "$repo/.git/config")" = "$config_mode" ] || return 1
    [ ! -e "$state/fsmonitor.executed" ] || return 1
    [ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
  }
  tr_check "verify-collection rejects and restores changed hooks and fsmonitor config" verify_config_containment verify-collection
  tr_check "finalize rejects and restores changed hooks and fsmonitor config" verify_config_containment finalize --arbitration "$work/arbitration.json"
  cp "$state/config.before" "$repo/.git/config"
  # Round 2: use the collector's functions without its CLI dispatch for helper probes.
  sed '/^require_tools$/,$d' "$plugin/scripts/collect-review-evidence.sh" > "$plugin/scripts/surface-functions.sh"
  tr_check "round 2 T-004: protective config wins over caller config" \
    bash -c '. "$1"; test "$(hardened_git -c core.hooksPath=/caller config --get core.hooksPath)" = /dev/null' \
    _ "$plugin/scripts/surface-functions.sh"
  mkdir -p "$work/home"
  git config --file "$work/home/.gitconfig" "includeIf.gitdir:$repo/.git.path" "$work/home/target-config"
  git config --file "$work/home/target-config" safe.directory "$repo"
  # The collector loads the system scope too and unsets GIT_CONFIG_SYSTEM when sourced:
  # pin that scope to a fixture afterwards so the host's /etc/gitconfig cannot change the result.
  git config --file "$work/home/system-config" safe.directory /system/fixture
  tr_check "round 2 T-005: safe.directory includeIf uses target repo" \
    env HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" GIT_CONFIG_NOSYSTEM=1 \
    bash -c '. "$1"; export GIT_CONFIG_SYSTEM="$3"; SURFACE_ROOT="$2"; load_safe_directories; SURFACE_ROOT=""; test "$(hardened_git config --get-all safe.directory)" = "$(printf "%s\n%s" /system/fixture "$2")"' \
    _ "$plugin/scripts/surface-functions.sh" "$repo" "$work/home/system-config"
  rm -rf "$work/home"
  mkdir "$work/version-bin"
  printf '#!/usr/bin/env bash\nprintf "git version 2.41.0\\n"\n' > "$work/version-bin/git"
  chmod +x "$work/version-bin/git"
  ec=0
  PATH="$work/version-bin:$PATH" bash -c '. "$1"; require_git_version' _ "$plugin/scripts/surface-functions.sh" \
    > "$work/version.out" 2> "$work/version.err" || ec=$?
  tr_check "round 2 T-002: git 2.41 is rejected with 2.42 requirement" \
    bash -c '[ "$1" = 1 ] && grep -Fq "git 2.42+ is required" "$2"' _ "$ec" "$work/version.err"

  local main_repo="$repo" root_gitdir target phase saved
  git -C "$main_repo" worktree add --detach -q "$work/linked" "$head"
  repo="$work/linked"; root_gitdir="$(git -C "$repo" rev-parse --absolute-git-dir)"
  cp "$repo/.git" "$state/root.git.before"
  cp "$root_gitdir/commondir" "$state/commondir.before"
  ec=0; collect FIXTURE_CODEX_ERROR= TRIBUNAL_BACKUP_LEGS=off || ec=$?
  tr_check "round 2 T-001: linked root collects with stub legs" test "$ec" -eq 0
  manifest_sha="$(jq -r '.manifest_sha256 // empty' "$work/collect-$n.json")"
  # Tracking changes remain legitimate across later verification/finalization too.
  git -C "$repo" config branch.after-collection.remote origin
  git -C "$repo" config branch.after-collection.merge refs/heads/after-collection
  for command in verify-collection finalize; do
    verify_args=("$command")
    [ "$command" != finalize ] || verify_args+=(--arbitration "$work/arbitration.json")
    ec=0
    env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_STATE="$state" \
      "$plugin/scripts/collect-review-evidence.sh" "${verify_args[@]}" --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" > "$work/$command.json" 2> "$work/$command.err" || ec=$?
    tr_check "round 2 T-001: linked root $command succeeds with branch-only config changes" test "$ec" -eq 0
  done
  saved="$collection"
  for scenario in root-gitfile root-commondir; do
    case "$scenario" in
      root-gitfile) target="$repo/.git"; expected="$state/root.git.before" ;;
      root-commondir) target="$root_gitdir/commondir"; expected="$state/commondir.before" ;;
    esac
    for phase in primary backup verify-collection finalize; do
      rm -f "$state/git.calls" "$state/git.watch" "$state/claude.ready" "$state/wrappers.started"
      ec=0
      if [ "$phase" = primary ]; then
        mkfifo "$state/claude.ready"
        collect FIXTURE_CODEX_ERROR= FIXTURE_MUTATOR=codex FIXTURE_MUTATION="$scenario" TRIBUNAL_BACKUP_LEGS=off || ec=$?
      elif [ "$phase" = backup ]; then
        collect FIXTURE_MUTATOR=deepseek FIXTURE_MUTATION="$scenario" || ec=$?
      else
        printf '/missing-resolution\n' > "$target"
        touch "$state/git.watch"
        verify_args=("$phase")
        [ "$phase" != finalize ] || verify_args+=(--arbitration "$work/missing-arbitration.json")
        env PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_STATE="$state" \
          "$plugin/scripts/collect-review-evidence.sh" "${verify_args[@]}" --collection "$saved" \
          --expected-manifest-sha256 "$manifest_sha" > "$work/collect-$n.json" 2> "$work/collect-$n.err" || ec=$?
      fi
      linked_redirect_rejected() {
        [ "$ec" -eq 1 ] && grep -Fq "git surface changed: $target" "$work/collect-$n.err" \
          && cmp -s "$target" "$expected" && [ ! -e "$state/git.calls" ] || return 1
        case "$phase" in primary|backup) [ -e "$state/wrappers.started" ] && [ ! -e "$collection" ] ;; esac
      }
      tr_check "round 2 T-001: $phase $scenario fails named before Git and restores bytes" linked_redirect_rejected
      cp "$expected" "$target"
      rm -f "$state/git.watch" "$state/claude.ready"
      while IFS= read -r wt; do
        case "$wt" in "$main_repo"|"$repo") ;; *) git -C "$main_repo" worktree remove -f -f "$wt" ;; esac
      done < <(git -C "$main_repo" worktree list --porcelain | sed -n 's/^worktree //p')
    done
  done
  git -C "$main_repo" worktree remove -f "$repo"
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}


test_backup_leg_collection
