#!/usr/bin/env bash
# ship-gates.sh — PreToolUse Bash gate for git push and gh issue close.
#
# Fast exit 0 unless the command is a git push, git -C <dir> push, or
# gh issue close. Unparseable commands and missing tools allow (no block).
# No git or gh call until the command matches. Block is exit 2 and a reason
# on stderr.
#
# Target repo: .claude/multi-model-orchestrator.local.md YAML frontmatter.
#   push_check: <bash -c command>   absent → allow; non-zero or timeout → block
#   test_path_regex: <ERE>          deleted test paths, and net removal of
#                                   def test_ / func Test / it( / test( on them
#   live_recheck: true              gh issue close needs VERIFIED LIVE: <sha>
#                                   or Live-Recheck: no-live-surface — <reason>
# Renames (-M) are not deletions. Real Git trailers in the push range
# (not subject or body prose):
#   Push-Gate: skip — <reason>
#   Test-Deletion: justified — <reason>
# `git push` and `git push <remote>` (no refspec) take local:remote pairs from
# `git push --dry-run --porcelain --no-verify` (remote.<name>.push and
# push.default). --no-verify keeps that lookup from running a local pre-push
# hook. `git push --repo=<remote>` is that same remote; a positional remote
# wins when both are present. A failed dry-run falls back to @{push} and keeps
# the remote. A new branch is attributed from
# merge-base(tip, origin/<default>).
# push_check runs for every non-delete push even when HEAD or the range
# cannot be resolved. A Push-Gate skip trailer in a resolved range skips it.
# A live marker and its SHA share one line. The SHA is a standalone 7-40 hex token.
# GH_REPO= and -R/--repo select the repository for the evidence lookup.
# gh read failure warns and allows. Delete-ref pushes are not gated.
set -uo pipefail

PUSH_CHECK_TIMEOUT=240
# Short so an offline dry-run falls back to @{push} instead of hanging the hook.
PUSH_DRY_RUN_TIMEOUT=10
DEFAULT_TEST_RE='(\.test\.|\.spec\.|(^|/)test_[^/]*\.py$|_test\.go$|(^|/)tests?/|(^|/)__tests__/|(^|/)spec/)'
DECL_RE='def[[:space:]]+test_|func[[:space:]]+Test|it\(|test\('
PUSH_SKIP_RE='^[[:space:]]*skip[[:space:]]*(—|–|-)[[:space:]]*[^[:space:]]'
TEST_JUST_RE='^[[:space:]]*justified[[:space:]]*(—|–|-)[[:space:]]*[^[:space:]]'
LIVE_SHA_RE='VERIFIED LIVE:.*\<[[:xdigit:]]{7,40}\>'
LIVE_NONE_RE='Live-Recheck:[[:space:]]*no-live-surface[[:space:]]*(—|–|-)[[:space:]]*[^[:space:]]'

block() {
  local reason="$1" esc
  printf 'ship-gates: %s\n' "$reason" >&2
  esc="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '{"systemMessage":"ship-gates: %s"}\n' "$esc" >&2
  exit 2
}
warn() { printf 'ship-gates: warning: %s\n' "$1" >&2; }

normalize_val() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

config_value() { # config_value FILE KEY
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    BEGIN { fm = 0 }
    /^---[ \t]*$/ { fm++; if (fm >= 2) exit; next }
    fm == 1 && $0 ~ "^[ \t]*" key ":[ \t]*" {
      sub(/^[ \t]*[^:]+:[ \t]*/, "")
      print
      exit
    }
  ' "$file" 2>/dev/null || true
}

