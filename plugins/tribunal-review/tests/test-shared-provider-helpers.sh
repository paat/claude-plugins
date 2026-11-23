#!/usr/bin/env bash
# Focused tests for shared provider helpers (lib-provider.sh) in tribunal-review,
# including the configurable Claude auth timeout and shared failure/env/Grok-auth helpers.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../scripts/lib.sh
. "$PLUGIN_ROOT/scripts/lib.sh"

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

# 1. Claude auth timeout: default 20s and overridable via TRIBUNAL_AUTH_TIMEOUT_SECONDS.
grep -Fq 'TRIBUNAL_AUTH_TIMEOUT_SECONDS:-20' "$PLUGIN_ROOT/scripts/lib.sh" \
  && grep -Fq 'timeout -k 1 "$timeout_s" claude auth status --json' "$PLUGIN_ROOT/scripts/lib-provider.sh" \
  && pass 'tribunal_claude_authenticated defaults to 20s and honors TRIBUNAL_AUTH_TIMEOUT_SECONDS' \
  || fail 'tribunal_claude_authenticated timeout wiring missing'

cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_CLAUDE_SLEEP:-0}" -gt 0 ]; then
  sleep "$STUB_CLAUDE_SLEEP"
fi
printf '%s\n' "${STUB_CLAUDE_STATUS:-{\"loggedIn\":true}}"
EOF
chmod +x "$BIN/claude"

if PATH="$BIN:/usr/bin:/bin" TRIBUNAL_AUTH_TIMEOUT_SECONDS=5 tribunal_claude_authenticated; then
  pass 'tribunal_claude_authenticated succeeds when loggedIn=true'
else
  fail 'tribunal_claude_authenticated failed for loggedIn=true'
fi

if PATH="$BIN:/usr/bin:/bin" STUB_CLAUDE_STATUS='{"loggedIn":false}' TRIBUNAL_AUTH_TIMEOUT_SECONDS=5 tribunal_claude_authenticated; then
  fail 'tribunal_claude_authenticated unexpectedly passed for loggedIn=false'
else
  pass 'tribunal_claude_authenticated fails when loggedIn=false'
fi

started=$SECONDS
if PATH="$BIN:/usr/bin:/bin" STUB_CLAUDE_SLEEP=5 TRIBUNAL_AUTH_TIMEOUT_SECONDS=1 tribunal_claude_authenticated; then
  fail 'tribunal_claude_authenticated unexpectedly passed on timeout'
else
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 4 ] \
    && pass "tribunal_claude_authenticated honors TRIBUNAL_AUTH_TIMEOUT_SECONDS=1 (timed out in ${elapsed}s)" \
    || fail "tribunal_claude_authenticated did not time out promptly (${elapsed}s)"
fi

# 2. Shared plan-limit classification catches Claude/billing/limit patterns and ignores stack frames.
printf '%s\n' "You've hit your weekly limit" > "$WORK/limit-hit.txt"
printf '%s\n' "Credit balance is too low" > "$WORK/limit-credit.txt"
printf '%s\n' "at handler (app.js:402:12)" > "$WORK/stack-402.txt"
printf '%s\n' "HTTP 429 rate limit exceeded" > "$WORK/rate-429.txt"

tribunal_plan_limited 1 "$WORK/limit-hit.txt" \
  && pass 'tribunal_plan_limited detects "hit your ... limit"' \
  || fail 'tribunal_plan_limited missed "hit your ... limit"'
tribunal_plan_limited 1 "$WORK/limit-credit.txt" \
  && pass 'tribunal_plan_limited detects "Credit balance is too low"' \
  || fail 'tribunal_plan_limited missed "Credit balance is too low"'
if tribunal_plan_limited 1 "$WORK/stack-402.txt"; then
  fail 'tribunal_plan_limited misclassified stack-frame :402:12'
else
  pass 'tribunal_plan_limited ignores stack-frame line:col numbers'
fi
if tribunal_plan_limited 1 "$WORK/rate-429.txt"; then
  fail 'tribunal_plan_limited misclassified transient 429 rate limit'
else
  pass 'tribunal_plan_limited does not treat transient 429 as plan limit'
fi
if tribunal_plan_limited 124 "$WORK/limit-hit.txt"; then
  fail 'tribunal_plan_limited misclassified timeout exit 124'
else
  pass 'tribunal_plan_limited never treats exit 124 as plan limit'
fi

# 3. Shared env scrubbing preserves allowlisted + provider + TRIBUNAL_LEG_ENV vars and drops secrets.
env_out="$(SECRET_TOKEN=nope EXTRA_OK=yes PROVIDER_KEY=ok TRIBUNAL_LEG_ENV='EXTRA_OK BAD-NAME' \
  tribunal_leg_env 'PROVIDER_*' -- env 2>"$WORK/env.err")"
