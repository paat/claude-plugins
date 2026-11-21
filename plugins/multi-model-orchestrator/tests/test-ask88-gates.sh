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
grep -q '"version": "0.31.6"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" || fail 'plugin.json is not 0.31.6'
python3 - "$ROOT/.claude-plugin/marketplace.json" <<'PY' || fail 'marketplace.json multi-model-orchestrator is not 0.31.6'
import json, sys
data = json.load(open(sys.argv[1]))
hit = [p for p in data["plugins"] if p.get("name") == "multi-model-orchestrator"]
sys.exit(0 if len(hit) == 1 and hit[0].get("version") == "0.31.6" else 1)
PY
pass 'hooks, README, and version 0.31.6 are wired'

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
printf 'gh %s\n' "\$*" >> "$TOOLLOG"
if [ "\${GH_RC:-0}" != 0 ]; then
  printf 'gh failed\n' >&2
  exit "\$GH_RC"
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
    | env -u GH_RC -u GH_VIEW PATH="$S:$PATH" "$@" bash "$GATES" >"$T/hook.out" 2>"$T/hook.err" || got=$?
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

git -C "$REPO" commit --allow-empty -qm $'Push-Gate: skip — ci is down'
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'push_check exited' 'Push-Gate skip allows a failing push_check'
git -C "$REPO" commit --allow-empty -qm $'Push-Gate: skip - hyphen also counts'
# The previous skip commit is still in the range, so this only locks the hyphen form
# once that commit is published and the range is the hyphen commit alone.
publish
git -C "$REPO" commit --allow-empty -qm $'Push-Gate: skip - hyphen also counts'
hook 0 'git push' "$REPO"
absent "$T/hook.err" 'push_check exited' 'a hyphen Push-Gate skip allows the push'
pass 'Push-Gate skip trailer is honored inside the push range'

# A trailer already on origin/main is outside the range.
publish
git -C "$REPO" commit --allow-empty -qm 'ordinary follow-up'
hook 2 'git push' "$REPO"
contains "$T/hook.err" 'push_check exited 3' 'a skip trailer already on the remote does not apply'
pass 'Push-Gate skip outside the push range does not apply'

# No remote-tracking base: fail open, and do not run push_check.
NOR="$T/noremote"
mkdir -p "$NOR"
git init -q -b main "$NOR"
git -C "$NOR" config user.email t@t
git -C "$NOR" config user.name t
printf 'base\n' > "$NOR/README.md"
git -C "$NOR" add README.md && git -C "$NOR" commit -qm base
mkdir -p "$NOR/.claude"
printf -- '---\npush_check: exit 3\n---\n' > "$NOR/.claude/multi-model-orchestrator.local.md"
hook 0 'git push' "$NOR"
contains "$T/hook.err" 'cannot resolve the push range' 'an unresolvable range warns'
absent "$T/hook.err" 'push_check exited' 'an unresolvable range does not run push_check'
pass 'ship gates fail open when the push range cannot be resolved'

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

# Live recheck is opt-in.
make_repo live
write_cfg 'live_recheck: true'
hook 2 'gh issue close 7' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'close without a live marker blocks'
grep -q 'gh issue view' "$TOOLLOG" || fail "close without a marker did not read the issue: $(cat "$TOOLLOG")"
hook 2 'gh issue close 7 --comment "VERIFIED LIVE: abcdef"' "$REPO"
contains "$T/hook.err" 'VERIFIED LIVE:' 'a SHA shorter than 7 hex digits blocks'
hook_nogh 'gh issue close 7 --comment "VERIFIED LIVE: abcdef1"' "$REPO"
hook_nogh 'gh issue close 7 -c "Live-Recheck: no-live-surface — no deploy"' "$REPO"
hook 0 'gh issue close 7' "$REPO" GH_VIEW=$'earlier note\nVERIFIED LIVE: deadbee\n'
grep -q 'gh issue view' "$TOOLLOG" || fail 'an existing comment was not read'
hook 0 'gh issue close 7' "$REPO" GH_RC=1
contains "$T/hook.err" 'could not read issue' 'gh read failure warns'
absent "$T/hook.err" 'needs VERIFIED LIVE:' 'gh read failure does not block'
write_cfg 'live_recheck: false'
hook_nogh 'gh issue close 7' "$REPO"
pass 'live recheck is opt-in and accepts a SHA, a prior comment, or no-live-surface'

# --- worker preflight through pool.sh ---
P="$T/pool"
mkdir -p "$P/bin" "$P/calls" "$P/home" "$P/safe"
cat > "$P/bin/agy" <<'STUB'
#!/usr/bin/env bash
n=$(find "$STUB_AGY_CALLS" -name 'call.*.args' | wc -l)
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
impl 'task' STUB_AGY_TOUCH="$WREPO/new.txt"
[ "$rc" -eq 56 ] || fail "uncommitted want 56 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'check=uncommitted' 'uncommitted names the check'
contains "$T/pool.err" 'dirty worktree after a worker exit 0' 'uncommitted names the cause'
contains "$T/pool.err" 'pool: exit=56' 'pool reports exit 56'
[ -f "$WREPO/new.txt" ] || fail 'the worker file was not created'
rm -f "$WREPO/new.txt"
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
impl $'Do not edit any other path or commit.' STUB_AGY_TOUCH="$WREPO/left.txt"
[ "$rc" -eq 0 ] || fail "orchestrate no-commit sentence want 0 got $rc: $(cat "$T/pool.err")"
absent "$T/pool.err" 'check=uncommitted' 'orchestrate no-commit sentence stays exit 0'
clean_work
impl $'Commit on `feat/x` when your leg'"'"'s contract permits committing; otherwise leave the tree uncommitted — the orchestrator commits.' \
  STUB_AGY_TOUCH="$WREPO/tpl.txt"
[ "$rc" -eq 0 ] || fail "worker template want 0 got $rc: $(cat "$T/pool.err")"
absent "$T/pool.err" 'check=uncommitted' 'worker template leaves the tree uncommitted'
clean_work
impl $'Do not broaden scope or commit.\nCommit on the branch.' STUB_AGY_TOUCH="$WREPO/must.txt"
[ "$rc" -eq 56 ] || fail "unconditional Commit on want 56 got $rc: $(cat "$T/pool.err")"
contains "$T/pool.err" 'check=uncommitted' 'Commit on without the contract clause still requires a commit'
pass 'no-commit contracts skip check=uncommitted unless Commit on is unconditional'

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
pass 'leg --out is excluded from the uncommitted check'

printf 'ask88 gates: %s passed\n' "$passes"
