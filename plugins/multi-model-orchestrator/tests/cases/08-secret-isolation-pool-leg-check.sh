#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

mmo_ensure_agy_stub
mmo_ensure_muse_stub
mmo_ensure_vibe_stub

# --- secret isolation (#589): untracked .env* refusal and a scrubbed leg environment ---
SE="$WORK/secret-env"; mkdir -p "$SE"; git -C "$SE" init -q
printf '.env*\n' > "$SE/.gitignore"; printf 'x\n' > "$SE/f.txt"
git -C "$SE" add .gitignore f.txt; git -C "$SE" -c user.email=t@t -c user.name=t commit -qm base
printf 'TOKEN=1\n' > "$SE/.env.local"
seen="$WORK/secret-seen"; : > "$seen"
se_env=(env PATH="$WORK/bin:$AG/bin:$MU/bin:$VB/bin:$PATH" STUB_AGY_CALLS="$AG/calls" STUB_MUSE_CALLS="$MU/calls" STUB_VIBE_CALLS="$VB/calls" STUB_SECRET_SEEN="$seen" LEG_SECRET=leak)
for runner in claude codex grok agy muse vibe; do
  rc=0; printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-$runner.sh" --mode implement --repo "$SE" --timeout 30 >/dev/null 2>"$WORK/secret.err" || rc=$?
  [ "$rc" -eq 2 ] || fail "run-$runner refuses a repo holding an untracked .env file (got $rc)"
  contains "$WORK/secret.err" '.env.local' "run-$runner names the env file it refused"
done
rc=0; printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-agy.sh" --mode review --base HEAD --repo "$SE" --timeout 30 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "run-agy review refuses too, since its diff inlines untracked files (got $rc)"
rc=0; printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-muse.sh" --mode research --repo "$SE" --timeout 30 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "run-muse research refuses too, since it keeps read tools (got $rc)"
[ ! -s "$seen" ] || fail 'a refused leg never starts its provider CLI'
printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-claude.sh" --mode research --repo "$SE" --timeout 30 >/dev/null 2>"$WORK/secret.err" \
  || fail "a research leg has no repository access and is not refused: $(cat "$WORK/secret.err")"
printf 'x\n' | "${se_env[@]}" MMO_ALLOW_ENV_FILES=1 bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo "$SE" --timeout 30 >/dev/null 2>&1 \
  || fail 'MMO_ALLOW_ENV_FILES=1 opts out of the refusal'
rm "$SE/.env.local"; : > "$seen"
for runner in claude codex grok agy muse vibe; do
  printf 'x\n' | "${se_env[@]}" bash "$PLUGIN_ROOT/scripts/run-$runner.sh" --mode implement --repo "$SE" --timeout 30 >/dev/null 2>"$WORK/secret.err" \
    || fail "run-$runner runs in a repo without env files: $(cat "$WORK/secret.err")"
  exact_line "$seen" "$runner unset" "run-$runner scrubs an unlisted variable from the leg environment"
done
: > "$seen"
printf 'x\n' | "${se_env[@]}" MMO_LEG_ENV='STUB_* LEG_SECRET' bash "$PLUGIN_ROOT/scripts/run-codex.sh" --mode implement --repo "$SE" --timeout 30 >/dev/null 2>&1 \
  || fail 'run-codex runs with MMO_LEG_ENV additions'
exact_line "$seen" 'codex leak' 'MMO_LEG_ENV passes a listed variable through'
rc=0; MMO_LEG_ENV='BAD-NAME' mmo_leg_env -- true 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "an invalid MMO_LEG_ENV name is rejected (got $rc)"
pass 'Legs refuse untracked .env files and run with a scrubbed environment'

# --- pool.sh: pick filters and orders; run falls through unavailable workers ---
POOL="$PLUGIN_ROOT/scripts/pool.sh"
PL="$WORK/pool"; mkdir -p "$PL/bin" "$PL/calls"
for cli in claude codex grok; do printf '#!/usr/bin/env bash\nexit 0\n' > "$PL/bin/$cli"; chmod +x "$PL/bin/$cli"; done
cp "$AG/bin/agy" "$PL/bin/agy"
cat > "$PL/tiers.tsv" <<'TSV'
# test table
T1	qwen	default	n/a
T1	agy	gemini-3.8-flash	low
T2	claude	claude-sonnet-5	medium
T2	agy	gemini-3.8-flash	low
T2	agy	gemini-3.8-flash	high
T2	codex	gpt-5.6-terra	medium
T3	codex	gpt-6-astra	high
T3	claude	claude-opus-5-5	high
TSV
far=$(( $(date +%s) + 86400 )); soon=$(( $(date +%s) + 60 ))
utc_min() { date -u -d "@$1" +%Y-%m-%dT%H:%MZ; }
printf 'codex 7d 98%% resets %s in 1d as-of x\nclaude 7d_opus 95%% resets %s in 1d as-of x\nclaude 5h 95%% resets %s in 1m as-of x\ngrok unknown (none)\n' \
  "$(utc_min "$far")" "$(utc_min "$far")" "$(utc_min "$soon")" > "$PL/usage.txt"
mkdir -p "$PL/home"
# HOME and PATH hide any real local-Qwen wrapper, so the qwen row answers 75 (no wrapper).
pool_env=(env -u MMO_QWEN_LOCAL_RUN HOME="$PL/home" PATH="$PL/bin:/usr/bin:/bin" MMO_POOL_TIERS="$PL/tiers.tsv" STUB_AGY_CALLS="$PL/calls")
pick() { "${pool_env[@]}" bash "$POOL" pick --usage "$PL/usage.txt" "$@"; }

