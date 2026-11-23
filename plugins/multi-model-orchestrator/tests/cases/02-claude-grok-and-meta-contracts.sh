#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.


out="$(printf 'acceptance criterion\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode review --repo "$WORK/repo" --base HEAD --model claude-opus-5 --effort xhigh --timeout 5 2> "$WORK/claude.err")"
[ "$out" = $'claude findings\nAPPROVE' ] || fail 'Claude final output'
exact_line "$WORK/claude.args" 'claude-opus-5' 'explicit prior-generation pin'
contains "$WORK/claude.args" 'xhigh' 'Opus effort pin'
contains "$WORK/claude.args" '--dangerously-skip-permissions' 'Claude YOLO posture'
contains "$WORK/claude.args" 'Bash,Write,Edit,NotebookEdit,Task,WebFetch,WebSearch' 'Opus mutation tools disabled'
exact_line "$WORK/claude.args" '--strict-mcp-config' 'Claude keeps strict MCP config'
exact_line "$WORK/claude.args" '{"mcpServers":{}}' 'Claude default MCP config stays empty'
absent "$WORK/claude.args" 'mcp__' 'Claude default allowed tools omit MCP servers'
contains "$WORK/claude.prompt" 'acceptance criterion' 'Opus review task'
contains "$WORK/claude.prompt" '+after' 'Opus receives diff'
pass 'Claude review is current-model pinned, bounded, and diff-aware'

printf 'new file\n' > "$WORK/repo/new.txt"
printf 'review new file\n' | "$PLUGIN_ROOT/scripts/run-opus.sh" --mode review --repo "$WORK/repo" --base HEAD --timeout 5 >/dev/null 2> "$WORK/opus-untracked.err"
contains "$WORK/claude.prompt" 'new.txt' 'Opus receives untracked file diff'
exact_line "$WORK/claude.args" 'claude-opus-5-5' 'Compatibility wrapper pins Opus 5.5'
pass 'Opus compatibility wrapper uses Opus 5.5 and includes untracked files'

printf 'architecture question\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 >/dev/null 2> "$WORK/claude-advice.err"
contains "$WORK/claude.prompt" 'architecture question' 'Opus advice prompt'
contains "$WORK/claude.prompt" 'Do not implement' 'Opus advice no-write contract'
pass 'Claude advice stays bounded and read-only'

printf 'implementation task\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode implement --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 >/dev/null 2> "$WORK/claude-implement.err"
contains "$WORK/claude.args" 'Read,Glob,Grep,Bash,Write,Edit' 'Claude implementation tools enabled'
contains "$WORK/claude.args" 'Task,WebFetch,WebSearch,NotebookEdit' 'Claude implementation fan-out and network tools disabled'
contains "$WORK/claude.args" '--dangerously-skip-permissions' 'Claude implementation YOLO posture'
contains "$WORK/claude.prompt" 'implementation task' 'Claude implementation task packet'
pass 'Claude implementation is writable, single-agent, and unrestricted'

printf 'quick file map\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-5-5 --timeout 5 >/dev/null 2> "$WORK/haiku.err"
contains "$WORK/claude.args" 'claude-haiku-5-5' 'Haiku current model pin'
absent "$WORK/claude.args" '--effort' 'Haiku must omit unsupported effort flag'
printf 'quick file map\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-4-5 --timeout 5 >/dev/null 2>&1 || fail 'prior-generation Haiku stays routable'
exact_line "$WORK/claude.args" 'claude-haiku-4-5' 'prior-generation Haiku pin'
absent "$WORK/claude.args" '--effort' 'prior-generation Haiku omits the effort flag'
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-haiku-5-5 --effort low >/dev/null 2>&1; then
  fail 'explicit Haiku effort rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-opus-4-8 >/dev/null 2>"$WORK/claude-unknown-model.err"; then
  fail 'earlier Claude model rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-opus >/dev/null 2>"$WORK/claude-partial-model.err"; then
  fail 'partial Claude model id rejected'
fi
if printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model 'claude-fable-5-1|claude-opus-5-5' >/dev/null 2>"$WORK/claude-pipe-model.err"; then
  fail 'pipe-joined Claude model ids rejected'
fi
contains "$WORK/claude-unknown-model.err" 'claude-fable-5-2|claude-fable-5-1|claude-opus-5-5|claude-sonnet-5-5|claude-fable-5|claude-opus-5|claude-sonnet-5|claude-haiku-5-5|claude-haiku-4-5' 'unsupported model lists the full catalog'
printf 'pin opus 5.5\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-opus-5-5 --effort high --timeout 5 >/dev/null 2>"$WORK/claude-opus55.err" \
  || fail 'claude-opus-5-5 accepted'
exact_line "$WORK/claude.args" 'claude-opus-5-5' 'claude-opus-5-5 pinned in args'
printf 'pin fable 5.1\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-fable-5-1 --effort max --timeout 5 >/dev/null 2>"$WORK/claude-fable51.err" \
  || fail 'claude-fable-5-1 accepted'
exact_line "$WORK/claude.args" 'claude-fable-5-1' 'claude-fable-5-1 pinned in args'
pass 'Claude runner enforces the current catalog and Haiku effort compatibility'

