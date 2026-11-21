#!/usr/bin/env bash
# ASK-88: worker preflight (pool implement) and ship gates (git push / gh issue close).
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
POOL="$PLUGIN_ROOT/scripts/pool.sh"
GATES="$PLUGIN_ROOT/hooks/ship-gates.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
unset MMO_ALLOW_DIRTY MMO_ALLOW_REDO MMO_ALLOW_UNCOMMITTED
export GIT_TERMINAL_PROMPT=0

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; passes=$((passes + 1)); }
passes=0

contains() { grep -F -- "$2" "$1" >/dev/null || fail "$3: $(cat "$1")"; }
absent() { ! grep -F -- "$2" "$1" >/dev/null || fail "$3: $(cat "$1")"; }

# --- static wiring ---
grep -q '"PreToolUse"' "$PLUGIN_ROOT/hooks/hooks.json" || fail 'hooks.json has no PreToolUse'
grep -q '"Bash"' "$PLUGIN_ROOT/hooks/hooks.json" || fail 'hooks.json Bash matcher missing'
grep -q 'hooks/ship-gates.sh' "$PLUGIN_ROOT/hooks/hooks.json" || fail 'hooks.json does not run ship-gates.sh'
grep -q '"timeout": 300' "$PLUGIN_ROOT/hooks/hooks.json" || fail 'ship-gates timeout is not 300'
grep -q 'CODEX_PLUGIN_ROOT' "$PLUGIN_ROOT/hooks/hooks.json" || fail 'hooks.json omits the Codex plugin root'
grep -q 'CLAUDE_PLUGIN_ROOT:-' "$PLUGIN_ROOT/hooks/hooks.json" || fail 'hooks.json root fallback is not ${VAR:-}'
grep -q 'push_check' "$PLUGIN_ROOT/README.md" || fail 'README omits push_check'
grep -q 'test_path_regex' "$PLUGIN_ROOT/README.md" || fail 'README omits test_path_regex'
grep -q 'live_recheck' "$PLUGIN_ROOT/README.md" || fail 'README omits live_recheck'
grep -q 'MMO_ALLOW_DIRTY' "$PLUGIN_ROOT/README.md" || fail 'README omits MMO_ALLOW_DIRTY'
grep -q 'MMO_ALLOW_REDO' "$PLUGIN_ROOT/README.md" || fail 'README omits MMO_ALLOW_REDO'
grep -q 'MMO_ALLOW_UNCOMMITTED' "$PLUGIN_ROOT/README.md" || fail 'README omits MMO_ALLOW_UNCOMMITTED'
grep -q 'VERIFIED LIVE:' "$PLUGIN_ROOT/README.md" || fail 'README omits VERIFIED LIVE:'
grep -q -- '--worker-commits' "$PLUGIN_ROOT/README.md" || fail 'README omits --worker-commits'
grep -F 'pass `--worker-commits` when the packet assigns the commit to the worker' \
  "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" \
  || fail 'dispatch omits when to pass --worker-commits'
pass 'hooks and README are wired'

# --- ship gates ---
REAL_GIT="$(command -v git)"
S="$T/shipbin"
mkdir -p "$S"
TOOLLOG="$T/toollog"
: > "$TOOLLOG"
cat > "$S/git" <<EOF
#!/bin/bash
printf 'git %s\n' "\$*" >> "$TOOLLOG"
exec "$REAL_GIT" "\$@"
EOF
cat > "$S/gh" <<EOF
#!/bin/bash
printf 'cwd %s\n' "\$PWD" >> "$TOOLLOG"
printf 'gh %s\n' "\$*" >> "$TOOLLOG"
if [ "\${GH_RC:-0}" != 0 ]; then
  printf 'gh failed\n' >&2
  exit "\$GH_RC"
fi
target=cwd
prev=""
for a in "\$@"; do
  case "\$prev" in
    --repo|-R) target="\$a" ;;
  esac
  case "\$a" in
    --repo=*) target="\${a#--repo=}" ;;
  esac
  prev="\$a"
done
printf 'gh target=%s\n' "\$target" >> "$TOOLLOG"
if [ "\$target" != cwd ]; then
  printf '%s\n' "\${GH_REPO_VIEW-}"
  exit 0
fi
case " \$* " in
  *" http://"*|*" https://"*)
    printf '%s\n' "\${GH_URL_VIEW-}"
    exit 0
    ;;
esac
if [ -f "\$PWD/gh-view.txt" ]; then
  cat "\$PWD/gh-view.txt"
  exit 0
