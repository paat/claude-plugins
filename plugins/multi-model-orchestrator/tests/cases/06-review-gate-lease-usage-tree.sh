#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

# review-gate: the advisory local engine may never be the only reviewer.
GATE="$PLUGIN_ROOT/scripts/review-gate.sh"
gate_dir="$WORK/gate"
mkdir -p "$gate_dir"
printf 'nothing blocking\n\nAPPROVE\n' > "$gate_dir/qwen.txt"
printf 'fine\n\nAPPROVE\n' > "$gate_dir/codex.txt"
printf 'a real problem\n\nNEEDS_WORK\n' > "$gate_dir/grok.txt"
printf 'prose with no verdict\n' > "$gate_dir/noverdict.txt"

rc=0
bash "$GATE" --leg qwen-local="$gate_dir/qwen.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "a local-only review set exits 3 (got $rc)"
rc=0
bash "$GATE" --leg qwen-local-8b="$gate_dir/qwen.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "any qwen-local-* provider is advisory (got $rc)"
out="$(bash "$GATE" --leg qwen-local="$gate_dir/qwen.txt" --leg codex="$gate_dir/codex.txt")"
[ "$out" = "APPROVE" ] || fail "local plus an independent approver returns APPROVE (got $out)"
rc=0
out="$(bash "$GATE" --leg qwen-local="$gate_dir/qwen.txt" --leg grok="$gate_dir/grok.txt")" || rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "NEEDS_WORK" ] || fail "any NEEDS_WORK leg wins (got $rc/$out)"
rc=0
bash "$GATE" --leg codex="$gate_dir/noverdict.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a leg without a terminal verdict exits 2 (got $rc)"
rc=0
bash "$GATE" --leg codex="$gate_dir/missing.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "an unreadable leg exits 2 (got $rc)"
rc=0
bash "$GATE" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "no legs is a usage error (got $rc)"
# --author: a leg must come from a hosted provider family other than the author's.
gate_author() { # EXPECTED_RC DESCRIPTION ARGS...
  local want="$1" desc="$2" got=0; shift 2
  bash "$GATE" "$@" >/dev/null 2>"$gate_dir/author.err" || got=$?
  [ "$got" -eq "$want" ] || fail "gate $desc: want $want, got $got"
}
gate_author 3 '--author codex --leg codex' --author codex --leg codex="$gate_dir/codex.txt"
contains "$gate_dir/author.err" 'other than the author' 'same-family gate exit 3 names the author rule'
gate_author 3 '--author gpt-6.1-sol --leg astra' --author gpt-6.1-sol --leg astra="$gate_dir/codex.txt"
gate_author 0 '--author codex --leg grok' --author codex --leg grok="$gate_dir/codex.txt"
gate_author 0 '--author qwen --leg codex' --author qwen --leg codex="$gate_dir/codex.txt"
gate_author 0 '--author claude-opus-5-5 --leg sonnet --leg codex' --author claude-opus-5-5 --leg sonnet="$gate_dir/codex.txt" --leg codex="$gate_dir/codex.txt"
gate_author 3 '--author grok --leg qwen' --author grok --leg qwen="$gate_dir/codex.txt"
gate_author 2 '--author without a value' --leg codex="$gate_dir/codex.txt" --author
gate_author 0 'no --author keeps --leg codex independent' --leg codex="$gate_dir/codex.txt"
gate_author 3 'agy is not a hosted label' --leg agy="$gate_dir/codex.txt"
gate_author 3 "dropped $gone_provider is not a hosted label" --leg "$gone_provider=$gate_dir/codex.txt"
gate_author 0 'agy/claude-opus-5-5 is an independent reviewer' --leg agy/claude-opus-5-5="$gate_dir/codex.txt"
gate_author 3 'any other agy model stays advisory' --leg agy/gemini-4-argon="$gate_dir/codex.txt"
gate_author 3 'agy/claude-opus-5-5 is not independent of a claude author' --author claude --leg agy/claude-opus-5-5="$gate_dir/codex.txt"
gate_author 3 '--author agy conflicts with a claude reviewer (model unknown)' --author agy --leg claude="$gate_dir/codex.txt"
gate_author 0 '--author agy stays independent of a codex reviewer' --author agy --leg codex="$gate_dir/codex.txt"
gate_author 3 '--author agy/claude-opus-5-5 conflicts with a direct claude reviewer' --author agy/claude-opus-5-5 --leg claude="$gate_dir/codex.txt"
gate_author 0 '--author agy/claude-opus-5-5 stays independent of a codex reviewer' --author agy/claude-opus-5-5 --leg codex="$gate_dir/codex.txt"
gate_author 3 '--author agy/claude-sonnet-5-5 conflicts with an agy opus reviewer' --author agy/claude-sonnet-5-5 --leg agy/claude-opus-5-5="$gate_dir/codex.txt"
gate_author 3 "'claude-sonnet-5-5 (agy)' names the agy transport" --leg "claude-sonnet-5-5 (agy)=$gate_dir/codex.txt"
pass 'review-gate --author requires a reviewer from another provider family'
! grep -E -- '--model [^-"$]' "$PLUGIN_ROOT/commands/orchestrate.md" >/dev/null \
  || fail 'fallback reviewer legs take the model from the route card, not a literal'

# --- handoff-lease.sh ---
LEASE="$PLUGIN_ROOT/scripts/handoff-lease.sh"
lease_dir="$WORK/lease"
lease_rc() { local got=0; "$@" >/dev/null 2>"$WORK/lease.err" || got=$?; printf '%s' "$got"; }
[ "$(lease_rc bash "$LEASE" claim a1 --dir "$lease_dir")" = 0 ] || fail 'lease: first claim succeeds'
case "$(cat "$lease_dir/.lease")" in 'a1 '*) ;; *) fail 'lease: the lease file starts with the owner' ;; esac
[ "$(lease_rc bash "$LEASE" claim b2 --dir "$lease_dir")" = 75 ] || fail 'lease: a second owner exits 75'
contains "$WORK/lease.err" 'held by a1' 'lease: exit 75 names the holder'
[ "$(lease_rc bash "$LEASE" claim a1 --dir "$lease_dir")" = 0 ] || fail 'lease: the owner renews'
[ "$(lease_rc bash "$LEASE" release b2 --dir "$lease_dir")" = 0 ] || fail 'lease: a non-owner release exits 0'
[ -f "$lease_dir/.lease" ] || fail 'lease: a non-owner release leaves the lease in place'
case "$(cat "$lease_dir/.lease")" in 'a1 '*) ;; *) fail 'lease: still held by a1 after b2 release' ;; esac
[ "$(lease_rc bash "$LEASE" release a1 --dir "$lease_dir")" = 0 ] || fail 'lease: owner release exits 0'
[ ! -e "$lease_dir/.lease" ] || fail 'lease: owner release removes the lease'
[ "$(lease_rc bash "$LEASE" claim b2 --dir "$lease_dir")" = 0 ] || fail 'lease: claim after release succeeds'
printf 'a1 1\n' > "$lease_dir/.lease"
[ "$(lease_rc bash "$LEASE" claim b2 --dir "$lease_dir")" = 0 ] || fail 'lease: an expired lease is taken over'
case "$(cat "$lease_dir/.lease")" in 'b2 '*) ;; *) fail 'lease: takeover rewrites the owner' ;; esac
for bad in 'claim a1 --ttl 0' 'claim a1 --ttl x' 'claim' 'claim a\ b' 'frobnicate a1'; do
  # shellcheck disable=SC2086
  [ "$(lease_rc bash "$LEASE" $bad --dir "$lease_dir")" = 2 ] || fail "lease: '$bad' exits 2"