out="$(pick --tier T2 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f2,4 | tr '\t\n' ': ')" = "claude:medium agy:low agy:high " ] || fail "T2 pick keeps table order and skips a tight provider: $out"
contains "$PL/err" 'skip T2 codex/gpt-5.6-terra: plan window >= 90%' 'pick names the tight window it skipped'
rc=0; pick --tier T3 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "T3 with Astra tight and Opus behind 7d_opus exits 75 (got $rc)"
contains "$PL/err" 'skip T3 claude/claude-opus-5-5: plan window' 'a per-model window binds Opus'
contains "$PL/err" "earliest plan reset $(utc_min "$far")" 'no-worker exit names the earliest reset'
absent "$PL/err" 'claude-sonnet-5' 'T3 never falls to a weaker tier'
out="$(pick --tier T2 --deny agy 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2 | tr '\n' ' ')" = "claude " ] || fail "a short-window 95% that resets before the timeout does not bind; deny removes a provider: $out"
out="$(pick --tier T2 --allow gemini-3.8-flash --prefer agy 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2 | sort -u)" = agy ] || fail "allow by model keeps only that model: $out"
out="$(pick --tier T2 --prefer agy 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2,4 | tr '\t\n' ': ')" = "agy:low agy:high claude:medium " ] || fail "prefer moves a provider first, keeping its table order: $out"
out="$(pick --tier T2 --prefer gpt-5.6-terra --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f3)" = gpt-5.6-terra ] || fail "an exact model preference leads its tier: $out"
out="$(pick --tier T2 --prefer gpt-6-astra --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f1)" = T2 ] || fail "a preferred model cannot pull a higher tier ahead of the requested tier: $out"
out="$(pick --tier T2 --prefer gpt-5.6-terra --deny codex --usage /dev/null 2>/dev/null)"
case "$out" in *gpt-5.6-terra*) fail 'model preference cannot bypass provider denial' ;; esac
out="$(pick --tier T2 --prefer gpt-5.6-terra 2>/dev/null)"
case "$out" in *gpt-5.6-terra*) fail 'model preference cannot bypass tight usage windows' ;; esac
# A worker bound by several tight windows is usable only after the LATEST of them resets.
two_h=$(( $(date +%s) + 7200 )); three_d=$(( $(date +%s) + 259200 ))
printf 'claude 5h 95%% resets %s in 2h as-of x\nclaude 7d 97%% resets %s in 3d as-of x\n' "$(utc_min "$two_h")" "$(utc_min "$three_d")" > "$PL/usage-multi.txt"
rc=0; pick --tier T2 --allow claude --usage "$PL/usage-multi.txt" >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "two tight Claude windows with only Claude allowed exit 75 (got $rc)"
contains "$PL/err" "skip T2 claude/claude-sonnet-5: plan window >= 90% until $(utc_min "$three_d")" 'skip line shows the latest binding reset'
contains "$PL/err" "earliest plan reset $(utc_min "$three_d")" 'no-worker exit shows the latest binding reset of the only worker'
pass 'pool reports the latest reset among the tight windows binding a worker'
# Use it or lose it: a 7d window <= 60% used that resets within 24h moves that provider first.
half=$(( $(date +%s) + 43200 )); twodays=$(( $(date +%s) + 172800 ))
printf 'codex 7d 40%% resets %s in 12h as-of x\nagy 7d 61%% resets %s\nclaude 7d 10%% resets %s\n' \
  "$(utc_min "$half")" "$(utc_min "$half")" "$(utc_min "$twodays")" > "$PL/spare.txt"
out="$(pick --tier T2 --usage "$PL/spare.txt" 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | grep '^T2' | cut -f2,4 | tr '\t\n' ': ')" = "codex:medium claude:medium agy:low agy:high " ] \
  || fail "a spare 7d window resetting within 24h moves its provider first; >60% or >24h does not: $out"
contains "$PL/err" 'use it or lose it: codex 7d 40% used' 'pick names the spare window'
absent "$PL/err" 'lose it: agy' 'a 61% window is not spare'
absent "$PL/err" 'lose it: claude' 'a window resetting after 24h is not spare'
out="$(pick --tier T2 --usage "$PL/spare.txt" --prefer agy 2>/dev/null)"
[ "$(printf '%s\n' "$out" | grep '^T2' | cut -f2,4 | tr '\t\n' ': ')" = "agy:low agy:high codex:medium claude:medium " ] || fail "explicit --prefer stays ahead of a spare provider: $out"
out="$(pick --tier T2 --usage "$PL/spare.txt" --prefer claude-sonnet-5 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f3)" = claude-sonnet-5 ] || fail "task-fit model preference stays ahead of spare headroom: $out"
out="$(pick --tier T3 --usage "$PL/spare.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f1,2 | tr '\t\n' ': ')" = "T3:codex T3:claude " ] || fail "spare reorders T3 within the tier only: $out"
printf 'claude 7d 30%% resets %s\n' "$(utc_min "$half")" > "$PL/spare.txt"
out="$(pick --tier T3 --usage "$PL/spare.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f1,2 | tr '\t\n' ': ')" = "T3:claude T3:codex " ] || fail "a spare provider leads T3 without pulling in a weaker tier: $out"
# Operator-written lines for providers usage.sh cannot read (Grok, Muse) parse like usage.sh's own.
printf 'grok unknown (none)\ngrok 7d 30%% resets %s\n' "$(utc_min "$half")" > "$PL/manual.txt"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --usage "$PL/manual.txt" 2>/dev/null)" || true
[ "$(printf '%s\n' "$out" | head -n1 | cut -f2)" = grok ] || fail "an operator-written spare Grok line moves Grok first: $out"
printf 'grok 7d 95%% resets %s\n' "$(utc_min "$far")" > "$PL/manual.txt"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --usage "$PL/manual.txt" 2>"$PL/err")" || true
contains "$PL/err" 'skip T2 grok/grok-4.7: plan window >= 90%' 'an operator-written tight Grok line skips Grok'
out="$(pick --tier T2 --mode review 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f2 | tr '\n' ' ')" = "claude " ] || fail "review skips advisory engines: $out"
contains "$PL/err" 'advisory reviewer' 'pick names the advisory skip'
out="$(pick --tier T1 --deny agy 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f1,2 | head -n1 | tr '\t' ':')" = "T1:qwen" ] || fail "qwen needs no CLI on PATH to be picked: $out"
out="$(pick --tier T1 --deny agy,qwen 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f1 | sort -u)" = T2 ] || fail "an empty T1 escalates to T2: $out"
rm "$PL/bin/claude"
out="$(pick --tier T2 --deny agy 2>"$PL/err")" || true
contains "$PL/err" 'skip T2 claude/claude-sonnet-5: CLI not installed' 'pick skips a provider whose CLI is missing'
printf '#!/usr/bin/env bash\nexit 0\n' > "$PL/bin/claude"; chmod +x "$PL/bin/claude"
for compat in gpt-5.6-luna; do
  out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T1 --allow "$compat" --usage /dev/null 2>/dev/null)" || true
  [ "$(printf '%s\n' "$out" | head -n1 | cut -f3)" = "$compat" ] || fail "shipped table keeps an allowlisted prior-generation model routable: $compat ($out)"
done
if grep -qiE 'terra|claude-sonnet-5([^-]|$)|gpt-6-sol([^-]|$)' "$PLUGIN_ROOT/scripts/pool-tiers.tsv"; then fail 'shipped table has a terra, claude-sonnet-5 or gpt-6-sol row'; fi
[ "$(awk -F'\t' '$1=="T2" {print $2}' "$PLUGIN_ROOT/scripts/pool-tiers.tsv" | tail -n1)" = vibe ] || fail 'shipped T2 table ends with Vibe'
[ "$(awk -F'\t' '$1=="T2" && $2=="muse" {n=NR} $1=="T2" && $2=="vibe" {v=NR} END {exit !(n && v && n+1==v)}' "$PLUGIN_ROOT/scripts/pool-tiers.tsv"; echo $?)" = 0 ] || fail 'shipped T2 table puts Muse Spark just before Vibe'
cp "$MU/bin/muse" "$PL/bin/muse"
muse_tight_reset=$(( $(date +%s) + 3 * 86400 ))
jq -cn --argjson reset_ms "$((muse_tight_reset * 1000))" --argjson as_of_ms "$(( $(date +%s) * 1000 ))" \
  '{payload_type:"run.usage",payload:{allowance:{weekly:{resets_at_ms:$reset_ms,used_percent:99},window:{resets_at_ms:$reset_ms,used_percent:6},as_of_ms:$as_of_ms}}}' \
  > "$U/muse-tight.jsonl"