fi
printf '%s\n' "\${GH_VIEW:-}"
exit 0
EOF
chmod +x "$S/git" "$S/gh"

hook() { # hook WANT CMD CWD [env assignments...]
  local want="$1" cmd="$2" cwd="$3" got=0
  shift 3
  : > "$TOOLLOG"
  jq -n --arg c "$cmd" --arg d "$cwd" '{tool_input:{command:$c},cwd:$d}' \
    | env -u GH_RC -u GH_VIEW -u GH_URL_VIEW PATH="$S:$PATH" "$@" bash "$GATES" >"$T/hook.out" 2>"$T/hook.err" || got=$?
  [ "$got" -eq "$want" ] || fail "hook want $want got $got for [$cmd]: $(cat "$T/hook.err")"
}
hook_quiet() {
  hook 0 "$1" "$2"
  [ ! -s "$TOOLLOG" ] || fail "command called git or gh: $1 -- $(cat "$TOOLLOG")"
  [ ! -s "$T/hook.err" ] || fail "unexpected stderr for [$1]: $(cat "$T/hook.err")"
}
# issue close may rev-parse to find config; it must not call gh unless live_recheck is on.
hook_nogh() {
  hook 0 "$1" "$2" "${@:3}"
  ! grep -q '^gh ' "$TOOLLOG" || fail "command called gh: $1 -- $(cat "$TOOLLOG")"
  [ ! -s "$T/hook.err" ] || fail "unexpected stderr for [$1]: $(cat "$T/hook.err")"
}

