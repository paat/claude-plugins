#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/repo" "$WORK/tmp"
export TMPDIR="$WORK/tmp"
REAL_GROK="${MMO_TEST_REAL_GROK:-$(command -v grok || true)}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
contains() { grep -F -- "$2" "$1" >/dev/null || fail "$3"; }
absent() { ! grep -F -- "$2" "$1" >/dev/null || fail "$3"; }

git -C "$WORK/repo" init -q
git -C "$WORK/repo" config user.email test@example.com
git -C "$WORK/repo" config user.name Test
printf 'before\n' > "$WORK/repo/app.txt"
git -C "$WORK/repo" add app.txt
git -C "$WORK/repo" commit -qm base
printf 'after\n' > "$WORK/repo/app.txt"

cat > "$WORK/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_CODEX_ARGS"
out=""
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out="$2"; shift 2; continue; }
  shift
done
cat > "$STUB_CODEX_PROMPT"
case "${STUB_CODEX_RESULT:-ok}" in
  empty) : > "$out" ;;
  progress) : > "$out"; printf 'I will inspect the diff.\n' ;;
  noverdict) printf 'codex-final\n' > "$out" ;;
  *) printf 'codex-final APPROVE\n' > "$out" ;;
esac
STUB
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_CLAUDE_ARGS"
cat > "$STUB_CLAUDE_PROMPT"
case "${STUB_CLAUDE_RESULT:-ok}" in
  empty) exit 0 ;;
  progress) printf 'I will inspect the diff.\n' ;;
  *) printf 'claude-final APPROVE\n' ;;
esac
STUB
cat > "$WORK/bin/grok" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_GROK_ARGS"
printf '%s\n' "$HOME" > "$STUB_GROK_HOME_ENV"
printf '%s\n' "$GROK_HOME" > "$STUB_GROK_DIR_ENV"
[ ! -f "$GROK_HOME/config.toml" ] || cp "$GROK_HOME/config.toml" "$STUB_GROK_CONFIG"
[ "${STUB_GROK_REFRESH:-0}" != 1 ] || printf '{"key":"new"}\n' > "$GROK_HOME/auth.json"
prompt=""
while [ "$#" -gt 0 ]; do
  [ "$1" = --prompt-file ] && { prompt="$2"; shift 2; continue; }
  shift
done
[ -n "$prompt" ] && cat "$prompt" > "$STUB_GROK_PROMPT"
case "${STUB_GROK_RESULT:-ok}" in
  empty) exit 0 ;;
  progress) printf 'Let me inspect the files.\n' ;;
  *) printf 'grok-final APPROVE\n' ;;
esac
STUB
chmod +x "$WORK/bin/codex" "$WORK/bin/claude" "$WORK/bin/grok"
export PATH="$WORK/bin:$PATH"
export STUB_CODEX_ARGS="$WORK/codex.args" STUB_CODEX_PROMPT="$WORK/codex.prompt"
export STUB_CLAUDE_ARGS="$WORK/claude.args" STUB_CLAUDE_PROMPT="$WORK/claude.prompt"
export STUB_GROK_ARGS="$WORK/grok.args" STUB_GROK_PROMPT="$WORK/grok.prompt"
export STUB_GROK_HOME_ENV="$WORK/grok.home-env" STUB_GROK_DIR_ENV="$WORK/grok.dir-env"
export STUB_GROK_CONFIG="$WORK/grok.config"
export GROK_HOME="$WORK/host-grok"
mkdir -p "$GROK_HOME"

out="$(printf 'bounded review\n' | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" --effort ultra --timeout 5 2> "$WORK/codex.err")"
[ "$out" = 'codex-final APPROVE' ] || fail 'Codex final output'
contains "$WORK/codex.args" 'gpt-5.6-sol' 'Codex model pin'
contains "$WORK/codex.args" 'model_reasoning_effort="ultra"' 'Codex Ultra pin'
contains "$WORK/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'Codex unrestricted posture'
contains "$WORK/codex.prompt" 'bounded review' 'Codex stdin prompt'
pass 'Codex runner pins Sol Ultra and stdin prompt'

if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --effort extreme >/dev/null 2>&1; then
  fail 'invalid Codex effort rejected'
fi
pass 'Codex runner rejects unknown effort'

if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-5.5 >/dev/null 2>&1; then
  fail 'earlier Codex model rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --dir "$WORK/repo" --model gpt-5.6-terra --effort ultra >/dev/null 2>&1; then
  fail 'Ultra on non-Sol model rejected'
fi
pass 'Codex runner enforces the GPT-5.6 catalog and Sol-only Ultra'

if printf x | STUB_CODEX_RESULT=empty "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --dir "$WORK/repo" >/dev/null 2>&1; then
  fail 'Codex empty success rejected'
fi
if printf x | STUB_CODEX_RESULT=progress "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" >/dev/null 2>&1; then
  fail 'Codex progress-only review rejected'