muse_usage=$(CODEX_HOME="$U/none" PATH="$U/bin:/usr/bin:/bin" bash "$USAGE_SH" --muse-log "$U/muse-tight.jsonl")
printf '%s\n' "$muse_usage" > "$PL/muse-usage.txt"
case "$muse_usage" in *"muse 7d 99% resets"*) ;; *) fail "usage.sh emits a tight Muse weekly window for pool: $muse_usage" ;; esac
rc=0
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow muse --usage "$PL/muse-usage.txt" 2>"$PL/err")" || rc=$?
[ "$rc" -eq 75 ] || fail "pool pick skips Muse when its weekly window is at 99% (got $rc): $out"
contains "$PL/err" 'skip T2 muse/muse-spark-1.3: plan window >= 90%' 'pick names the tight Muse weekly window'
contains "$PL/err" 'skip T3 muse/muse-wonder-full-1.0: plan window >= 90%' 'a tight Muse window binds every Muse model'
case "$out" in *muse*) fail "a tight Muse window still listed a Muse row: $out" ;; esac
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --prefer gpt-6.1-sol --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f3)" = gpt-6.1-sol ] || fail "exact preference distinguishes models within one provider: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow muse --mode review --usage /dev/null 2>/dev/null)" || true
[ "$(printf '%s\n' "$out" | head -n1 | cut -f2-4 | tr '\t' ' ')" = "muse muse-spark-1.3 medium" ] || fail "shipped T2 table routes Muse Spark, including review: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --usage /dev/null 2>/dev/null)" || true
[ "$(printf '%s\n' "$out" | cut -f2-4 | tr '\t' ' ' | tr '\n' '|')" = "codex gpt-6.2-astra high|claude claude-opus-5-5 high|agy claude-opus-5-5 high|muse muse-wonder-full-1.0 high|codex gpt-6.2-sol high|agy gemini-4-neon high|agy gemini-4-argon high|agy gemini-4-hydrogen high|agy gemini-4-carbon high|codex gpt-6-astra high|codex gpt-6.1-sol high|" ] \
  || fail "shipped T3 table keeps Astra and Opus ahead of muse-wonder-full-1.0: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --allow muse-wonder-full-1.0 --usage /dev/null 2>/dev/null)" || true
[ "$(printf '%s\n' "$out" | cut -f2-4 | tr '\t' ' ')" = "muse muse-wonder-full-1.0 high" ] || fail "allow muse-wonder-full-1.0 keeps only that T3 worker: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --deny muse-wonder-full-1.0 --usage /dev/null 2>/dev/null)" || true
case "$out" in *muse-wonder-full-1.0*) fail "deny muse-wonder-full-1.0 still listed it: $out" ;; esac
[ "$(printf '%s\n' "$out" | cut -f3 | tr '\n' ' ')" = "gpt-6.2-astra claude-opus-5-5 claude-opus-5-5 gpt-6.2-sol gemini-4-neon gemini-4-argon gemini-4-hydrogen gemini-4-carbon gpt-6-astra gpt-6.1-sol " ] || fail "deny muse-wonder-full-1.0 keeps the other T3 workers: $out"
# The agy review fixture leaves f.txt dirty; implement preflight would stop these runs.
git -C "$AR" checkout -q -- f.txt
rm -rf "$PL/muse-calls"; mkdir -p "$PL/muse-calls"
printf 'task\n' | "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" \
  STUB_MUSE_CALLS="$PL/muse-calls" STUB_MUSE_SERVED=muse-wonder-full-1.0 \
  bash "$POOL" run --tier T3 --allow muse-wonder-full-1.0 --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "pool run dispatches muse-wonder-full-1.0: $(cat "$PL/err")"
exact_line "$PL/muse-calls/call.0.args" '--model' 'pool run passes --model for muse-wonder-full-1.0'
exact_line "$PL/muse-calls/call.0.args" 'muse-wonder-full-1.0' 'pool run sends muse-wonder-full-1.0 to the Muse CLI'
exact_line "$PL/muse-calls/call.0.args" 'high' 'pool run sends the T3 high effort'
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --prefer gemini-4-argon --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f3-4 | tr '\t' ' ')" = 'gemini-4-argon high' ] || fail "hard-debugging preference selects Argon high: $out"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T3 --prefer gemini-4-argon --mode review --usage /dev/null 2>/dev/null)"
case "$out" in *gemini-4-argon*) fail 'a stronger agy model cannot bypass advisory-review restrictions' ;; esac
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T4 --prefer gemini-4-argon --usage /dev/null 2>/dev/null)"
case "$out" in *gemini-4-argon*) fail 'task preference cannot lower the high-risk tier floor' ;; esac
printf 'fixture-api-key\n' > "$PL/api-key"
printf 'claude 7d 95%% resets %s\n' "$(utc_min "$far")" > "$PL/claude-usage.txt"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" MMO_CLAUDE_API_KEY_FILE="$PL/api-key" \
  bash "$POOL" pick --tier T4 --usage "$PL/claude-usage.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2-4 | tr '\t' ' ' | tr '\n' '|')" = 'codex gpt-6.2-astra xhigh|codex gpt-6-astra xhigh|' ] \
  || fail "T4 with a tight Claude plan and key file keeps only Codex: $out"
pass 'T4 never routes claude-api with a tight Claude plan and key file'
argon_n="$(find "$PL/calls" -name 'call.*.args' | wc -l | tr -d ' ')"
printf 'debug a bounded problem\n' | "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" \
  bash "$POOL" run --tier T3 --prefer gemini-4-argon --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "pool executes the exact preferred Argon route: $(cat "$PL/err")"
exact_line "$PL/calls/call.${argon_n}.args" 'gemini-4-argon-high' 'pool execution preserves selected model and effort'

# agy quota pools: each per-pool window binds only its own models.
ship() { "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick "$@"; }
printf 'agy 7d_flash 95%% resets %s\n' "$(utc_min "$far")" > "$PL/agy-usage.txt"
out="$(ship --tier T1 --allow agy --usage "$PL/agy-usage.txt" 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f3 | tr '\n' ' ')" = "claude-sonnet-5-5 gemini-4-hydrogen claude-opus-5-5 gemini-4-neon gemini-4-argon gemini-4-hydrogen gemini-4-carbon " ] || fail "a spent agy Gemini pool skips only Flash: $out"
contains "$PL/err" 'skip T1 agy/gemini-3.8-flash: plan window >= 90%' 'pick names the spent Gemini pool'
printf 'agy 5h_claude 95%% resets %s\n' "$(utc_min "$far")" > "$PL/agy-usage.txt"
out="$(ship --tier T1 --allow agy --usage "$PL/agy-usage.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f3 | tr '\n' ' ')" = "gemini-3.8-flash gemini-4-hydrogen gemini-3.8-flash gemini-4-neon gemini-4-argon gemini-4-hydrogen gemini-4-carbon " ] || fail "a spent agy Claude 5h pool skips only agy Claude: $out"
printf 'claude 7d 95%% resets %s\n' "$(utc_min "$far")" > "$PL/agy-usage.txt"
out="$(ship --tier T3 --usage "$PL/agy-usage.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2,3 | tr '\t\n' ':|')" = "codex:gpt-6.2-astra|agy:claude-opus-5-5|muse:muse-wonder-full-1.0|codex:gpt-6.2-sol|agy:gemini-4-neon|agy:gemini-4-argon|agy:gemini-4-hydrogen|agy:gemini-4-carbon|codex:gpt-6-astra|codex:gpt-6.1-sol|" ] \
  || fail "a spent Claude plan moves Opus to agy in its table position: $out"