make_repo() { # sets REPO to a main branch whose origin/main matches HEAD
  local name="$1"
  REPO="$T/repos/$name"
  local bare="$T/bares/$name.git"
  mkdir -p "$REPO"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  printf 'base\n' > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -qm base
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$bare"
  git -C "$REPO" remote add origin "$bare"
  git -C "$REPO" push -q origin HEAD:main
  git -C "$REPO" rev-parse --verify -q origin/main >/dev/null || fail "origin/main missing in $name"
}
write_cfg() { # write_cfg TEXT  (frontmatter body; file is untracked)
  mkdir -p "$REPO/.claude"
  printf -- '---\n%s\n---\n' "$1" > "$REPO/.claude/multi-model-orchestrator.local.md"
}
commit_repo() { git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1"; }
publish() { git -C "$REPO" push -q origin HEAD:main; }

make_repo push
write_cfg 'push_check: exit 3'
hook_quiet 'echo hello' "$REPO"
hook_quiet 'git status' "$REPO"
hook_quiet 'echo "git push"' "$REPO"
hook_quiet 'git push "' "$REPO"
hook_quiet 'git push --all' "$REPO"
hook_quiet 'git push origin --delete stale' "$REPO"
hook_quiet 'gh pr merge 1' "$REPO"
hook_nogh 'gh issue close 9' "$REPO" # live_recheck is not set
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'push_check exited 3' 'a failing push_check blocks'
hook 2 "git -C $REPO push" /tmp
contains "$T/hook.err" 'push_check exited 3' 'git -C from another cwd still blocks'
hook 2 "cd $REPO && git push" /tmp
contains "$T/hook.err" 'push_check exited 3' 'cd && git push is the same push'
pass 'ship gates ignore other commands and block a failing push_check'

git -C "$REPO" commit --allow-empty -qm $'ci\n\nPush-Gate: skip — ci is down'
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'push_check exited' 'Push-Gate skip allows a failing push_check'
git -C "$REPO" commit --allow-empty -qm $'hyphen subject\n\nPush-Gate: skip - hyphen also counts'
# The previous skip commit is still in the range, so this only locks the hyphen form
# once that commit is published and the range is the hyphen commit alone.
publish
git -C "$REPO" commit --allow-empty -qm $'hyphen\n\nPush-Gate: skip - hyphen also counts'
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'push_check exited' 'a hyphen Push-Gate skip allows the push'
pass 'Push-Gate skip trailer is honored inside the push range'

# A trailer already on origin/main is outside the range.
publish
git -C "$REPO" commit --allow-empty -qm 'ordinary follow-up'
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'push_check exited 3' 'a skip trailer already on the remote does not apply'
pass 'Push-Gate skip outside the push range does not apply'

# The phrase in a subject is not a trailer, so a failing push_check still blocks.
git -C "$REPO" commit --allow-empty -qm $'Push-Gate: skip — maintenance\n\nThe subject documents the phrase.'
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'push_check exited 3' 'a subject that mentions Push-Gate skip does not waive push_check'
pass 'Push-Gate skip in a subject is not a trailer'

# No remote-tracking base: the diff cannot be attributed, but push_check still runs.
NOR="$T/noremote"
mkdir -p "$NOR"
git init -q -b main "$NOR"
git -C "$NOR" config user.email t@t
git -C "$NOR" config user.name t
printf 'base\n' > "$NOR/README.md"
git -C "$NOR" add README.md && git -C "$NOR" commit -qm base
mkdir -p "$NOR/.claude"
printf -- '---\npush_check: exit 23\n---\n' > "$NOR/.claude/multi-model-orchestrator.local.md"
hook 2 'git push' "$NOR"
contains "$T/hook.err" 'push_check exited 23' 'push_check runs when the push range cannot be resolved'
pass 'push_check runs without a resolved push range'

# Test deletion. push_check stays failing; deletion cases that must reach the
# diff either omit it or carry a Push-Gate skip so the deletion decision is visible.
make_repo tests
mkdir -p "$REPO/tests"
printf 'it("keep", () => {})\nit("drop", () => {})\n' > "$REPO/tests/foo.test.js"
commit_repo 'add test'
publish
rm "$REPO/tests/foo.test.js"
commit_repo $'drop the test\n\nPush-Gate: skip — not a test excuse'
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'deleted test file: tests/foo.test.js' 'a deleted test file blocks'
absent "$T/hook.err" 'push_check exited' 'Push-Gate skip does not waive a deleted test'
pass 'deleted test file blocks even with a Push-Gate skip'

publish
# restore a test, publish, then rename
printf 'it("keep", () => {})\n' > "$REPO/tests/foo.test.js"
commit_repo 'restore test'
publish
git -C "$REPO" mv tests/foo.test.js tests/bar.test.js
commit_repo 'rename test'
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'deleted test file' 'a rename is not a deleted test'
pass 'a test rename is not a deletion'

publish
printf 'it("keep", () => {})\nit("drop", () => {})\n' > "$REPO/tests/decl.test.js"
commit_repo 'two decls'
publish
printf 'it("keep", () => {})\n' > "$REPO/tests/decl.test.js"
commit_repo 'drop one decl'
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'removed test declarations' 'net removal of it( blocks'
pass 'net removal of test declarations blocks'

publish
rm "$REPO/tests/decl.test.js"
commit_repo $'delete decl test\n\nTest-Deletion: justified — covered elsewhere'
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'deleted test file' 'Test-Deletion justified allows the deletion'
pass 'Test-Deletion justified allows a deleted test'

publish
printf 'it("z", () => {})\n' > "$REPO/tests/subj.test.js"
commit_repo 'add subj'
publish
rm "$REPO/tests/subj.test.js"
commit_repo $'Test-Deletion: justified — maintenance\n\nThe subject is not a trailer.'
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'deleted test file: tests/subj.test.js' 'a subject Test-Deletion does not waive a deleted test'
pass 'Test-Deletion in a subject is not a trailer'

publish
rm "$REPO/README.md"
commit_repo 'drop readme'
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'deleted test file' 'a non-test deletion is allowed'
pass 'deleting a non-test file is allowed'

publish
printf 'it("x", () => {})\n' > "$REPO/tests/only.test.js"
commit_repo 'only'
publish
rm "$REPO/tests/only.test.js"
commit_repo 'drop only'
write_cfg 'test_path_regex: "^nomatch$"'
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'deleted test file' 'test_path_regex can exclude a path'
pass 'test_path_regex override skips an unmatched deletion'

write_cfg 'test_path_regex: "["'
hook 0 'git push' "$REPO"
contains "$T/hook.err" 'invalid test_path_regex' 'an invalid test regex warns'
absent "$T/hook.err" 'deleted test file' 'an invalid test regex does not block'
pass 'an invalid test_path_regex fails open'

# Body keys are not config. Publish first so an earlier deletion is not still in range.
publish
printf -- '---\n---\npush_check: exit 9\nlive_recheck: true\n' > "$REPO/.claude/multi-model-orchestrator.local.md"
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'push_check exited' 'a body push_check is ignored'
hook_nogh 'gh issue close 4' "$REPO"
pass 'config keys outside frontmatter are ignored'

# Plain git push follows @{push} (push.default), not the upstream branch.
make_repo plain
mkdir -p "$REPO/tests"
printf 'it("keep", () => {})\n' > "$REPO/tests/keep.test.js"
commit_repo 'add test'
publish
git -C "$REPO" checkout -q -b topic
git -C "$REPO" branch -u origin/main
git -C "$REPO" config push.default current
rm "$REPO/tests/keep.test.js"
commit_repo 'drop test on topic'
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'deleted test file: tests/keep.test.js' 'plain git push checks the push destination, not upstream'
hook 2 'git push origin topic' "$REPO"
contains "$T/hook.err" 'deleted test file: tests/keep.test.js' 'an explicit refspec still blocks the deleted test'
pass 'plain git push uses the push destination'

# Named remote, no refspec. push.default=upstream sends integration to topic.
# origin/integration already has the deletion, so the branch name is the wrong base.
make_repo remotespec
mkdir -p "$REPO/tests"
printf 'it("keep", () => {})\n' > "$REPO/tests/keep.test.js"
commit_repo 'add test'
publish
git -C "$REPO" branch topic
git -C "$REPO" push -q origin topic
git -C "$REPO" checkout -q -b integration
rm "$REPO/tests/keep.test.js"
commit_repo 'drop test on integration'
git -C "$REPO" push -q origin integration
git -C "$REPO" branch -u origin/topic
git -C "$REPO" config push.default upstream
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'deleted test file: tests/keep.test.js' 'plain push with push.default=upstream checks topic'
hook 2 'git push origin integration:topic' "$REPO"
contains "$T/hook.err" 'deleted test file: tests/keep.test.js' 'an explicit refspec to topic still blocks'
hook 2 'git push origin' "$REPO"
contains "$T/hook.err" 'deleted test file: tests/keep.test.js' 'a named remote without a refspec uses the push destination'
pass 'a named remote without a refspec resolves the push destination'

# Detached HEAD. push_check must run; an explicit HEAD is that commit.
make_repo detach
write_cfg 'push_check: exit 23'
git -C "$REPO" checkout -q --detach
hook 2 'git push origin HEAD:refs/heads/topic' "$REPO"
contains "$T/hook.err" 'push_check exited 23' 'detached HEAD runs push_check for an explicit HEAD refspec'
absent "$T/hook.err" 'cannot resolve the branch being pushed' 'detached HEAD is resolved as a commit'
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'push_check exited 23' 'plain push from detached HEAD runs push_check'
pass 'push_check runs from a detached HEAD'

make_repo detachdel
mkdir -p "$REPO/tests"
printf 'it("keep", () => {})\n' > "$REPO/tests/keep.test.js"
commit_repo 'add test'
publish
rm "$REPO/tests/keep.test.js"
commit_repo 'drop test'
git -C "$REPO" checkout -q --detach
hook 2 'git push origin HEAD:refs/heads/topic' "$REPO"
contains "$T/hook.err" 'deleted test file: tests/keep.test.js' 'detached HEAD attributes the commit being pushed'
pass 'an explicit HEAD refspec is the commit at HEAD'

# A test added on the default branch after the fork is not a deletion on the new branch.
make_repo fork
git -C "$REPO" checkout -q -b topic
git -C "$REPO" checkout -q main
mkdir -p "$REPO/tests"
printf 'it("later", () => {})\n' > "$REPO/tests/later.test.js"
commit_repo 'add test on main'
publish
git -C "$REPO" checkout -q topic
printf 'more\n' >> "$REPO/README.md"
commit_repo 'topic addition'
hook 0 'git push origin topic' "$REPO"
absent "$T/hook.err" 'deleted test file' 'a test added on the default branch after the fork is not deleted by the topic'
pass 'a new branch is attributed from the merge base'

# Live recheck is opt-in.
make_repo live
write_cfg 'live_recheck: true'
hook 2 'gh issue close 7' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'close without a live marker blocks'
grep -q 'gh issue view' "$TOOLLOG" || fail "close without a marker did not read the issue: $(cat "$TOOLLOG")"
hook 2 'gh issue close 7 --comment "VERIFIED LIVE: abcdef"' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'a SHA shorter than 7 hex digits blocks'
hook 2 'gh issue close 7 --comment "VERIFIED LIVE: succeeded"' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'hex inside an ordinary word is not a SHA'
hook 2 'gh issue close 7 --comment "VERIFIED LIVE: prefixdeadbee1"' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'a hex token must stand alone'
sha41="$(printf 'a%.0s' {1..41})"
hook 2 "gh issue close 7 --comment \"VERIFIED LIVE: $sha41\"" "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'a hex token longer than 40 digits is not a SHA'
sha40="$(printf 'b%.0s' {1..40})"
hook_nogh "gh issue close 7 --comment \"VERIFIED LIVE: $sha40\"" "$REPO"
hook_nogh 'gh issue close 7 --comment "VERIFIED LIVE: abcdef1"' "$REPO"
hook_nogh 'gh issue close 7 -c "Live-Recheck: no-live-surface — no deploy"' "$REPO"
hook 0 'gh issue close 7' "$REPO" GH_VIEW=$'earlier note\nVERIFIED LIVE: deadbee\n'
grep -q 'gh issue view' "$TOOLLOG" || fail 'an existing comment was not read'
hook 2 'gh issue close 7' "$REPO" GH_VIEW=$'VERIFIED LIVE: pending\nrollback deadbee1\n'
contains "$T/hook.err" 'VERIFIED LIVE:' 'a marker and a SHA on different lines do not combine'
hook 2 $'gh issue close 7 --comment "VERIFIED LIVE: pending\ndeadbee1"' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'a multiline close comment needs the marker and SHA on one line'
LIVE="$REPO"
make_repo other
OTHER="$REPO"
write_cfg 'live_recheck: true'
printf 'no marker\n' > "$OTHER/gh-view.txt"
hook 2 "cd $OTHER && gh issue close 123" "$LIVE" GH_VIEW=$'VERIFIED LIVE: deadbee1\n'
contains "$T/hook.err" 'VERIFIED LIVE:' 'a marker in the starting directory does not satisfy the target repo'
grep -F "cwd $OTHER" "$TOOLLOG" || fail "gh did not run in the target repo: $(cat "$TOOLLOG")"
hook 2 'gh issue close https://github.com/acme/widgets/issues/123' "$LIVE" \
  GH_VIEW=$'VERIFIED LIVE: deadbee1\n' GH_URL_VIEW='no marker'
contains "$T/hook.err" 'VERIFIED LIVE:' 'an issue URL is not looked up as a bare number'
grep -F 'https://github.com/acme/widgets/issues/123' "$TOOLLOG" || fail "issue URL was not preserved: $(cat "$TOOLLOG")"
REPO="$LIVE"
hook 0 'gh issue close 7' "$REPO" GH_RC=1
contains "$T/hook.err" 'could not read issue' 'gh read failure warns'
absent "$T/hook.err" 'needs VERIFIED LIVE:' 'gh read failure does not block'
write_cfg 'live_recheck: false'
hook_nogh 'gh issue close 7' "$REPO"
pass 'live recheck is opt-in and accepts a SHA, a prior comment, or no-live-surface'
# Checkout evidence must not satisfy a close aimed at another repository.
write_cfg 'live_recheck: true'
printf 'VERIFIED LIVE: deadbee1\n' > "$REPO/gh-view.txt"
hook 2 'GH_REPO=acme/widgets gh issue close 9' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'GH_REPO= is the issue repository for the evidence lookup'
grep -F 'gh target=acme/widgets' "$TOOLLOG" || fail "GH_REPO was not passed to gh: $(cat "$TOOLLOG")"
hook 2 'gh -R acme/widgets issue close 9' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' '-R is the issue repository for the evidence lookup'
grep -F 'gh target=acme/widgets' "$TOOLLOG" || fail "-R was not passed to gh: $(cat "$TOOLLOG")"
hook 0 'GH_REPO=acme/widgets gh issue close 9' "$REPO" GH_REPO_VIEW=$'VERIFIED LIVE: cafebae\n'
grep -F 'gh target=acme/widgets' "$TOOLLOG" || fail "evidence lookup ignored GH_REPO: $(cat "$TOOLLOG")"
pass 'GH_REPO= and -R select the issue repository for the evidence lookup'
pass 'live recheck keeps the target repo, the issue URL, and one evidence line'

# --- worker preflight through pool.sh ---
P="$T/pool"
mkdir -p "$P/bin" "$P/calls" "$P/home" "$P/safe"
cat > "$P/bin/agy" <<'STUB'
#!/usr/bin/env bash
n=$(find "$STUB_AGY_CALLS" -name 'call.*.args' | wc -l)
cat > "$STUB_AGY_CALLS/call.$n.stdin"
printf '%s\n' "$@" > "$STUB_AGY_CALLS/call.$n.args"
printf '%s\n' '{"event":"init","init":{}}'
case "$*" in *"${STUB_AGY_TOUCH_MODEL:-}"*) [ -z "${STUB_AGY_TOUCH:-}" ] || printf 'touched\n' >> "$STUB_AGY_TOUCH" ;; esac
jq -cn --arg r "${STUB_AGY_RESPONSE:-done