done
[ "$(lease_rc bash "$LEASE" claim 'a b' --dir "$lease_dir")" = 2 ] || fail 'lease: an owner with a space exits 2'
lease_repo="$WORK/lease-repo"; mkdir -p "$lease_repo"; git -C "$lease_repo" init -q
(cd "$lease_repo" && bash "$LEASE" claim r1 >/dev/null 2>&1) || fail 'lease: default dir claim succeeds in a repo'
[ -f "$lease_repo/.claude/handoffs/.lease" ] || fail 'lease: default dir is <repo>/.claude/handoffs'
(cd "$lease_repo" && MMO_HANDOFF_DIR=state/h bash "$LEASE" claim r1 >/dev/null 2>&1) || fail 'lease: MMO_HANDOFF_DIR claim succeeds'
[ -f "$lease_repo/state/h/.lease" ] || fail 'lease: MMO_HANDOFF_DIR is relative to the repo root'
pass 'handoff-lease: claim, renew, release, expiry, usage, and default directories'
# Fail-closed labels: the catalog names for the local engine, other casings, and
# unknown providers are all advisory; only hosted catalog names count.
for label in 'Local Qwen' 'qwen3.8-27b-local' 'Qwen-Local' 'gemini' 'codex-local' "$gone_provider" 'kimi-k3.1-pro'; do
  rc=0
  bash "$GATE" --leg "$label=$gate_dir/qwen.txt" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "label '$label' alone is advisory (got $rc)"
done
for label in codex Claude grok-4.7 grok-4.6 grok-4.5 muse-spark-1.3 gpt-6-astra claude-opus-5 gpt GPT-5.6; do
  out="$(bash "$GATE" --leg "Local Qwen=$gate_dir/qwen.txt" --leg "$label=$gate_dir/codex.txt")" \
    || fail "label '$label' counts as independent"
  [ "$out" = APPROVE ] || fail "label '$label' beside Local Qwen approves (got $out)"
done
# The verdict is the LAST verdict line: quoted options earlier must not decide it.
printf 'the options are:\n* NEEDS_WORK\n* APPROVE\n\nall fine\n\nAPPROVE\n' > "$gate_dir/quoted.txt"
out="$(bash "$GATE" --leg codex="$gate_dir/quoted.txt")" || fail 'quoted options with terminal APPROVE approves'
[ "$out" = APPROVE ] || fail "terminal verdict decides the leg (got $out)"
printf '%s\n' '**VERDICT: APPROVE.**' > "$gate_dir/approve-period.txt"
out="$(bash "$GATE" --leg claude="$gate_dir/approve-period.txt")" || fail 'gate accepts **VERDICT: APPROVE.**'
[ "$out" = APPROVE ] || fail "gate APPROVE. got $out"
printf '%s\n' 'VERDICT: NEEDS_WORK.' > "$gate_dir/needs-period.txt"
rc=0
out="$(bash "$GATE" --leg claude="$gate_dir/needs-period.txt")" || rc=$?
[ "$rc" -eq 1 ] && [ "$out" = NEEDS_WORK ] || fail "gate NEEDS_WORK. got $rc/$out"
printf '%s\n' 'I approve.' > "$gate_dir/i-approve.txt"
rc=0
bash "$GATE" --leg claude="$gate_dir/i-approve.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "gate rejects 'I approve.' (got $rc)"
pass 'review-gate: the local engine can never be the only reviewer'
pass 'review-gate accepts one trailing period and still rejects prose'

contains "$PLUGIN_ROOT/skills/meta-orchestration/references/review-prompts.md" \
  'review-gate.sh' 'review-prompts points at the enforced gate'
# The meta loop is the surface that uses those prompts: it must call the gate,
# not hand-grep a verdict it could satisfy with an advisory leg alone.
contains "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" \
  'review-gate.sh' 'meta per-item loop combines legs through the gate'
contains "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" \
  'never hand-grep' 'meta loop forbids hand-grepping the verdict'
contains "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" \
  '${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh' 'meta loop calls the gate by plugin-root path'
contains "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" \
  'review-gate.sh' 'orchestration skill keeps the gate instruction'
contains "$PLUGIN_ROOT/commands/orchestrate.md" \
  'scripts/review-gate.sh' 'orchestrate fallback block calls the gate'
contains "$PLUGIN_ROOT/commands/orchestrate.md" \
  'Only a gate exit of 0 ends' 'NEEDS_WORK loops back through the gate instead of proceeding'

REANCHOR="$PLUGIN_ROOT/hooks/reanchor.sh"
R="$WORK/re anchor"; H="$R/.claude/handoffs"; mkdir -p "$H"
hook() { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$R" bash "$REANCHOR"; }
[ -z "$(hook '{"source": "compact"}')" ] || fail 'Compact hook is silent without a handoff'
touch -t 200001010000 "$H/handoff-2026-01-01T0000Z.md"
[ -z "$(hook '{"source": "compact"}')" ] || fail 'Compact hook ignores a stale handoff'
touch "$H/handoff-2026-01-02T0000Z.md"
case "$(hook '{"hook_event_name":"SessionStart","source":"compact","model":"clear"}')" in
  *"handoff-2026-01-02T0000Z.md"*"--resume"*) ;; *) fail 'Compact hook reads the source field exactly and names the newest fresh handoff' ;; esac
for src in startup clear; do
  [ -z "$(hook "{\"source\": \"$src\"}" 2>&1)" ] || fail "Reanchor hook ignores SessionStart source $src"
done
mkdir -p "$WORK/abs-handoffs"; touch "$WORK/abs-handoffs/handoff-2026-01-03T0000Z.md"
case "$(printf '%s' '{"source":"compact"}' | MMO_HANDOFF_DIR="$WORK/abs-handoffs" CLAUDE_PROJECT_DIR="$R" bash "$REANCHOR")" in
  *"$WORK/abs-handoffs/handoff-2026-01-03T0000Z.md"*) ;; *) fail 'Reanchor hook honors an absolute MMO_HANDOFF_DIR' ;; esac
contains "$PLUGIN_ROOT/hooks/hooks.json" '"matcher": "compact"' 'Reanchor hook runs after compaction'
! grep -q '"matcher": "clear"' "$PLUGIN_ROOT/hooks/hooks.json" || fail 'No clear hook: the desktop app does not restart a cleared session'
contains "$META_REFS/handoff-template.md" '## Brief' 'Handoff template carries the verbatim brief'
pass 'Reanchor hook re-points a compacted orchestrator at its newest handoff'

WATCH="$PLUGIN_ROOT/hooks/context-watch.sh"
CW="$WORK/cw"; mkdir -p "$CW"
cw_claude() { printf '{"type":"user","message":{"content":"/multi-model-orchestrator:meta-orchestrate epic"}}\n{"message":{"usage":{"input_tokens":2,"cache_read_input_tokens":%s,"cache_creation_input_tokens":1000}},"type":"assistant"}\n{"type":"attachment","attachment":{"type":"x"}}\n' "$1" > "$CW/claude.jsonl"; }
watch() { printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2" | MMO_CONTEXT_WARN_TOKENS=100000 bash "$WATCH"; }
cw_claude 50000
[ -z "$(watch s1 "$CW/claude.jsonl")" ] || fail 'Context watch is silent below the threshold'
cw_claude 120000
case "$(watch s1 "$CW/claude.jsonl")" in
  *'"hookEventName":"PostToolUse"'*'121002 tokens'*'compaction resumes from the handoff'*) ;; *) fail 'Context watch sums Claude usage and warns past the threshold' ;; esac