printf 'one mcp\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 \
  --mcp 'browseros=http://127.0.0.1:9200/mcp' >/dev/null 2>"$WORK/claude-mcp1.err" || fail 'one --mcp accepted'
exact_line "$WORK/claude.args" '--strict-mcp-config' 'one --mcp keeps strict MCP config'
exact_line "$WORK/claude.args" '{"mcpServers":{"browseros":{"type":"http","url":"http://127.0.0.1:9200/mcp"}}}' 'one --mcp config'
exact_line "$WORK/claude.args" 'Read,Glob,Grep,mcp__browseros' 'one --mcp advise allowedTools'
printf 'research mcp\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode research --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 \
  --mcp 'browseros=http://127.0.0.1:9200/mcp' >/dev/null 2>"$WORK/claude-mcp-research.err" || fail 'research --mcp accepted'
exact_line "$WORK/claude.args" 'WebSearch,WebFetch,mcp__browseros' 'research --mcp allowedTools'
printf 'two mcp\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode implement --repo "$WORK/repo" --model claude-sonnet-5-5 --effort high --timeout 5 \
  --mcp 'browseros=http://127.0.0.1:9200/mcp' \
  --mcp 'docs=http://127.0.0.1:9/mcp?q="a\b"' >/dev/null 2>"$WORK/claude-mcp2.err" || fail 'two --mcp accepted'
exact_line "$WORK/claude.args" '{"mcpServers":{"browseros":{"type":"http","url":"http://127.0.0.1:9200/mcp"},"docs":{"type":"http","url":"http://127.0.0.1:9/mcp?q=\"a\\b\""}}}' 'two --mcp config escapes URL'
exact_line "$WORK/claude.args" 'Read,Glob,Grep,Bash,Write,Edit,mcp__browseros,mcp__docs' 'two --mcp implement allowedTools'
reject_mcp() {
  rm -f "$WORK/claude.args"
  set +e
  printf x | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$WORK/repo" --model claude-sonnet-5-5 --mcp "$1" >/dev/null 2>"$WORK/claude-mcp-bad.err"
  local mcp_rc=$?
  set -e
  [ "$mcp_rc" -eq 2 ] || fail "$2 rc=$mcp_rc want 2"
  [ ! -f "$WORK/claude.args" ] || fail "$2 must not invoke claude"
  contains "$WORK/claude-mcp-bad.err" '--mcp' "$2 explains --mcp"
}
reject_mcp 'browseros' 'mcp missing equals'
reject_mcp '=http://127.0.0.1:9200/mcp' 'mcp empty name'
reject_mcp 'browseros=' 'mcp empty url'
reject_mcp 'bad name=http://127.0.0.1:9200/mcp' 'mcp invalid name'
pass 'Claude --mcp attaches named HTTP servers and rejects malformed values'

out="$(printf 'bounded implementation\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode implement --repo "$WORK/repo" --effort medium --timeout 5 2> "$WORK/grok.err")"
[ "$out" = $'grok findings\nAPPROVE' ] || fail 'Grok final output'
contains "$WORK/grok.args" 'grok-4.7' 'Grok default model pin'
contains "$WORK/grok.args" '--reasoning-effort' 'Grok effort flag'
contains "$WORK/grok.args" 'medium' 'Grok medium effort pin'
contains "$WORK/grok.args" '--no-subagents' 'Grok worker fan-out disabled'
contains "$WORK/grok.args" '--max-turns' 'Grok turn cap flag'
contains "$WORK/grok.args" '150' 'Grok implement default turn cap'
contains "$WORK/grok.args" '--sandbox' 'Grok sandbox flag'
contains "$WORK/grok.args" 'none' 'Grok unrestricted sandbox'
contains "$WORK/grok.args" '--permission-mode' 'Grok permission mode flag'
contains "$WORK/grok.args" 'bypassPermissions' 'Grok YOLO permission mode'
contains "$WORK/grok.prompt" 'bounded implementation' 'Grok receives task packet'
contains "$WORK/grok.config" '[compat.claude]' 'Grok isolated config disables Claude compatibility'
contains "$WORK/grok.config" 'skills = false' 'Grok isolated config disables inherited skills'
absent "$WORK/grok.args" '--tools' 'Grok implementation unexpectedly restricts tools'
absent "$WORK/grok.args" '--debug-file' 'Grok implementation unexpectedly requests allowlist debug evidence'
[ "$(cat "$WORK/grok.home-env")" = "$HOME" ] || fail 'Grok implementation preserves toolchain HOME'
[ "$(cat "$WORK/grok.dir-env")" != "$GROK_HOME" ] || fail 'Grok config isolation'
printf 'explicit 4.7\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.7 --effort medium --timeout 5 >/dev/null 2> "$WORK/grok-47.err" \
  || fail 'grok-4.7 accepted'
contains "$WORK/grok.args" 'grok-4.7' 'explicit grok-4.7 forwarded'
printf 'explicit 4.6\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.6 --effort medium --timeout 5 >/dev/null 2> "$WORK/grok-46.err" \
  || fail 'grok-4.6 accepted'