out="$(ship --tier T2 --usage "$PL/agy-usage.txt" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | head -n1 | cut -f2,3 | tr '\t' ':')" = "agy:claude-sonnet-5-5" ] || fail "a spent Claude plan moves Sonnet to agy first: $out"
printf 'agy 7d_argon 10%% resets %s\n' "$(utc_min "$half")" > "$PL/agy-usage.txt"
out="$(ship --tier T3 --usage "$PL/agy-usage.txt" 2>"$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f3 | tr '\n' ' ')" = "gemini-4-argon gpt-6.2-astra claude-opus-5-5 claude-opus-5-5 muse-wonder-full-1.0 gpt-6.2-sol gemini-4-neon gemini-4-hydrogen gemini-4-carbon gpt-6-astra gpt-6.1-sol " ] \
  || fail "a spare agy Argon pool promotes only Argon: $out"
contains "$PL/err" 'use it or lose it: agy 7d_argon 10% used' 'pick names the spare per-pool window'
out="$(ship --tier T1 --deny claude --usage /dev/null 2>/dev/null)"
case "$out" in *claude*) fail "deny claude removes Claude through every transport: $out" ;; esac
case "$out" in *gemini-3.8-flash*gemini-4-argon*) ;; *) fail "deny claude keeps agy Gemini rows: $out" ;; esac
out="$(ship --tier T1 --allow claude --usage /dev/null 2>/dev/null)"
[ "$(printf '%s\n' "$out" | cut -f2 | sort -u)" = claude ] || fail "allow claude admits no agy transport: $out"
out="$(ship --tier T3 --mode review --allow agy --usage /dev/null 2>"$PL/err")" \
  || fail "review pick keeps agy Opus: $(cat "$PL/err")"
[ "$(printf '%s\n' "$out" | cut -f2,3 | tr '\t' ' ')" = "agy claude-opus-5-5" ] \
  || fail "review allow agy keeps agy Opus and drops other agy models: $out"
contains "$PL/err" 'skip T3 agy/gemini-4-argon: advisory reviewer' 'Argon stays an advisory reviewer'
out="$(ship --tier T3 --mode review --allow agy --deny claude --usage /dev/null 2>"$PL/err")" || true
case "$out" in *claude-opus-5-5*) fail "deny claude still drops agy claude rows in review: $out" ;; esac

