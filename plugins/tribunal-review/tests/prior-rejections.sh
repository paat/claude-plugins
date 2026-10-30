#!/usr/bin/env bash
# Sourced by run-tests.sh; CLI stubs retain exactly the prompt they receive.
test_prior_rejections() {
  local work repo fake plugin base head provider rc=0 manifest_sha
  work="$(mktemp -d)"; repo="$work/repo"; fake="$work/bin"; plugin="$work/plugin"
  mkdir -p "$repo" "$fake" "$work/prompts" "$work/home"
  cp -R "$PLUGIN_ROOT" "$plugin"
  if [ -n "${TRIBUNAL_TEST_BASELINE_SCRIPTS:-}" ]; then
    cp "$TRIBUNAL_TEST_BASELINE_SCRIPTS/"{lib.sh,collect-review-evidence.sh} "$plugin/scripts/"
  fi
  bash "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.com
  printf 'one\n' > "$repo/app.txt"
  printf 'Project convention\n' > "$repo/AGENTS.md"
  printf 'Production path\n' > "$repo/reachability.md"
  git -C "$repo" add app.txt AGENTS.md reachability.md
  git -C "$repo" commit -qm base
  base="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -qb feature
  printf 'two\n' > "$repo/app.txt"
  git -C "$repo" commit -qam change
  head="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" remote add origin https://github.com/example/fixture.git
  cat > "$fake/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = repo ]; then
  jq -nc '{nameWithOwner:"example/fixture",url:"https://github.com/example/fixture"}'
else
  jq -nc --arg base "$FIXTURE_BASE" --arg head "$FIXTURE_HEAD" \
    '{number:7,url:"https://github.com/example/fixture/pull/7",state:"OPEN",baseRefName:"main",baseRefOid:$base,headRefName:"feature",headRefOid:$head,body:"Fixture"}'
fi
STUB
  cat > "$fake/provider" <<'STUB'
#!/usr/bin/env bash
provider="${0##*/}"
[ "$provider" != agy ] || provider=gemini
[ "$provider" != dsh ] || provider=deepseek
if [ "$provider" = claude ] && [ "${1:-}" = auth ]; then
  printf '%s\n' '{"loggedIn":true}'; exit
fi
last=""; prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message) last="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    -p) if [ "$provider" = qwen ]; then printf '%s' "$2" > "$FIXTURE_PROMPTS/$provider"; shift 2; else shift; fi ;;
    *) shift ;;
  esac
done
case "$provider" in
  grok|muse) cat "$prompt" > "$FIXTURE_PROMPTS/$provider" ;;
  gemini) jq -r '.message.content' > "$FIXTURE_PROMPTS/$provider" ;;
  qwen) cat >/dev/null ;;
  *) cat > "$FIXTURE_PROMPTS/$provider" ;;
esac
review="$(jq -nc --arg provider "$provider" '{provider:$provider,model:"default",files_examined:["app.txt"],findings:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10,verdict:"APPROVE"}}')"
case "$provider" in
  codex) printf '%s\n' "$review" > "$last"; printf '%s\n' "$review" ;;
  gemini) jq -nc --arg review "$review" '{event:"result",result:{status:"SUCCESS",response:$review}}' ;;
  deepseek) jq -nc --arg review "$review" '{type:"final",text:$review},{type:"status",phase:"turn_end",reason:{kind:"completed"}}' ;;
  grok) jq -nc --argjson review "$review" '{structuredOutput:$review}' ;;
  muse) jq -nc --arg review "$review" '{payload_type:"run.terminal.completed",payload:{text:$review}}' ;;
  claude) jq -nc --argjson review "$review" '{structured_output:$review}' ;;
  qwen) jq -nc --arg review "$review" '{response:$review}' ;;