contains "$WORK/grok.args" 'grok-4.6' 'explicit grok-4.6 forwarded'
printf 'compat 4.5\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.5 --effort medium --timeout 5 >/dev/null 2> "$WORK/grok-45.err" \
  || fail 'grok-4.5 still accepted'
contains "$WORK/grok.args" 'grok-4.5' 'explicit grok-4.5 forwarded'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-9.9 >/dev/null 2> "$WORK/grok-unknown.err"
unknown_rc=$?
set -e
[ "$unknown_rc" -eq 2 ] || fail "unknown Grok model rc=$unknown_rc want 2"
contains "$WORK/grok-unknown.err" 'grok-4.7' 'unknown model error names grok-4.7'
contains "$WORK/grok-unknown.err" 'grok-4.6' 'unknown model error names grok-4.6'
contains "$WORK/grok-unknown.err" 'grok-4.5' 'unknown model error names grok-4.5'
[ ! -f "$WORK/grok.args" ] || fail 'unknown Grok model must not invoke grok'
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.5 --effort xhigh >/dev/null 2> "$WORK/grok-45-xhigh.err"
xhigh45_rc=$?
set -e
[ "$xhigh45_rc" -eq 2 ] || fail "grok-4.5+xhigh rc=$xhigh45_rc want 2"
contains "$WORK/grok-45-xhigh.err" 'low|medium|high' 'grok-4.5+xhigh names allowed efforts'
contains "$WORK/grok-45-xhigh.err" 'grok-4.5' 'grok-4.5+xhigh names the model'
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.5+xhigh must not invoke grok'
printf 'xhigh 4.6\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.6 --effort xhigh --timeout 5 >/dev/null 2> "$WORK/grok-46-xhigh.err" \
  || fail 'grok-4.6+xhigh accepted'
contains "$WORK/grok.args" 'grok-4.6' 'grok-4.6+xhigh forwards model'
contains "$WORK/grok.args" '--reasoning-effort' 'grok-4.6+xhigh forwards effort flag'
exact_line "$WORK/grok.args" 'xhigh' 'grok-4.6+xhigh passes xhigh through'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.6 --effort max >/dev/null 2> "$WORK/grok-46-max.err"
max46_rc=$?
set -e
[ "$max46_rc" -eq 2 ] || fail "grok-4.6+max rc=$max46_rc want 2"
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.6+max must not invoke grok'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.6 --effort ultra >/dev/null 2> "$WORK/grok-46-ultra.err"
ultra46_rc=$?
set -e
[ "$ultra46_rc" -eq 2 ] || fail "grok-4.6+ultra rc=$ultra46_rc want 2"
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.6+ultra must not invoke grok'
printf 'xhigh 4.7\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.7 --effort xhigh --timeout 5 >/dev/null 2> "$WORK/grok-47-xhigh.err" \
  || fail 'grok-4.7+xhigh accepted'
contains "$WORK/grok.args" 'grok-4.7' 'grok-4.7+xhigh forwards model'
exact_line "$WORK/grok.args" 'xhigh' 'grok-4.7+xhigh passes xhigh through'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.7 --effort max >/dev/null 2> "$WORK/grok-47-max.err"
max47_rc=$?
set -e
[ "$max47_rc" -eq 2 ] || fail "grok-4.7+max rc=$max47_rc want 2"
contains "$WORK/grok-47-max.err" 'grok-4.7' 'grok-4.7+max names the model'
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.7+max must not invoke grok'
rm -f "$WORK/grok.args"
set +e
printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4.7 --effort ultra >/dev/null 2> "$WORK/grok-47-ultra.err"
ultra47_rc=$?
set -e
[ "$ultra47_rc" -eq 2 ] || fail "grok-4.7+ultra rc=$ultra47_rc want 2"
[ ! -f "$WORK/grok.args" ] || fail 'grok-4.7+ultra must not invoke grok'
printf 'env model override\n' | MMO_GROK_MODEL=grok-4.5 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --effort medium --timeout 5 >/dev/null 2> "$WORK/grok-env-model.err" \
  || fail 'MMO_GROK_MODEL=grok-4.5 accepted'
contains "$WORK/grok.args" 'grok-4.5' 'MMO_GROK_MODEL override forwarded'
if printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --model grok-4 >/dev/null 2>&1; then
  fail 'earlier Grok model rejected'
fi
pass 'Grok runner defaults to 4.7 and enforces per-model efforts'

out="$(printf 'review Grok diff\n' | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$WORK/repo" --base HEAD --effort high --timeout 5 2> "$WORK/grok-review.err")"
[ "$out" = $'grok findings\nAPPROVE' ] || fail 'Grok review output'
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