resolve_dir() {
  case "$2" in
    /*) printf '%s' "$2" ;;
    *) printf '%s' "$1/$2" ;;
  esac
}

# Classify one simple command. Sets kind=push|close|none|ambiguous and the
# fields the gates need. kind=none is not a gated command.
classify_words() {
  local -a words=("$@")
  local n=${#words[@]} i=0 t git_dir="" pending_cd=""
  kind=none
  gate_repo=""
  gate_remote=""
  gate_src=""
  gate_dst=""
  gate_delete=0
  gate_issue=""
  gate_comment=""
  gate_gh_repo=""
  (( n == 0 )) && return 0
  while (( i < n )); do
    t="${words[$i]}"
    if [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      # Same simple command only; classify_words resets gate_gh_repo per segment.
      # A later -R/--repo overwrites this, matching gh flag precedence.
      case "$t" in
        GH_REPO=*) gate_gh_repo="${t#GH_REPO=}" ;;
      esac
      i=$((i + 1))
      continue
    fi
    case "$t" in
      env|command|time|nice|nohup|builtin|exec) i=$((i + 1)); continue ;;
    esac
    break
  done
  (( i >= n )) && return 0
  t="${words[$i]}"
  if [ "$t" = cd ]; then
    pending_cd="${words[$((i + 1))]:-}"
    case "$pending_cd" in
      ''|-*) kind=ambiguous ;;
      /*) seg_cwd="$pending_cd" ;;
      *) seg_cwd="$seg_cwd/$pending_cd" ;;
    esac
    return 0
  fi
  case "$t" in
    git|*/git) classify_git "${words[@]:$i}" ;;
    gh|*/gh) classify_gh "${words[@]:$i}" ;;
  esac
}

classify_git() {
  local -a words=("$@")
  local n=${#words[@]} i=1 t git_dir="$seg_cwd"
  while (( i < n )); do
    t="${words[$i]}"
    case "$t" in
      -C)
        [ $((i + 1)) -lt "$n" ] || { kind=ambiguous; return 0; }
        git_dir="$(resolve_dir "$git_dir" "${words[$((i + 1))]}")"
        i=$((i + 2)) ;;
      -C*)
        git_dir="$(resolve_dir "$git_dir" "${t#-C}")"
        i=$((i + 1)) ;;
      -c)
        [ $((i + 1)) -lt "$n" ] || { kind=ambiguous; return 0; }
        i=$((i + 2)) ;;
      -c?*) i=$((i + 1)) ;;
      --git-dir|--work-tree|--namespace|--super-prefix|--exec-path|--bare) kind=ambiguous; return 0 ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*) kind=ambiguous; return 0 ;;
      -*) kind=ambiguous; return 0 ;;
      *) break ;;
    esac
  done
  [ "${words[$i]:-}" = push ] || return 0
  i=$((i + 1))
  local -a pos=()
  local delete_flag=0 repo_opt=""
  while (( i < n )); do
    t="${words[$i]}"
    case "$t" in
      *'<'*|*'>&'*|*'>'*) kind=ambiguous; return 0 ;;
      -h|--help) return 0 ;;
      --all|--mirror|--tags) kind=ambiguous; return 0 ;;
      -d|--delete) delete_flag=1; i=$((i + 1)) ;;
      -u|--set-upstream|-f|--force|--force-with-lease|--force-if-includes|--no-force-with-lease|-q|--quiet|-v|--verbose|--progress|--no-progress|-n|--dry-run|--no-verify|--verify|--follow-tags|--no-follow-tags|--atomic|--no-atomic|--prune|--no-prune|--thin|--no-thin|-4|--ipv4|-6|--ipv6|--signed|--no-signed|--porcelain)
        i=$((i + 1)) ;;
      --repo=*)
        repo_opt="${t#--repo=}"
        i=$((i + 1)) ;;
      --force-with-lease=*|--signed=*|--push-option=*|--receive-pack=*|--exec=*)
        i=$((i + 1)) ;;
      --repo)
        [ $((i + 1)) -lt "$n" ] || { kind=ambiguous; return 0; }
        repo_opt="${words[$((i + 1))]}"
        i=$((i + 2)) ;;
      -o|--push-option|--receive-pack|--exec)
        [ $((i + 1)) -lt "$n" ] || { kind=ambiguous; return 0; }
        i=$((i + 2)) ;;
      -*) kind=ambiguous; return 0 ;;
      *) pos+=("$t"); i=$((i + 1)) ;;
    esac
  done
  kind=push
  gate_repo="$git_dir"
  gate_delete=$delete_flag
  if [ "$delete_flag" -eq 1 ]; then
    [ "${#pos[@]}" -gt 0 ] && gate_remote="${pos[0]}"
    [ -z "$gate_remote" ] && [ -n "$repo_opt" ] && gate_remote="$repo_opt"
    return 0
  fi
  local spec src dst updates=0
  if [ "${#pos[@]}" -eq 0 ]; then
    [ -n "$repo_opt" ] && gate_remote="$repo_opt"
    return 0
  fi
  # First positional is the remote unless it is a refspec (colon or HEAD).
  if [[ "${pos[0]}" != *:* && "${pos[0]}" != HEAD && "${pos[0]#+}" != HEAD ]]; then
    gate_remote="${pos[0]}"
    pos=("${pos[@]:1}")
  fi
  for spec in ${pos[@]+"${pos[@]}"}; do
    src="${spec%%:*}"
    if [[ "$spec" == *:* ]]; then
      dst="${spec#*:}"
    else
      dst=""
    fi
    src="${src#+}"
    if [ -z "$src" ]; then
      continue
    fi
    updates=$((updates + 1))
    if [ "$updates" -gt 1 ]; then
      kind=ambiguous
      return 0
    fi
    gate_src="$src"
    gate_dst="$dst"
  done
  if [ "$updates" -eq 0 ] && [ "${#pos[@]}" -gt 0 ]; then
    gate_delete=1
  fi
  # Positional <repository> wins over --repo, matching git push.
  if [ -z "$gate_remote" ] && [ -n "$repo_opt" ]; then
    gate_remote="$repo_opt"
  fi
}

