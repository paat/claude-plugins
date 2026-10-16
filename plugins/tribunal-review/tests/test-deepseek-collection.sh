#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
work="$(mktemp -d)"; trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
plugin="$work/plugin"; repo="$work/repo"; fake="$work/bin"
mkdir -p "$repo" "$fake"
cp -R "$ROOT" "$plugin"
cat > "$plugin/scripts/fixture-review.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
provider="$1"
if [ "$provider" = codex ] && [ -n "${FIXTURE_CODEX_ERROR:-}" ]; then
  jq -nc --arg e "$FIXTURE_CODEX_ERROR" '{provider:"codex",error:$e}'
elif [ "$provider" = codex ] || { [ "$provider" = qwen ] && [ "${TRIBUNAL_QWEN:-off}" = on ]; }; then
  source "$(dirname "$0")/lib.sh"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  BASE_REF="$TRIBUNAL_BASE_REF"
  tribunal_prepare_diff "$tmp/diff"
  stat="$(tribunal_take_diff_stat "$tmp/diff")"
  printf '%s\n' '{"model":"fixture","files_examined":["app.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' > "$tmp/review"
  tribunal_emit_review "$provider" < "$tmp/review" | tribunal_stamp_diff_stat "$stat"
else
  jq -nc --arg p "$provider" '{provider:$p,status:"disabled",note:"fixture disabled"}'
fi
FIXTURE
for provider in codex gemini qwen grok muse claude; do
  printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/fixture-review.sh" %s\n' "$provider" > "$plugin/scripts/run-$provider-review.sh"
done
cat > "$fake/dsh" <<'FIXTURE'
#!/usr/bin/env bash
cat >/dev/null
if [ -n "${FIXTURE_DSH_ERROR:-}" ]; then
  printf 'dsh: %s: fixture failure %s\n' "$FIXTURE_DSH_ERROR" "$DEEPSEEK_API_KEY" >&2
  jq -nc --arg key "$DEEPSEEK_API_KEY" '{type:"error",text:$key}'
  exit 1
fi
jq -nc --arg text '{"model":"deepseek-v4-pro","files_examined":["app.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}' '{type:"final",text:$text}'
printf '%s\n' '{"type":"status","phase":"turn_end","reason":{"kind":"completed"}}'
FIXTURE
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/qwen"
cat > "$fake/gh" <<'FIXTURE'
#!/usr/bin/env bash
if [ "$1" = repo ]; then
  jq -nc '{nameWithOwner:"example/fixture",url:"https://github.com/example/fixture"}'
else
  jq -nc --arg base "$FIXTURE_BASE" --arg head "$FIXTURE_HEAD" '{number:7,url:"https://github.com/example/fixture/pull/7",state:"OPEN",baseRefName:"main",baseRefOid:$base,headRefName:"feature",headRefOid:$head,body:"Fixture"}'
fi
FIXTURE
chmod +x "$fake/"* "$plugin/scripts/"*.sh
bash "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
git -C "$repo" remote add origin https://github.com/example/fixture.git
printf 'one\n' > "$repo/app.txt"
git -C "$repo" add app.txt
git -C "$repo" commit -qm base
printf 'two\n' >> "$repo/app.txt"
git -C "$repo" commit -qam change
export FIXTURE_BASE="$(git -C "$repo" rev-parse HEAD~1)" FIXTURE_HEAD="$(git -C "$repo" rev-parse HEAD)"
export PATH="$fake:$PATH" TRIBUNAL_LEG_ENV='FIXTURE_*' DEEPSEEK_API_KEY=DSH_COLLECT_SENTINEL_651
export TRIBUNAL_DEEPSEEK=on TRIBUNAL_QWEN=off TRIBUNAL_BACKUP_LEGS=off
export TRIBUNAL_DIAGNOSTIC_TAILS=on
export DSH_HOME="$work/dsh-home"
collect() {
  env "$@" bash "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/$case" > "$work/$case.json" 2> "$work/$case.err"
}
case=enabled
collect
jq -e '(.providers|length)==7 and all(.providers[]; .provider!="glm") and any(.providers[]; .provider=="deepseek" and .status=="ok" and (.wrapper.path|endswith("/run-deepseek-review.sh")))' "$work/$case/manifest.json" >/dev/null
jq -e '.provider=="deepseek" and .summary.verdict=="APPROVE" and (.diff_stat.base_oid|length)>0' "$work/$case/providers/deepseek.json" >/dev/null
printf 'PASS: enabled DeepSeek seals its own artifact without a retired provider\n'
case=backup
collect TRIBUNAL_DEEPSEEK=off TRIBUNAL_BACKUP_LEGS=deepseek FIXTURE_CODEX_ERROR='plan limit: fixture Codex quota'
jq -e 'any(.providers[]; .provider=="deepseek" and .status=="ok")' "$work/$case/manifest.json" >/dev/null
grep -q 'running backup legs for plan-limited legs: deepseek' "$work/$case.err"
printf 'PASS: DeepSeek relaunches as default backup\n'
for error in RATE_LIMIT QUOTA; do
  case="$error"
  collect TRIBUNAL_BACKUP_LEGS=qwen FIXTURE_DSH_ERROR="$error"
  jq -e '.error|startswith("plan limit:")' "$work/$case/providers/deepseek.json" >/dev/null
  jq -e 'any(.providers[]; .provider=="qwen" and .status=="ok")' "$work/$case/manifest.json" >/dev/null
  printf 'PASS: %s relaunches the next backup\n' "$error"
done
if grep -R -F -q "$DEEPSEEK_API_KEY" "$work" --exclude=test-deepseek-collection.sh; then
  printf 'FAIL: sentinel credential leaked into fixture outputs or artifacts\n'
  exit 1
fi
printf 'PASS: sentinel credential absent from all fixture outputs and artifacts\n'