fi
if printf x | STUB_CODEX_RESULT=noverdict "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --dir "$WORK/repo" >/dev/null 2>&1; then
  fail 'Codex verdict-free review rejected'
fi
pass 'Codex rejects empty or verdict-free success'

out="$(printf 'acceptance criterion\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD --model claude-opus-5 --effort xhigh --timeout 5 2> "$WORK/claude.err")"
[ "$out" = 'claude-final APPROVE' ] || fail 'Claude final output'
contains "$WORK/claude.args" 'claude-opus-5' 'Claude Opus 5 model pin'
contains "$WORK/claude.args" 'xhigh' 'Opus effort pin'
contains "$WORK/claude.args" '--dangerously-skip-permissions' 'Claude YOLO posture'
contains "$WORK/claude.args" 'Bash,Write,Edit,NotebookEdit,Task,WebFetch,WebSearch' 'Opus mutation tools disabled'
contains "$WORK/claude.prompt" 'acceptance criterion' 'Opus review task'
contains "$WORK/claude.prompt" '+after' 'Opus receives diff'
pass 'Claude review is current-model pinned, bounded, and diff-aware'

printf 'new file\n' > "$WORK/repo/new.txt"
printf 'review new file\n' | "$PLUGIN_ROOT/scripts/run-opus.sh" --mode review --repo "$WORK/repo" --base HEAD --timeout 5 >/dev/null 2> "$WORK/opus-untracked.err"
contains "$WORK/claude.prompt" 'new.txt' 'Opus receives untracked file diff'
contains "$WORK/claude.args" 'claude-opus-5' 'Compatibility wrapper pins Opus 5'
pass 'Opus compatibility wrapper uses Opus 5 and includes untracked files'

printf 'architecture question\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-sonnet-5 --effort high --timeout 5 >/dev/null 2> "$WORK/claude-advice.err"
contains "$WORK/claude.prompt" 'architecture question' 'Opus advice prompt'
contains "$WORK/claude.prompt" 'Do not implement' 'Opus advice no-write contract'
pass 'Claude advice stays bounded and read-only'

printf 'implementation task\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode implement --repo "$WORK/repo" --model claude-sonnet-5 --effort high --timeout 5 >/dev/null 2> "$WORK/claude-implement.err"
contains "$WORK/claude.args" 'Read,Glob,Grep,Bash,Write,Edit' 'Claude implementation tools enabled'
contains "$WORK/claude.args" 'Task,WebFetch,WebSearch,NotebookEdit' 'Claude implementation fan-out and network tools disabled'
contains "$WORK/claude.args" '--dangerously-skip-permissions' 'Claude implementation YOLO posture'
contains "$WORK/claude.prompt" 'implementation task' 'Claude implementation task packet'
pass 'Claude implementation is writable, single-agent, and unrestricted'

printf 'quick file map\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-4-5 --timeout 5 >/dev/null 2> "$WORK/haiku.err"
contains "$WORK/claude.args" 'claude-haiku-4-5' 'Haiku current model pin'
absent "$WORK/claude.args" '--effort' 'Haiku must omit unsupported effort flag'
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-4-5 --effort low >/dev/null 2>&1; then
  fail 'explicit Haiku effort rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-opus-4-8 >/dev/null 2>&1; then
  fail 'earlier Claude model rejected'
fi
pass 'Claude runner enforces the current catalog and Haiku effort compatibility'

out="$(printf 'bounded implementation\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode implement --repo "$WORK/repo" --model grok-4.5 --effort medium --timeout 5 2> "$WORK/grok.err")"
[ "$out" = 'grok-final APPROVE' ] || fail 'Grok final output'
contains "$WORK/grok.args" 'grok-4.5' 'Grok 4.5 model pin'
contains "$WORK/grok.args" '--reasoning-effort' 'Grok effort flag'
contains "$WORK/grok.args" 'medium' 'Grok medium effort pin'
contains "$WORK/grok.args" '--no-subagents' 'Grok worker fan-out disabled'
contains "$WORK/grok.args" '--max-turns' 'Grok turn cap flag'
contains "$WORK/grok.args" '30' 'Grok default turn cap'
contains "$WORK/grok.args" '--sandbox' 'Grok sandbox flag'
contains "$WORK/grok.args" 'none' 'Grok unrestricted sandbox'
contains "$WORK/grok.args" '--permission-mode' 'Grok permission mode flag'
contains "$WORK/grok.args" 'bypassPermissions' 'Grok YOLO permission mode'
contains "$WORK/grok.prompt" 'bounded implementation' 'Grok receives task packet'
contains "$WORK/grok.config" '[compat.claude]' 'Grok isolated config disables Claude compatibility'
contains "$WORK/grok.config" 'skills = false' 'Grok isolated config disables inherited skills'
[ "$(cat "$WORK/grok.home-env")" = "$HOME" ] || fail 'Grok implementation preserves toolchain HOME'
[ "$(cat "$WORK/grok.dir-env")" != "$GROK_HOME" ] || fail 'Grok config isolation'
if printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4 >/dev/null 2>&1; then
  fail 'earlier Grok model rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --effort xhigh >/dev/null 2>&1; then
  fail 'unsupported Grok effort rejected'