APPROVE}" '{event:"result",result:{status:"SUCCESS",response:$r}}'
STUB
cat > "$P/bin/gh" <<EOF
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$T/ghlog"
if [ "\${GH_RC:-0}" != 0 ]; then
  exit "\$GH_RC"
fi
printf '%s\n' "\${GH_OUT:-}"
exit 0
EOF
chmod +x "$P/bin/agy" "$P/bin/gh"
# A PATH with no gh. /bin itself contains gh, so the directory is only symlinks.
mkdir -p "$P/nogh"
for tool in bash env git jq timeout cksum find wc mktemp sed tr grep head tail cat cp date \
  realpath xargs dirname basename tee touch chmod rm mkdir ln ls stat cut paste awk uname id; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sfn "$src" "$P/nogh/$tool"
done
ln -sfn "$P/bin/agy" "$P/nogh/agy"
printf 'T2\tagy\tgemini-3.8-flash\tlow\n' > "$P/tiers.tsv"
printf 'T2\tagy\tclaude-opus-5-5\thigh\n' > "$P/review-tiers.tsv"
GHLOG="$T/ghlog"
POOL_EXTRA=()

worker_repo() { # fresh committed repo in $WREPO
  local name="$1"
  WREPO="$T/work/$name"
  mkdir -p "$WREPO"
  git init -q -b main "$WREPO"
  git -C "$WREPO" config user.email t@t
  git -C "$WREPO" config user.name t
  printf 'one\n' > "$WREPO/README.md"
  git -C "$WREPO" add README.md
  git -C "$WREPO" commit -qm base
}
clean_work() {
  git -C "$WREPO" checkout -q -- .
  git -C "$WREPO" clean -fdq
}
calls_n() { find "$P/calls" -name 'call.*.args' 2>/dev/null | wc -l | tr -d ' '; }
impl() { # impl PROMPT [env...]   uses WREPO and POOL_EXTRA
  local prompt="$1"
  shift
  rm -rf "$P/calls"
  mkdir -p "$P/calls"
  : > "$GHLOG"
  rc=0
  printf '%s\n' "$prompt" | env -u MMO_ALLOW_DIRTY -u MMO_ALLOW_REDO -u MMO_ALLOW_UNCOMMITTED \
    -u STUB_AGY_TOUCH -u STUB_AGY_TOUCH_MODEL -u STUB_AGY_FAIL_MODEL -u STUB_AGY_RESPONSE \
    -u GH_RC -u GH_OUT \
    HOME="$P/home" PATH="$P/bin:/usr/bin:/bin" MMO_LEG_ENV='STUB_*' \
    MMO_POOL_TIERS="$P/tiers.tsv" STUB_AGY_CALLS="$P/calls" \
    MMO_OUTCOMES_FILE="$T/outcomes.tsv" MMO_LEG_CHECKS_FILE="$T/leg-checks.tsv" \
    "$@" \
    bash "$POOL" run --tier T2 --usage /dev/null --repo "$WREPO" --timeout 30 \
    "${POOL_EXTRA[@]}" >"$T/pool.out" 2>"$T/pool.err" || rc=$?
  POOL_EXTRA=()
}

