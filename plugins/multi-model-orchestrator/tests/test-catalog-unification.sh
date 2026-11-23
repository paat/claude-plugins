#!/usr/bin/env bash
# Focused tests for unified model catalog (lib-catalog.sh + model-catalog.tsv + pool-tiers.tsv)
# and shared provider helpers (lib-provider.sh) in multi-model-orchestrator.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPTS="$PLUGIN_ROOT/scripts"
# shellcheck source=../scripts/lib-catalog.sh
. "$SCRIPTS/lib-catalog.sh"
# shellcheck source=../scripts/lib-review-verdict.sh
. "$SCRIPTS/lib-review-verdict.sh"

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Shipped catalog derives every provider cleanly without hardcoded runner allowlists.
claude_list="$(mmo_catalog_list claude '|')"
[ "$claude_list" = 'claude-fable-5-2|claude-fable-5-1|claude-opus-5-5|claude-sonnet-5-5|claude-fable-5|claude-opus-5|claude-sonnet-5|claude-haiku-5-5|claude-haiku-4-5' ] \
  && pass 'claude catalog preserves exact canonical order from pool-tiers.tsv + model-catalog.tsv' \
  || fail "unexpected claude catalog: $claude_list"

grok_list="$(mmo_catalog_list grok ' ')"
[ "$grok_list" = 'grok-4.7 grok-4.6 grok-4.5' ] \
  && pass 'grok catalog combines pool-tiers.tsv + model-catalog.tsv' \
  || fail "unexpected grok catalog: $grok_list"

for m in gemini-3.8-flash gemini-4-neon gemini-4-argon gemini-4-hydrogen gemini-4-carbon claude-opus-5-5 claude-sonnet-5-5; do
  mmo_catalog_has_model agy "$m" || fail "agy catalog missing $m"
done
pass 'agy catalog derives all 7 pool models from pool-tiers.tsv'

for m in gpt-6.2-astra gpt-6.2-sol gpt-6-astra gpt-6.1-sol gpt-6-sol gpt-6-luna gpt-6.1-terra gpt-5.6-terra gpt-5.6-luna; do
  mmo_catalog_has_model codex "$m" || fail "codex catalog missing $m"
done
pass 'codex catalog derives pool + direct-pin models'

for bad in '' '*' 'claude-opus' 'claude-opus-5-5|claude-sonnet-5-5' 'grok-9.9'; do
  if mmo_catalog_has_model claude "$bad" || mmo_catalog_has_model grok "$bad"; then
    fail "mmo_catalog_has_model unexpectedly accepted '$bad'"
  fi
done
pass 'mmo_catalog_has_model rejects empty, wildcard, partial, pipe-joined, and unknown ids'

# 2. Unreadable override tables fail closed.
if MMO_POOL_TIERS="$WORK/missing-tiers.tsv" mmo_catalog_models agy >/dev/null 2>&1; then
  fail 'missing MMO_POOL_TIERS must fail closed'
else
  pass 'missing MMO_POOL_TIERS fails closed'
fi
if MMO_MODEL_CATALOG="$WORK/missing-catalog.tsv" mmo_catalog_models claude >/dev/null 2>&1; then
  fail 'missing MMO_MODEL_CATALOG must fail closed'
else
  pass 'missing MMO_MODEL_CATALOG fails closed'
fi

# 3. Adding a new model to MMO_POOL_TIERS makes all four runners accept it with zero runner edits.
REPO="$WORK/repo"
BIN="$WORK/bin"
mkdir -p "$REPO" "$BIN" "$WORK/home/.grok"
git -C "$REPO" init -q
printf 'hello\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init

cat > "$WORK/custom-tiers.tsv" <<'EOF'
# tier	provider	model	effort
T3	agy	gemini-5-krypton	high
T2	grok	grok-4.9	medium
T3	codex	gpt-6.5-astra	high
T3	claude	claude-opus-6-0	high
T2	claude-api	claude-api-only-1	medium
EOF
: > "$WORK/empty-catalog.tsv"