# A lock directory with no pid file is stale only once it is older than a minute.
printf '{"key":"old"}\n' > "$GROK_HOME/auth.json"
mkdir "$GROK_HOME/auth.json.lockdir"; touch -d '5 minutes ago' "$GROK_HOME/auth.json.lockdir"
printf 'refresh auth\n' | STUB_GROK_REFRESH=1 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-nopid.err"
contains "$GROK_HOME/auth.json" '"new"' 'Grok refreshed auth written back past an old pid-less lock'
[ ! -e "$GROK_HOME/auth.json.lockdir" ] || fail 'Grok old pid-less auth lock removed'
printf '{"key":"old"}\n' > "$GROK_HOME/auth.json"
mkdir "$GROK_HOME/auth.json.lockdir"
printf 'refresh auth\n' | STUB_GROK_REFRESH=1 "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-fresh.err"
contains "$WORK/grok-auth-fresh.err" 'lock busy' 'Grok fresh pid-less lock reports lock busy'
contains "$GROK_HOME/auth.json" '"old"' 'Grok fresh pid-less lock blocks the write-back'
rmdir "$GROK_HOME/auth.json.lockdir"
pass 'Grok pid-less auth lock: stale after a minute, busy while fresh'

# Concurrent host refresh while a leg runs must not be clobbered by stale isolated auth.
printf '{"key":"start"}\n' > "$GROK_HOME/auth.json"
printf 'host race no isolated refresh\n' | \
  STUB_GROK_HOST_RACE=1 STUB_GROK_HOST_AUTH="$GROK_HOME/auth.json" \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-race.err"
contains "$GROK_HOME/auth.json" '"host-newer"' 'Grok host refresh survives when isolated did not refresh'
printf '{"key":"start"}\n' > "$GROK_HOME/auth.json"
printf 'host race with isolated refresh\n' | \
  STUB_GROK_HOST_RACE=1 STUB_GROK_HOST_AUTH="$GROK_HOME/auth.json" STUB_GROK_REFRESH=1 \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-race2.err"
contains "$GROK_HOME/auth.json" '"host-newer"' 'Grok host refresh not clobbered by stale isolated refresh'
absent "$GROK_HOME/auth.json" '"new"' 'Grok isolated refresh must not overwrite concurrent host value'
# No host auth at start: concurrent host creation during the leg must survive.
rm -f "$GROK_HOME/auth.json"
printf 'host appears mid-leg\n' | \
  STUB_GROK_HOST_RACE=1 STUB_GROK_HOST_AUTH="$GROK_HOME/auth.json" STUB_GROK_REFRESH=1 \
  "$PLUGIN_ROOT/scripts/run-grok.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/grok-auth-race3.err"
contains "$GROK_HOME/auth.json" '"host-newer"' 'Grok concurrent host create not clobbered when no start snapshot'
absent "$GROK_HOME/auth.json" '"new"' 'Grok isolated refresh must not overwrite mid-leg host create'
pass 'Grok auth writeback skips when host changed during the leg'

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
[ "$out" = $'claude findings\nAPPROVE' ] || fail 'Legacy Opus alias output'
exact_line "$WORK/claude.args" 'claude-opus-5-5' 'Legacy Opus alias maps to Opus 5.5'
pass 'Legacy Opus alias maps only to the current model'

printf 'primary config\n' | MMO_CLAUDE_MODEL=claude-sonnet-5-5 MMO_CLAUDE_EFFORT=xhigh "$PLUGIN_ROOT/scripts/run-opus.sh" --mode advise --repo "$WORK/repo" --timeout 5 >/dev/null 2> "$WORK/primary-config.err"
contains "$WORK/claude.args" 'claude-sonnet-5-5' 'Compatibility wrapper preserves primary model config'
contains "$WORK/claude.args" 'xhigh' 'Compatibility wrapper preserves primary effort config'
pass 'Opus wrapper does not override primary Claude configuration'

contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$claude_pid"' 'Orchestration checks Claude reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$astra_pid"' 'Orchestration checks Codex reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'wait "$grok_pid"' 'Orchestration checks Grok reviewer status'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'review_failed' 'Orchestration refuses arbitration after reviewer failure'
pass 'Orchestration preserves each parallel reviewer exit status'

contains "$PLUGIN_ROOT/commands/orchestrate.md" 'tribunal-review:closing-tribunal-loop' 'Orchestrate defaults final review to the tribunal flow'
contains "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" 'tribunal-review:closing-tribunal-loop' 'Orchestration skill defaults final review to the tribunal flow'
contains "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" 'Fallback' 'Orchestration skill keeps inline review as explicit fallback'
absent "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" 'tribunal-round' 'Orchestration skill references tribunal instead of duplicating its round protocol'
pass 'Orchestrate uses the closing-tribunal-loop flow by default'

# A bare `--leg <provider>=` placeholder (possibly line-wrapped) must never stand alone:
# every markdown doc showing it also carries the qualified agy leg note.
while IFS= read -r leg_doc; do
  joined="$(tr '\n' ' ' <"$leg_doc")"
  case "$joined" in
    *'--leg <provider>='*)
      case "$joined" in
        *'agy/claude-opus-5-5'*) ;;
        *) fail "doc shows bare --leg <provider>= without the agy qualification note: $leg_doc" ;;
      esac
      ;;
  esac
done < <(grep -rlF --include='*.md' -- '--leg' "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/README.md" || true)
pass 'No doc shows a bare --leg <provider>= without the agy qualification note'