classify_gh() {
  local -a words=("$@")
  local n=${#words[@]} i=1 t
  while (( i < n )); do
    t="${words[$i]}"
    case "$t" in
      -R|--repo)
        [ $((i + 1)) -lt "$n" ] || { kind=ambiguous; return 0; }
        gate_gh_repo="${words[$((i + 1))]}"
        i=$((i + 2)) ;;
      --repo=*) gate_gh_repo="${t#--repo=}"; i=$((i + 1)) ;;
      -*) kind=ambiguous; return 0 ;;
      *) break ;;
    esac
  done
  [ "${words[$i]:-}" = issue ] || return 0
  i=$((i + 1))
  [ "${words[$i]:-}" = close ] || return 0
  i=$((i + 1))
  kind=close
  while (( i < n )); do
    t="${words[$i]}"
    case "$t" in
      *'<'*|*'>&'*|*'>'*) kind=ambiguous; return 0 ;;
      -c|--comment)
        [ $((i + 1)) -lt "$n" ] || { kind=ambiguous; return 0; }
        gate_comment="${words[$((i + 1))]}"
        i=$((i + 2)) ;;
      --comment=*) gate_comment="${t#--comment=}"; i=$((i + 1)) ;;
      -R|--repo)
        [ $((i + 1)) -lt "$n" ] || { kind=ambiguous; return 0; }
        gate_gh_repo="${words[$((i + 1))]}"
        i=$((i + 2)) ;;
      --repo=*) gate_gh_repo="${t#--repo=}"; i=$((i + 1)) ;;
      -r|--reason|--duplicate-of|--body)
        [ $((i + 1)) -lt "$n" ] || { kind=ambiguous; return 0; }
        i=$((i + 2)) ;;
      --reason=*|--duplicate-of=*|--body=*) i=$((i + 1)) ;;
      -*) kind=ambiguous; return 0 ;;
      *)
        [ -z "$gate_issue" ] || { kind=ambiguous; return 0; }
        gate_issue="$t"
        i=$((i + 1)) ;;
    esac
  done
  [ -n "$gate_issue" ] || kind=ambiguous
  gate_repo="$seg_cwd"
}

# Quote-aware split. Unbalanced quotes → ambiguous (caller allows).
analyze_command() {
  local cmd="$1" c q="" buf="" in_word=0 k len
  seg_cwd="$2"
  [ -n "$seg_cwd" ] || seg_cwd="$PWD"
  len=${#cmd}
  _WORDS=()
  for (( k = 0; k < len; k++ )); do
    c="${cmd:k:1}"
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=""; else buf+="$c"; in_word=1; fi
      continue
    fi
    case "$c" in
      '"'|"'") q="$c"; in_word=1 ;;
      '\\') k=$((k + 1)); buf+="${cmd:k:1}"; in_word=1 ;;
      ' '|$'\t') [ "$in_word" -eq 1 ] && { _WORDS+=("$buf"); buf=""; in_word=0; } ;;
      ';'|'&'|'|'|$'\n')
        [ "$in_word" -eq 1 ] && { _WORDS+=("$buf"); buf=""; in_word=0; }
        classify_words ${_WORDS[@]+"${_WORDS[@]}"}
        [ "$kind" != ambiguous ] || return 0
        record_gate
        _WORDS=()
        ;;
      *) buf+="$c"; in_word=1 ;;
    esac
  done
  [ -z "$q" ] || { kind=ambiguous; return 0; }
  [ "$in_word" -eq 1 ] && _WORDS+=("$buf")
  classify_words ${_WORDS[@]+"${_WORDS[@]}"}
  [ "$kind" != ambiguous ] || return 0
  record_gate
}