[ -z "$(watch s1 "$CW/claude.jsonl")" ] || fail 'Context watch warns once per crossing'
cw_claude 10000; watch s1 "$CW/claude.jsonl" >/dev/null; cw_claude 120000
[ -n "$(watch s1 "$CW/claude.jsonl")" ] || fail 'Context watch re-arms after context drops (compaction)'
printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":130000,"cached_input_tokens":120000}}}}\n{"type":"user","message":"$multi-model-orchestrator:meta-orchestrate epic"}\n' > "$CW/codex.jsonl"
case "$(watch s2 "$CW/codex.jsonl")" in *'130000 tokens'*) ;; *) fail 'Context watch reads Codex token_count input tokens' ;; esac
printf '{"type":"assistant","message":{"usage":{"input_tokens":200000}}}\n' > "$CW/plain.jsonl"
[ -z "$(watch s3 "$CW/plain.jsonl")" ] || fail 'Context watch stays silent outside meta-orchestrate sessions'
printf '{"type":"user","message":{"content":"/multi-model-orchestrator:meta-orchestrate go"}}\n' >> "$CW/plain.jsonl"
[ -n "$(watch s3 "$CW/plain.jsonl")" ] || fail 'Context watch warns when meta-orchestrate starts after the crossing'
[ -z "$(printf '{}' | bash "$WATCH")" ] || fail 'Context watch tolerates missing hook fields'
cw_over='{"type":"assistant","message":{"usage":{"input_tokens":200000}}}'
cw_case() { printf '%s\n%s\n' "$cw_over" "$2" > "$CW/case.jsonl"; watch "$1" "$CW/case.jsonl"; }
[ -z "$(cw_case sl1 '{"skills":["multi-model-orchestrator:meta-orchestrate"]}
- multi-model-orchestrator:meta-orchestration: Use when ... Entrypoint: /multi-model-orchestrator:meta-orchestrate.')" ] || fail 'Context watch ignores a skill listing that only mentions the skill'
[ -n "$(cw_case sl2 '{"type":"user","message":{"content":"<command-name>/multi-model-orchestrator:meta-orchestrate</command-name>"}}')" ] || fail 'Context watch warns on a command-name invocation'
[ -n "$(cw_case sl3 '{"name":"Skill","input":{"skill":"multi-model-orchestrator:meta-orchestration"}}')" ] || fail 'Context watch warns on a Skill tool invocation'
[ -n "$(cw_case sl4 '{"type":"user","message":"$multi-model-orchestrator:meta-orchestrate epic"}')" ] || fail 'Context watch warns on a $-prefixed Codex invocation'
[ -n "$(cw_case sl5 '{"type":"user","message":"# /multi-model-orchestrator:meta-orchestrate Codex Workflow"}')" ] || fail 'Context watch warns on the loaded Codex workflow heading'
[ -z "$(cw_case sl6 '{"type":"user","message":"Explain \"/multi-model-orchestrator:meta-orchestrate\" without running it"}')" ] || fail 'Context watch ignores a quoted mention of the command'
contains "$PLUGIN_ROOT/hooks/hooks.json" 'hooks/context-watch.sh' 'Context watch runs as a PostToolUse hook'
# Multi-harness hooks: agy (root hooks.json + protojson), Grok (camelCase + GROK_PLUGIN_ROOT), Muse (MUSE_PLUGIN_ROOT)
[ -z "$(jq -nc --arg r "$R" '{conversationId:"agy-s1",cwd:$r,workspacePaths:[$r]}' | bash "$REANCHOR")" ] || fail 'Reanchor hook stays silent without source=compact'
printf '{"step_index":0,"source":"user","content":"/multi-model-orchestrator:meta-orchestrate epic"}\n{"step_index":1,"input_tokens":110000,"cache_read_tokens":20000}\n{"step_index":2,"source":"tool","content":"quoted \\"input_tokens\\": 5"}\n' > "$CW/agy.jsonl"
case "$(printf '{"conversationId":"agy-c1","transcriptPath":"%s"}' "$CW/agy.jsonl" | HOOK_RUNTIME=agy MMO_CONTEXT_WARN_TOKENS=100000 bash "$WATCH")" in
  *'"injectSteps"'*'"systemMessage"'*'130000 tokens'*) ;;
  *) fail 'Context watch sums agy input_tokens + cache_read_tokens even when a later tool result quotes input_tokens' ;;
esac
[ "$(printf '{"conversationId":"agy-c1","transcriptPath":"%s"}' "$CW/agy.jsonl" | HOOK_RUNTIME=agy MMO_CONTEXT_WARN_TOKENS=100000 bash "$WATCH")" = '{}' ] || fail 'Context watch warns once on agy then returns {}'
printf '{"step_index":0,"source":"tool","content":"read plugins/multi-model-orchestrator/skills/meta-orchestration/SKILL.md"}\n{"step_index":1,"input_tokens":150000,"cache_read_tokens":0}\n' > "$CW/agy-read-only.jsonl"
[ "$(printf '{"conversationId":"agy-c2","transcriptPath":"%s"}' "$CW/agy-read-only.jsonl" | HOOK_RUNTIME=agy MMO_CONTEXT_WARN_TOKENS=100000 bash "$WATCH")" = '{}' ] || fail 'Context watch ignores reading skills/meta-orchestration/SKILL.md outside an invocation'
printf '{"type":"user","message":{"content":"/multi-model-orchestrator:meta-orchestrate go"}}\n{"usage":{"inputTokens":140000}}\n' > "$CW/grok.jsonl"
case "$(printf '{"sessionId":"grok-s1","transcriptPath":"%s"}' "$CW/grok.jsonl" | MMO_CONTEXT_WARN_TOKENS=100000 bash "$WATCH")" in
  *'"hookEventName":"PostToolUse"'*'140000 tokens'*) ;;
  *) fail 'Context watch parses Grok camelCase sessionId/transcriptPath/inputTokens' ;;
esac
# T-001: substring "conversationId" in a Claude/Codex compact payload must stay plain text (not agy JSON)
reanchor_sub="$(jq -nc '{source:"compact",note:"has \"conversationId\" text"}' | CLAUDE_PROJECT_DIR="$R" bash "$REANCHOR")"
case "$reanchor_sub" in
  *'handoff-2026-01-02T0000Z.md'*) ;;
  *) fail 'Reanchor keeps plain-text output when conversationId is only a substring' ;;
esac
case "$reanchor_sub" in
  *'"injectSteps"'*) fail 'Reanchor must not emit agy injectSteps on substring conversationId' ;;