worker_repo main
printf 'dirt\n' >> "$WREPO/README.md"
impl 'implement the task'
[ "$rc" -eq 56 ] || fail "dirty implement want 56 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'check=preflight' 'dirty implement names check=preflight'
contains "$T/pool.err" 'dirty worktree' 'dirty implement names the worktree'
[ "$(calls_n)" = 0 ] || fail 'dirty implement must not exec a runner'
impl 'Do not broaden scope or commit.' MMO_ALLOW_DIRTY='keeping local notes'
[ "$rc" -eq 0 ] || fail "MMO_ALLOW_DIRTY want 0 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'MMO_ALLOW_DIRTY=keeping local notes' 'dirty escape prints the reason'
[ "$(calls_n)" = 1 ] || fail 'MMO_ALLOW_DIRTY did not reach the runner'
printf 'dirt\n' >> "$WREPO/README.md"
impl 'task' MMO_ALLOW_DIRTY='   '
[ "$rc" -eq 56 ] || fail "blank MMO_ALLOW_DIRTY want 56 got $rc: $(cat "$T/pool.err")"
[ "$(calls_n)" = 0 ] || fail 'a blank dirty escape must not run'
pass 'dirty implement blocks unless MMO_ALLOW_DIRTY has a reason'

clean_work
git -C "$WREPO" remote add origin git@github.com:example/fixture.git
POOL_EXTRA=(--task 12)
impl 'task' GH_OUT='{"state":"closed"}'
[ "$rc" -eq 56 ] || fail "closed issue want 56 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'issue 12 is CLOSED' 'closed issue names the issue'
[ "$(calls_n)" = 0 ] || fail 'a closed issue must not exec a runner'
grep -q 'issue view' "$GHLOG" || fail 'closed issue did not query gh'
POOL_EXTRA=(--task 12)
impl 'task' GH_OUT='{"state":"closed"}' MMO_ALLOW_REDO='the close was wrong'
[ "$rc" -ne 56 ] || fail "MMO_ALLOW_REDO still blocked: $(cat "$T/pool.err")"
contains "$T/pool.err" 'MMO_ALLOW_REDO=the close was wrong' 'redo escape prints the reason'
[ "$(calls_n)" = 1 ] || fail 'MMO_ALLOW_REDO did not reach the runner'
POOL_EXTRA=(--task 12)
impl 'task' GH_OUT='{"state":"OPEN"}'
[ "$rc" -ne 56 ] || fail "open issue blocked: $(cat "$T/pool.err")"
[ "$(calls_n)" = 1 ] || fail 'an open issue did not run'
contains "$T/pool.err" 'check=no_change' 'an open issue still runs the no-op leg check'
POOL_EXTRA=(--task 12)
impl 'task' GH_RC=1
[ "$rc" -ne 56 ] || fail "gh failure blocked: $(cat "$T/pool.err")"
contains "$T/pool.err" 'gh could not read issue 12' 'gh failure warns'
[ "$(calls_n)" = 1 ] || fail 'gh failure did not continue'
POOL_EXTRA=(--task ASK-88)
impl 'task' GH_OUT='{"state":"closed"}'
[ "$rc" -ne 56 ] || fail "non-numeric task blocked: $(cat "$T/pool.err")"
[ ! -s "$GHLOG" ] || fail "non-numeric task called gh: $(cat "$GHLOG")"
[ "$(calls_n)" = 1 ] || fail 'non-numeric task did not run'
# No GitHub remote: numeric task does not call gh and does not warn.
worker_repo noremote
POOL_EXTRA=(--task 4)
impl 'task' GH_OUT='{"state":"closed"}'
[ "$rc" -ne 56 ] || fail "missing remote blocked: $(cat "$T/pool.err")"
[ ! -s "$GHLOG" ] || fail "missing remote called gh: $(cat "$GHLOG")"
absent "$T/pool.err" 'leg-preflight: warning' 'missing remote stays silent'
[ "$(calls_n)" = 1 ] || fail 'missing remote did not run'
# gh binary absent. /bin/gh exists here, so the PATH is only the symlink dir.
worker_repo nogh
git -C "$WREPO" remote add origin git@github.com:example/fixture.git
POOL_EXTRA=(--task 5)
impl 'task' PATH="$P/nogh"
[ "$rc" -ne 56 ] || fail "missing gh blocked: $(cat "$T/pool.err")"
contains "$T/pool.err" 'gh not found' 'missing gh warns'
[ "$(calls_n)" = 1 ] || fail "missing gh did not continue (rc=$rc): $(cat "$T/pool.err")"
pass 'closed issues block; open, non-numeric, missing remote, and gh failure do not'

