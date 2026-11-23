#!/usr/bin/env bash
# Tribunal git walk-root, base-ref resolution, and repository policy gates.
# Sourced by scripts/lib.sh.

tribunal_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Repo-walking legs read files with tools the host's deny rules do not cover. When the
# checkout holds untracked .env* files (ignored or not; ignored directories are not entered),
# walk a scratch clone of HEAD instead, so a leg cannot read them and send the values to its
# provider. The reviewed range ends at HEAD, so the clone holds everything a reviewer needs.
# TRIBUNAL_ALLOW_ENV_FILES=1 walks the checkout. A supplied PINNED_HEAD always
# clones that commit, excluding dirty/untracked files. Prints the root to walk.
tribunal_walk_root() {  # tribunal_walk_root SCRATCH_DIR [PINNED_HEAD]
  local repo
  repo="$(tribunal_repo_root)"
  if [ -z "${2:-}" ] && { [ "${TRIBUNAL_ALLOW_ENV_FILES:-0}" = 1 ] || ! provider_find_untracked_env_files "$repo" >/dev/null; }; then
    printf '%s\n' "$repo"
    return 0
  fi
  git clone -q --shared --no-checkout "$repo" "$1" 2>/dev/null \
    && git -C "$1" -c core.hooksPath=/dev/null checkout -q --detach "${2:-$(git -C "$repo" rev-parse HEAD)}" 2>/dev/null \
    && printf '%s\n' "$1"
}

tribunal_default_branch() {
  local branch
  branch="${TRIBUNAL_BASE_BRANCH:-}"
  [ -n "$branch" ] || branch="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
  [ -n "$branch" ] || branch="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)"
  [ -n "$branch" ] || branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  printf '%s\n' "${branch:-main}"
}

tribunal_base_ref() {
  local branch
  branch="$(tribunal_default_branch)"
  printf '%s\n' "${TRIBUNAL_BASE_REF:-origin/$branch}"
}

tribunal_ignored_additions() {
  local base_ref="${1:-$(tribunal_base_ref)}" repo_root base_commit head_commit
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'cannot resolve repository root\n' >&2; return 1; }
  base_commit="$(git rev-parse --verify "${base_ref}^{commit}" 2>/dev/null)" \
    || { printf 'cannot resolve base ref %s\n' "$base_ref" >&2; return 1; }
  head_commit="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || { printf 'cannot resolve HEAD\n' >&2; return 1; }

  (
    local temp_root checkout ignored_file empty_excludes
    local -a pipeline_status
    temp_root="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$temp_root"' EXIT
    trap 'exit 1' HUP INT TERM
    checkout="$temp_root/head"
    ignored_file="$temp_root/ignored"
    empty_excludes="$temp_root/empty-excludes"
    mkdir "$temp_root/template" || exit 1
    : > "$empty_excludes" || exit 1

    git -c init.templateDir="$temp_root/template" clone --shared --no-checkout --quiet \
      "$repo_root" "$checkout" \
      || { printf 'cannot create pristine HEAD checkout\n' >&2; exit 1; }
    git -C "$checkout" -c core.excludesFile="$empty_excludes" checkout --detach --quiet "$head_commit" \
      || { printf 'cannot check out reviewed HEAD\n' >&2; exit 1; }

    set +e
    git -C "$checkout" diff --name-only --no-renames --diff-filter=A -z "$base_commit"..."$head_commit" \
      | git -C "$checkout" -c core.excludesFile="$empty_excludes" \
          check-ignore -v -z --no-index --stdin > "$ignored_file" 2>/dev/null
    pipeline_status=("${PIPESTATUS[@]}")
    if (( pipeline_status[0] != 0 || pipeline_status[1] > 1 )); then
      printf 'git check-ignore failed (diff %s, check-ignore %s)\n' \
        "${pipeline_status[0]}" "${pipeline_status[1]}" >&2
      exit 1
    fi

    jq -Rs -c '
      split("\u0000")
      | if .[-1] == "" then .[:-1] else . end
      | . as $fields
      | [range(0; length; 4) as $i
          | select(($fields[$i + 2] | startswith("!")) | not)
          | {path:$fields[$i + 3], pattern:$fields[$i + 2],
             source:$fields[$i], line:($fields[$i + 1] | tonumber)}]
    ' "$ignored_file"
  )
}