esac
absent "$PLUGIN_ROOT/hooks.json" 'reanchor.sh' 'Root hooks.json omits agy SessionStart reanchor (no compaction hook)'
contains "$PLUGIN_ROOT/hooks.json" 'HOOK_RUNTIME=agy bash ./hooks/ship-gates.sh' 'Root hooks.json wires agy PreToolUse ship-gates'
contains "$PLUGIN_ROOT/hooks.json" 'HOOK_RUNTIME=agy bash ./hooks/context-watch.sh' 'Root hooks.json wires agy PostInvocation context-watch'
SG_REPO="$WORK/sg-agy"; SG_NONGIT="$WORK/sg-nongit"; mkdir -p "$SG_REPO/.claude" "$SG_NONGIT"
git -C "$SG_REPO" init -q && git -C "$SG_REPO" config user.email t@t.t && git -C "$SG_REPO" config user.name t
printf 'a\n' > "$SG_REPO/f" && git -C "$SG_REPO" add f && git -C "$SG_REPO" commit -qm init
printf -- '---\npush_check: "false"\n---\n' > "$SG_REPO/.claude/multi-model-orchestrator.local.md"
case "$(jq -nc --arg cwd "$SG_REPO" '{hookEventName:"PreToolUse",toolCall:{id:"1",name:"run_command",args:{CommandLine:"git push origin main"}},cwd:$cwd}' | HOOK_RUNTIME=agy bash "$PLUGIN_ROOT/hooks/ship-gates.sh")" in
  *'"decision":"deny"'*'push_check exited 1'*) ;;
  *) fail 'ship-gates emits agy deny JSON for failing push_check' ;;
esac
# T-201: toolCall.args.Cwd overrides non-git top-level cwd
case "$(jq -nc --arg cmd_cwd "$SG_REPO" --arg ws_cwd "$SG_NONGIT" '{hookEventName:"PreToolUse",toolCall:{id:"1b",name:"run_command",args:{CommandLine:"git push origin main",Cwd:$cmd_cwd}},cwd:$ws_cwd}' | HOOK_RUNTIME=agy bash "$PLUGIN_ROOT/hooks/ship-gates.sh")" in
  *'"decision":"deny"'*'push_check exited 1'*) ;;
  *) fail 'ship-gates honors toolCall.args.Cwd over non-git session cwd' ;;
esac
[ "$(jq -nc --arg cwd "$SG_REPO" '{hookEventName:"PreToolUse",toolCall:{id:"2",name:"run_command",args:{CommandLine:"echo hi"}},cwd:$cwd}' | HOOK_RUNTIME=agy bash "$PLUGIN_ROOT/hooks/ship-gates.sh")" = '{"decision":"allow"}' ] || fail 'ship-gates emits agy allow JSON for non-push commands'
sg_grok_rc=0
jq -nc --arg cwd "$SG_REPO" '{toolName:"run_terminal_command",toolInput:{command:"git push origin main"},cwd:$cwd}' | bash "$PLUGIN_ROOT/hooks/ship-gates.sh" >/dev/null 2>&1 || sg_grok_rc=$?
[ "$sg_grok_rc" -eq 2 ] || fail "ship-gates blocks Grok camelCase push with exit 2 (got $sg_grok_rc)"
# T-001: Claude payload whose command mentions "toolCall" must still exit 2 (not flip to agy exit 0)
sg_spoof_rc=0
jq -nc --arg cwd "$SG_REPO" '{tool_name:"Bash",tool_input:{command:"echo \"toolCall\" && git push origin main"},cwd:$cwd}' | bash "$PLUGIN_ROOT/hooks/ship-gates.sh" >/dev/null 2>&1 || sg_spoof_rc=$?
[ "$sg_spoof_rc" -eq 2 ] || fail "ship-gates must exit 2 even when Claude command text contains toolCall (got $sg_spoof_rc)"
# T-003: Grok toolInputTruncated=true fails closed
sg_trunc_rc=0
jq -nc --arg cwd "$SG_REPO" '{toolName:"run_terminal_command",toolInput:{command:"echo hi"},toolInputTruncated:true,cwd:$cwd}' | bash "$PLUGIN_ROOT/hooks/ship-gates.sh" >/dev/null 2>&1 || sg_trunc_rc=$?
[ "$sg_trunc_rc" -eq 2 ] || fail "ship-gates must block Grok toolInputTruncated=true with exit 2 (got $sg_trunc_rc)"
pass 'Context watch warns a meta-orchestrator once past MMO_CONTEXT_WARN_TOKENS'

USAGE_SH="$PLUGIN_ROOT/scripts/usage.sh"
U="$WORK/usage"; mkdir -p "$U/codex/sessions/2026/01/01" "$U/bin"
# Hermetic: a real agy on PATH must not answer these runs.
printf '#!/usr/bin/env bash\nexit 1\n' > "$U/bin/agy"; chmod +x "$U/bin/agy"
export PATH="$U/bin:$PATH"
future=$(( $(date +%s) + 90000 )); past=$(( $(date +%s) - 60 ))
rl() { printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":91.6,"window_minutes":10080,"resets_at":%s}}}}\n' "$1" "$2" "$future"; }
{ rl 10 "$future"; rl 40 "$past"; } > "$U/codex/sessions/2026/01/01/rollout-a.jsonl"
out=$(CODEX_HOME="$U/codex" PATH="$U/bin:$PATH" bash "$USAGE_SH")
case "$out" in *"codex 5h 0% (reset at"*) ;; *) fail "usage.sh zeroes a Codex window whose reset passed: $out" ;; esac
case "$out" in *"codex 7d 92% resets "*" in 1d1h0m as-of "*|*"codex 7d 92% resets "*" in 1d0h59m as-of "*) ;; *) fail "usage.sh reports the newest Codex secondary window: $out" ;; esac
case "$out" in *"claude unknown (pass --claude-log or --probe-claude"*"grok unknown"*"muse unknown (no stream log with run.usage; pass --muse-log)"*) ;; *) fail "usage.sh names providers it cannot read: $out" ;; esac
case "$out" in *"$gone_provider"*) fail "usage.sh no longer reports the dropped provider: $out" ;; esac
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.014,"resetsAt":%s},"seven_day":{"utilization":0.86,"resetsAt":%s}}}}\n' "$future" "$future" > "$U/claude.jsonl"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH" --claude-log "$U/claude.jsonl" --claude-log "$U/missing.jsonl")
case "$out" in *"codex unknown"*"claude 5h 1% resets"*"claude 7d 86% resets"*) ;; *) fail "usage.sh reads Claude windows from a stream log: $out" ;; esac
printf '#!/usr/bin/env bash\n[ "$PWD" != "%s" ] || exit 9\ncat "%s"\n' "$PWD" "$U/claude.jsonl" > "$U/bin/claude"; chmod +x "$U/bin/claude"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --probe-claude)
case "$out" in *"claude 7d 86% resets"*) ;; *) fail "usage.sh --probe-claude parses the probe stream: $out" ;; esac
printf '#!/usr/bin/env bash\nexit 1\n' > "$U/bin/claude"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --probe-claude)
case "$out" in *"claude unknown (probe returned no rate_limit_event)"*) ;; *) fail "usage.sh reports a failed probe as unknown: $out" ;; esac
set +e; bash "$USAGE_SH" --bogus >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || fail "usage.sh rejects unknown flags (got $rc)"

# Top-level per-model window (e.g. seven_day_opus) not among unifiedWindows is also emitted.
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.02,"resetsAt":%s}},"rateLimitType":"seven_day_opus","utilization":1.0,"resetsAt":%s}}\n' "$future" "$future" > "$U/claude-toplevel.jsonl"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH" --claude-log "$U/claude-toplevel.jsonl")
case "$out" in *"claude 7d_opus 100% resets"*) ;; *) fail "usage.sh emits a per-model top-level window not in unifiedWindows: $out" ;; esac