worker_repo dirt
POOL_EXTRA=(--worker-commits)
impl 'task' STUB_AGY_TOUCH="$WREPO/new.txt"
[ "$rc" -eq 56 ] || fail "uncommitted want 56 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'check=uncommitted' 'uncommitted names the check'
contains "$T/pool.err" 'dirty worktree after a worker exit 0' 'uncommitted names the cause'
contains "$T/pool.err" 'pool: exit=56' 'pool reports exit 56'
[ -f "$WREPO/new.txt" ] || fail 'the worker file was not created'
rm -f "$WREPO/new.txt"
POOL_EXTRA=(--worker-commits)
impl 'task' STUB_AGY_TOUCH="$WREPO/new2.txt" MMO_ALLOW_UNCOMMITTED='orchestrator commits next'
[ "$rc" -eq 0 ] || fail "MMO_ALLOW_UNCOMMITTED want 0 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'MMO_ALLOW_UNCOMMITTED=orchestrator commits next' 'uncommitted escape prints the reason'
tail -n 1 "$T/pool.err" | grep -q 'pool: exit=0 ' || fail "escape should finish exit 0: $(tail -n 1 "$T/pool.err")"
pass 'a worker exit 0 on a dirty tree is check=uncommitted unless escaped'

clean_work
printf 'review dirt\n' >> "$WREPO/README.md"
POOL_EXTRA=(--mode review --base HEAD)
impl 'review it' MMO_POOL_TIERS="$P/review-tiers.tsv"
[ "$rc" -ne 56 ] || fail "review on a dirty tree blocked: $(cat "$T/pool.err")"
[ "$(calls_n)" = 1 ] || fail 'review did not run'
absent "$T/pool.err" 'check=preflight' 'review does not preflight'
POOL_EXTRA=()
rc=0
env HOME="$P/home" PATH="$P/bin:/usr/bin:/bin" MMO_POOL_TIERS="$P/tiers.tsv" \
  bash "$POOL" pick --tier T2 --usage /dev/null >"$T/pick.out" 2>"$T/pick.err" || rc=$?
