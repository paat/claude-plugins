#!/usr/bin/env bash
# Offline source-checkout/root-drift regression tests; gh and reviewers are fixtures.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
plugin="$work/source-checkout"; other="$work/other-install"; repo="$work/repo"
mkdir -p "$plugin/scripts" "$plugin/schemas" "$plugin/.claude-plugin" "$work/bin" "$repo"
for script in collect-review-evidence.sh lib.sh check-runner-bundle.sh generate-runner-bundle.sh dsh-review.patch.yml; do
  cp "$PLUGIN_ROOT/scripts/$script" "$plugin/scripts/"
done
cp "$PLUGIN_ROOT/schemas/review-output.json" "$plugin/schemas/"
cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$plugin/.claude-plugin/"
cat > "$plugin/scripts/run-codex-review.sh" <<'EOF'
#!/usr/bin/env bash
base="$(git rev-parse --verify "${TRIBUNAL_BASE_REF}^{commit}")"
head="$(git rev-parse --verify 'HEAD^{commit}')"
jq -nc --arg base "$base" --arg head "$head" --arg ref "$TRIBUNAL_BASE_REF" \
  '{provider:"codex",model:"fixture",files_examined:["app.txt"],findings:[],
    summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"},
    diff_stat:{files_changed:1,insertions:1,deletions:0,base:$ref,base_oid:$base,head_oid:$head,truncated:false}}'
EOF
for provider in gemini deepseek qwen grok muse claude; do
  printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' '\''{"provider":"%s","status":"disabled","note":"fixture disabled"}'\''\n' "$provider" \
    > "$plugin/scripts/run-$provider-review.sh"
done
chmod +x "$plugin/scripts/"*.sh
bash "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
cp -a "$plugin" "$other"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name "Test User"
printf 'one\n' > "$repo/app.txt"
git -C "$repo" add app.txt
git -C "$repo" commit -q -m base
printf 'two\n' >> "$repo/app.txt"
git -C "$repo" commit -q -am change
git -C "$repo" remote add origin https://github.com/example/fixture.git
export FIXTURE_BASE="$(git -C "$repo" rev-parse HEAD~1)" FIXTURE_HEAD="$(git -C "$repo" rev-parse HEAD)"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = 'repo view' ]; then
  printf '%s\n' '{"nameWithOwner":"example/fixture","url":"https://github.com/example/fixture"}'
elif [ "$1 $2" = 'pr view' ]; then
  jq -nc --arg base "$FIXTURE_BASE" --arg head "$FIXTURE_HEAD" \
    '{number:7,url:"https://github.com/example/fixture/pull/7",state:"OPEN",baseRefName:"main",
      baseRefOid:$base,headRefName:"feature",headRefOid:$head,body:"Bound PR body"}'
else
  printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 2
fi
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" TRIBUNAL_PLUGIN_ROOT="$plugin" TRIBUNAL_MIN_OK_LEGS=1
export TRIBUNAL_BACKUP_LEGS=off TRIBUNAL_LEG_ENV='FIXTURE_*'
jq -nc '{tribunal_verdict:{decision:"APPROVE",confidence:0.95,rationale:"Fixture review passed."},
  findings:[],scope_findings:[],conflicts_resolved:[],summary:"No blocking findings.",
  provider_assessment:(["codex","gemini","deepseek","qwen","grok","muse","claude"] |
    map({key:.,value:{findings_accepted:0,findings_rejected:0,false_positives:[],status:(if .=="codex" then "ok" else "disabled" end)}}) | from_entries)}' \
  > "$work/arbitration.json"
bash "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
  --output "$work/collection" > "$work/collect.json"
manifest_sha="$(jq -r .manifest_sha256 "$work/collect.json")"
PASS=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@"; then printf 'PASS %s\n' "$label"; PASS=$((PASS+1))
  else printf 'FAIL %s\n' "$label"; FAIL=$((FAIL+1)); fi
}
finalize() {
  bash "$1/scripts/collect-review-evidence.sh" finalize --collection "$work/collection" \
    --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
    > "$work/finalize.json" 2> "$work/finalize.err"
}
same_source() {
  finalize "$plugin" && jq -e '.schema=="tribunal-proof/v1"' "$work/collection/proof.json" >/dev/null
}
check 'same source checkout collects and finalizes with TRIBUNAL_PLUGIN_ROOT' same_source
cross_root() {
  ! finalize "$other" && grep -q 'collection runner path differs' "$work/finalize.err" \
    && grep -Fq "collection root=$plugin" "$work/finalize.err" \
    && grep -Fq "invoked root=$other" "$work/finalize.err"
}
check 'cross-install finalize names collection and invoked roots despite root env' cross_root
cp "$plugin/integrity/runner-bundle.json" "$work/bundle.saved"
printf '\n' >> "$plugin/integrity/runner-bundle.json"
bundle_drift() {
  ! finalize "$plugin" && grep -Fq "runner bundle changed since collect at $plugin" "$work/finalize.err"
}
check 'same-root bundle drift names changed bundle root and refuses finalize' bundle_drift
cp "$work/bundle.saved" "$plugin/integrity/runner-bundle.json"
printf '\n# fixture drift\n' >> "$plugin/scripts/lib.sh"
stale_collect() {
  ! bash "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/stale" > "$work/stale.json" 2> "$work/stale.err" \
    && grep -q 'installed tribunal runner bundle failed integrity validation' "$work/stale.err"
}
check 'stale runner bundle is rejected during collection' stale_collect
printf 'Collector portability: %s PASS / %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