# A window with a non-numeric reset is dropped, not shown blank, while a valid sibling survives.
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":null},"seven_day":{"utilization":0.2,"resetsAt":%s}}}}\n' "$future" > "$U/claude-badreset.jsonl"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH" --claude-log "$U/claude-badreset.jsonl")
case "$out" in *"claude 5h"*) fail "usage.sh should drop a Claude window with a non-numeric reset: $out" ;; esac
case "$out" in *"claude 7d 20% resets"*) ;; *) fail "usage.sh keeps a valid Claude window beside a dropped one: $out" ;; esac

mkdir -p "$U/codex-badreset/sessions/2026/01/01"
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":"n/a","window_minutes":300,"resets_at":"2026-01-01"}}}}\n' > "$U/codex-badreset/sessions/2026/01/01/rollout-a.jsonl"
out=$(CODEX_HOME="$U/codex-badreset" PATH="$U/bin:$PATH" bash "$USAGE_SH")
case "$out" in *"codex unknown"*) ;; *) fail "usage.sh drops a Codex window with a non-numeric used value: $out" ;; esac

# A truncated final JSONL line must not hide the last complete event.
printf '{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.3,"resetsAt":%s}}}}\n{"type":"rate_limit_event","rate_limit_info":{"unifiedWindow' "$future" > "$U/claude-trunc.jsonl"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH" --claude-log "$U/claude-trunc.jsonl")
case "$out" in *"claude 5h 30% resets"*) ;; *) fail "usage.sh keeps the last complete Claude event despite a truncated line after it: $out" ;; esac

mkdir -p "$U/codex-trunc/sessions/2026/01/01"
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":15,"window_minutes":300,"resets_at":%s}}}}\n{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_pe' "$future" > "$U/codex-trunc/sessions/2026/01/01/rollout-a.jsonl"
out=$(CODEX_HOME="$U/codex-trunc" PATH="$U/bin:$PATH" bash "$USAGE_SH")
case "$out" in *"codex 5h 15% resets"*) ;; *) fail "usage.sh keeps the last complete Codex event despite a truncated line after it: $out" ;; esac

# Newer file mtime must not beat an older file whose last rate_limits event is newer (#577).
# Mtimes are offsets from now (older file first, both inside 8 days). Event order stays on .timestamp.
mkdir -p "$U/codex-order/sessions/old" "$U/codex-order/sessions/new"
order_older_ts='2026-10-03T12:00:00.500Z'
order_newer_ts='2026-10-01T00:00:00Z'
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":55,"window_minutes":300,"resets_at":%s}}}}\n' "$order_older_ts" "$future" > "$U/codex-order/sessions/old/rollout-older-mtime.jsonl"
printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":%s}}}}\n' "$order_newer_ts" "$future" > "$U/codex-order/sessions/new/rollout-newer-mtime.jsonl"
order_now=$(date +%s)
touch -d "@$((order_now - 3 * 86400))" "$U/codex-order/sessions/old/rollout-older-mtime.jsonl"
touch -d "@$((order_now - 86400))" "$U/codex-order/sessions/new/rollout-newer-mtime.jsonl"
out=$(CODEX_HOME="$U/codex-order" PATH="$U/bin:$PATH" bash "$USAGE_SH")
expect_asof=$(jq -nr --arg t "$order_older_ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | strftime("%Y-%m-%dT%H:%MZ")')
lose_asof=$(jq -nr --arg t "$order_newer_ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | strftime("%Y-%m-%dT%H:%MZ")')
case "$out" in *"codex 5h 55% resets "*" as-of ${expect_asof}"*) ;; *) fail "usage.sh as-of follows the newer rate_limits event (want as-of ${expect_asof}): $out" ;; esac
case "$out" in *"codex 5h 10%"*|*"as-of ${lose_asof}"*) fail "usage.sh let the newer-mtime file hide a newer event: $out" ;; esac
absent "$USAGE_SH" 'date -u -d' 'usage.sh does not format times with GNU date -d'
absent "$USAGE_SH" 'stat -c' 'usage.sh does not read mtime with GNU stat -c'
absent "$USAGE_SH" '-printf' 'usage.sh does not list files with GNU find -printf'

# Only the 20 newest rollout files are candidates. A newer event in an older file stays unread.
# bi=0 is the oldest mtime; each later file is one minute newer, a few hours before now.
mkdir -p "$U/codex-bound/sessions"
bound_excluded_ts='2026-10-04T18:00:00Z'
bound_kept_ts='2026-10-03T08:00:00Z'
bound_base=$(( $(date +%s) - 4 * 3600 ))
bi=0
while [ "$bi" -lt 21 ]; do
  bf="$U/codex-bound/sessions/rollout-$bi.jsonl"
  if [ "$bi" -eq 0 ]; then
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99,"window_minutes":300,"resets_at":%s}}}}\n' "$bound_excluded_ts" "$future" > "$bf"
  elif [ "$bi" -eq 20 ]; then
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12,"window_minutes":300,"resets_at":%s}}}}\n' "$bound_kept_ts" "$future" > "$bf"
  else
    printf '{"timestamp":"2026-10-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":3,"window_minutes":300,"resets_at":%s}}}}\n' "$future" > "$bf"
  fi
  touch -d "@$((bound_base + bi * 60))" "$bf"
  bi=$((bi + 1))
done
out=$(CODEX_HOME="$U/codex-bound" PATH="$U/bin:$PATH" bash "$USAGE_SH")
expect_bound=$(jq -nr --arg t "$bound_kept_ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | strftime("%Y-%m-%dT%H:%MZ")')
lose_bound=$(jq -nr --arg t "$bound_excluded_ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | strftime("%Y-%m-%dT%H:%MZ")')
case "$out" in *"codex 5h 12% resets "*" as-of ${expect_bound}"*) ;; *) fail "usage.sh keeps Codex candidates to the 20 newest files (want 12% as-of ${expect_bound}): $out" ;; esac
case "$out" in *"codex 5h 99%"*|*"as-of ${lose_bound}"*) fail "usage.sh read a rate_limits event outside the 20 newest files: $out" ;; esac

# No .timestamp: the newer file mtime wins, and as-of is that mtime (still inside 8 days).
mkdir -p "$U/codex-mtime/sessions"
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":77,"window_minutes":300,"resets_at":%s}}}}\n' "$future" > "$U/codex-mtime/sessions/rollout-old.jsonl"
printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":33,"window_minutes":300,"resets_at":%s}}}}\n' "$future" > "$U/codex-mtime/sessions/rollout-new.jsonl"
mtime_now=$(date +%s)
touch -d "@$((mtime_now - 2 * 86400))" "$U/codex-mtime/sessions/rollout-old.jsonl"
touch -d "@$((mtime_now - 86400))" "$U/codex-mtime/sessions/rollout-new.jsonl"
out=$(CODEX_HOME="$U/codex-mtime" PATH="$U/bin:$PATH" bash "$USAGE_SH")
mt_new=$(date -r "$U/codex-mtime/sessions/rollout-new.jsonl" +%s)
expect_mt=$(jq -nr --argjson t "$mt_new" '$t | strftime("%Y-%m-%dT%H:%MZ")')
case "$out" in *"codex 5h 33% resets "*" as-of ${expect_mt}"*) ;; *) fail "usage.sh falls back to file mtime when the event has no timestamp (want 33% as-of ${expect_mt}): $out" ;; esac
case "$out" in *"codex 5h 77%"*) fail "usage.sh let an older untimestamped rollout win: $out" ;; esac