[ "$rc" -eq 0 ] || fail "pick on a dirty tree failed: $(cat "$T/pick.err")"
absent "$T/pick.err" 'preflight' 'pick is not preflighted'
pass 'review and pick ignore a dirty tree'

clean_work
POOL_EXTRA=(--allow-paths 'README.md' --verify-cmd true --task 88 --cycle 2)
impl $'Update README.md to rename the button from Commit on save to Save changes.\nDo not edit any other path or commit.' \
  STUB_AGY_TOUCH="$WREPO/README.md"
[ "$rc" -eq 0 ] || fail "orchestrator-commits want 0 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'check=pass' 'the same contract without --worker-commits is check=pass'
absent "$T/pool.err" 'check=uncommitted' 'Commit on save does not require a worker commit'
grep -F 'Do not broaden scope or commit.' "$P/calls/call.0.stdin" >/dev/null \
  || fail "default worker prompt should forbid commit: $(cat "$P/calls/call.0.stdin")"
clean_work
POOL_EXTRA=(--worker-commits --allow-paths 'README.md' --verify-cmd true --task 88 --cycle 2)
impl $'Document how the orchestrator commits changes.' STUB_AGY_TOUCH="$WREPO/README.md"
[ "$rc" -eq 56 ] || fail "worker-commits want 56 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'check=uncommitted' '--worker-commits enforces a commit despite the prompt text'
grep -F 'Commit your changes.' "$P/calls/call.0.stdin" >/dev/null \
  || fail "worker-commits prompt should say to commit: $(cat "$P/calls/call.0.stdin")"
