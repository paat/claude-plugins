#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH_CHECK="$ROOT/scripts/check-campaign-path.sh"
METRICS_CHECK="$ROOT/scripts/check-metrics-preflight.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
mkdir -p "$tmp/docs/ads"
passes=0

pass() { printf 'PASS %s\n' "$1"; passes=$((passes + 1)); }
expect_exit() {
  local name="$1" want="$2"; shift 2
  set +e; "$@" >"$tmp/out" 2>"$tmp/err"; local got=$?; set -e
  [ "$got" -eq "$want" ] || { printf 'FAIL %s: expected %s, got %s\n' "$name" "$want" "$got" >&2; exit 1; }
  pass "$name"
}
in_repo() { bash -c 'cd "$1" && shift && "$@"' _ "$tmp" "$@"; }

expect_exit path-usage 2 bash "$PATH_CHECK"
expect_exit path-escape 2 in_repo bash "$PATH_CHECK" ../outside
expect_exit path-missing 3 in_repo bash "$PATH_CHECK" docs/ads/missing
mkdir -p "$tmp/docs/ads/no-current"
expect_exit path-require-current 3 in_repo bash "$PATH_CHECK" --require-current docs/ads/no-current
[ ! -e "$tmp/docs/ads/no-current/launched_at" ]
pass path-failure-writes-no-marker
mkdir -p "$tmp/outside"
ln -s "$tmp/outside" "$tmp/docs/ads/escape"
expect_exit path-symlink-campaign 3 in_repo bash "$PATH_CHECK" docs/ads/escape
rm "$tmp/docs/ads/escape"

campaign="$tmp/docs/ads/campaign"
mkdir -p "$campaign/iterations/v1"
ln -s iterations/v1 "$campaign/current"
in_repo bash "$PATH_CHECK" docs/ads/campaign >/dev/null
pass path-valid
ln -s "$tmp/outside/brief.md" "$campaign/brief.md"
expect_exit path-symlink-brief 3 in_repo bash "$PATH_CHECK" docs/ads/campaign
rm "$campaign/brief.md"
rm "$campaign/current"
ln -s "$tmp/outside" "$campaign/current"
expect_exit path-symlink-current 3 in_repo bash "$PATH_CHECK" docs/ads/campaign
rm "$campaign/current"
ln -s iterations/v1 "$campaign/current"
ln -s "$tmp/outside" "$campaign/iterations/v1/verification"
expect_exit path-symlink-artifact 3 in_repo bash "$PATH_CHECK" docs/ads/campaign
rm "$campaign/iterations/v1/verification"