# agy: local /usage JSON, one window per quota pool; unknown buckets skipped; fractional-second resets parse.
cat > "$U/bin/agy" <<STUB
#!/usr/bin/env bash
[ "\$1" = "-p=/usage" ] || exit 9
printf '%s' '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","remaining_fraction":0.97,"reset_time":"$(iso "$future")Z"},{"id":"gemini-5h","remaining_fraction":0.84,"reset_time":"$(iso "$future").250Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-5h","remaining_fraction":0.5,"reset_time":"$(iso "$future")Z"},{"id":"3p-weekly","remaining_fraction":0.91,"reset_time":"$(iso "$future")Z"}]},{"name":"Gemini 4 Argon","buckets":[{"id":"gemini-argon-wtu-weekly","remaining_fraction":0.99,"reset_time":"$(iso "$future")Z"},{"id":"mystery-bucket","remaining_fraction":0.2,"reset_time":"$(iso "$future")Z"}]}]}}}'
STUB
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH")
case "$out" in *"agy 7d_flash 3% resets"*) ;; *) fail "usage.sh reads the agy Gemini weekly bucket: $out" ;; esac
case "$out" in *"agy 5h_flash 16% resets"*) ;; *) fail "usage.sh parses a fractional-second agy reset: $out" ;; esac
case "$out" in *"agy 5h_claude 50% resets"*) ;; *) fail "usage.sh reads the agy Claude 5h bucket: $out" ;; esac
case "$out" in *"agy 7d_claude 9% resets"*) ;; *) fail "usage.sh reads the agy Claude weekly bucket: $out" ;; esac
case "$out" in *"agy 7d_argon 1% resets"*) ;; *) fail "usage.sh reads the agy Argon weekly bucket: $out" ;; esac
[ "$(printf '%s\n' "$out" | grep -c '^agy ')" -eq 5 ] || fail "usage.sh skips an unknown agy bucket id: $out"
case "$out" in *"80%"*|*mystery*|*"agy 5h "*|*"agy 7d "*) fail "usage.sh emits only per-pool agy windows: $out" ;; esac
printf '#!/usr/bin/env bash\nexit 1\n' > "$U/bin/agy"
out=$(CODEX_HOME="$U/none" bash "$USAGE_SH")
case "$out" in *"agy unknown (/usage returned no known quota buckets)"*) ;; *) fail "usage.sh reports a failed agy probe as unknown: $out" ;; esac

# #718: Muse allowance comes from a run stream, not the CLI session store.
# emit zeroes a window whose reset has passed, so the same parsed percent is asserted either way.
muse_allowance='{"tier":"Muse Code Power Usage","weekly":{"resets_at_ms":1794787200000,"used_percent":99},"window":{"resets_at_ms":1794764145000,"used_percent":6},"as_of_ms":1794700800000,"source":"mint"}'
muse_reason='API error 429 […]: Subscription quota exhausted. Your usage window resets at 2026-11-16T00:00:00Z. (rate_limit_error)'
jq -cn --argjson allowance "$muse_allowance" --arg reason "$muse_reason" \
  '{payload_type:"run.usage",payload:{allowance:$allowance}},{payload_type:"run.terminal.failed",payload:{terminal:"failed",reason:$reason,text:""}}' \
  > "$U/muse-issue.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-issue.jsonl" --muse-log "$U/missing-muse.jsonl")
expect_muse_line "$out" 7d 99 1794787200 '2026-11-15T00:00Z' 'usage.sh Muse weekly line from the issue allowance'
expect_muse_line "$out" 5h 6 1794764145 '2026-11-15T00:00Z' 'usage.sh Muse window line from the issue allowance'
jq -cn --argjson as_of 1794600000000 '{payload_type:"run.usage",payload:{allowance:{weekly:{resets_at_ms:1794787200000,used_percent:11},window:{resets_at_ms:1794764145000,used_percent:1},as_of_ms:$as_of}}}' > "$U/muse-old.jsonl"
jq -cn --argjson as_of 1794730000000 '{payload_type:"run.usage",payload:{allowance:{weekly:{resets_at_ms:1794787200000,used_percent:42},window:{resets_at_ms:1794764145000,used_percent:3},as_of_ms:$as_of}}}' > "$U/muse-new.jsonl"
touch -d "@$(( $(date +%s) - 86400 ))" "$U/muse-new.jsonl"
touch "$U/muse-old.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-old.jsonl" --muse-log "$U/muse-new.jsonl")
expect_muse_asof=$(jq -nr '1794730000 | strftime("%Y-%m-%dT%H:%MZ")')
expect_muse_line "$out" 7d 42 1794787200 "$expect_muse_asof" "usage.sh keeps the Muse allowance with the newest as_of_ms (want 42% as-of ${expect_muse_asof})"
case "$out" in *"muse 7d 11%"*) fail "usage.sh let an older Muse as_of_ms win: $out" ;; esac
jq -cn '{payload_type:"run.usage",payload:{allowance:{weekly:{used_percent:"n/a",resets_at_ms:1794787200000},window:{used_percent:6,resets_at_ms:1794764145000},as_of_ms:1794700800000}}}' > "$U/muse-partial.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-partial.jsonl")
case "$out" in *"muse 7d"*) fail "usage.sh should drop a Muse weekly bucket with a non-numeric used value: $out" ;; esac
expect_muse_line "$out" 5h 6 1794764145 '*' 'usage.sh keeps a valid Muse window beside a dropped weekly bucket'
jq -cn '{payload_type:"run.usage",payload:{allowance:{weekly:{used_percent:99,resets_at_ms:1794787200000},as_of_ms:1794700800000}}}' > "$U/muse-nowindow.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-nowindow.jsonl")
case "$out" in *"muse 5h"*) fail "usage.sh should omit a missing Muse window bucket: $out" ;; esac
expect_muse_line "$out" 7d 99 1794787200 '2026-11-15T00:00Z' 'usage.sh keeps a valid Muse weekly bucket when window is missing'
printf '%s\n' '{"payload_type":"run.usage","payload":{"allowance":{"weekly":{"used_percent":"x","resets_at_ms":"soon"},"window":{"used_percent":null,"resets_at_ms":1},"as_of_ms":"yesterday"}}}' > "$U/muse-bad.jsonl"
set +e
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-bad.jsonl")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "usage.sh exits 0 on a malformed Muse allowance (got $rc): $out"
case "$out" in *"muse unknown (no stream log with run.usage; pass --muse-log)"*) ;; *) fail "a Muse allowance with no numeric bucket is unknown: $out" ;; esac
case "$out" in *"muse 7d"*|*"muse 5h "*) fail "a malformed Muse allowance emitted a window: $out" ;; esac
jq -cn '{payload_type:"run.usage",payload:{allowance:{weekly:{used_percent:17,resets_at_ms:1794787200000}}}}' > "$U/muse-noasof.jsonl"
out=$(CODEX_HOME="$U/none" PATH="$U/bin:$PATH" bash "$USAGE_SH" --muse-log "$U/muse-noasof.jsonl")
case "$out" in *"muse unknown (no stream log with run.usage; pass --muse-log)"*) ;; *) fail "a Muse allowance without numeric as_of_ms is unknown: $out" ;; esac