grep -F 'Do not broaden scope or commit.' "$P/calls/call.0.stdin" >/dev/null \
  && fail 'worker-commits prompt still forbids commit'
pass '--worker-commits, not the prompt text, decides who commits'

clean_work
printf '*.log\n' > "$WREPO/.gitignore"
git -C "$WREPO" add .gitignore && git -C "$WREPO" commit -qm 'ignore logs'
printf 'noise\n' > "$WREPO/noise.log"
impl 'task'
[ "$rc" -eq 0 ] || fail "gitignored file want 0 got $rc: $(cat "$T/pool.err")"
[ "$(calls_n)" = 1 ] || fail 'a gitignored file blocked dispatch'
mkdir -p "$WREPO/.git/info"
printf '*.tmp\n' >> "$WREPO/.git/info/exclude"
printf 'x\n' > "$WREPO/secret.tmp"
impl 'task'
[ "$rc" -eq 0 ] || fail "info/exclude file want 0 got $rc: $(cat "$T/pool.err")"
[ "$(calls_n)" = 1 ] || fail 'an info/exclude file blocked dispatch'
pass 'gitignore and info/exclude do not trip preflight'

clean_work
POOL_EXTRA=(--out "$WREPO/leg.out")
impl 'task'
[ "$rc" -eq 0 ] || fail "leg --out want 0 got $rc: $(cat "$T/pool.err")"
[ -f "$WREPO/leg.out" ] || fail 'runner did not write --out'
absent "$T/pool.err" 'check=uncommitted' 'a leg --out is not uncommitted work'
printf 'stream\n' > "$WREPO/leg.out.stream"
POOL_EXTRA=(--out "$WREPO/leg.out")
impl 'task'
[ "$rc" -eq 0 ] || fail "retry with the same --out want 0 got $rc: $(cat "$T/pool.err")"
[ "$(calls_n)" = 1 ] || fail 'an existing --out blocked dispatch'
absent "$T/pool.err" 'check=preflight' 'preflight excludes --out and its sidecars'
pass 'leg --out is excluded from the uncommitted check and from preflight'

printf 'ask88 gates: %s passed\n' "$passes"