if grep -Fq 'PROVIDER_KEY=ok' <<< "$env_out" \
  && grep -Fq 'EXTRA_OK=yes' <<< "$env_out" \
  && ! grep -Fq 'SECRET_TOKEN=' <<< "$env_out" \
  && grep -Fq 'ignoring invalid TRIBUNAL_LEG_ENV name: BAD-NAME' "$WORK/env.err"; then
  pass 'tribunal_leg_env delegates to shared scrubber with warn-on-invalid policy'
else
  fail "tribunal_leg_env mismatch: out=$env_out err=$(cat "$WORK/env.err")"
fi

# 4. Shared Grok isolated config & auth writeback helpers.
cfg="$WORK/grok-config.toml"
provider_grok_write_isolated_config "$cfg"
if grep -Fq '[compat.claude]' "$cfg" && grep -Fq '[compat.codex]' "$cfg" && grep -Fq 'telemetry = false' "$cfg"; then
  pass 'provider_grok_write_isolated_config emits expected compat and feature flags'
else
  fail 'provider_grok_write_isolated_config output incomplete'
fi

host_dir="$WORK/host-grok"
iso_dir="$WORK/iso-grok"
mkdir -p "$host_dir" "$iso_dir"
printf '{"a":{"key":"old","expires_at":"2026-01-01T00:00:00Z"}}\n' > "$host_dir/auth.json"
printf '{"a":{"key":"new","expires_at":"2099-01-01T00:00:00Z"}}\n' > "$iso_dir/auth.json"
mkdir -p "$host_dir/auth.json.lockdir"
printf '99999999\n' > "$host_dir/auth.json.lockdir/pid"
tribunal_grok_auth_writeback "$iso_dir/auth.json" "$host_dir/auth.json"
if grep -Fq '"new"' "$host_dir/auth.json" && [ ! -e "$host_dir/auth.json.lockdir" ]; then
  pass 'tribunal_grok_auth_writeback recovers stale lockdir and writes fresher token'
else
  fail 'tribunal_grok_auth_writeback failed stale lock recovery'
fi

printf '{"a":{"key":"stale","expires_at":"2020-01-01T00:00:00Z"}}\n' > "$iso_dir/auth.json"
tribunal_grok_auth_writeback "$iso_dir/auth.json" "$host_dir/auth.json"
if grep -Fq '"new"' "$host_dir/auth.json"; then
  pass 'tribunal_grok_auth_writeback refuses to regress fresher host expires_at'
else
  fail 'tribunal_grok_auth_writeback clobbered fresher host expires_at'
fi

# 4b. Contended lock retry: waiter retries until holder releases, then writes back without dropping refresh.
printf '{"a":{"key":"base","expires_at":"2026-01-01T00:00:00Z"}}\n' > "$host_dir/auth.json"
printf '{"a":{"key":"after-wait","expires_at":"2099-05-01T00:00:00Z"}}\n' > "$iso_dir/auth.json"
mkdir -p "$host_dir/auth.json.lockdir"
printf '%s\n' "$$" > "$host_dir/auth.json.lockdir/pid"
(
  sleep 0.3
  rm -f "$host_dir/auth.json.lockdir/pid"
  rmdir "$host_dir/auth.json.lockdir"
) &
holder_pid=$!
PROVIDER_GROK_LOCK_WAIT_SECONDS=5 tribunal_grok_auth_writeback "$iso_dir/auth.json" "$host_dir/auth.json" 2>"$WORK/lock-wait.err"
wait "$holder_pid"
if grep -Fq '"after-wait"' "$host_dir/auth.json" && [ ! -e "$host_dir/auth.json.lockdir" ] && [ ! -s "$WORK/lock-wait.err" ]; then
  pass 'provider_grok_auth_writeback retries contended lock and writes back once released'
else
  fail "contended lock retry failed: host=$(cat "$host_dir/auth.json") err=$(cat "$WORK/lock-wait.err")"
fi

# 4c. Contended lock timeout: respects PROVIDER_GROK_LOCK_WAIT_SECONDS=0 and warns without clobbering.
printf '{"a":{"key":"busy-keep","expires_at":"2026-01-01T00:00:00Z"}}\n' > "$host_dir/auth.json"
printf '{"a":{"key":"busy-new","expires_at":"2099-06-01T00:00:00Z"}}\n' > "$iso_dir/auth.json"
mkdir -p "$host_dir/auth.json.lockdir"
printf '%s\n' "$$" > "$host_dir/auth.json.lockdir/pid"
PROVIDER_GROK_LOCK_WAIT_SECONDS=0 tribunal_grok_auth_writeback "$iso_dir/auth.json" "$host_dir/auth.json" 2>"$WORK/lock-busy.err"
rm -f "$host_dir/auth.json.lockdir/pid"
rmdir "$host_dir/auth.json.lockdir"
if grep -Fq '"busy-keep"' "$host_dir/auth.json" && grep -Fq 'lock busy' "$WORK/lock-busy.err"; then
  pass 'provider_grok_auth_writeback honors PROVIDER_GROK_LOCK_WAIT_SECONDS and warns on timeout'
else
  fail "lock timeout behavior unexpected: host=$(cat "$host_dir/auth.json") err=$(cat "$WORK/lock-busy.err")"