contains "$META_SKILL" 'references/usage-limits.md' 'Meta skill routes with usage headroom'
contains "$META_REFS/usage-limits.md" 'get_usage' 'Usage limits prefer the desktop get_usage tool'
contains "$META_REFS/handoff-template.md" '- Usage:' 'Handoff records the usage snapshot'
pass 'usage.sh reports plan-limit windows per provider'

# --- plan limits are 75 with failure=limit, not task failures or transient retries ---
for msg in 'You have hit your usage limit' 'RESOURCE_EXHAUSTED: quota exceeded' 'Resource exhausted' \
  'API error (status 402 Payment Required): Grok Build usage balance exhausted'; do
  printf '%s\n' "$msg" > "$WORK/plan-limit.txt"
  [ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = limit ] || fail "plan limit '$msg' classifies as limit"
done
printf '429 Too Many Requests\n' > "$WORK/plan-limit.txt"
[ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = transient ] || fail 'a 429 stays transient'
pass 'Plan-limit errors classify as limit; rate limits stay transient'
printf '    at run (file:///x/cli.js:503:12)\n' > "$WORK/plan-limit.txt"
[ -z "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" ] || fail 'a stack-frame position is not a 503'
printf 'API Error: 503\n' > "$WORK/plan-limit.txt"
[ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = transient ] || fail 'a real 503 stays transient'
printf 'at x.js:429:7\nIndividual quota reached\n' > "$WORK/plan-limit.txt"
[ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = limit ] || fail 'a stack-frame 429 does not mask a quota limit'
printf '401 Unauthorized\n' > "$WORK/plan-limit.txt"
[ "$(mmo_classify_provider_failure "$WORK/plan-limit.txt")" = auth ] || fail 'a 401 stays auth'
pass 'Failure classification ignores stack-frame positions'

# --- mmo_tree_state sees tracked, untracked-content, and HEAD changes; ignores the --out prefix ---
TS="$WORK/tree-state"; mkdir -p "$TS"
git -C "$TS" init -q
printf 'a\n' > "$TS/a.txt"; git -C "$TS" add a.txt; git -C "$TS" -c user.email=t@t -c user.name=t commit -qm a
s0="$(mmo_tree_state "$TS")"
printf 'u1\n' > "$TS/u.txt"; s1="$(mmo_tree_state "$TS")"
[ "$s1" != "$s0" ] || fail 'tree state sees a new untracked file'
printf 'u2\n' > "$TS/u.txt"; [ "$(mmo_tree_state "$TS")" != "$s1" ] || fail 'tree state sees untracked content change'
rm "$TS/u.txt"; [ "$(mmo_tree_state "$TS")" = "$s0" ] || fail 'tree state is stable for an unchanged tree'
printf 'x\n' > "$TS/out.txt"; printf 'x\n' > "$TS/out.txt.stream"
[ "$(mmo_tree_state "$TS" "$TS/out.txt")" = "$(mmo_tree_state "$TS" "$TS/out.txt")" ] || fail 'tree state is deterministic'
rm "$TS/out.txt" "$TS/out.txt.stream"
before="$(mmo_tree_state "$TS" "$TS/out.txt")"
printf 'x\n' > "$TS/out.txt"; printf 'x\n' > "$TS/out.txt.stream"
[ "$(mmo_tree_state "$TS" "$TS/out.txt")" = "$before" ] || fail 'tree state ignores the --out file and its siblings'
printf 'b\n' > "$TS/a.txt"; [ "$(mmo_tree_state "$TS" "$TS/out.txt")" != "$before" ] || fail 'tree state sees a tracked edit'
# The --out exclusion is exact: a source file sharing the --out prefix still counts.
printf 'r\n' > "$TS/result.py"; git -C "$TS" add result.py; git -C "$TS" -c user.email=t@t -c user.name=t commit -qm r
before="$(mmo_tree_state "$TS" "$TS/result")"
printf 'x\n' > "$TS/result"; printf 'x\n' > "$TS/result.exit"; printf 'x\n' > "$TS/result.stream.stderr"
[ "$(mmo_tree_state "$TS" "$TS/result")" = "$before" ] || fail 'tree state ignores --out, .exit, and .stream.stderr'
printf 'r2\n' > "$TS/result.py"
[ "$(mmo_tree_state "$TS" "$TS/result")" != "$before" ] || fail 'tree state sees an edit to a file that shares the --out prefix'
# A repository with no commits: a staged rewrite still counts.
TN="$WORK/tree-nohead"; mkdir -p "$TN"; git -C "$TN" init -q
printf 'one\n' > "$TN/n.txt"; git -C "$TN" add n.txt
before="$(mmo_tree_state "$TN")"
printf 'two\n' > "$TN/n.txt"; git -C "$TN" add n.txt
[ "$(mmo_tree_state "$TN")" != "$before" ] || fail 'tree state sees a staged rewrite in a repository without HEAD'
# Several OUT paths: each leg file and its siblings are ignored, anything else counts.
before="$(mmo_tree_state "$TS" "$TS/o1" "$TS/o2")"
printf 'x\n' > "$TS/o1"; printf 'x\n' > "$TS/o1.stream"; printf 'x\n' > "$TS/o2"; printf 'x\n' > "$TS/o2.exit"
[ "$(mmo_tree_state "$TS" "$TS/o1" "$TS/o2")" = "$before" ] || fail 'tree state ignores every OUT path and its siblings'
printf 'x\n' > "$TS/o3"
[ "$(mmo_tree_state "$TS" "$TS/o1" "$TS/o2")" != "$before" ] || fail 'tree state sees a file that is none of the OUT paths'
rm "$TS/o3"
pass 'mmo_tree_state detects repository writes and ignores leg artifacts'