expect_exit metrics-usage 2 bash "$METRICS_CHECK"
expect_exit metrics-missing-brief 3 in_repo bash "$METRICS_CHECK" docs/ads/campaign
printf '# brief\n' > "$campaign/brief.md"
expect_exit metrics-missing-current-spec 3 in_repo bash "$METRICS_CHECK" docs/ads/campaign
printf '# spec\n' > "$campaign/iterations/v1/spec.md"
expect_exit metrics-missing-launch 3 in_repo bash "$METRICS_CHECK" docs/ads/campaign
printf 'not-a-timestamp\n' > "$campaign/launched_at"
expect_exit metrics-invalid-timestamp 3 in_repo bash "$METRICS_CHECK" docs/ads/campaign
printf '2026-02-30T00:00:00Z\n' > "$campaign/launched_at"
expect_exit metrics-impossible-date 3 in_repo bash "$METRICS_CHECK" docs/ads/campaign
printf '2026-07-14T00:00:00+24:00\n' > "$campaign/launched_at"
expect_exit metrics-invalid-offset 3 in_repo bash "$METRICS_CHECK" docs/ads/campaign
printf '2026-07-14T00:00:00Z\n' > "$campaign/launched_at"
cat > "$campaign/brief.md" <<'EOF'
- **Google Ads account ID**: <customer ID shown in Google Ads>
- **Google Ads campaign ID**: <numeric campaign ID>
EOF
expect_exit metrics-placeholders 3 in_repo bash "$METRICS_CHECK" docs/ads/campaign
cat > "$campaign/brief.md" <<'EOF'
- **Google Ads account ID**: 123-456-7890
ads_account_id: 987-654-3210
- **Google Ads campaign ID**: 12345
EOF
expect_exit metrics-duplicate-account 3 in_repo bash "$METRICS_CHECK" docs/ads/campaign
cat > "$campaign/brief.md" <<'EOF'
ads_account_id: 123-456-7890
campaign_id: 12345
EOF
legacy="$(in_repo bash "$METRICS_CHECK" docs/ads/campaign)"
printf '%s\n' "$legacy" | grep -qx 'ads_account_id=1234567890'
printf '%s\n' "$legacy" | grep -qx 'campaign_id=12345'
pass metrics-legacy-identities
cat > "$campaign/brief.md" <<'EOF'
- **Google Ads account ID**: 123-456-7890
- **Google Ads campaign ID**: 12345
EOF
current="$(in_repo bash "$METRICS_CHECK" docs/ads/campaign)"
printf '%s\n' "$current" | grep -qx 'ads_account_id=1234567890'
printf '%s\n' "$current" | grep -qx 'campaign_id=12345'
pass metrics-current-identities
expect_exit monitor-placeholder-access 3 in_repo bash "$METRICS_CHECK" --require-read-only docs/ads/campaign
cat >> "$campaign/brief.md" <<'EOF'
- **Google Ads metrics access**: read-only
EOF
monitor_preflight="$(in_repo bash "$METRICS_CHECK" --require-read-only docs/ads/campaign)"
printf '%s\n' "$monitor_preflight" | grep -qx 'metrics_access=read-only'
pass monitor-read-only-access
cat >> "$campaign/brief.md" <<'EOF'
- **Google Ads metrics access**: read-only
EOF
expect_exit monitor-duplicate-access 3 in_repo bash "$METRICS_CHECK" --require-read-only docs/ads/campaign

metrics_cmd="$ROOT/commands/ads-metrics.md"
path_line="$(grep -n 'check-campaign-path.sh.*--require-current' "$metrics_cmd" | head -1 | cut -d: -f1)"
write_line="$(grep -n 'date -Iseconds' "$metrics_cmd" | head -1 | cut -d: -f1)"
[ "$path_line" -lt "$write_line" ]
grep -q 'check-metrics-preflight.sh' "$metrics_cmd"
grep -q -- '--require-read-only' "$metrics_cmd"
grep -q 'do not render a success table' "$metrics_cmd"
grep -q 'expected screenshot plus metrics Markdown exist' "$metrics_cmd"
pass persistent-workflow-gates

monitor="$ROOT/commands/ads-monitor.md"
grep -q '^allowed-tools: Task, Read, Glob, Bash(\${CLAUDE_PLUGIN_ROOT}/scripts/check-metrics-preflight.sh:\*)$' "$monitor"
! sed -n '/^allowed-tools:/p' "$monitor" | grep -Eq 'Write|Edit|Bash\([^$]'
grep -q 'server-enforced.*read-only' "$monitor"
! grep -q 'browser-verification' "$monitor"
grep -q '^codex-sandbox: read-only$' "$monitor"
generated_monitor="$ROOT/skills/google-ads-strategist-ads-monitor-workflow/SKILL.md"
grep -q 'only in a Codex `read-only` sandbox' "$generated_monitor"
! grep -q 'fresh role phase in the current Codex session' "$generated_monitor"
pass monitor-command-boundary

reader="$ROOT/agents/ads-metrics-reader.md"
grep -q '^tools: Read, Glob,' "$reader"
! sed -n '/^tools:/p' "$reader" | grep -Eq '(^|, )(Bash|Write|Edit)(,|$)'
grep -q 'server-enforced.*Read only' "$reader"
pass monitor-agent-boundary

create="$ROOT/commands/ads-create.md"
grep -q 'check-campaign-path.sh' "$create"
grep -q 'exactly one account field and one campaign field' "$create"
grep -q 'Campaign creation incomplete' "$create"
pass creation-conditional-success

printf '%s tests passed\n' "$passes"