# Deleted paths matching policy/rules globs in base...HEAD (issue #537).
# Defaults: docs/policies/** and rules/**. If base contains
# .tribunal-deleted-globs (one glob per line; blanks/# ignored), that list
# replaces the defaults — including empty ⇒ []. A HEAD-only override must not
# disable defaults. Match via git show + git diff pathspecs only — never
# clone/checkout a worktree, and never check-ignore / .gitignore.
tribunal_deleted_policy_paths() {
  local base_ref="${1:-$(tribunal_base_ref)}" repo_root base_commit head_commit
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'cannot resolve repository root\n' >&2; return 1; }
  base_commit="$(git rev-parse --verify "${base_ref}^{commit}" 2>/dev/null)" \
    || { printf 'cannot resolve base ref %s\n' "$base_ref" >&2; return 1; }
  head_commit="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || { printf 'cannot resolve HEAD\n' >&2; return 1; }

  (
    local temp_root matched_file paths_file glob path diff_status show_status globs_content
    local -a globs=()
    local -A seen=()
    temp_root="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$temp_root"' EXIT
    trap 'exit 1' HUP INT TERM
    matched_file="$temp_root/matched"
    paths_file="$temp_root/paths"
    : > "$matched_file" || exit 1

    if git -C "$repo_root" cat-file -e "${base_commit}:.tribunal-deleted-globs" 2>/dev/null; then
      set +e
      globs_content="$(git -C "$repo_root" show "${base_commit}:.tribunal-deleted-globs")"
      show_status=$?
      if (( show_status != 0 )); then
        printf 'cannot read base .tribunal-deleted-globs\n' >&2
        exit 1
      fi
      # Base list replaces defaults (including when empty after comments).
      mapfile -t globs < <(printf '%s\n' "$globs_content" | awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { print }
      ') || exit 1
    else
      globs=('docs/policies/**' 'rules/**')
    fi

    # Empty custom list on base ⇒ [] (never a pathspec-less diff of all deletions).
    if (( ${#globs[@]} == 0 )); then
      printf '[]\n'
      exit 0
    fi

    for glob in "${globs[@]}"; do
      set +e
      git -C "$repo_root" diff --name-only --no-renames --diff-filter=D -z \
        "$base_commit"..."$head_commit" -- ":(glob)$glob" > "$paths_file"
      diff_status=$?
      if (( diff_status != 0 )); then
        printf 'git deleted-policy path match failed (diff %s)\n' "$diff_status" >&2
        exit 1
      fi
      while IFS= read -r -d '' path; do
        [ -n "${seen[$path]+x}" ] && continue
        seen[$path]=1
        jq -nc --arg path "$path" --arg glob "$glob" '{path:$path,glob:$glob}' \
          >> "$matched_file" || exit 1
      done < "$paths_file"
    done

    if [ ! -s "$matched_file" ]; then
      printf '[]\n'
    else
      jq -s -c '.' "$matched_file"
    fi
  )
}

# Opt-in mutation gate (issue #538 item 3): when head contains
# .tribunal-mutation-gate with one non-comment command line, overlay
# added/changed test paths from head onto a base checkout and run that
# command. Non-zero exit ⇒ RED; zero ⇒ vacuous. Absence / comments-only ⇒ [].
# Enablement is read from head_oid via git show (never the ambient worktree).
tribunal_mutation_test_path() {
  local path="$1" base
  case "/$path/" in
    */test/*|*/tests/*|*/__tests__/*) return 0 ;;
  esac
  base="${path##*/}"
  case "$base" in
    test_*|*_test.*|*.test.*|*.spec.*) return 0 ;;
  esac
  return 1
}

tribunal_mutation_gate() {
  local base_ref="$1" head_ref="$2" repo_root base_commit head_commit
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'cannot resolve repository root\n' >&2; return 1; }
  base_commit="$(git rev-parse --verify "${base_ref}^{commit}" 2>/dev/null)" \
    || { printf 'cannot resolve base ref %s\n' "$base_ref" >&2; return 1; }
  head_commit="$(git rev-parse --verify "${head_ref}^{commit}" 2>/dev/null)" \
    || { printf 'cannot resolve head ref %s\n' "$head_ref" >&2; return 1; }

  (
    local temp_root paths_file matched_file config_content command path
    local show_status diff_status worktree exit_code result parent
    local -a targets=()
    temp_root="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$temp_root"' EXIT
    trap 'exit 1' HUP INT TERM
    paths_file="$temp_root/paths"
    matched_file="$temp_root/matched"
    : > "$matched_file" || exit 1

    if ! git -C "$repo_root" cat-file -e "${head_commit}:.tribunal-mutation-gate" 2>/dev/null; then
      printf '[]\n'
      exit 0
    fi
    set +e
    config_content="$(git -C "$repo_root" show "${head_commit}:.tribunal-mutation-gate")"
    show_status=$?
    set -e
    if (( show_status != 0 )); then
      printf 'cannot read head .tribunal-mutation-gate\n' >&2
      exit 1
    fi
    command="$(printf '%s\n' "$config_content" | awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      { print; exit }
    ')"
    if [ -z "$command" ]; then
      printf '[]\n'
      exit 0
    fi

    set +e
    git -C "$repo_root" diff --name-only --diff-filter=AMR --find-renames \
      "$base_commit"..."$head_commit" > "$paths_file"
    diff_status=$?
    set -e
    if (( diff_status != 0 )); then
      printf 'git mutation-gate path match failed (diff %s)\n' "$diff_status" >&2
      exit 1
    fi
    while IFS= read -r path || [ -n "$path" ]; do
      [ -n "$path" ] || continue
      tribunal_mutation_test_path "$path" || continue
      targets+=("$path")
    done < "$paths_file"

    if (( ${#targets[@]} == 0 )); then
      printf '[]\n'
      exit 0
    fi

    worktree="$temp_root/base-wt"
    git -C "$repo_root" worktree add --detach --quiet "$worktree" "$base_commit" \
      || { printf 'cannot create base worktree for mutation gate\n' >&2; exit 1; }
    # shellcheck disable=SC2064
    trap 'git -C "$repo_root" worktree remove -f -f "$worktree" >/dev/null 2>&1 || true; rm -rf -- "$temp_root"' EXIT

    for path in "${targets[@]}"; do
      parent="$(dirname -- "$path")"
      mkdir -p -- "$worktree/$parent" || exit 1
      git -C "$repo_root" show "${head_commit}:${path}" > "$worktree/$path" || {
        printf 'cannot overlay mutation-gate test path from head: %s\n' "$path" >&2
        exit 1
      }
    done

    set +e
    (cd "$worktree" && bash -c "$command") >/dev/null 2>&1
    exit_code=$?
    set -e
    if (( exit_code == 0 )); then
      result=vacuous
    else
      result=RED
    fi

    for path in "${targets[@]}"; do
      jq -nc --arg path "$path" --arg command "$command" \
        --argjson exit_code "$exit_code" --arg result "$result" \
        '{path:$path,command:$command,exit_code:$exit_code,result:$result}' \
        >> "$matched_file" || exit 1
    done
    jq -s -c 'sort_by(.path)' "$matched_file"
  )
}