esac
STUB
  chmod +x "$fake/gh" "$fake/provider"
  for provider in codex agy dsh qwen grok muse claude; do ln -s provider "$fake/$provider"; done
  local -a fixture_env=(env PATH="$fake:$PATH" HOME="$work/home" CODEX_HOME="$work/home/.codex"
    FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_PROMPTS="$work/prompts"
    TRIBUNAL_CODEX=on TRIBUNAL_GEMINI=on TRIBUNAL_DEEPSEEK=on TRIBUNAL_QWEN=on
    TRIBUNAL_GROK=on TRIBUNAL_MUSE=on TRIBUNAL_CLAUDE=on TRIBUNAL_BACKUP_LEGS=off
    TRIBUNAL_LEG_ENV='FIXTURE_*' GEMINI_API_KEY=fixture XAI_API_KEY=fixture
    TRIBUNAL_PLUGIN_ROOT="$plugin")
  printf '[{"title":"Disproved splitlines claim","file":"app.txt","reason":"Execution returns one line"}]\n' > "$work/prior.json"
  local rejection_merge
  rejection_merge="$(sed -n "/^jq -s '/p" "$plugin/skills/closing-tribunal-loop/SKILL.md")"
  printf '[]\n' > "$work/old.json"
  printf '[]\n' > "$work/round.json"
  jq -n '{provider_assessment:{codex:{false_positives:["","Disproved splitlines claim"]}}}' > "$work/rejected.json"
  PRIOR_REJECTIONS="$work/old.json" PREVIOUS_ARBITRATION="$work/rejected.json" \
    ROUND_REJECTIONS="$work/round.json" NEXT_REJECTIONS="$work/merged.json" bash -c "$rejection_merge"
  tr_check 'tribunal T-001 skill jq filters empty false positives' \
    jq -e 'length == 1 and .[0] == {title:"Disproved splitlines claim",file:"",reason:"Disproved splitlines claim"}' "$work/merged.json"
  # Feed the skill output through collect's real prior-rejections validator.
  cp "$work/merged.json" "$work/prior.json"
  "${fixture_env[@]}" bash "$plugin/scripts/collect-review-evidence.sh" collect \
    --repo-root "$repo" --pr 7 --output "$work/collection" --prior-rejections "$work/prior.json" \
    > "$work/collect.json" 2> "$work/collect.err" || rc=$?
  tr_check '#667 prior rejections copied byte-for-byte and digest sealed' \
    bash -c '[ "$1" = 0 ] && cmp -s "$2/prior.json" "$2/collection/prior-rejections.json" && jq -e --arg sha "$(sha256sum "$2/prior.json" | cut -d " " -f 1)" --argjson bytes "$(wc -c < "$2/prior.json")" '\'' .prior_rejections == {path:"prior-rejections.json",sha256:$sha,bytes:$bytes} '\'' "$2/collection/manifest.json" >/dev/null' _ "$rc" "$work"
  for provider in codex gemini deepseek qwen grok muse claude; do
    tr_check "#667 $provider stub receives rejected finding and execution-evidence reminder" \
      bash -c 'test -f "$1" && grep -Fq "Already rejected in earlier rounds — do not re-raise without NEW execution evidence:" "$1" && grep -Fq "Disproved splitlines claim —  — Disproved splitlines claim" "$1"' _ "$work/prompts/$provider"
  done
  jq -n '{tribunal_verdict:{decision:"APPROVE",confidence:0.95,rationale:"All seven fixture legs reviewed the diff."},findings:[],scope_findings:[],provider_assessment:(["codex","gemini","deepseek","qwen","grok","muse","claude"]|map({key:.,value:{findings_accepted:0,findings_rejected:0,false_positives:[],status:"ok"}})|from_entries),conflicts_resolved:[],summary:"All seven legs are clean."}' > "$work/arbitration.json"
  local clean_finalize=1 tamper_rc=0
  if [ "$rc" = 0 ]; then
    manifest_sha="$(jq -r .manifest_sha256 "$work/collect.json")"
    "${fixture_env[@]}" bash "$plugin/scripts/collect-review-evidence.sh" finalize \
      --collection "$work/collection" --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
      > "$work/finalize.json" 2> "$work/finalize.err" && clean_finalize=0
    chmod u+w "$work/collection/prior-rejections.json"
    printf '[]\n' > "$work/collection/prior-rejections.json"
    "${fixture_env[@]}" bash "$plugin/scripts/collect-review-evidence.sh" finalize \
      --collection "$work/collection" --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
      > "$work/tamper.json" 2> "$work/tamper.err" || tamper_rc=$?
  fi
  tr_check '#667 original arbitration schema still finalizes with sealed prior rejections' test "$clean_finalize" = 0
  tr_check '#667 changed prior rejection bytes make finalize refuse' \
    bash -c '[ "$1" = 0 ] && [ "$2" != 0 ] && grep -qi "prior.*rejection" "$3"' _ "$rc" "$tamper_rc" "$work/tamper.err"

  # SHA-256 snapshots of the complete pre-#667 prompts, including both legacy contexts.
  local unchanged=0 index=0
  local -a prompt_hashes=(
    99fb6f31b3ee10a2ef08ac3528232fc5b314231583c32e614c75f98504858b39
    2580510f474dc31170b0ba8a67b02421f1fbb7e8bc5041dfb28d6de36a993fb4
    4ad15afcbb380b208cf282dd75bf7cd31afe594068d04c288683f12e2fef6d24
    33f7d59f99f8e421c9834c90093d0ef79c38ae337119e38a393172b586db060c
    5c5f84669b675f9dffa45840420f95ce578d5235d1989a396f8412e5b649f558
    a39c90ad03139fb0b06cdcaec30595d74f6c133300eef8de5c2bd1f044613e96
    ad9fca233ce8dacc325f5a3ce7eaf28ae266ed34eb39448f785e8a6365084f26
  )
  for provider in codex gemini deepseek qwen grok muse claude; do
    env -u TRIBUNAL_PRIOR_REJECTIONS_FILE bash -c '. "$1"; tribunal_context_block "$2" "$3"; tribunal_review_prompt "$4" review.diff "$3" repo-walking' \
      _ "$plugin/scripts/lib.sh" "$repo" "$work/context" "$provider" > "$work/after"
    [ "$(sha256sum "$work/after" | cut -d ' ' -f 1)" = "${prompt_hashes[$index]}" ] || unchanged=1
    index=$((index+1))
  done
  tr_check '#667 absent input preserves all seven complete prompts byte-for-byte' test "$unchanged" = 0
  mkdir "$work/empty"
  jq -n '[range(25)|{title:("entry-"+tostring),file:"app.txt",reason:"disproved"}]' > "$work/entries.json"
  TRIBUNAL_PRIOR_REJECTIONS_FILE="$work/entries.json" bash -c '. "$1"; tribunal_context_block "$2" "$3"' \
    _ "$plugin/scripts/lib.sh" "$work/empty" "$work/entry-context"
  tr_check '#667 reminder caps entries at twenty' \
    bash -c '[ "$(grep -c "entry-" "$1")" = 20 ] && ! grep -Fq "entry-20" "$1"' _ "$work/entry-context"
  jq -n '[range(25)|{title:("T"*1000),file:("f"*1000),reason:("R"*3000)}]' > "$work/long.json"
  TRIBUNAL_PRIOR_REJECTIONS_FILE="$work/long.json" bash -c '. "$1"; tribunal_context_block "$2" "$3"' \
    _ "$plugin/scripts/lib.sh" "$work/empty" "$work/long-context"
  prior_rejection_json_check() { jq -Rse "$@" >/dev/null; }
  tr_check '#667 reminder has a 4096-character content budget' \
    prior_rejection_json_check '(split("\n")[2:] | join("\n") | rtrimstr("\n") | length) == 4096 and (split("\n")[2] | split(" — ") | map(length)) == [258,256,1024]' "$work/long-context"
  jq -n '[{title:"Title\u0001\u001b\u007f\u0085",file:"app\t.txt",reason:"Proof\r\nverified"}]' > "$work/controls.json"
  TRIBUNAL_PRIOR_REJECTIONS_FILE="$work/controls.json" bash -c '. "$1"; tribunal_context_block "$2" "$3"' \
    _ "$plugin/scripts/lib.sh" "$work/empty" "$work/control-context"
  tr_check '#667 prior rejection text strips C0 DEL and C1 controls' \
    prior_rejection_json_check 'contains("Title — app.txt — Proofverified") and (test("[\u0000-\u0009\u000b-\u001f\u007f-\u009f]")|not)' "$work/control-context"
  local absent_rc=0
  "${fixture_env[@]}" TRIBUNAL_PRIOR_REJECTIONS_FILE="$work/prior.json" bash "$plugin/scripts/collect-review-evidence.sh" collect \
    --repo-root "$repo" --pr 7 --output "$work/absent" > "$work/absent.json" 2> "$work/absent.err" || absent_rc=$?
  tr_check '#667 absent flag excludes ambient unsealed rejections from every leg' \
    bash -c '[ "$1" = 0 ] && jq -e '\''has("prior_rejections")|not'\'' "$2/absent/manifest.json" >/dev/null && ! grep -q "Already rejected in earlier rounds" "$2/prompts/"*' _ "$absent_rc" "$work"
  if [ "${TRIBUNAL_TEST_KEEP_PRIOR_FIXTURE:-off}" = on ]; then printf 'prior fixture: %s\n' "$work"
  else chmod -R u+w "$work"; rm -rf "$work"; fi
}