# --- codex/claude: a non-implement leg that changes the repository exits 7; leg files and review diff ---
# The usage tests above put hermetic provider stubs first on PATH; these runs need the leg stubs.
leg_old_path="$PATH"; PATH="$WORK/bin:$PATH"
LR="$WORK/leg-repo"; mkdir -p "$LR"; git -C "$LR" init -q
printf 'one\n' > "$LR/f.txt"; git -C "$LR" add f.txt; git -C "$LR" -c user.email=t@t -c user.name=t commit -qm base
printf 'two\n' > "$LR/f.txt"
LR2="$WORK/leg-repo-clean"; mkdir -p "$LR2"; git -C "$LR2" init -q
printf 'one\n' > "$LR2/f.txt"; git -C "$LR2" add f.txt; git -C "$LR2" -c user.email=t@t -c user.name=t commit -qm base
for r in claude codex; do
  prompt="$WORK/$r.prompt"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR" --base HEAD --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$r clean review exits 0 (got $rc)"
  case "$r" in claude) leg_modes='review advise research' ;; *) leg_modes='review research' ;; esac
  for mode in $leg_modes; do
    base_args=(); [ "$mode" != review ] || base_args=(--base HEAD)
    for mut in "printf changed >> '$LR/f.txt'" "printf fresh > '$LR/new.txt'"; do
      rc=0; printf x | STUB_MUTATE="$mut" "$PLUGIN_ROOT/scripts/run-$r.sh" --mode "$mode" --repo "$LR" "${base_args[@]}" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
      printf 'two\n' > "$LR/f.txt"; rm -f "$LR/new.txt"
      [ "$rc" -eq 7 ] || fail "$r $mode leg that changed the repo exits 7 for '$mut' (got $rc)"
      exact_line "$WORK/$r-leg.err" "run-$r: the $mode leg changed $LR; inspect git status before trusting it" "$r $mode names the changed repository"
    done
  done
  rc=0; printf x | STUB_MUTATE="printf changed >> '$LR/f.txt'" "$PLUGIN_ROOT/scripts/run-$r.sh" --mode implement --repo "$LR" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  printf 'two\n' > "$LR/f.txt"
  [ "$rc" -eq 0 ] || fail "$r implement may change the repository (got $rc)"
  # --out (and its siblings) inside the repo are not repository changes
  rm -f "$LR"/leg.out*
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR" --base HEAD --out "$LR/leg.out" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$r review with --out inside the repo exits 0 (got $rc): $(cat "$WORK/$r-leg.err")"
  # leg files of an earlier attempt are not under review; a genuinely new file is
  printf 'LEG_MARKER\n' > "$LR/leg.out"; printf 'LEG_MARKER\n' > "$LR/leg.out.stream"; printf 'LEG_MARKER\n' > "$LR/leg.out.exit"
  printf 'brand-new-body\n' > "$LR/new.txt"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR" --base HEAD --out "$LR/leg.out" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$r review with earlier leg files exits 0 (got $rc)"
  contains "$prompt" 'brand-new-body' "$r review diff carries a new untracked file"
  absent "$prompt" 'LEG_MARKER' "$r review diff leaves out the leg's own --out, .stream and .exit"
  rm -f "$LR"/leg.out* "$LR/new.txt"
  # only leg files untracked and nothing tracked changed: nothing to review
  printf 'LEG_MARKER\n' > "$LR2/leg.out"; printf 'LEG_MARKER\n' > "$LR2/leg.out.stream"; printf 'LEG_MARKER\n' > "$LR2/leg.out.exit"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR2" --base HEAD --out "$LR2/leg.out" --timeout 10 >/dev/null 2>"$WORK/$r-leg.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "$r review with only leg files untracked exits 3 (got $rc)"
  contains "$WORK/$r-leg.err" 'no diff to review' "$r names the empty review"
  rm -f "$LR2"/leg.out*
done
printf 'x\n' | "$PLUGIN_ROOT/scripts/run-claude.sh" --mode advise --repo "$LR" --model claude-fable-5-2 --timeout 10 >/dev/null 2>"$WORK/claude-fable52.err" \
  || fail "claude accepts --model claude-fable-5-2: $(cat "$WORK/claude-fable52.err")"
exact_line "$WORK/claude.args" 'claude-fable-5-2' 'claude-fable-5-2 reaches the CLI'
# A failed codex rerun must not leave the previous round's verdict in --out.
printf 'APPROVE\n' > "$LR/stale.out"
rc=0; printf x | STUB_CODEX_RESULT=fake_metadata "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --repo "$LR" --base HEAD --out "$LR/stale.out" --timeout 10 >/dev/null 2>"$WORK/codex-stale.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'a failing codex review exits non-zero'
[ ! -e "$LR/stale.out" ] || fail 'a failed codex rerun removes the previous --out'
rc=0; bash "$PLUGIN_ROOT/scripts/review-gate.sh" --leg codex="$LR/stale.out" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "review-gate rejects the removed --out with exit 2 (got $rc)"
# A rerun that stops in preflight (nothing to review) must not leave the earlier verdict either.
for r in claude codex grok; do
  printf 'APPROVE\n' > "$LR2/stale.out"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR2" --base HEAD --out "$LR2/stale.out" --timeout 10 >/dev/null 2>"$WORK/$r-stale.err" || rc=$?
  [ "$rc" -eq 3 ] || fail "$r review of a clean tree exits 3 (got $rc)"
  [ ! -e "$LR2/stale.out" ] || fail "$r preflight failure removes the previous --out"
done
# A symlinked --out inside the repo keeps pointing at its report and is not a repository change.
for r in claude codex; do
  printf 'APPROVE\n' > "$WORK/ext-report.txt"; ln -s "$WORK/ext-report.txt" "$LR/link.out"
  rc=0; printf x | "$PLUGIN_ROOT/scripts/run-$r.sh" --mode review --repo "$LR" --base HEAD --out "$LR/link.out" --timeout 10 >/dev/null 2>"$WORK/$r-link.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "$r review with a symlinked --out exits 0 (got $rc): $(cat "$WORK/$r-link.err")"
  [ -L "$LR/link.out" ] || fail "$r keeps the --out symlink"
  [ -s "$WORK/ext-report.txt" ] || fail "$r writes the report through the --out symlink"
  rm -f "$LR"/link.out* "$WORK/ext-report.txt"
done
# Grok resolves --out before writing: the symlink as given is still a leg output, not a change.
ln -s "$WORK/ext-grok.txt" "$LR2/link.out"
rc=0; printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$LR2" --base HEAD --out "$LR2/link.out" --timeout 10 >/dev/null 2>"$WORK/grok-link.err" || rc=$?
[ "$rc" -eq 3 ] || fail "grok review of a clean tree with a symlinked --out exits 3 (got $rc): $(cat "$WORK/grok-link.err")"
rm -f "$LR2"/link.out* "$WORK/ext-grok.txt"
# A tracked --out is a leg output too: it stays out of the tracked part of the review diff.
LR3="$WORK/leg-repo-tracked"; mkdir -p "$LR3"; git -C "$LR3" init -q
printf 'one\n' > "$LR3/f.txt"; printf 'TRACKED_MARKER\n' > "$LR3/leg.out"
git -C "$LR3" add f.txt leg.out; git -C "$LR3" -c user.email=t@t -c user.name=t commit -qm base
printf 'two\n' > "$LR3/f.txt"
rc=0; printf x | "$PLUGIN_ROOT/scripts/run-codex.sh" --mode review --repo "$LR3" --base HEAD --out "$LR3/leg.out" --timeout 10 >/dev/null 2>"$WORK/codex-tracked.err" || rc=$?
[ "$rc" -eq 0 ] || fail "codex review with a tracked --out exits 0 (got $rc): $(cat "$WORK/codex-tracked.err")"
contains "$WORK/codex.prompt" '+two' 'codex review diff carries the tracked change'
absent "$WORK/codex.prompt" 'TRACKED_MARKER' 'codex review diff leaves out a tracked --out'
# A custom --stream-log inside the repo is a leg output: an earlier run's stream is not under review.
printf 'GROK_STREAM_MARKER\n' > "$LR/custom.stream"
rc=0; printf x | "$PLUGIN_ROOT/scripts/run-grok.sh" --mode review --repo "$LR" --base HEAD --out "$WORK/grok-leg.out" --stream-log "$LR/custom.stream" --timeout 10 >/dev/null 2>"$WORK/grok-leg.err" || rc=$?
[ "$rc" -eq 0 ] || fail "grok review with an in-repo --stream-log exits 0 (got $rc): $(cat "$WORK/grok-leg.err")"
absent "$WORK/grok.prompt" 'GROK_STREAM_MARKER' 'grok review diff leaves out its --stream-log'
rm -f "$LR"/custom.stream*
PATH="$leg_old_path"
pass 'codex/claude: a non-implement leg that changes the repo exits 7; leg files stay out of the review diff; fable-5-2 accepted'