fi

# 4d. Concurrent stale-lock reclaim: two racers reclaiming one dead-PID lockdir both finish cleanly with no leftovers.
printf '{"a":{"key":"pre-race","expires_at":"2026-01-01T00:00:00Z"}}\n' > "$host_dir/auth.json"
printf '{"a":{"key":"racer-a","expires_at":"2099-07-01T00:00:00Z"}}\n' > "$iso_dir/a.json"
printf '{"a":{"key":"racer-b","expires_at":"2099-08-01T00:00:00Z"}}\n' > "$iso_dir/b.json"
mkdir -p "$host_dir/auth.json.lockdir"
printf '99999999\n' > "$host_dir/auth.json.lockdir/pid"
(PROVIDER_GROK_LOCK_WAIT_SECONDS=5 tribunal_grok_auth_writeback "$iso_dir/a.json" "$host_dir/auth.json") &
p1=$!
(PROVIDER_GROK_LOCK_WAIT_SECONDS=5 tribunal_grok_auth_writeback "$iso_dir/b.json" "$host_dir/auth.json") &
p2=$!
wait "$p1" "$p2"
leftovers="$(find "$host_dir" -maxdepth 1 -name 'auth.json.lockdir*' | wc -l | tr -d ' ')"
if grep -Fq '"racer-b"' "$host_dir/auth.json" && [ "$leftovers" -eq 0 ]; then
  pass 'concurrent stale-lock reclaim is atomic, keeps freshest token, and leaves no lockdirs'
else
  fail "concurrent stale-lock reclaim failed: host=$(cat "$host_dir/auth.json") leftovers=$leftovers"
fi

# 4e. Best-effort chmod 600: a failing chmod (e.g. non-POSIX FS) does not abort write-back.
chmod_bin="$WORK/chmod-fail-bin"
mkdir -p "$chmod_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$chmod_bin/chmod"
chmod +x "$chmod_bin/chmod"
printf '{"a":{"key":"pre-chmod","expires_at":"2026-01-01T00:00:00Z"}}\n' > "$host_dir/auth.json"
printf '{"a":{"key":"post-chmod","expires_at":"2099-09-01T00:00:00Z"}}\n' > "$iso_dir/chmod.json"
PATH="$chmod_bin:$PATH" tribunal_grok_auth_writeback "$iso_dir/chmod.json" "$host_dir/auth.json"
if grep -Fq '"post-chmod"' "$host_dir/auth.json" && [ ! -e "$host_dir/auth.json.lockdir" ]; then
  pass 'provider_grok_auth_writeback treats chmod 600 as best-effort and still completes writeback'
else
  fail "chmod failure aborted writeback: host=$(cat "$host_dir/auth.json")"
fi

# 4f. Persistent mv failure during stale-lock reclaim must respect deadline instead of spinning.
mv_fail_bin="$WORK/mv-fail-bin"
mkdir -p "$mv_fail_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$mv_fail_bin/mv"
chmod +x "$mv_fail_bin/mv"
printf '{"a":{"key":"pre-mv-fail","expires_at":"2026-01-01T00:00:00Z"}}\n' > "$host_dir/auth.json"
printf '{"a":{"key":"post-mv-fail","expires_at":"2099-10-01T00:00:00Z"}}\n' > "$iso_dir/mv-fail.json"
mkdir -p "$host_dir/auth.json.lockdir"
printf '99999999\n' > "$host_dir/auth.json.lockdir/pid"
started=$SECONDS
PATH="$mv_fail_bin:$PATH" PROVIDER_GROK_LOCK_WAIT_SECONDS=1 \
  tribunal_grok_auth_writeback "$iso_dir/mv-fail.json" "$host_dir/auth.json" 2>"$WORK/mv-fail.err"
elapsed=$((SECONDS - started))
rm -rf -- "$host_dir/auth.json.lockdir" "$host_dir/auth.json.lockdir.reclaim"
if [ "$elapsed" -lt 5 ] && grep -Fq 'lock busy' "$WORK/mv-fail.err" && grep -Fq '"pre-mv-fail"' "$host_dir/auth.json"; then
  pass "persistent mv failure during stale-lock reclaim exits cleanly within deadline (${elapsed}s)"
else
  fail "persistent mv failure did not bound cleanly: elapsed=${elapsed}s err=$(cat "$WORK/mv-fail.err")"
fi

# 5. Sealed runner bundle includes lib-provider.sh and validates cleanly.
if jq -e '.files | any(.path == "scripts/lib-provider.sh")' "$PLUGIN_ROOT/integrity/runner-bundle.json" >/dev/null \
  && bash "$PLUGIN_ROOT/scripts/check-runner-bundle.sh" | jq -e '.status == "valid"' >/dev/null; then
  pass 'runner-bundle.json seals scripts/lib-provider.sh and validates'
else
  fail 'runner-bundle.json missing scripts/lib-provider.sh or invalid'
fi

printf 'Shared provider helpers tests: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