# run: the Claude plan is spent at run time (exit 75), so the same Opus model runs through agy.
mv "$PL/bin/claude" "$PL/claude.ok"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "API Error: 429 rate limit\\n"\nexit 1\n' > "$PL/bin/claude"; chmod +x "$PL/bin/claude"
rm -f "$PL/calls"/*
printf 'task\n' | "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" \
  bash "$POOL" run --tier T3 --allow claude,agy --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "a spent Claude plan falls through to agy Opus: $(cat "$PL/err")"
contains "$PL/err" 'pool: claude unavailable (exit 75); next worker' 'the Claude Opus row was tried first'
exact_line "$PL/calls/call.0.args" 'claude-opus-5-5-high' 'agy receives the same Opus model and effort'
contains "$PL/err" 'pool: exit=0 worker=agy model=claude-opus-5-5 effort=high tier=T3' 'pool names the agy Opus worker'
mv "$PL/claude.ok" "$PL/bin/claude"
for bad in '--tier T5' '--tier T2 --mode advise' '--tier T2 --timeout 0' '--tier T2 --bogus'; do
  rc=0
  # shellcheck disable=SC2086
  "${pool_env[@]}" bash "$POOL" pick --usage "$PL/usage.txt" $bad >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "pool rejects '$bad' as usage (got $rc)"
done
rc=0; printf 'x\n' | "${pool_env[@]}" bash "$POOL" run --tier T2 --mode review --usage "$PL/usage.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "pool run --mode review without --base is usage (got $rc)"

# run: the low worker hits a quota (75); the same provider/model is not retried at high (#740).
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 --out "$AR/leg.out" >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "pool exits 75 when the only available provider/model failed (got $rc)"
[ "$(find "$PL/calls" -name 'call.*.args' | wc -l | tr -d ' ')" = 1 ] || fail 'pool tries a failed provider/model only once per run'
contains "$PL/err" 'pool: agy unavailable (exit 75); next worker' 'pool reports the failed worker'
contains "$PL/err" 'skip T2 agy/gemini-3.8-flash: already unavailable (exit 75)' 'pool skips the same-model retry at high'
contains "$PL/err" 'every T2 worker was unavailable' 'pool names the exhausted tier'
rm -f "$AR"/leg.out*

# run: a quota (75) falls through to a different model, whose body reaches the caller.
rm -f "$PL/calls"/*
printf 'T2\tagy\tgemini-3.8-flash\tlow\nT2\tagy\tgemini-4-argon\thigh\n' > "$PL/fallback-tiers.tsv"
out="$(printf 'task\n' | "${pool_env[@]}" MMO_POOL_TIERS="$PL/fallback-tiers.tsv" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low \
  bash "$POOL" run --tier T2 --usage /dev/null --repo "$AR" --timeout 30 --out "$AR/leg.out" 2>"$PL/err")" \
  || fail "pool run falls through to a different model: $(cat "$PL/err")"
exact_line "$PL/calls/call.0.args" 'gemini-3.8-flash-low' 'pool tries the first worker first'
exact_line "$PL/calls/call.1.args" 'gemini-4-argon-high' 'pool moves to the next model on exit 75'
contains "$PL/err" 'pool: agy unavailable (exit 75); next worker' 'pool reports the fall-through'
case "$out" in *done*) ;; *) fail "pool passes the worker's body through: $out" ;; esac
rm -f "$AR"/leg.out*

# run: a worker that changed the repo before failing is not replaced.
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low STUB_AGY_TOUCH="$AR/f.txt" \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 55 ] || fail "pool exits 55 when the failed leg changed the repo (got $rc)"
[ ! -e "$PL/calls/call.1.args" ] || fail 'pool must not hand a dirtied tree to another worker'
contains "$PL/err" 'after changing the repository' 'pool explains why it stopped'
git -C "$AR" checkout -q -- f.txt

# run: a clean fall-through followed by a leg that edits and fails still exits 55.
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low STUB_AGY_TOUCH="$AR/f.txt" \
  STUB_AGY_TOUCH_MODEL=gemini-3.8-flash-low \
  bash "$POOL" run --tier T1 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ -e "$PL/calls/call.0.args" ] || fail 'the agy worker ran after the clean qwen fall-through'
[ "$rc" -eq 55 ] || fail "a dirtying leg after a clean fall-through exits 55 (got $rc)"
contains "$PL/err" 'after changing the repository' 'pool explains why it stopped'
git -C "$AR" checkout -q -- f.txt

# run: T1 agy hits a quota (75); the T2 agy rows are the same provider/model, so the run exits 75 (#740).
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash-low \
  bash "$POOL" run --tier T1 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "pool exits 75 when T2 only repeats the failed T1 provider/model (got $rc)"
contains "$PL/err" 'pool: qwen unavailable (exit 75); next worker' 'the T1 qwen row was tried first'
contains "$PL/err" 'skip T2 agy/gemini-3.8-flash: already unavailable (exit 75)' 'the T2 agy rows are skipped after the T1 quota failure'
contains "$PL/err" 'every T1 worker was unavailable' 'pool names the exhausted tier'

# run: every worker unavailable -> 75 naming the tier.
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_FAIL_MODEL=gemini-3.8-flash \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "pool exits 75 when every worker is unavailable (got $rc)"
contains "$PL/err" 'every T2 worker was unavailable' 'pool names the exhausted tier'

# ASK-76: the shipped table has no row for the dropped provider, and a custom row for it is
# skipped as an unknown provider even with an executable of that name on PATH.
if awk -F '\t' -v p="$gone_provider" '$2 == p {found = 1} END {exit !found}' "$PLUGIN_ROOT/scripts/pool-tiers.tsv"; then
  fail "shipped pool table still routes $gone_provider"
fi
printf '#!/usr/bin/env bash\nexit 0\n' > "$PL/bin/$gone_provider"; chmod +x "$PL/bin/$gone_provider"
printf 'T2\t%s\tglm-5.3\thigh\n' "$gone_provider" > "$PL/gone-tiers.tsv"
rc=0; "${pool_env[@]}" MMO_POOL_TIERS="$PL/gone-tiers.tsv" bash "$POOL" pick --tier T2 --usage /dev/null >"$PL/out" 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "pool rejects a $gone_provider row (got $rc): $(cat "$PL/out")"
contains "$PL/err" "skip T2 $gone_provider/glm-5.3: unknown provider" "pool names the unknown $gone_provider provider"
rm -f "$PL/bin/$gone_provider"
pass 'pool: dropped provider has no shipped row and an unknown custom row is skipped'
printf '#!/usr/bin/env bash\nexit 0\n' > "$PL/bin/vibe"
chmod +x "$PL/bin/vibe"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow vibe --usage /dev/null 2>"$PL/err")" \
  || fail "pool pick T2 --allow vibe failed: $(cat "$PL/err")"
[ "$(printf '%s\n' "$out" | head -n1)" = $'T2\tvibe\tmistral-large-4\tmedium' ] || fail "T2 pick returns the vibe row when others are excluded: $out"
[ "$(printf '%s\n' "$out" | cut -f2 | sort -u)" = vibe ] || fail "allow vibe keeps only vibe rows: $out"
rc=0
"${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow vibe --mode review --usage /dev/null >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "vibe is not picked for review (got $rc)"
contains "$PL/err" 'advisory reviewer' 'vibe stays an advisory reviewer'
# ASK-76 spare pool: with every CLI installed, implement at T2/T3 reaches Muse, agy (Gemini and
# Opus) and Mistral; a review can land on Muse and agy Opus, never on agy Gemini or Mistral.
spare_rows() { "${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --usage /dev/null "$@" 2>/dev/null | cut -f1-3 | tr '\t' ' '; }
out="$(spare_rows --tier T2)"
for want in 'T2 muse muse-spark-1.3' 'T2 agy gemini-4-hydrogen' 'T2 agy gemini-3.8-flash' 'T2 vibe mistral-large-4' \
  'T3 muse muse-wonder-full-1.0' 'T3 agy claude-opus-5-5' 'T3 agy gemini-4-argon' 'T3 vibe mistral-large-4'; do
  printf '%s\n' "$out" | grep -qxF "$want" || fail "T2 implement pick reaches $want: $out"
done
out="$(spare_rows --tier T3)"
for want in 'T3 muse muse-wonder-full-1.0' 'T3 agy claude-opus-5-5' 'T3 agy gemini-4-neon' 'T3 agy gemini-4-argon' 'T3 agy gemini-4-hydrogen' \
  'T3 agy gemini-4-carbon' 'T3 vibe mistral-large-4'; do
  printf '%s\n' "$out" | grep -qxF "$want" || fail "T3 implement pick reaches $want: $out"
done
[ "$(printf '%s\n' "$out" | tail -n1)" = 'T3 vibe mistral-large-4' ] || fail "Mistral stays last in T3: $out"
out="$(spare_rows --tier T2 --mode review)"
for want in 'T2 muse muse-spark-1.3' 'T3 muse muse-wonder-full-1.0' 'T3 agy claude-opus-5-5'; do
  printf '%s\n' "$out" | grep -qxF "$want" || fail "T2 review pick can land on $want: $out"
done
case "$out" in *vibe*|*gemini*) fail "review keeps Mistral and agy Gemini advisory: $out" ;; esac
[ "$(spare_rows --tier T3 --mode review --allow muse,agy)" = $'T3 agy claude-opus-5-5\nT3 muse muse-wonder-full-1.0' ] \
  || fail "T3 review restricted to the spare pool lands on agy Opus, then Muse Wonder"
pass 'pool: spare routes Muse, agy and Mistral reachable for implement at T2/T3; review lands on Muse and agy Opus'
rm -f "$PL/bin/vibe"
out="$("${pool_env[@]}" MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" bash "$POOL" pick --tier T2 --allow vibe --usage /dev/null 2>"$PL/err")" || true
case "$out" in *vibe*) fail "pick skips vibe when the CLI is missing: $out" ;; esac
contains "$PL/err" 'CLI not installed' 'pick names a missing vibe CLI'
mkdir -p "$PL/vibe-calls"
printf 'task\n' | env -u MMO_VIBE_MODEL -u MMO_VIBE_EFFORT -u MMO_VIBE_MAX_TURNS \
  HOME="$PL/home" PATH="$VB/bin:/usr/bin:/bin" \
  MMO_POOL_TIERS="$PLUGIN_ROOT/scripts/pool-tiers.tsv" STUB_VIBE_CALLS="$PL/vibe-calls" \
  bash "$POOL" run --tier T2 --allow vibe --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" \
  || fail "pool run dispatches vibe: $(cat "$PL/err")"
exact_line "$PL/vibe-calls/call.0.args" '--model' 'pool run passes --model to vibe'
exact_line "$PL/vibe-calls/call.0.args" 'mistral-large-4' 'pool run sends mistral-large-4'
exact_line "$PL/vibe-calls/call.0.args" '--thinking' 'pool run passes effort as --thinking'
exact_line "$PL/vibe-calls/call.0.args" 'medium' 'pool run sends the T2 medium effort'
exact_line "$PL/vibe-calls/call.0.args" '--max-price' 'pool run keeps the hard price cap'
exact_line "$PL/vibe-calls/call.0.args" '0' 'pool run caps price at 0'
# run: a provider/model that exited 75 is skipped on later rows of the same run.
rm -rf "$PL/vibe75-calls"; mkdir -p "$PL/vibe75-calls"
printf 'T2\tvibe\tmistral-large-4\tmedium\nT3\tvibe\tmistral-large-4\thigh\n' > "$PL/vibe75-tiers.tsv"
rc=0; printf 'task\n' | env -u MMO_VIBE_MODEL -u MMO_VIBE_EFFORT -u MMO_VIBE_MAX_TURNS \
  HOME="$PL/home" PATH="$VB/bin:/usr/bin:/bin" \
  MMO_POOL_TIERS="$PL/vibe75-tiers.tsv" STUB_VIBE_CALLS="$PL/vibe75-calls" \
  STUB_VIBE_EXIT=3 STUB_VIBE_OUTCOME=price_limit \
  bash "$POOL" run --tier T2 --allow vibe --usage /dev/null --repo "$AR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 75 ] || fail "pool exits 75 when the only provider/model failed (got $rc)"
[ "$(find "$PL/vibe75-calls" -name 'call.*.args' | wc -l | tr -d ' ')" = 1 ] || fail 'pool tries a failed provider/model only once per run'
contains "$PL/err" 'already unavailable (exit 75)' 'pool names the skipped repeat row'
pass 'pool.sh: tiers, headroom, allow/deny/prefer, advisory review skip, escalation, fall-through'

# --- leg-check.sh: deterministic scope/verify/no-change checks, one TSV row per check ---
LC="$WORK/leg-check"; LCR="$LC/repo"; mkdir -p "$LCR/src/lib"
LEG_CHECK="$PLUGIN_ROOT/scripts/leg-check.sh"
git -C "$LCR" init -q
printf 'one\n' > "$LCR/f.txt"; printf 'lib\n' > "$LCR/src/lib/a.txt"
git -C "$LCR" add . && git -C "$LCR" -c user.email=t@t -c user.name=t commit -qm base
lc_base="$(git -C "$LCR" rev-parse HEAD)"
lc_rc() {  # lc_rc WANT ARGS... (stderr in $LC/err)
  local want="$1" got=0; shift
  bash "$LEG_CHECK" "$@" >"$LC/out" 2>"$LC/err" || got=$?
  [ "$got" -eq "$want" ] || fail "leg-check want $want got $got: $* -- $(cat "$LC/err")"
}
lc_row() { tail -n 1 "$MMO_LEG_CHECKS_FILE"; }
lc_rc 10 --repo "$LCR" --base "$lc_base"
contains "$LC/err" 'leg-check: exit=10 check=no_change paths=0' 'leg-check reports no_change'
[ "$(head -n 1 "$MMO_LEG_CHECKS_FILE")" = $'utc_time\trepo\ttask\tcycle\ttier\tprovider\tmodel\teffort\tcheck\tdetail\thead_sha\tchanged_paths\tduration_seconds' ] \
  || fail 'leg-check writes the TSV header once'
printf 'two\n' > "$LCR/f.txt"
lc_rc 0 --repo "$LCR" --base "$lc_base" --allow-paths 'f.txt' --verify-cmd 'grep -q two f.txt && echo "1 passed"' \
  --verify-pattern '[1-9][0-9]* passed' --task "T	7" --cycle 2 --tier T2 --provider codex --model gpt-5.6-terra --effort medium
exact_line "$LC/err" 'leg-check: exit=0 check=pass paths=1' 'leg-check reports a pass'
awk -F '\t' -v head="$lc_base" 'END {
  if (NF != 13 || $2 != "repo" || $3 != "T 7" || $4 != "2" || $5 != "T2" || $6 != "codex" || $7 != "gpt-5.6-terra" ||
      $8 != "medium" || $9 != "pass" || $10 != "" || $11 != head || $12 != "1" || $13 !~ /^[0-9]+$/) exit 1
}' "$MMO_LEG_CHECKS_FILE" || fail "leg-check row fields: $(lc_row)"
# Committed work counts as changed against the base, too.
git -C "$LCR" -c user.email=t@t -c user.name=t commit -qam leg
lc_rc 8 --repo "$LCR" --base "$lc_base" --allow-paths 'src/'
contains "$LC/err" 'changed outside --allow-paths: f.txt' 'leg-check names a committed edit outside the allow-list'
[ "$(lc_row | cut -f9,10)" = $'scope\tf.txt' ] || fail "scope row names the first offending path: $(lc_row)"
git -C "$LCR" reset -q --hard "$lc_base"
printf 'new\n' > "$LCR/stray.txt"; printf 'more\n' >> "$LCR/src/lib/a.txt"
lc_rc 8 --repo "$LCR" --base "$lc_base" --allow-paths 'src/'
contains "$LC/err" 'changed outside --allow-paths: stray.txt' 'leg-check catches an untracked file outside the allow-list'
absent "$LC/err" 'src/lib/a.txt' 'a directory prefix allows nested paths'
lc_rc 0 --repo "$LCR" --base "$lc_base" --allow-paths 'src/,*.txt'
lc_rc 0 --repo "$LCR" --base "$lc_base" --allow-paths 'src/' --out "$LCR/stray.txt"
contains "$LC/err" 'paths=1' 'a leg --out file is not a changed path'
rm -f "$LCR/stray.txt"
lc_rc 9 --repo "$LCR" --base "$lc_base" --verify-cmd 'echo VERIFY_TAIL_MARKER; exit 3'
contains "$LC/err" 'VERIFY_TAIL_MARKER' 'a failed verify prints its output tail'
[ "$(lc_row | cut -f9,10)" = $'verify\tverify-exit=3' ] || fail "verify failure row: $(lc_row)"
lc_rc 9 --repo "$LCR" --base "$lc_base" --verify-cmd 'sleep 30' --verify-timeout 1
[ "$(lc_row | cut -f10)" = verify-timeout ] || fail "verify timeout row: $(lc_row)"
lc_rc 9 --repo "$LCR" --base "$lc_base" --verify-cmd 'echo "0 tests ran"' --verify-pattern '[1-9][0-9]* passed'
[ "$(lc_row | cut -f10)" = verify-pattern ] || fail "verify pattern miss row: $(lc_row)"
printf 'Done.\nWould you like me to add more tests?\n' > "$LC/final.txt"
lc_rc 0 --repo "$LCR" --base "$lc_base" --final "$LC/final.txt"
contains "$LC/err" 'check=pass paths=1 note=asks-to-continue' 'an ask-to-continue final message is advisory only'
[ "$(lc_row | cut -f9,10)" = $'pass\tasks-to-continue' ] || fail "advisory note row: $(lc_row)"
printf 'Done. Assumed UTC.\n' > "$LC/final.txt"
lc_rc 0 --repo "$LCR" --base "$lc_base" --final "$LC/final.txt"
absent "$LC/err" 'note=' 'a plain final message adds no note'
rows_before="$(wc -l < "$MMO_LEG_CHECKS_FILE")"
lc_rc 2 --repo "$LCR"
lc_rc 2 --repo "$LCR" --base no-such-ref
lc_rc 2 --repo "$LCR" --base "$lc_base" --verify-pattern x
lc_rc 2 --repo "$LCR" --base "$lc_base" --verify-cmd true --verify-timeout 0
lc_rc 2 --repo "$LCR" --base "$lc_base" --allow-paths ' , '
lc_rc 2 --repo "$LCR" --base "$lc_base" --bogus x
[ "$(wc -l < "$MMO_LEG_CHECKS_FILE")" -eq "$rows_before" ] || fail 'usage errors record no row'
touch "$LC/not-a-dir"
MMO_LEG_CHECKS_FILE="$LC/not-a-dir/leg.tsv" bash "$LEG_CHECK" --repo "$LCR" --base "$lc_base" 2>/dev/null \
  || fail 'leg-check keeps its exit when the record cannot be written'
git -C "$LCR" checkout -q -- src/lib/a.txt
# Baseline: edits that predate the leg are not its work.
printf 'pre-existing\n' >> "$LCR/src/lib/a.txt"
bash "$LEG_CHECK" --snapshot "$LC/snap" --repo "$LCR" || fail 'leg-check --snapshot succeeds'
lc_rc 10 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt'
contains "$LC/err" 'check=no_change paths=0' 'a no-op leg on a dirty tree is no_change'
printf 'leg\n' >> "$LCR/f.txt"
lc_rc 0 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt'
contains "$LC/err" 'check=pass paths=1' 'a pre-existing unrelated edit does not fail scope'
lc_rc 8 --repo "$LCR" --base "$lc_base" --allow-paths 'f.txt'
git -C "$LCR" checkout -q -- src/lib/a.txt
lc_rc 8 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt'
contains "$LC/err" 'changed outside --allow-paths: src/lib/a.txt' 'reverting a pre-existing edit is a change'
printf 'pre-existing\n' >> "$LCR/src/lib/a.txt"
# A staged out-of-scope change with the working copy restored is still a change.
printf 'staged\n' > "$LCR/staged.txt"; git -C "$LCR" add staged.txt; rm "$LCR/staged.txt"
lc_rc 8 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt'
contains "$LC/err" 'changed outside --allow-paths: staged.txt' 'a staged-only change is enumerated'
lc_rc 8 --repo "$LCR" --base "$lc_base" --allow-paths 'f.txt,src/'
contains "$LC/err" 'changed outside --allow-paths: staged.txt' 'a staged-only change is enumerated without a baseline'
git -C "$LCR" rm -q --cached staged.txt
# A verify that rewrites a disallowed tracked file cannot pass.
lc_rc 8 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --allow-paths 'f.txt' --verify-cmd 'printf x >> src/lib/a.txt'
contains "$LC/err" 'changed outside --allow-paths: src/lib/a.txt' 'scope is re-checked after verify'
[ "$(lc_row | cut -f9,12)" = $'scope\t2' ] || fail "post-verify scope row records the final path count: $(lc_row)"
git -C "$LCR" checkout -q -- src/lib/a.txt; printf 'pre-existing\n' >> "$LCR/src/lib/a.txt"
# The verify command runs in the scrubbed leg environment; MMO_LEG_ENV passes a name through.
LEG_SECRET=leak lc_rc 0 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --verify-cmd 'test "${LEG_SECRET-unset}" = unset'
LEG_SECRET=leak MMO_LEG_ENV=LEG_SECRET lc_rc 0 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap" --verify-cmd 'test "$LEG_SECRET" = leak'
lc_rc 9 --repo "$LCR" --base "$lc_base" --verify-cmd 'exit 124'
[ "$(lc_row | cut -f10)" = verify-exit=124 ] || fail "a fast exit 124 is not a timeout: $(lc_row)"
# A git failure while enumerating is exit 11, never a pass.
mkdir -p "$LC/failgit"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" != "${FAIL_GIT_ON:-diff}" ] || { echo "fatal: injected" >&2; exit 128; }; done\nexec %s "$@"\n' "$(command -v git)" > "$LC/failgit/git"
chmod +x "$LC/failgit/git"
PATH="$LC/failgit:$PATH" lc_rc 11 --repo "$LCR" --base "$lc_base" --allow-paths 'f.txt'
contains "$LC/err" 'check=error' 'a failed git diff reports check=error'
[ "$(lc_row | cut -f9)" = error ] || fail "a failed enumeration records an error row: $(lc_row)"
FAIL_GIT_ON=ls-files PATH="$LC/failgit:$PATH" lc_rc 11 --repo "$LCR" --base "$lc_base" --baseline "$LC/snap"
# Snapshot edge cases, in a fresh repository.
LB="$LC/base-repo"; git init -q "$LB"
printf 'a\n' > "$LB/a.txt"; printf 'd\n' > "$LB/d.txt"
git -C "$LB" add . && git -C "$LB" -c user.email=t@t -c user.name=t commit -qm base
lb_base="$(git -C "$LB" rev-parse HEAD)"
lb_snap() { (cd "$LB" && bash "$LEG_CHECK" --snapshot ./before.snap --repo .) || fail 'leg-check --snapshot inside the worktree succeeds'; }
lb_rc() {  # lb_rc WANT ARGS...: check from inside the worktree against ./before.snap
  local want="$1" got=0; shift
  (cd "$LB" && bash "$LEG_CHECK" --repo . --base "$lb_base" --baseline ./before.snap "$@") >"$LC/out" 2>"$LC/err" || got=$?
  [ "$got" -eq "$want" ] || fail "baseline case want $want got $got: $* -- $(cat "$LC/err")"
}
lb_snap; lb_rc 10  # the snapshot file in the worktree is not worker output
printf 'u\n' > "$LB/u.txt"; lb_snap; printf 'u.txt\n' > "$LB/.gitignore"
lb_rc 0 --allow-paths .gitignore  # an untouched file the worker ignores does not count
rm -f "$LB/.gitignore" "$LB/u.txt"
rm "$LB/d.txt"; mkdir "$LB/d.txt"; lb_snap; printf 'x\n' >> "$LB/a.txt"
lb_rc 0 --allow-paths a.txt  # a plain directory is not fingerprinted through the enclosing repository
git -C "$LB" checkout -q -- a.txt; rmdir "$LB/d.txt"; git -C "$LB" checkout -q -- d.txt
git init -q "$LB/sub"; printf 's\n' > "$LB/sub/s.txt"; git -C "$LB/sub" add s.txt
git -C "$LB/sub" -c user.email=t@t -c user.name=t commit -qm s; printf 'm\n' >> "$LB/sub/s.txt"
lb_snap; lb_rc 10; printf 'm2\n' >> "$LB/sub/s.txt"
lb_rc 8 --allow-paths a.txt
contains "$LC/err" 'changed outside --allow-paths: sub/' 'a further edit inside a dirty nested repository is a change'
rm -rf "$LB/sub"
lb_snap; head -c -1 "$LB/before.snap" > "$LC/trunc.snap"
lc_rc 11 --repo "$LB" --base "$lb_base" --baseline "$LC/trunc.snap"
lc_rc 11 --repo "$LB" --base "$lb_base" --baseline "$LC"
# A previous leg's report at --out, rewritten by a no-op leg, is not a change.
rm -f "$LB/before.snap"
printf 'old report\n' > "$LB/worker-report.txt"; bash "$LEG_CHECK" --snapshot "$LC/out.snap" --repo "$LB" || fail 'snapshot with a leftover report'
printf 'new report\n' > "$LB/worker-report.txt"
lc_rc 10 --repo "$LB" --base "$lb_base" --baseline "$LC/out.snap" --out "$LB/worker-report.txt"
rm -f "$LB/worker-report.txt"
# An outcomes record configured inside the checkout is not worker output.
MMO_OUTCOMES_FILE="$LB/outcomes.tsv" bash "$LEG_CHECK" --snapshot "$LC/rec.snap" --repo "$LB" || fail 'snapshot with an in-repo outcomes file'
printf 'row\n' >> "$LB/outcomes.tsv"
MMO_OUTCOMES_FILE="$LB/outcomes.tsv" lc_rc 10 --repo "$LB" --base "$lb_base" --baseline "$LC/rec.snap"
rm -f "$LB/outcomes.tsv"
contains "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" '`scripts/leg-check.sh --snapshot' 'a pinned runner takes a snapshot before dispatch'
contains "$PLUGIN_ROOT/skills/multi-model-orchestration/SKILL.md" '`--baseline FILE`' 'a pinned runner passes the baseline to the check'
contains "$PLUGIN_ROOT/skills/meta-orchestration/SKILL.md" '`leg-check.sh --snapshot`/`--baseline`' 'meta direct routes wrap the runner in snapshot and baseline'
# --validate checks the contract without a repository.
lc_rc 0 --validate --allow-paths 'f.txt,src/' --verify-cmd true --verify-pattern 'ok' --task 1 --cycle 0
lc_rc 2 --validate --verify-cmd true --verify-pattern '['
lc_rc 2 --validate --allow-paths ','
lc_rc 2 --validate --allow-paths $'f.txt\nsrc/'
contains "$LC/err" 'must not contain a newline' 'a newline in --allow-paths is rejected'
git -C "$LCR" checkout -q -- f.txt src/lib/a.txt
pass 'leg-check.sh: pass, scope, verify, no_change, advisory note, rows, usage errors'

# pool.sh run: contract flags run leg-check after a worker exit 0; without them nothing changes.
rm -f "$PL/calls"/*
rc=0; printf 'task\n' | "${pool_env[@]}" STUB_AGY_TOUCH="$LCR/outside.txt" \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 \
  --allow-paths 'f.txt' --task 9 --cycle 1 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 8 ] || fail "pool run exits 8 when the worker edits outside --allow-paths (got $rc): $(cat "$PL/err")"
contains "$PL/err" 'pool: exit=8 worker=agy model=gemini-3.8-flash effort=low tier=T2 check=scope' 'pool final line carries check=scope'
[ "$(lc_row | cut -f3-9)" = $'9\t1\tT2\tagy\tgemini-3.8-flash\tlow\tscope' ] || fail "pool passes the selected row to leg-check: $(lc_row)"
rows_before="$(wc -l < "$MMO_LEG_CHECKS_FILE")"
rm -f "$LCR/outside.txt"
rc=0; printf 'task\n' | "${pool_env[@]}" \
  bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 0 ] || fail "pool run without contract flags keeps the worker exit (got $rc)"
tail -n 1 "$PL/err" | grep -Fxq 'pool: exit=0 worker=agy model=gemini-3.8-flash effort=low tier=T2' || fail "pool final line unchanged without contract flags: $(tail -n 1 "$PL/err")"
[ "$(wc -l < "$MMO_LEG_CHECKS_FILE")" -eq "$rows_before" ] || fail 'pool run without contract flags runs no leg check'
for bad in "pick --tier T2 --allow-paths f.txt" "run --tier T2 --mode review --base HEAD --verify-cmd true"; do
  rc=0
  # shellcheck disable=SC2086
  printf 'task\n' | "${pool_env[@]}" bash "$POOL" $bad --usage "$PL/usage.txt" --repo "$LCR" >/dev/null 2>"$PL/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "pool rejects contract flags outside run --mode implement: $bad (got $rc)"
  contains "$PL/err" 'apply to run --mode implement only' "pool names the contract-flag restriction: $bad"
done
rm -f "$PL/calls"/*
for bad in "--verify-pattern passed" "--cycle one --allow-paths f.txt" "--allow-paths f.txt --task  " "--allow-paths ," "--verify-cmd true --verify-pattern ["; do
  rc=0
  # shellcheck disable=SC2086
  printf 'task\n' | "${pool_env[@]}" bash "$POOL" run --tier T2 --deny claude $bad --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 >/dev/null 2>"$PL/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "pool rejects a malformed contract before dispatch: $bad (got $rc)"
done
[ -z "$(ls -A "$PL/calls" 2>/dev/null)" ] || fail 'a malformed contract must not reach a worker'
# Dirty start: the pool snapshots the tree, so edits made before dispatch are not the leg's.
printf 'pre-existing\n' >> "$LCR/src/lib/a.txt"
rc=0; printf 'task\n' | "${pool_env[@]}" MMO_ALLOW_DIRTY=snapshot bash "$POOL" run --tier T2 --deny claude --usage "$PL/usage.txt" \
  --repo "$LCR" --timeout 30 --allow-paths 'f.txt' >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 10 ] || fail "a no-op worker on a dirty tree exits 10 (got $rc): $(cat "$PL/err")"
contains "$PL/err" 'check=no_change' 'pool reports no_change on a dirty start'
rc=0; printf 'task\n' | "${pool_env[@]}" MMO_ALLOW_DIRTY=snapshot MMO_ALLOW_UNCOMMITTED=snapshot STUB_AGY_TOUCH="$LCR/f.txt" bash "$POOL" run --tier T2 --deny claude \
  --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 --allow-paths 'f.txt' >/dev/null 2>"$PL/err" || rc=$?
[ "$rc" -eq 0 ] || fail "a pre-existing unrelated edit does not fail the pool's scope check (got $rc): $(cat "$PL/err")"
contains "$PL/err" 'check=pass' 'pool passes a leg on a dirty start'
git -C "$LCR" checkout -q -- f.txt src/lib/a.txt
# Cancelling the pool during a long verify stops the verify instead of waiting for its timeout.
rm -f "$LC/verify.pid"
lc_started=$SECONDS
printf 'task\n' | "${pool_env[@]}" STUB_AGY_TOUCH="$LCR/f.txt" bash "$POOL" run --tier T2 --deny claude \
  --usage "$PL/usage.txt" --repo "$LCR" --timeout 30 --allow-paths 'f.txt' \
  --verify-cmd "echo \$\$ > '$LC/verify.pid'; exec sleep 60" >/dev/null 2>"$PL/err" &
pool_pid=$!
timeout 20 bash -c "until [ -s '$LC/verify.pid' ]; do sleep 0.1; done" || fail 'the pool verify command started'
kill -TERM "$pool_pid"
rc=0; wait "$pool_pid" || rc=$?
[ "$rc" -eq 143 ] || fail "a cancelled pool exits 143 during verify (got $rc): $(cat "$PL/err")"
[ $((SECONDS - lc_started)) -lt 30 ] || fail 'a cancelled pool does not wait for the verify'
! kill -0 "$(cat "$LC/verify.pid")" 2>/dev/null || fail 'cancelling the pool stops the verify command'
git -C "$LCR" checkout -q -- f.txt
pass 'pool.sh run: contract flags gate a worker exit 0 through leg-check'

contains "$PLUGIN_ROOT/skills/route-model-task/SKILL.md" 'pool.sh pick --tier' 'route-model-task picks through the pool'
contains "$PLUGIN_ROOT/skills/route-model-task/SKILL.md" 'never lifts a family exclusion' 'route-model-task keeps a family exclusion when a multi-family runner is allowed'
contains "$PLUGIN_ROOT/skills/route-model-task/references/routing.md" 'pool-tiers.tsv' 'routing names the tier table'
contains "$PLUGIN_ROOT/commands/orchestrate.md" 'pool.sh" run --tier' 'orchestrate dispatches through the pool'
contains "$META_SKILL" 'pool.sh run --tier' 'meta loop dispatches implement legs through the pool'
contains "$META_REFS/usage-limits.md" '--usage <file>' 'usage limits feed the pool'
pass 'Pool is wired into route-model-task, orchestrate, and meta-orchestrate'