META_CMD="$PLUGIN_ROOT/commands/meta-orchestrate.md"
META_SKILL="$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md"
META_REFS="$PLUGIN_ROOT/skills/meta-orchestration/references"
contains "$META_CMD" "Skill('multi-model-orchestrator:meta-orchestration')" 'Meta command invokes the meta-orchestration skill via the Skill tool'
contains "$META_CMD" 'allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill' 'Meta command allows the Skill tool'
contains "$META_SKILL" 'the summary is not authoritative' 'Meta skill re-anchors on the handoff after compaction'
contains "$PLUGIN_ROOT/README.md" '"autoCompactWindow": 500000' 'README documents the compaction cap'
contains "$META_CMD" '--resume' 'Meta command documents resume'
contains "$META_CMD" 'mission brief' 'Meta command takes a free-form what-to-achieve brief'
contains "$META_SKILL" 'HOW is yours' 'Meta skill owns the how; the brief owns the what'
contains "$META_SKILL" 'review-gate.sh --author <worker>' 'Meta skill gates with the worker as author'
contains "$META_SKILL" 'Hold the run lease' 'Meta skill holds the run lease'
contains "$META_REFS/handoff-template.md" 'handoff-lease.sh claim <owner>' 'Handoff template claims the lease'
contains "$META_REFS/handoff-template.md" 'Lease owner' 'Handoff template records the lease owner'
contains "$PLUGIN_ROOT/commands/orchestrate.md" '--author "$WORKER_PROVIDER"' 'Orchestrate passes the worker as gate author'
contains "$PLUGIN_ROOT/README.md" '--mode probe' 'README documents probe mode'
contains "$PLUGIN_ROOT/README.md" 'handoff-lease.sh' 'README documents the handoff lease'
contains "$META_SKILL" 'only on a gate exit of 0' 'Meta skill merges only on a gate exit of 0'
absent "$META_SKILL" 'READY TO MERGE' 'Meta skill no longer relies on a literal merge line'
contains "$META_SKILL" 'route-model-task' 'Meta skill routes via route-model-task'
contains "$META_SKILL" 'any research memo for the item' 'Meta skill feeds research memos into the worker packet'
contains "$META_SKILL" 'tribunal-review:closing-tribunal-loop' 'Meta skill chains the tribunal close-out'
contains "$META_SKILL" '124' 'Meta skill keeps the exit-124 salvage rule'
contains "$META_SKILL" 'not a liveness check' 'Meta skill keeps the transcript-mtime liveness rule'
contains "$META_SKILL" 'exit marker' 'Meta skill names exit marker in the liveness rule'
contains "$META_SKILL" 'never `pgrep`' 'Meta skill forbids pgrep for liveness'
contains "$META_SKILL" 'references/leg-liveness.md' 'Meta skill points at the leg-liveness reference'
[ -f "$META_REFS/leg-liveness.md" ] || fail 'Leg liveness reference exists'
contains "$META_REFS/leg-liveness.md" 'echo $?' 'Leg liveness reference names the exit-marker write'
contains "$META_REFS/leg-liveness.md" 'out.exit' 'Leg liveness reference names the out.exit example'
contains "$META_REFS/leg-liveness.md" 'never `pgrep`' 'Leg liveness reference forbids pgrep'
contains "$META_REFS/leg-liveness.md" '75 (EX_TEMPFAIL)' 'Leg liveness reference names exit 75 transient rule'
contains "$META_REFS/leg-liveness.md" '77 (EX_NOPERM)' 'Leg liveness reference names exit 77 auth rule'
contains "$META_REFS/leg-liveness.md" 'Wait at least 60s' 'Leg liveness reference requires 60s wait before transient retry'
contains "$META_REFS/leg-liveness.md" 'OPERATOR ACTIONS REQUIRED' 'Leg liveness reference queues auth under operator actions'
contains "$META_SKILL" 'failure exits 75/77' 'Meta skill points at failure exits in leg-liveness'
absent "$META_REFS/leg-liveness.md" 'queue.json' 'Leg liveness reference does not introduce queue.json'
contains "$META_SKILL" 'references/handoff-template.md' 'Meta skill instantiates the handoff template'
contains "$META_SKILL" 'write nothing and stop' 'Meta skill makes a no-op scan near-zero cost'
contains "$META_SKILL" 'multi-model-orchestrator.local.md' 'Meta skill reads per-repo source/model config'
contains "$META_SKILL" 'apply to the tribunal panel' 'Meta skill exempts the tribunal panel from leg model constraints'
contains "$META_SKILL" 'unresearched' 'Meta skill distinguishes unresearched unknowns from human decisions'
contains "$META_SKILL" 'completion re-invokes the orchestrator' 'Meta skill requires a completion path back to the orchestrator'
contains "$META_SKILL" 'run_in_background: true' 'Meta skill names the Claude Code completion mechanism'
contains "$META_SKILL" 'never use bare shell `&`' 'Meta skill forbids bare shell backgrounding'
contains "$META_SKILL" 'Start every turn by reading any unread dispatched-leg output' 'Meta skill reads unread leg output at turn start'
contains "$META_SKILL" 'resume at the gate' 'Meta skill resumes completed legs at their gate'
contains "$META_SKILL" 'a defect, not a wait' 'Meta skill rejects ending a turn with an unarranged live leg'
contains "$META_SKILL" 'immediately before every dispatch' 'Meta skill writes the handoff immediately before every dispatch'
[ "$(grep -cF 'immediately before every dispatch' "$META_SKILL")" -eq 1 ] || fail 'Meta skill states immediately before every dispatch exactly once'
contains "$META_SKILL" 'Once the queue is ordered, and again' 'Meta skill writes the handoff once the queue is ordered and again before dispatch'
contains "$META_SKILL" 'git rev-parse --git-path info/exclude' 'Meta skill excludes the handoff dir via git rev-parse --git-path'
contains "$META_SKILL" 'never commit it during the run' 'Meta skill never commits the handoff during the run'
contains "$META_SKILL" 'Handoff is local — never commit it during the run' 'Meta skill names the handoff as the local, uncommitted file'
contains "$META_SKILL" 'git ls-files -- "${MMO_HANDOFF_DIR:-.claude/handoffs}"' 'Meta skill detects already-tracked handoff files via git ls-files'
contains "$META_SKILL" 'git rm -r --cached' 'Meta skill queues untrack as git rm -r --cached'
contains "$META_SKILL" 'write new handoffs under fresh names' 'Meta skill writes new handoffs under fresh names when the dir is tracked'
contains "$META_REFS/handoff-template.md" "Write rules: see the skill's Preflight and Handoff discipline (handoffs are local; never commit them)" 'Handoff template write rules say handoffs are local and never committed'
absent "$META_REFS/handoff-template.md" 'Write/commit rules' 'Handoff template drops Write/commit'
contains "$META_SKILL" 'write the final handoff; close the epic' 'Meta skill writes the final handoff locally at close-out'
contains "$META_SKILL" 'browser QA + UX' 'Meta skill keeps browser QA in the strategy A close-out'
absent "$META_SKILL" 'commit it on the epic branch' 'Meta skill never commits a handoff, even at close-out'
absent "$META_SKILL" 'git add -f <handoff>' 'Meta skill has no handoff commit command'
contains "$META_SKILL" 'repo-relative' 'Meta skill states the handoff dir is repo-relative'
contains "$PLUGIN_ROOT/README.md" 'Repo-relative' 'README states MMO_HANDOFF_DIR is a repo-relative directory'
absent "$META_SKILL" 'Strategy B: never commit it' 'Meta skill no longer splits handoff commits as strategy B never-commit'
absent "$META_SKILL" '.git/info/exclude' 'Meta skill does not hardcode .git/info/exclude as a literal path'
absent "$META_SKILL" 'task/job id' 'Meta skill does not record a session-local task/job id'
contains "$META_SKILL" 'unless already listed' 'Meta skill appends the handoff exclude entry only when absent'
contains "$META_SKILL" 'grep -qxF' 'Meta skill names the exact-match exclude check'
contains "$META_SKILL" 'literal resume command' 'Meta skill requires the literal resume command in the handoff'
contains "$META_SKILL" 'announcing a dispatch without that written handoff is a defect' 'Meta skill forbids announced dispatches without the written handoff'
contains "$META_SKILL" 'unless the brief explicitly waives it' 'Meta skill requires an explicit tribunal waiver'
[ "$(grep -cF '# optional' "$META_SKILL")" -eq 5 ] || fail 'Meta skill YAML example keeps exactly five # optional markers'
contains "$META_SKILL" 'reconcile; do not overwrite it' 'Meta skill refuses conflicting concurrent handoff overwrites'
contains "$META_SKILL" 'recorded in-flight leg and open item' 'Meta skill reconciles each recorded in-flight leg and open item on resume'
contains "$META_SKILL" 'with reality (PR merged/closed' 'Meta skill reconciles with reality including PR merged/closed'
contains "$META_SKILL" 'output mtime still advancing' 'Meta skill checks output mtime still advancing on resume'
contains "$META_SKILL" 'branch head as recorded' 'Meta skill checks branch head as recorded on resume'
contains "$META_SKILL" 'then execute its "Stop here first" action' 'Meta skill executes Stop here first after reconciling'
contains "$META_SKILL" 'authoritative baseline' 'Meta skill treats the handoff State block as the authoritative baseline'
contains "$META_SKILL" 'reconcile, never discard' 'Meta skill inspects and reconciles unexplained worktree state, never discards'
contains "$META_SKILL" 'overrides of decided judgment calls and brief deltas' 'Meta skill keeps trailing text as overrides of decided judgment calls'
contains "$META_SKILL" "Within the brief's autonomy bounds" 'Meta skill runs within the brief autonomy bounds'
absent "$META_SKILL" 'queue is ratified' 'Meta skill does not reopen a queue-ratification stall'
contains "$META_SKILL" 'Self-merge IS permitted' 'Meta skill states self-merge is permitted'
contains "$META_SKILL" 'Pause to ask only for credentials, browser authentication, repo-policy changes,' 'Meta skill names the closed escalation set (credentials through policy)'
contains "$META_SKILL" 'spend, or irreversible production data' 'Meta skill names the closed escalation set (spend and production data)'
absent "$META_SKILL" '— nothing else' 'Meta skill does not claim the closed list overrides every other stop'
contains "$META_SKILL" "The brief's stop conditions and gate blockers still stop" 'Meta skill keeps brief stop conditions and blockers binding'
contains "$META_SKILL" 'stops the run' 'Meta skill stops the run on run-level conditions'
contains "$META_SKILL" 'Genuine judgment calls outside the pause set above are decided with the recommended default and recorded' 'Meta skill decides judgment calls instead of parking them'
contains "$META_SKILL" 'outside the pause set' 'Meta skill scopes autonomous judgment calls outside the pause set'
contains "$META_SKILL" 'a gate blocker parks that item' 'Meta skill parks an item on a gate blocker'
contains "$META_SKILL" "fifth cycle's delta" 'Meta skill parks after the fifth cycle delta still NEEDS_WORK'
contains "$META_SKILL" 'up to 5 fix cycles' 'Meta skill allows up to 5 NEEDS_WORK fix cycles'
absent "$META_SKILL" 'second ''NEEDS_WORK' 'Meta skill does not use the off-by-one second-NEEDS_WORK phrasing'
absent "$META_SKILL" 'escalat' 'Meta skill has no escalation-path wording'
contains "$META_SKILL" 'OPERATOR ACTIONS REQUIRED' 'Meta skill queues refused privileged actions instead of blocking'
contains "$META_SKILL" 'tree-independent item' 'Meta skill continues with tree-independent work after a queued host action'
contains "$META_SKILL" 'permission layer refuses' 'Meta skill treats a host permission refusal as a dispatch that never started'
[ "$(grep -cF 'tree-independent item' "$META_SKILL")" -eq 1 ] || fail 'Meta skill mentions tree-independent item exactly once'
contains "$META_SKILL" 'Do not burn the session on preflight beyond the Fresh-start checks' 'Meta skill bounds preflight to the Fresh-start checks'
contains "$META_SKILL" 'CLAUDE_PLUGIN_ROOT}/scripts/' 'Meta skill names the plugin scripts directory for runners'
absent "$META_SKILL" 'Poll ' 'Meta skill removes unactionable polling guidance'
absent "$META_SKILL" 'preflight.sh' 'Meta skill references tribunal instead of duplicating its preflight'
absent "$META_SKILL" 'tribunal-round' 'Meta skill references tribunal instead of duplicating its round protocol'
absent "$META_SKILL" 'as soon as real work starts' 'Meta skill no longer triggers the handoff on vague real-work start'
absent "$META_REFS/handoff-template.md" 'committed on the working branch' 'Handoff template defers commit location to the skill'
contains "$META_REFS/handoff-template.md" 'Stop here first' 'Handoff template keeps the single next action'
contains "$META_REFS/handoff-template.md" 'do not re-litigate' 'Handoff template keeps ratified decisions'
contains "$META_REFS/handoff-template.md" 'remain in force verbatim' 'Handoff template keeps delta inheritance'
contains "$META_REFS/handoff-template.md" 'In-flight legs:' 'Handoff template records dispatched legs'
contains "$META_REFS/handoff-template.md" 'runner + mode + model' 'In-flight legs identify their runner configuration'
contains "$META_REFS/handoff-template.md" 'output path' 'In-flight legs identify their output'
contains "$META_REFS/handoff-template.md" 'exit marker path' 'In-flight legs record the exit marker path'
contains "$META_REFS/handoff-template.md" 'dispatch time (UTC)' 'In-flight legs record UTC dispatch time'
contains "$META_REFS/handoff-template.md" 'how completion will be observed' 'In-flight legs record their completion path'
absent "$META_REFS/handoff-template.md" 'task/job id' 'Handoff template does not list a session-local task/job id'
contains "$META_REFS/handoff-template.md" 'expected artifact paths' 'In-flight legs carry expected artifact paths'
contains "$META_REFS/handoff-template.md" 'baseline the gate measures against' 'In-flight legs carry the gate baseline'
contains "$META_REFS/handoff-template.md" 'literal resume command' 'In-flight legs carry the literal resume command'
contains "$META_REFS/handoff-template.md" 'repo path' 'In-flight legs carry the repository path'
contains "$META_REFS/handoff-template.md" '## OPERATOR ACTIONS REQUIRED' 'Handoff template has an OPERATOR ACTIONS REQUIRED block'
absent "$META_REFS/handoff-template.md" "Open"' '"human decisions" 'Handoff template drops the parked-decisions heading'
contains "$META_REFS/handoff-template.md" '## Judgment calls decided' 'Handoff template records decided judgment calls'
absent "$META_REFS/handoff-template.md" 'or filed research memo — never only' 'Handoff template defers trigger list to the skill'
contains "$META_REFS/worker-prompt.md" 'No push, no PR' 'Worker template forbids worker push'
contains "$META_REFS/worker-prompt.md" 'expected red before the fix' 'Worker template keeps the expected-red phrasing'
contains "$META_REFS/worker-prompt.md" 'Out of scope' 'Worker template keeps the scope fence'
contains "$META_REFS/review-prompts.md" 'BY EXECUTION' 'Review template mandates verification by execution'
contains "$META_REFS/review-prompts.md" 'NEEDS_WORK' 'Review template uses the runner verdict token'
# Keep the prescribed template verdict line executable against the shared runner gate.
tmpl="$(grep -m1 -E '^VERDICT:' "$META_REFS/review-prompts.md")" || fail 'Review template lost its VERDICT line'
assert_review_verdict "${tmpl%%|*}" 'Template APPROVE alternative renders past the runner gate'
assert_review_verdict "${tmpl#*|}" 'Template NEEDS_WORK alternative renders past the runner gate'
contains "$META_REFS/review-prompts.md" 'Bounded DELTA by execution' 'Review template keeps the bounded delta round'
absent "$META_REFS/review-prompts.md" 'READY TO MERGE' 'Review templates no longer request a literal merge line'
contains "$META_REFS/review-prompts.md" '--mode probe' 'Review templates route execute-probe legs through --mode probe'
contains "$META_REFS/review-prompts.md" 'review-gate.sh --author <worker provider>' 'Review templates run the gate with --author'
absent "$META_REFS/review-prompts.md" '`--mode implement` + modify-nothing contract' 'Review templates dropped the implement+modify-nothing contract'
contains "$META_REFS/review-prompts.md" 'Send after each fix cycle' 'Delta re-review runs after each fix cycle'
absent "$META_REFS/review-prompts.md" 'single fix ''cycle' 'Delta re-review is not limited to one fix cycle'
contains "$META_REFS/worker-prompt.md" 'the orchestrator commits' 'Worker template reconciles commits with no-commit leg contracts'
absent "$META_REFS/review-prompts.md" 'REQUEST_CHANGES' 'Review template does not reintroduce the unsupported verdict token'
[ -f "$META_REFS/research-leg.md" ] || fail 'Research leg reference exists'
contains "$META_REFS/research-leg.md" 'Do not trigger' 'Research leg reference keeps the negative trigger rules'
absent "$META_REFS/research-leg.md" 'prompt-bounded' 'Research leg reference does not restate runner posture'
absent "$META_REFS/research-leg.md" 'would otherwise be ''escalated' 'Research leg does not assume an escalation path'
absent "$META_REFS/research-leg.md" 'skipping the ''human' 'Research leg does not frame convergence as skipping a human'
absent "$PLUGIN_ROOT/README.md" 'escalated as ''human' 'README does not escalate unknowns as human decisions'
meta_over_budget_fixture="$WORK/meta-orchestration-over-budget.md"
printf '%10001s' '' | tr ' ' x > "$meta_over_budget_fixture"
[ "$(wc -l < "$meta_over_budget_fixture")" -lt 150 ] || fail 'Meta skill budget fixture must stay below 150 lines'
[ "$(wc -c < "$meta_over_budget_fixture")" -gt 10000 ] || fail 'Meta skill budget fixture must exceed 10000 bytes'
! [ "$(wc -c < "$meta_over_budget_fixture")" -le 10000 ] || fail 'Meta skill character budget accepts an over-budget fixture'
[ "$(wc -c < "$META_SKILL")" -le 10000 ] || fail 'meta-orchestration SKILL.md exceeds the 10000-byte budget'
pass 'Meta orchestration skill character budget rejects an over-budget fixture'
pass 'Meta orchestration command, skill, and templates carry the required contracts'