cat > "$BIN/agy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_OUT:?}"
cat >/dev/null
printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"ok\nAPPROVE"}}'
EOF
cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_OUT:?}"
out=""
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out="$2"; shift 2; continue; }
  shift
done
cat >/dev/null
printf 'ok\nAPPROVE\n' > "$out"
EOF
cat > "$BIN/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_OUT:?}"
debug=""
while [ "$#" -gt 0 ]; do
  [ "$1" = --debug-file ] && { debug="$2"; shift 2; continue; }
  shift
done
[ -z "$debug" ] || printf '2026-11-23T00:00:00Z INFO xai_grok_agent::builder: tools allowlist applied allowed=["read_file","list_dir","grep"]\n' > "$debug"
printf 'ok\nAPPROVE\n'
EOF
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_OUT:?}"
cat >/dev/null
printf 'ok\nAPPROVE\n'
EOF
chmod +x "$BIN/agy" "$BIN/codex" "$BIN/grok" "$BIN/claude"

custom_env=(env PATH="$BIN:/usr/bin:/bin" HOME="$WORK/home" GROK_HOME="$WORK/home/.grok"
  MMO_LEG_ENV=STUB_OUT
  MMO_POOL_TIERS="$WORK/custom-tiers.tsv" MMO_MODEL_CATALOG="$WORK/empty-catalog.tsv"
  MMO_OUTCOMES_FILE="$WORK/outcomes.tsv")

printf 'task\n' | "${custom_env[@]}" STUB_OUT="$WORK/agy.args" bash "$SCRIPTS/run-agy.sh" \
  --mode implement --repo "$REPO" --model gemini-5-krypton --effort high --timeout 10 >/dev/null 2>"$WORK/agy.err" \
  && grep -Fxq 'gemini-5-krypton-high' "$WORK/agy.args" \
  && pass 'run-agy accepts new model added only to MMO_POOL_TIERS' \
  || fail "run-agy failed on custom pool model: $(cat "$WORK/agy.err")"

if printf 'task\n' | "${custom_env[@]}" STUB_OUT="$WORK/agy.args" bash "$SCRIPTS/run-agy.sh" \
  --mode implement --repo "$REPO" --model gemini-3.8-flash --effort high --timeout 10 >/dev/null 2>"$WORK/agy-shipped.err"; then
  pass 'MMO_POOL_TIERS subset extends shipped pool-tiers.tsv without revoking defaults'
else
  fail "MMO_POOL_TIERS unexpectedly revoked shipped agy default: $(cat "$WORK/agy-shipped.err")"
fi

# Retiring a model from pool-tiers.tsv (simulated in a standalone scripts copy) removes it from the runner.
RET_SCRIPTS="$WORK/retired-scripts"
cp -R "$SCRIPTS" "$RET_SCRIPTS"
grep -v 'gemini-4-argon' "$SCRIPTS/pool-tiers.tsv" > "$RET_SCRIPTS/pool-tiers.tsv"
if printf 'task\n' | env PATH="$BIN:/usr/bin:/bin" HOME="$WORK/home" MMO_LEG_ENV=STUB_OUT \
  MMO_OUTCOMES_FILE="$WORK/outcomes.tsv" STUB_OUT="$WORK/agy-ret.args" \
  bash "$RET_SCRIPTS/run-agy.sh" --mode implement --repo "$REPO" --model gemini-4-argon --effort high --timeout 10 >/dev/null 2>"$WORK/agy-rej.err"; then
  fail 'run-agy accepted model removed from pool-tiers.tsv'
else
  err_text="$(cat "$WORK/agy-rej.err")"
  grep -Fq 'unsupported model gemini-4-argon' "$WORK/agy-rej.err" \
    && ! grep -Fq 'gemini-4-argon' <<< "${err_text#*(current catalog:}" \
    && pass 'retiring a model from pool-tiers.tsv immediately removes it from run-agy' \
    || fail "run-agy retired-model error unexpected: $err_text"
