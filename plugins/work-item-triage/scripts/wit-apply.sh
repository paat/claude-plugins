#!/usr/bin/env bash
# Apply a single exactly authorized action and retain its independent outcome.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/wit-read.sh"
run='' action='' authorization='' config=''
while (($#)); do
  case "$1" in
    --run-dir) run=$2; shift 2;; --action) action=$2; shift 2;;
    --authorization) authorization=$2; shift 2;; --config) config=$2; shift 2;;
    --help) echo 'wit-apply.sh --run-dir DIR --action FILE --authorization FILE [--config FILE]'; exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done
[[ -f $run/register.json && -f $action && -f $authorization ]] || exit 2
jq -e 'type=="object" and (.item_id|type=="string" and length>0) and (.verb=="comment" or .verb=="close") and (.body|type=="string" and length>0) and (keys|sort==["body","item_id","verb"])' "$action" >/dev/null || exit 2
run_id=$(jq -r '.run_id' "$run/register.json")
marker=$(python3 - "$action" "$run_id" <<'PY'
import hashlib,json,sys
card=json.load(open(sys.argv[1])); digest=hashlib.sha256(json.dumps(card,sort_keys=True,separators=(',',':')).encode()).hexdigest()
print('<!-- work-item-triage:'+sys.argv[2]+':'+digest+' -->')
PY
)
action_hash=${marker##*:}; action_hash=${action_hash% -->}
matching='def matching: (($wanted[0].body|sub("\\n+$";""))+"\n\n") as $prefix | (.body|sub("\\n+$";"")) as $text | ($text|startswith($prefix)) and ($text[($prefix|length):]|test("^<!-- work-item-triage:[A-Za-z0-9][A-Za-z0-9._-]*:"+$hash+" -->$"));'
lock="$(dirname "$run")/.apply-lock"
if ! mkdir "$lock" 2>/dev/null; then
  jq -n --arg marker "$marker" '{marker:$marker,status:"ambiguous",reason:"Another apply holds this output lock; no write attempted"}'; exit 1
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"; rmdir "$lock"' EXIT
finish() {
  local status=$1 reason=$2 code=${3:-1}
  jq -n --arg status "$status" --arg reason "$reason" --arg marker "$marker" --arg now "${WIT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" --slurpfile action "$action" '{marker:$marker,action:$action[0],status:$status,reason:$reason,at:$now}' > "$tmp/result"
  if [[ -f $run/applied.json ]]; then
    jq -e '.schema_version==1 and (.actions|type=="array")' "$run/applied.json" >/dev/null || { echo 'Invalid applied.json; refusing to replace history' >&2; exit 1; }
    jq --slurpfile result "$tmp/result" '.actions += $result' "$run/applied.json" > "$tmp/applied"
  else jq -s '{schema_version:1,actions:.}' "$tmp/result" > "$tmp/applied"; fi
  mv "$tmp/applied" "$run/applied.json"; cat "$tmp/result"; exit "$code"
}
jq -e --slurpfile wanted "$action" '.actions|any(. == $wanted[0])' "$authorization" >/dev/null || finish unauthorized 'No matching current authorization'
item_id=$(jq -r '.item_id' "$action"); verb=$(jq -r '.verb' "$action")
source_system=$(jq -r '.source.system' "$run/register.json"); scope=$(jq -r '.source.scope' "$run/register.json")
row=$(jq -c --arg id "$item_id" '[.items[]|select((.id|tostring)==$id)]|if length==1 then .[0] else empty end' "$run/register.json")
[[ -n $row ]] || finish unsupported 'Item is absent or ambiguous in this register'
[[ $(jq -r '.provenance.completeness' <<< "$row") == complete ]] || finish incomplete 'Original item history was incomplete'
adapter='{}'
if [[ $source_system != github ]]; then
  [[ -n $config ]] || finish unsupported 'Configured source needs --config'
  adapter=$(wit_config "$config" "$source_system" 'comment,close') || finish unsupported 'Cannot load source actions'
  jq -e --arg verb "$verb" '.comment and .[$verb]' <<< "$adapter" >/dev/null || finish unsupported 'Source does not support the requested action and marker comment'
fi
read_args=(--system "$source_system" --scope "$scope" --id "$item_id" --full)
[[ -z $config ]] || read_args+=(--config "$config")
"$HERE/wit-read.sh" "${read_args[@]}" > "$tmp/before" || finish unknown 'Current tracker state could not be read'
jq -e '.completeness=="complete" and (.items|length==1)' "$tmp/before" >/dev/null || finish incomplete 'Current history is incomplete'
existing=$(jq --arg hash "$action_hash" --slurpfile wanted "$action" "$matching"'[.items[0].comments[]|select(matching)]|length' "$tmp/before")
((existing<2)) || finish ambiguous 'Multiple comments contain the action marker'
if ((existing==1)); then
  if [[ $verb == comment ]] || [[ $(jq -r '.items[0].state' "$tmp/before") == closed ]]; then finish reused 'Verified existing action marker and requested state' 0; fi
  finish ambiguous 'Marker exists but requested state is not confirmed'
fi
# A fresh assessment must not turn an uncertain earlier write into a blind retry.
prior=$run_id; seen='|'
while [[ -n $prior ]]; do
  [[ $prior =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $seen != *"|$prior|"* ]] || finish unknown 'Invalid or cyclic assessment history'
  seen="$seen$prior|"; prior_dir="$(dirname "$run")/$prior"
  [[ -f $prior_dir/register.json ]] || finish unknown 'Assessment history is unavailable for write reconciliation'
  if [[ -f $prior_dir/applied.json ]] && jq -e --slurpfile wanted "$action" --slurpfile current "$run/register.json" --slurpfile previous "$prior_dir/register.json" '$current[0].source==$previous[0].source and any(.actions[]; .action==$wanted[0] and (.status=="unknown" or .status=="ambiguous"))' "$prior_dir/applied.json" >/dev/null; then
    finish unknown 'An earlier uncertain attempt requires reconciliation; no automatic retry'
  fi
  prior=$(jq -r '.previous_run_id // empty' "$prior_dir/register.json")
done
printf '%s\n' "$row" > "$tmp/row"
jq -e --slurpfile rows "$tmp/row" '$rows[0] as $row | .items[0] | .updatedAt==$row.provenance.updatedAt and .comments_fetched==$row.provenance.comments_fetched and (if $row.provenance.history_digest then .history_digest==$row.provenance.history_digest else true end)' "$tmp/before" >/dev/null || finish stale 'Item or decision history changed since the decision snapshot'
if [[ $verb == close && $(jq -r '.items[0].state' "$tmp/before") == closed ]]; then finish reused 'Item is already closed; no write needed' 0; fi
printf '%s\n\n%s\n' "$(jq -r '.body' "$action")" "$marker" > "$tmp/body"
if [[ $source_system == github ]]; then
  gh issue comment "$item_id" --repo "$scope" --body-file "$tmp/body" > "$tmp/write-result" 2> "$tmp/write-error" || finish unknown 'Comment result is uncertain; reconcile marker before another attempt'
else
  wit_command comment "$item_id" "$(cat "$tmp/body")" > "$tmp/write-result" 2> "$tmp/write-error" || finish unknown 'Comment result is uncertain; reconcile marker before another attempt'
fi
"$HERE/wit-read.sh" "${read_args[@]}" > "$tmp/after" || finish unknown 'Could not verify comment result'
jq -e --arg hash "$action_hash" --slurpfile wanted "$action" "$matching"'.completeness=="complete" and ([.items[0].comments[]|select(matching)]|length==1)' "$tmp/after" >/dev/null || finish unknown 'Comment marker was not uniquely verified'
# Disregard only this action's own marker when checking for concurrent changes.
jq -e --arg hash "$action_hash" --slurpfile wanted "$action" --slurpfile before "$tmp/before" "$matching"'.items[0] as $after | $before[0].items[0] as $prior | $after.state==$prior.state and $after.body==$prior.body and $after.title==$prior.title and $after.relations==$prior.relations and $after.comments_fetched==($prior.comments_fetched+1) and (($after.comments|map(select(matching|not)))==$prior.comments) and (($after.history|map(select(matching|not)))==$prior.history)' "$tmp/after" >/dev/null || finish ambiguous 'Concurrent item or decision history change; dependent writes stopped'
if [[ $verb == close ]]; then
  cp "$tmp/after" "$tmp/pre-status"
  if [[ $source_system == github ]]; then
    gh issue close "$item_id" --repo "$scope" > "$tmp/write-result" 2> "$tmp/write-error" || finish unknown 'Status result is uncertain; re-read before resolving'
  else
    wit_command close "$item_id" "$(cat "$tmp/body")" > "$tmp/write-result" 2> "$tmp/write-error" || finish unknown 'Status result is uncertain; re-read before resolving'
  fi
  "$HERE/wit-read.sh" "${read_args[@]}" > "$tmp/after" || finish unknown 'Could not verify status result'
  jq -e '.completeness=="complete" and .items[0].state=="closed"' "$tmp/after" >/dev/null || finish unknown 'Requested status was not verified'
  jq -e --slurpfile before "$tmp/pre-status" '.items[0] as $after | $before[0].items[0] as $prior | $after.comments==$prior.comments and $after.body==$prior.body and $after.title==$prior.title and (($after.history|map(select(.event!="closed")))==($prior.history|map(select(.event!="closed"))))' "$tmp/after" >/dev/null || finish ambiguous 'Concurrent decision history change during status write; reconcile outcome'
fi
finish created 'Requested change verified; providers do not guarantee atomicity' 0