# Installed-CLI smoke must use the user's real config path, not the fixture GROK_HOME
# (fixture auth.json is deliberately simplified and can fail stricter grok inspect).
if [ -n "$REAL_GROK" ]; then
  unset GROK_HOME
  real_grok_help="$($REAL_GROK --help 2>&1)"
  for flag in --reasoning-effort --sandbox --permission-mode --max-turns --no-subagents --prompt-file --tools --output-format --disable-web-search --cwd; do
    case "$real_grok_help" in
      *"$flag"*) ;;
      *) fail "installed Grok CLI lacks $flag" ;;
    esac
  done
  case "$real_grok_help" in
    *bypassPermissions*) ;;
    *) fail 'installed Grok CLI lacks bypassPermissions mode' ;;
  esac
  "$REAL_GROK" --sandbox none --permission-mode bypassPermissions --no-subagents --no-memory inspect >/dev/null
  grok_debug="$WORK/grok-research.debug"
  timeout -k 2 15 "$REAL_GROK" --cwd "$WORK/repo" --sandbox none --permission-mode bypassPermissions \
    --no-subagents --no-memory --max-turns 1 --tools "$GROK_RESEARCH_TOOLS" \
    --debug-file "$grok_debug" -p 'Reply only OK.' >/dev/null 2>&1 || true
  [ -s "$grok_debug" ] || fail 'installed Grok research tool resolution produced no debug log'
  absent "$grok_debug" 'unmappable' 'installed Grok resolves every research tool'
  absent "$grok_debug" 'keeping full grok toolset' 'installed Grok keeps the research allowlist'
  rm -f "$grok_debug"
  pass 'Installed Grok CLI parses the runner posture and supports its flags'
else
  printf 'SKIP: installed Grok CLI flag smoke test\n'
fi