fi

printf 'task\n' | "${custom_env[@]}" STUB_OUT="$WORK/codex.args" bash "$SCRIPTS/run-codex.sh" \
  --mode implement --repo "$REPO" --model gpt-6.5-astra --effort ultra --timeout 10 >/dev/null 2>"$WORK/codex.err" \
  && grep -Fxq 'gpt-6.5-astra' "$WORK/codex.args" \
  && pass 'run-codex accepts new Astra model from MMO_POOL_TIERS including ultra effort' \
  || fail "run-codex failed on custom Astra model: $(cat "$WORK/codex.err")"

printf 'task\n' | "${custom_env[@]}" STUB_OUT="$WORK/grok.args" bash "$SCRIPTS/run-grok.sh" \
  --mode advise --repo "$REPO" --model grok-4.9 --effort xhigh --timeout 10 >/dev/null 2>"$WORK/grok.err" \
  && grep -Fxq 'grok-4.9' "$WORK/grok.args" \
  && pass 'run-grok accepts new model from MMO_POOL_TIERS with xhigh effort' \
  || fail "run-grok failed on custom pool model: $(cat "$WORK/grok.err")"

printf 'task\n' | "${custom_env[@]}" STUB_OUT="$WORK/claude.args" bash "$SCRIPTS/run-claude.sh" \
  --mode advise --repo "$REPO" --model claude-opus-6-0 --effort high --timeout 10 >/dev/null 2>"$WORK/claude.err" \
  && grep -Fxq 'claude-opus-6-0' "$WORK/claude.args" \
  && pass 'run-claude accepts new model from MMO_POOL_TIERS' \
  || fail "run-claude failed on custom pool model: $(cat "$WORK/claude.err")"

printf 'task\n' | "${custom_env[@]}" STUB_OUT="$WORK/claude-api.args" bash "$SCRIPTS/run-claude.sh" \
  --mode advise --repo "$REPO" --model claude-api-only-1 --effort medium --timeout 10 >/dev/null 2>"$WORK/claude-api.err" \
  && grep -Fxq 'claude-api-only-1' "$WORK/claude-api.args" \
  && pass 'run-claude accepts claude-api models from MMO_POOL_TIERS' \
  || fail "run-claude failed on claude-api pool model: $(cat "$WORK/claude-api.err")"

# 4. Usage strings reflect dynamic catalog and static metadata drops ephemeral model-generation names.
agy_help="$("${custom_env[@]}" bash "$SCRIPTS/run-agy.sh" --help)"
case "$agy_help" in *'gemini-5-krypton'*) pass 'run-agy --help includes dynamic MMO_POOL_TIERS model' ;; *) fail "run-agy --help stale: $agy_help" ;; esac
grok_help="$("${custom_env[@]}" bash "$SCRIPTS/run-grok.sh" --help)"
case "$grok_help" in *'grok-4.9'*) pass 'run-grok --help includes dynamic MMO_POOL_TIERS model' ;; *) fail "run-grok --help stale: $grok_help" ;; esac

if grep -q 'Flash/Argon' "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
    "$PLUGIN_ROOT/skills/route-model-task/SKILL.md" \
    "$PLUGIN_ROOT/README.md"; then
  fail 'stale Gemini Flash/Argon wording still present in static plugin metadata/docs'
else
  pass 'stale Gemini Flash/Argon wording removed from plugin metadata and docs'
fi

# 5. Runners no longer hardcode allowlist strings.
if grep -Eq 'claude_model_catalog=|gpt-6\.1-terra|gemini-4-carbon|grok-4\.7\|grok-4\.6' \
    "$SCRIPTS/run-agy.sh" "$SCRIPTS/run-codex.sh" "$SCRIPTS/run-grok.sh" "$SCRIPTS/run-claude.sh"; then
  fail 'hardcoded model allowlist still present in run-*.sh'
else
  pass 'run-agy/codex/grok/claude have no hardcoded model allowlists'
fi

printf 'Catalog unification tests: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