fi
pass 'Grok runner pins 4.5 and enforces low-to-high effort'

out="$(printf 'review Grok diff\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --effort high --timeout 5 2> "$WORK/grok-review.err")"
[ "$out" = 'grok-final APPROVE' ] || fail 'Grok review output'
contains "$WORK/grok.args" '--tools' 'Grok review tools restriction'
contains "$WORK/grok.args" 'read_file,list_dir,grep' 'Grok review read-only tools'
contains "$WORK/grok.prompt" '+after' 'Grok review receives diff'
[ "$(cat "$WORK/grok.home-env")" != "$HOME" ] || fail 'Grok review HOME isolation'
if printf x | MMO_REVIEW_DIFF_MAX_BYTES=1 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD >/dev/null 2>&1; then
  fail 'Grok review diff cap enforced'
fi
pass 'Grok review is diff-aware, bounded, and read-only'

grok_log=''
while IFS= read -r line; do
  case "$line" in
    *' log='*) grok_log="${line##* log=}" ;;
  esac
done < "$WORK/grok.err"
[ -n "$grok_log" ] && [ -f "$grok_log" ] || fail 'Grok reported log persists after cleanup'
[ -f "${grok_log}.stderr" ] || fail 'Grok stderr log persists after cleanup'
rm -f "$grok_log" "${grok_log}.stderr"
pass 'Grok reports persistent diagnostic logs'

printf '{"key":"old"}\n' > "$GROK_HOME/auth.json"
mkdir "$GROK_HOME/auth.json.lockdir"
printf '99999999\n' > "$GROK_HOME/auth.json.lockdir/pid"
printf 'refresh auth\n' | STUB_GROK_REFRESH=1 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth.err"
contains "$GROK_HOME/auth.json" '"new"' 'Grok refreshed auth copied back after stale lock recovery'
[ ! -e "$GROK_HOME/auth.json.lockdir" ] || fail 'Grok stale auth lock removed'
pass 'Grok recovers stale auth locks safely'

if printf x | STUB_CLAUDE_RESULT=empty "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" >/dev/null 2>&1; then
  fail 'Claude empty success rejected'
fi
if printf x | STUB_CLAUDE_RESULT=progress "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD >/dev/null 2>&1; then
  fail 'Claude progress-only review rejected'
fi
if printf x | STUB_GROK_RESULT=empty "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" >/dev/null 2>&1; then
  fail 'Grok empty success rejected'
fi
if printf x | STUB_GROK_RESULT=progress "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD >/dev/null 2>&1; then
  fail 'Grok progress-only review rejected'
fi
pass 'Claude and Grok reject empty or verdict-free success'

out="$(printf 'legacy alias\n' | MMO_OPUS_MODEL=opus "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --timeout 5 2> "$WORK/legacy-opus.err")"
[ "$out" = 'claude-final APPROVE' ] || fail 'Legacy Opus alias output'
contains "$WORK/claude.args" 'claude-opus-5' 'Legacy Opus alias maps to Opus 5'
pass 'Legacy Opus alias maps only to the current model'

printf 'primary config\n' | MMO_CLAUDE_MODEL=claude-sonnet-5 MMO_CLAUDE_EFFORT=xhigh "$PLUGIN_ROOT/scripts/run-opus.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/primary-config.err"
contains "$WORK/claude.args" 'claude-sonnet-5' 'Compatibility wrapper preserves primary model config'
contains "$WORK/claude.args" 'xhigh' 'Compatibility wrapper preserves primary effort config'
pass 'Opus wrapper does not override primary Claude configuration'

contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$claude_pid"' 'Orchestration checks Claude reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$sol_pid"' 'Orchestration checks Codex reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$grok_pid"' 'Orchestration checks Grok reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'review_failed' 'Orchestration refuses arbitration after reviewer failure'
pass 'Orchestration preserves each parallel reviewer exit status'

if [ -n "$REAL_GROK" ]; then
  real_grok_help="$($REAL_GROK --help 2>&1)"
  for flag in --reasoning-effort --sandbox --permission-mode --max-turns --no-subagents --prompt-file --tools --output-format --no-memory --disable-web-search --cwd; do
    case "$real_grok_help" in
      *"$flag"*) ;;
      *) fail "installed Grok CLI lacks $flag" ;;
    esac
  done
  case "$real_grok_help" in
    *bypassPermissions*) ;;
    *) fail 'installed Grok CLI lacks bypassPermissions mode' ;;
  esac
  "$REAL_GROK" --sandbox none --permission-mode bypassPermissions --no-subagents inspect >/dev/null
  pass 'Installed Grok CLI parses the runner posture and supports its flags'
else
  printf 'SKIP: installed Grok CLI flag smoke test\n'
fi

printf 'All multi-model-orchestrator tests passed.\n'