record_gate() {
  [ "$kind" = push ] || [ "$kind" = close ] || return 0
  kinds+=("$kind")
  repos+=("$gate_repo")
  remotes+=("$gate_remote")
  srcs+=("$gate_src")
  dsts+=("$gate_dst")
  deletes+=("$gate_delete")
  issues+=("$gate_issue")
  comments+=("$gate_comment")
  gh_repos+=("$gate_gh_repo")
  kind=none
}

# One line is one evidence statement. A marker and a SHA in different lines,
# or in different comments, do not combine. The SHA is its own 7-40 hex word.
has_live_marker() {
  local line=""
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" | grep -Eq "$LIVE_SHA_RE" && return 0
    printf '%s\n' "$line" | grep -Eq "$LIVE_NONE_RE" && return 0
  done <<< "$1"
  return 1
}

# Fallback when the dry-run cannot be read. @{push} is the remote-tracking ref
# of a plain git push. It fails when that ref is not fetched yet; %(push) is
# the same name and still honours push.default. It does not read remote.<name>.push.
plain_push_dest() { # plain_push_dest REPO  -> "remote<TAB>branch" or nothing
  local repo="$1" push_ref="" head_ref="" rest="" best="" rname=""
  push_ref="$(git -C "$repo" rev-parse --symbolic-full-name '@{push}' 2>/dev/null || true)"
  if [ -z "$push_ref" ]; then
    head_ref="$(git -C "$repo" symbolic-ref -q HEAD 2>/dev/null || true)"
    if [ -n "$head_ref" ]; then
      push_ref="$(git -C "$repo" for-each-ref --format='%(push)' "$head_ref" 2>/dev/null || true)"
    fi
  fi
  case "$push_ref" in
    refs/remotes/*) ;;
    *) return 0 ;;
  esac
  rest="${push_ref#refs/remotes/}"
  while IFS= read -r rname; do
    [ -n "$rname" ] || continue
    case "$rest" in
      "$rname"/*)
        [ "${#rname}" -gt "${#best}" ] && best="$rname"
        ;;
    esac
  done < <(git -C "$repo" remote 2>/dev/null || true)
  [ -n "$best" ] || return 0
  printf '%s\t%s\n' "$best" "${rest#"$best"/}"
}

origin_default() { # origin_default REPO -> origin/<default>, or nothing
  local repo="$1" sym=""
  sym="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$sym" ] && git -C "$repo" rev-parse --verify -q "$sym" >/dev/null; then
    printf '%s\n' "$sym"
    return 0
  fi
  if git -C "$repo" rev-parse --verify -q origin/main >/dev/null; then
    printf '%s\n' origin/main
    return 0
  fi
  if git -C "$repo" rev-parse --verify -q origin/master >/dev/null; then
    printf '%s\n' origin/master
    return 0
  fi
  return 1
}

range_has_trailer() { # range_has_trailer REPO BASE TIP KEY ERE
  local vals=""
  vals="$(git -C "$1" log --format="%(trailers:key=$4,valueonly)" "$2..$3" 2>/dev/null || true)"
  printf '%s\n' "$vals" | grep -Eq "$5"
}

load_repo_config() {
  local file="$1/.claude/multi-model-orchestrator.local.md" raw
  cfg_push=""
  cfg_test="$DEFAULT_TEST_RE"
  cfg_live=0
  [ -f "$file" ] || return 0
  raw="$(config_value "$file" push_check)"
  cfg_push="$(normalize_val "$raw")"
  raw="$(config_value "$file" test_path_regex)"
  raw="$(normalize_val "$raw")"
  [ -z "$raw" ] || cfg_test="$raw"
  raw="$(config_value "$file" live_recheck)"
  raw="$(normalize_val "$raw")"
  [ "$raw" = true ] && cfg_live=1
}

# Remote whose push URL equals the dry-run "To" line. Relative paths are
# resolved from the checkout. Nothing is printed when none match.
match_push_remote() { # match_push_remote REPO URL
  local repo="$1" url="$2" name="" pushurl="" a="" b=""
  [ -n "$url" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    pushurl="$(git -C "$repo" remote get-url --push "$name" 2>/dev/null || true)"
    [ -n "$pushurl" ] || continue
    if [ "$pushurl" = "$url" ]; then
      printf '%s\n' "$name"
      return 0
    fi
    a="$(cd "$repo" && cd "$pushurl" 2>/dev/null && pwd -P || true)"
    b="$(cd "$url" 2>/dev/null && pwd -P || true)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(git -C "$repo" remote 2>/dev/null || true)
}

# "@remote<TAB>name" when the dry-run names one, then "src<TAB>dst" per
# non-delete ref. Delete-only success prints no pair. Returns 1 if the
# dry-run failed (timeout, offline, no destination) so the caller can fall back.
porcelain_push_pairs() { # porcelain_push_pairs REPO REMOTE
  local repo="$1" remote="$2" out="" line="" flag="" rest="" pair="" from="" to=""
  local to_url="" resolved="" saw=0
  local -a cmd
  # --no-verify: this probe must not run the repo pre-push hook. A slow hook
  # would exhaust PUSH_DRY_RUN_TIMEOUT and hide remote.<name>.push.
  cmd=(git -C "$repo" -c color.ui=never push --dry-run --porcelain --no-verify)
  [ -n "$remote" ] && cmd+=("$remote")
  if command -v timeout >/dev/null 2>&1; then
    out="$(GIT_TERMINAL_PROMPT=0 timeout "$PUSH_DRY_RUN_TIMEOUT" "${cmd[@]}" 2>/dev/null)" || true
  else
    out="$(GIT_TERMINAL_PROMPT=0 "${cmd[@]}" 2>/dev/null)" || true
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      "To "*) to_url="${line#To }"; continue ;;
    esac
    flag="${line%%$'\t'*}"
    [ "$flag" = "$line" ] && continue
    rest="${line#*$'\t'}"
    pair="${rest%%$'\t'*}"
    case "$flag" in
      ' '|'*'|'+'|'='|'!'|'-') ;;
      *) continue ;;
    esac
    case "$pair" in
      *:*) ;;
      *) continue ;;
    esac
    saw=1
    [ "$flag" = "-" ] && continue
    from="${pair%%:*}"
    to="${pair#*:}"
    [ -n "$from" ] && [ -n "$to" ] || continue
    from="${from#refs/heads/}"
    to="${to#refs/heads/}"
    printf '%s\t%s\n' "$from" "$to"
  done <<< "$out"
  [ "$saw" -eq 1 ] || return 1
  resolved="$(match_push_remote "$repo" "$to_url")"
  [ -n "$resolved" ] && printf '@remote\t%s\n' "$resolved"
  return 0
}

# Helpers below read and write push_gate's locals.
normalize_push_endpoint() {
  if [ -z "$src" ] || [ "$src" = HEAD ]; then
    local branch=""
    branch="$(git -C "$top" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ -n "$branch" ]; then
      src="$branch"
    else
      src="$(git -C "$top" rev-parse --verify -q HEAD 2>/dev/null || true)"
    fi
  fi
  src="${src#refs/heads/}"
  if [ -z "$dst" ] || [ "$dst" = HEAD ]; then
    dst="$src"
  fi
  dst="${dst#refs/heads/}"
}

resolve_push_base() {
  tip="$src"
  base=""
  if [ -n "$tip" ] && git -C "$top" rev-parse --verify -q "$tip" >/dev/null; then
    if [ -n "$dst" ] && git -C "$top" rev-parse --verify -q "$remote/$dst" >/dev/null; then
      base="$remote/$dst"
    else
      local def=""
      def="$(origin_default "$top" || true)"
      if [ -n "$def" ]; then
        base="$(git -C "$top" merge-base "$tip" "$def" 2>/dev/null || true)"
      fi
    fi
  fi
  skip_push=0
  if [ -n "$base" ] && [ -n "$tip" ] && range_has_trailer "$top" "$base" "$tip" Push-Gate "$PUSH_SKIP_RE"; then
    skip_push=1
  fi
}

run_push_check() {
  # push_check does not need a branch or a diff. Resolution failure is not a skip.
  if [ "$skip_push" -eq 0 ] && [ -n "$cfg_push" ]; then
    check_rc=0
    if command -v timeout >/dev/null 2>&1; then
      (cd "$top" && timeout "$PUSH_CHECK_TIMEOUT" bash -c "$cfg_push") >/dev/null 2>&1 || check_rc=$?
    else
      (cd "$top" && bash -c "$cfg_push") >/dev/null 2>&1 || check_rc=$?
    fi
    if [ "$check_rc" -eq 124 ]; then
      block "push_check timed out"
    elif [ "$check_rc" -ne 0 ]; then
      block "push_check exited $check_rc"
    fi
  fi
}

run_deletion_gate() {
  if [ -z "$base" ]; then
    warn "cannot resolve the push range; allowing"
    return 0
  fi
  range_has_trailer "$top" "$base" "$tip" Test-Deletion "$TEST_JUST_RE" && return 0
  greprc=0
  printf 'x\n' | grep -Eq "$cfg_test" >/dev/null 2>&1 || greprc=$?
  if [ "$greprc" -gt 1 ]; then
    warn "invalid test_path_regex; skipping the test-deletion gate"
    return 0
  fi
  deleted="$(git -C "$top" diff -M --diff-filter=D --name-only "$base" "$tip" 2>/dev/null || true)"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if printf '%s\n' "$path" | grep -Eq "$cfg_test"; then
      block "deleted test file: $path"
    fi
  done <<< "$deleted"
  diff_text="$(git -C "$top" diff -M -U0 --no-color "$base" "$tip" 2>/dev/null || true)"
  removed=0
  added=0
  file_match=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '--- a/'*)
        path="${line#--- a/}"
        path="${path%%$'\t'*}"
        ;;
      '+++ b/'*)
        path="${line#+++ b/}"
        path="${path%%$'\t'*}"
        path="${path#\"}"
        path="${path%\"}"
        if printf '%s\n' "$path" | grep -Eq "$cfg_test"; then file_match=1; else file_match=0; fi
        ;;
      '+++ /dev/null'*)
        path="${path#\"}"
        path="${path%\"}"
        if printf '%s\n' "$path" | grep -Eq "$cfg_test"; then file_match=1; else file_match=0; fi
        ;;
      'diff --git '*|'@@'*|'index '*|'rename '*|'similarity '*|'new file '*|'deleted file '*|'old mode '*|'new mode '*|'Binary '*)
        ;;
      +*)
        [ "$file_match" -eq 1 ] || continue
        content="${line:1}"
        printf '%s\n' "$content" | grep -Eq "$DECL_RE" && added=$((added + 1))
        ;;
      -*)
        [ "$file_match" -eq 1 ] || continue
        content="${line:1}"
        printf '%s\n' "$content" | grep -Eq "$DECL_RE" && removed=$((removed + 1))
        ;;
    esac
  done <<< "$diff_text"
  if [ "$removed" -gt "$added" ]; then
    block "removed test declarations ($removed removed, $added added)"
  fi
}

# Every non-delete pair from one dry-run. push_check runs once.
push_many_pairs() {
  local i need=0
  local -a bases=() tips=()
  [ -n "$remote" ] || remote=origin
  for i in "${!pair_srcs[@]}"; do
    src="${pair_srcs[$i]}"
    dst="${pair_dsts[$i]}"
    normalize_push_endpoint
    resolve_push_base
    bases+=("$base")
    tips+=("$tip")
    [ "$skip_push" -eq 0 ] && need=1
  done
  if [ "$need" -eq 1 ]; then
    skip_push=0
  else
    skip_push=1
  fi
  run_push_check
  for i in "${!bases[@]}"; do
    base="${bases[$i]}"
    tip="${tips[$i]}"
    run_deletion_gate
  done
}

push_gate() { # push_gate INDEX
  local i="$1" repo remote src dst top base tip bodies deleted path removed added content file_match=0 counting=0
  local check_rc greprc skip_tests=0 diff_text line skip_push=0
  [ "${deletes[$i]}" = 1 ] && return 0
  if ! command -v git >/dev/null 2>&1; then
    warn "git not found; allowing push"
    return 0
  fi
  top="$(git -C "${repos[$i]}" rev-parse --show-toplevel 2>/dev/null)" || {
    warn "push target is not a git repository; allowing"
    return 0
  }
  remote="${remotes[$i]}"
  src="${srcs[$i]}"
  dst="${dsts[$i]}"
  load_repo_config "$top"
  # No refspec: dry-run porcelain names each local:remote pair (remote.<name>.push
  # and push.default). @{push} is only the fallback when that dry-run fails.
  # A delete-only result is not gated. An explicit refspec keeps the parsed names.
  local resolved_remote="" pairs_out="" pairs_rc=0 pline=""
  local -a pair_srcs=() pair_dsts=()
  if [ -z "$src" ]; then
    pairs_out="$(porcelain_push_pairs "$top" "$remote")" || pairs_rc=$?
    if [ "$pairs_rc" -eq 0 ]; then
      while IFS= read -r pline || [ -n "$pline" ]; do
        [ -n "$pline" ] || continue
        case "$pline" in
          @remote*)
            resolved_remote="${pline#@remote}"
            resolved_remote="${resolved_remote#$'\t'}"
            ;;
          *)
            pair_srcs+=("${pline%%$'\t'*}")
            pair_dsts+=("${pline#*$'\t'}")
            ;;
        esac
      done <<< "$pairs_out"
      if [ "${#pair_srcs[@]}" -eq 0 ]; then
        return 0
      fi
      if [ -z "$remote" ] && [ -n "$resolved_remote" ]; then
        remote="$resolved_remote"
      fi
      if [ "${#pair_srcs[@]}" -gt 1 ]; then
        push_many_pairs
        return
      fi
      src="${pair_srcs[0]}"
      dst="${pair_dsts[0]}"
    else
      local dest_line=""
      dest_line="$(plain_push_dest "$top" || true)"
      if [ -n "$dest_line" ]; then
        if [ -z "$remote" ]; then
          remote="${dest_line%%$'\t'*}"
        fi
        if [ -z "$dst" ]; then
          dst="${dest_line#*$'\t'}"
        fi
      fi
    fi
  fi
  if [ -z "$remote" ]; then
    remote=origin
  fi
  normalize_push_endpoint
  resolve_push_base
  run_push_check
  run_deletion_gate
}

close_gate() { # close_gate INDEX
  local i="$1" issue comment text gh_repo top view_issue
  top="$(git -C "${repos[$i]}" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || top="${repos[$i]}"
  load_repo_config "$top"
  [ "$cfg_live" -eq 1 ] || return 0
  comment="${comments[$i]}"
  if has_live_marker "$comment"; then
    return 0
  fi
  issue="${issues[$i]}"
  case "$issue" in
    *://*) view_issue="$issue" ;;
    *)
      view_issue="${issue##*/}"
      view_issue="${view_issue#\#}"
      [[ "$view_issue" =~ ^[0-9]+$ ]] || { warn "cannot parse the issue number; allowing close"; return 0; }
      ;;
  esac
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh not found; allowing issue close"
    return 0
  fi
  gh_repo="${gh_repos[$i]}"
  local -a gh_args=(issue view "$view_issue" --comments)
  [ -z "$gh_repo" ] || gh_args+=(--repo "$gh_repo")
  # The command's repo (after cd / git -C), not the hook process's directory.
  if ! text="$(cd "$top" && gh "${gh_args[@]}" 2>/dev/null)"; then
    warn "gh could not read issue $view_issue; allowing close"
    return 0
  fi
  if has_live_marker "$text"; then
    return 0
  fi
  block "gh issue close needs VERIFIED LIVE: <sha> or Live-Recheck: no-live-surface — <reason>"
}

input="$(cat || true)"
case "$input" in
  *push*|*close*) ;;
  *) exit 0 ;;
esac
if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found; allowing"
  exit 0
fi
command="$(printf '%s' "$input" | jq -r '.tool_input.command // .command // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$command" ] || exit 0

kind=none
kinds=()
repos=()
remotes=()
srcs=()
dsts=()
deletes=()
issues=()
comments=()
gh_repos=()
analyze_command "$command" "$cwd"
[ "$kind" != ambiguous ] || exit 0

if [ "${#kinds[@]}" -gt 0 ]; then
  for idx in "${!kinds[@]}"; do
    case "${kinds[$idx]}" in
      push) push_gate "$idx" ;;
      close) close_gate "$idx" ;;
    esac
  done
fi
exit 0
