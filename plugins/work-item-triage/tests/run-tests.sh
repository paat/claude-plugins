#!/usr/bin/env bash
# Deterministic adapter/register contracts; these do not score model reasoning.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts"
FIX="$HERE/fixtures"
pass=0 fail=0
check() {
  if [ "$2" = "$3" ]; then printf 'PASS  %s\n' "$1"; pass=$((pass + 1));
  else printf 'FAIL  %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
truth() { jq -e "$2" "$1" >/dev/null 2>&1; printf '%s' "$?"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin" "$TMP/state"
export WIT_FIX="$FIX" WIT_LOG="$TMP/calls" WIT_STATE="$TMP/state"
export WIT_MODE=worked WIT_MUTATION=normal WIT_NOW=2026-09-10T10:00:00Z
export PATH="$TMP/bin:$PATH"
: > "$WIT_LOG"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WIT_LOG"
if [ "$1" = api ]; then
  endpoint="$2"
  if [[ "$endpoint" == *'/timeline?'* ]]; then
    if [ "$WIT_MODE" = shared-relations ]; then
      printf '%s\n' '[{"source":{"issue":{"number":12,"html_url":"https://github.com/sample/project/issues/12"}}},{"source":{"issue":{"number":12,"html_url":"https://github.com/other/project/issues/12"}}}]'; exit
    fi
    if [ -f "$WIT_STATE/comments.json" ]; then jq '[last|{id:77,event:"commented",body:.body,created_at:"2026-09-10T10:00:00Z"}]' "$WIT_STATE/comments.json"; else printf '[]\n'; fi
    exit
  fi
  if [[ "$endpoint" == *'/comments?'* ]]; then
    [ "$WIT_MODE" = missing-history ] && exit 1
    if [ -f "$WIT_STATE/comments.json" ]; then cat "$WIT_STATE/comments.json";
    elif [ "$WIT_MODE" = worked ]; then
      id="${endpoint#*/issues/}"; id="${id%%/*}"
      jq -s --argjson id "$id" '[.[]|select(.number==$id)|.fixture_comments[]?]' "$WIT_FIX"/{shipped-alert,future-database,upload-next-action,invoice-consolidation,conditional-successor,owner-permitted-behavior,rare-high-consequence,unavailable-incident-data,conditional-activation,changed-owner-ruling}.json 2>/dev/null || printf '[]\n'
    else jq '.fixture_comments // []' "$WIT_FIX/github-parity.json"; fi
    exit
  fi
  if [[ "$endpoint" == *'/issues?'* ]]; then
    case "$WIT_MODE" in
      body-reference|missing-relation|shared-relations)
        jq --arg mode "$WIT_MODE" '[. + {body:"Use #336699 for the banner. See also #12",relations:(if $mode=="missing-relation" then [{id:"336699",kind:"related"}] else [] end)}]' "$WIT_FIX/github-parity.json" ;;
      large) jq '[. + {body:("long evidence " * 12000)}]' "$WIT_FIX/github-parity.json" ;;
      worked) jq -s '[.[] | del(.fixture_comments)]' "$WIT_FIX"/{shipped-alert,future-database,upload-next-action,invoice-consolidation,conditional-successor,owner-permitted-behavior,rare-high-consequence,unavailable-incident-data,conditional-activation,changed-owner-ruling}.json ;;
      pages|truncated)
        if [[ "$endpoint" == *'page=1' ]]; then cat "$WIT_FIX/github-page1.json";
        elif [ "$WIT_MODE" = truncated ]; then cat "$WIT_FIX/github-page2-truncated.json"; exit 1;
        else jq '[. + {number:1101,title:"Final synthetic item",html_url:"https://tracker.example/items/1101"}]' "$WIT_FIX/github-parity.json"; fi ;;
      *) jq '[.]' "$WIT_FIX/github-parity.json" ;;
    esac
    exit
  fi
  if [[ "$endpoint" == *'/issues/'* ]]; then
    [[ "$endpoint" != */issues/336699 ]] || exit 1
    if [[ "$endpoint" == */issues/12 ]]; then jq -n --arg url "https://github.com/${endpoint#repos/}" '{number:12,title:"Linked item",state:"open",html_url:$url}'; exit; fi
    if [[ "$endpoint" == */issues/302 ]]; then printf '%s\n' '{"number":302,"title":"Existing support policy","state":"open","html_url":"https://tracker.example/items/302"}'; exit; fi
    if [ "$WIT_MUTATION" = concurrent ]; then jq '.updated_at="2026-09-10T12:00:00Z"' "$WIT_FIX/github-parity.json";
    elif [ -f "$WIT_STATE/closed" ]; then jq '.state="closed"' "$WIT_FIX/github-parity.json";
    else cat "$WIT_FIX/github-parity.json"; fi
    exit
  fi
fi
if [ "$1 $2" = 'issue comment' ]; then
  [ "$WIT_MUTATION" = unknown ] && exit 1
  body=''
  while [ "$#" -gt 0 ]; do
    case "$1" in --body) body="$2"; shift;; --body-file) body="$(cat "$2")"; shift;; esac
    shift
  done
  jq --arg body "$body" '(.fixture_comments // []) + [{id:77,body:$body,created_at:"2026-09-10T10:00:00Z"}]' "$WIT_FIX/github-parity.json" > "$WIT_STATE/comments.json"
  printf 'https://tracker.example/items/301#comment-77\n'; exit
fi
if [ "$1 $2" = 'issue close' ]; then touch "$WIT_STATE/closed"; exit; fi
printf 'Unexpected gh call: %s\n' "$*" >&2
exit 2
STUB
cat > "$TMP/bin/plane-stub" <<'STUB'
#!/usr/bin/env bash
printf 'plane %s\n' "$*" >> "$WIT_LOG"
case "$1" in
  list) [ "${2:-}" = 1 ] || exit 2; jq '{items:[.],next:false,complete:true}' "$WIT_FIX/plane-parity.json" ;;
  show) [ "${2:-}" = 301 ] || exit 2; cat "$WIT_FIX/plane-parity.json" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/gh" "$TMP/bin/plane-stub"
jq -n '{sources:[{name:"plane",list:"plane-stub list",show:"plane-stub show"}]}' > "$TMP/plane.json"
read_snapshot() { bash "$SCRIPTS/wit-read.sh" --system "$1" --scope sample/project "${@:2}"; }
write_register() { bash "$SCRIPTS/wit-register.sh" --snapshot "$1" --decisions "$2" --output-dir "$TMP/output" --run-id "$3"; }
# All ten worked examples exercise real normalization and the same writer.
read_snapshot github > "$TMP/worked.json"
check 'worked backlog read succeeds' 0 "$?"
jq -s '{items:.}' "$HERE"/expected/*.json > "$TMP/decisions.json"
run="$(write_register "$TMP/worked.json" "$TMP/decisions.json" worked)"
check 'worked register succeeds' 0 "$?"
register="$run/register.json"
check '1 schema and evidence enums' 0 "$(truth "$register" 'all(.items[]; has("id") and has("outcome") and has("evidence") and has("necessity") and has("readiness") and has("response") and has("cost") and has("disposition") and (.evidence.class as $c | ["reproduced","source-reachable","hypothetical","unavailable"]|index($c)!=null))')"
check '1 existing direction disposition enum' 0 "$(truth "$register" 'all(.items[]; .direction=="existing" and (.disposition as $d | ["implement-minimally","consolidate-into","verify-first","defer","close-completed","close-duplicate"]|index($d)!=null))')"
check '2 exactly one disposition per worked item' 0 "$(truth "$register" '(.items|length)==10 and ([.items[].id]|unique|length)==10')"
check '4 unavailable evidence contains no frequency' 0 "$(truth "$register" 'any(.items[]; .evidence.class=="unavailable") and all(.items[]|select(.evidence.class=="unavailable"); .evidence|has("frequency")|not)')"
check '5 defer has concrete source or dependency trigger' 0 "$(truth "$register" 'all(.items[]|select(.disposition=="defer"); .revisit_trigger|test("[0-9]{4}-[0-9]{2}-[0-9]{2}|#[0-9]+|Approved migration plan"))')"
check '6 necessity and readiness remain independent' 0 "$(truth "$register" 'any(.items[]; .necessity=="required" and .readiness=="blocked")')"
implement_now="$(awk '/^## Implement now/{emit=1;next} /^## /{emit=0} emit' "$run/queue.md")"
check '6 necessary blocked rows excluded from implement-now' 0 "$(printf '%s\n' "$implement_now" | grep -Ec 'Retain authority|Keep existing item open|Check activation evidence' || true)"
check '6 implement-now contains eligible minimum task' 1 "$(printf '%s\n' "$implement_now" | grep -c 'Priority .*Improve existing inline feedback' || true)"
check '6 fresh-session queue retains scope blockers stop and enforcement' 4 "$(grep -Eo 'Minimum scope:|Prerequisites:|Stop/refresh:|enforcement: instruction-only' <<< "$implement_now" | sort -u | wc -l | tr -d ' ')"
check 'queue preserves consolidation target owner' 1 "$(grep -c 'Target owner: 94' "$run/queue.md" || true)"
check 'summary preserves consolidation target owner' 1 "$(grep -c 'Target owner: 94' "$run/summary.md" || true)"
check 'rare irreversible consequence leads worked implement queue' 7 "$(sed -n 's/^- Priority [0-9]* — \([^:]*\):.*/\1/p' <<< "$implement_now" | head -n 1)"
# Both queue sections and summary must rank required work above discretionary priority 1.
jq '{items:[.items[0] + {id:"cosmetic-ready",necessity:"discretionary",priority:1}, .items[0] + {id:"payment-ready",necessity:"required",priority:2}, .items[0] + {id:"cosmetic-blocked",necessity:"discretionary",priority:1,readiness:"blocked"}, .items[0] + {id:"payment-blocked",necessity:"required",priority:2,readiness:"blocked"}]}' "$TMP/decisions.json" | jq '(.items[].disposition)="implement-minimally"' > "$TMP/ordering-decisions.json"
jq --slurpfile d "$TMP/ordering-decisions.json" '.items[0] as $item | .items=[$d[0].items[] | $item + {id:.id}]' "$TMP/worked.json" > "$TMP/ordering-snapshot.json"
ordering_run="$(write_register "$TMP/ordering-snapshot.json" "$TMP/ordering-decisions.json" ordering)"
check 'necessity orders both queue sections and summary before priority' 'payment-ready cosmetic-ready payment-blocked cosmetic-blocked |payment-blocked payment-ready cosmetic-blocked cosmetic-ready ' "$(sed -n 's/^- Priority [0-9]* — \([^:]*\):.*/\1/p' "$ordering_run/queue.md" | tr '\n' ' ')|$(sed -n 's/^## \([^:]*\):.*/\1/p' "$ordering_run/summary.md" | tr '\n' ' ')"
# The fixture answers are authored examples, compared as field contracts.
for expected in "$HERE"/expected/*.json; do
  check "scenario $(basename "$expected" .json) preserves obligations" 0 "$(jq -e --slurpfile want "$expected" '.items[]|select(.id==$want[0].id)|. as $row|all($want[0]|del(.code_refs)|keys[]; $row[.] == $want[0][.]) and (.provenance.code_refs|length)==0' "$register" >/dev/null 2>&1; printf '%s' "$?")"
done
# Writer validation rejects a second direction enum and invented incidence.
jq '.items[0].disposition="do-not-file"' "$TMP/decisions.json" > "$TMP/invalid.json"
write_register "$TMP/worked.json" "$TMP/invalid.json" invalid-enum >/dev/null 2>&1
check '1 wrong direction enum rejected' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
jq '(.items[]|select(.evidence.class=="unavailable")).evidence.frequency="rare"' "$TMP/decisions.json" > "$TMP/invalid.json"
write_register "$TMP/worked.json" "$TMP/invalid.json" invalid-frequency >/dev/null 2>&1
check '4 invented frequency rejected' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
for rule in defer-trigger id-coverage necessity enforcement; do
  case "$rule" in
    defer-trigger) filter='(.items[]|select(.disposition=="defer")).revisit_trigger="someday"' ;;
    id-coverage) filter='.items[0].id="absent-from-snapshot"' ;;
    necessity) filter='.items[0].necessity="optional"' ;;
    enforcement) filter='.items[0].enforcement.class="automatic"' ;;
  esac
  jq "$filter" "$TMP/decisions.json" > "$TMP/invalid.json"
  write_register "$TMP/worked.json" "$TMP/invalid.json" "invalid-$rule" >/dev/null 2>&1
  check "validator rejects invalid $rule" 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
done
cp "$register" "$TMP/original-register.json"
export WIT_NOW=2026-09-10T11:00:00Z
second="$(write_register "$TMP/worked.json" "$TMP/decisions.json" rerun)"
check '7 rerun succeeds with separate directory' 0 "$?"
cmp -s "$register" "$TMP/original-register.json"
check '7 first register byte-identical' 0 "$?"
check '7 supersedes names previous run' 0 "$(truth "$second/register.json" 'all(.items[]; .supersedes.run_id=="worked")')"
write_register "$TMP/worked.json" "$TMP/decisions.json" worked >/dev/null 2>&1
check '7 existing run cannot be overwritten' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
write_register "$TMP/worked.json" "$TMP/decisions.json" pointer.json >/dev/null 2>&1
check 'reserved pointer filename cannot be used as run directory' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
check 'reserved run refusal preserves latest pointer' 0 "$(truth "$TMP/output/work-item-triage/pointer.json" '.run_id=="rerun"')"
# Corrupt an isolated history chain; a timeout is a failure, not successful rejection.
mkdir -p "$TMP/cycle/work-item-triage/loop"
printf '{"run_id":"loop"}\n' > "$TMP/cycle/work-item-triage/pointer.json"
printf '{"previous_run_id":"loop"}\n' > "$TMP/cycle/work-item-triage/loop/register.json"
python3 - "$SCRIPTS/wit-register.sh" "$TMP/worked.json" "$TMP/decisions.json" "$TMP/cycle" <<'PYTEST' >/dev/null 2>&1
import subprocess, sys
try:
    result = subprocess.run(["bash", sys.argv[1], "--snapshot", sys.argv[2], "--decisions", sys.argv[3], "--output-dir", sys.argv[4], "--run-id", "after-cycle"], timeout=5)
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(result.returncode)
PYTEST
check 'cyclic prior-run chain fails promptly' 1 "$?"
check 'cycle refusal preserves pointer and releases lock' 1 "$([ "$(jq -r .run_id "$TMP/cycle/work-item-triage/pointer.json")" = loop ] && [ ! -e "$TMP/cycle/work-item-triage/.writer-lock" ] && [ ! -e "$TMP/cycle/work-item-triage/after-cycle" ] && echo 1 || echo 0)"
# More than a provider page, followed by a transport-truncated second page.
export WIT_MODE=pages
read_snapshot github > "$TMP/pages.json"
check '2 two-page census read succeeds' 0 "$?"
check '2 two-page census enumerates 101 items' 0 "$(truth "$TMP/pages.json" '(.items|length)==101 and .completeness=="complete"')"
jq --slurpfile d "$HERE/expected/upload-next-action.json" '{items:[.items[]|.id as $id|$d[0]+{id:$id}]}' "$TMP/pages.json" > "$TMP/page-decisions.json"
pages_run="$(write_register "$TMP/pages.json" "$TMP/page-decisions.json" multipage)"
check '2 every multipage item has exactly one disposition' 0 "$(truth "$pages_run/register.json" '(.items|length)==101 and ([.items[].id]|unique|length)==101')"
export WIT_MODE=truncated
read_snapshot github > "$TMP/truncated.json"
check '3 interrupted census explicitly incomplete' 0 "$(truth "$TMP/truncated.json" '.completeness=="incomplete" and (.items|length)==100')"
jq --slurpfile d "$HERE/expected/upload-next-action.json" '{items:[.items[]|.id as $id|$d[0]+{id:$id}]}' "$TMP/truncated.json" > "$TMP/truncated-decisions.json"
truncated_run="$(write_register "$TMP/truncated.json" "$TMP/truncated-decisions.json" truncated)"
check '3 register preserves incomplete census' 0 "$(truth "$truncated_run/register.json" '.completeness=="incomplete"')"
check '3 summary warns incomplete' 1 "$(grep -ic 'incomplete' "$truncated_run/summary.md" | awk '{print ($1>0)?1:0}')"
# Parity uses identical authored decisions; provider normalization must not change them.
export WIT_MODE=parity
read_snapshot github > "$TMP/github.json"
read_snapshot plane --config "$TMP/plane.json" > "$TMP/plane-snapshot.json"
jq '{items:[. + {id:"301",outcome:"Clarify existing support contact",response:"Update the existing support note",next_task:"Amend the contact note",code_refs:[]}]}' "$HERE/expected/upload-next-action.json" > "$TMP/parity-decisions.json"
github_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" github)"
plane_run="$(write_register "$TMP/plane-snapshot.json" "$TMP/parity-decisions.json" plane)"
check '10 GitHub and Plane normalize same non-code item' 0 "$(jq -e -s 'length==2 and (.[0].items|length)==1 and ((.[0].items|map({id,title,url,state,updatedAt,body,comments,comments_fetched,relations}))==(.[1].items|map({id,title,url,state,updatedAt,body,comments,comments_fetched,relations})))' "$TMP/github.json" "$TMP/plane-snapshot.json" >/dev/null 2>&1; echo $?)"
check '10 identical decision payload retains provider parity' 0 "$(jq -e -s 'length==2 and (.[0].items|length)==1 and ((.[0].items|map({disposition,necessity,response}))==(.[1].items|map({disposition,necessity,response})))' "$github_run/register.json" "$plane_run/register.json" >/dev/null 2>&1; echo $?)"
chain_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" github-again)"
check '7 interleaved provider retains matching prior provenance' 0 "$(truth "$chain_run/register.json" '.items[0].supersedes.run_id=="github"')"
check '10 core contains no provider-specific keys'  0 "$(truth "$plane_run/register.json" '[..|objects|keys[]|select(.=="number" or .=="sequence_id" or .=="html_url" or .=="description_stripped")]|length==0')"
read_snapshot plane --config "$TMP/plane.json" --search recovery > "$TMP/search.json"
check '11 absent optional search reports local-match limit' 0 "$(truth "$TMP/search.json" '.capability_limits|join(" ")|test("search|local";"i")')"
export WIT_MODE=body-reference
read_snapshot github > "$TMP/body-reference.json"
check 'unresolvable body reference is dropped without poisoning completeness' 0 "$(truth "$TMP/body-reference.json" '.completeness=="complete" and .items[0].completeness=="complete" and ([.items[0].relations[].id]==["12"])')"
export WIT_MODE=missing-relation
read_snapshot github > "$TMP/missing-relation.json"
check 'unresolved tracker-declared link still marks history incomplete' 0 "$(truth "$TMP/missing-relation.json" '.completeness=="incomplete" and .items[0].completeness=="incomplete" and any(.items[0].relations[]; .id=="336699" and .resolution=="unavailable")')"
export WIT_MODE=shared-relations
links_before=$(grep -c '^api repos/sample/project/issues/12$' "$WIT_LOG" || true)
read_snapshot github > "$TMP/shared-relations.json"
check 'body and timeline link dedupe retains distinct repository scopes' 0 "$(truth "$TMP/shared-relations.json" '.completeness=="complete" and (.items[0].relations|length)==2 and ([.items[0].relations[].url]|unique|length)==2 and all(.items[0].relations[]; .id=="12" and .kind=="related" and .resolution=="resolved")')"
check 'body and timeline duplicate makes one lookup per scope' 1 "$(($(grep -c '^api repos/sample/project/issues/12$' "$WIT_LOG") - links_before))"
check '8 read source has no mutating verbs' 0 "$(grep -Eic 'issue (close|edit|comment)|pr (merge|close)|(--method[ =]+|-X[ =]*)(POST|PATCH|DELETE|PUT)' "$SCRIPTS/wit-read.sh" || true)"
check '8 pre-direct-ID analysis call log contains read calls only' 0 "$(awk '!/^api repos\/[^/ ]+\/[^/ ]+\/(issues|pulls)(\/[0-9]+(\/(comments|timeline))?)?(\?[^ ]*)?$/ && !/^api search\/issues\?[^ ]+$/ && !/^plane (list [0-9]+|show [^ ]+)$/ {bad++} END {print bad+0}' "$WIT_LOG")"
export WIT_MODE=large
read_snapshot github > "$TMP/large.json"
check 'large tracker body normalizes without argv overflow' 0 "$?"
check 'compact packet bounds large body honestly' 0 "$(truth "$TMP/large.json" '(.items[0].body|length)==600 and .items[0].text_truncated==true')"
read_snapshot github --full > "$TMP/large-full.json"
check 'full evidence preserves large tracker body' 0 "$(truth "$TMP/large-full.json" '(.items[0].body|length)>131072 and .items[0].text_truncated==false')"
export WIT_MODE=parity
jq '.items[0].code_refs=["README.md"]' "$TMP/parity-decisions.json" > "$TMP/pinned.json"
pinned_run="$(bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/github.json" --decisions "$TMP/pinned.json" --output-dir "$TMP/output" --run-id pinned --code-ref "$HERE/../../..")"
check '7 code references pinned to actual HEAD' "$(git -C "$HERE/../../.." rev-parse HEAD)" "$(jq -r '.items[0].provenance.code_refs[0].commit' "$pinned_run/register.json")"
# Both direction enums share one validated card mechanism; no tracker item exists yet.
jq ' .items=[{id:"draft-1",title:"Proposed support note",updatedAt:null,comments_fetched:0,completeness:.completeness,comments:[],relations:[]}]' "$TMP/github.json" > "$TMP/proposed-snapshot.json"
for disposition in do-not-file file-minimal append-to fix-now-no-item record-as-limitation; do
  jq --arg disposition "$disposition" '.items[0] += {id:"draft-1",direction:"proposed",disposition:$disposition,target:"88"}' "$TMP/parity-decisions.json" > "$TMP/proposed.json"
  proposed_run="$(write_register "$TMP/proposed-snapshot.json" "$TMP/proposed.json" "proposed-$disposition")"
  check "1 proposed disposition $disposition" 0 "$(truth "$proposed_run/register.json" ".items[0].direction==\"proposed\" and .items[0].disposition==\"$disposition\"")"
done
for disposition in fix-now-no-item record-as-limitation; do
  jq --slurpfile item "$FIX/$disposition.json" '.items=$item' "$TMP/github.json" > "$TMP/proposed-snapshot.json"
  jq '{items:[.]}' "$HERE/expected/proposed/$disposition.json" > "$TMP/proposed.json"
  proposed_run="$(write_register "$TMP/proposed-snapshot.json" "$TMP/proposed.json" "worked-$disposition")"
  check "direction 2 worked $disposition preserves decision and local provenance" 0 "$(jq -e --slurpfile want "$HERE/expected/proposed/$disposition.json" '.items[0] | . as $row | all($want[0]|del(.code_refs)|keys[]; $row[.] == $want[0][.]) and .provenance.item_id==$want[0].id and .provenance.updatedAt==null and .provenance.comments_fetched==0 and .url==null' "$proposed_run/register.json" >/dev/null 2>&1; echo $?)"
done
check 'direction 2 file draft warns explicitly no PII review' 1 "$(grep -c 'WARNING: .*draft.*no PII review' "$TMP/output/work-item-triage/proposed-file-minimal/summary.md" || true)"
export WIT_MODE=missing-history
read_snapshot github --id 301 > "$TMP/missing-history.json"
check '3 unavailable comment history is incomplete' 0 "$(truth "$TMP/missing-history.json" '.completeness=="incomplete" and .items[0].completeness=="incomplete"')"
export WIT_MODE=parity
# Authorized mutation surface: a comment is created once, never an issue.
jq -n '{item_id:"301",verb:"comment",body:"Triage: retain the existing support contact scope."}' > "$TMP/action.json"
jq '{actions:[.]}' "$TMP/action.json" > "$TMP/auth.json"
apply() { bash "$SCRIPTS/wit-apply.sh" --run-dir "$1" --action "$TMP/action.json" --authorization "$TMP/auth.json" "${@:2}"; }
apply "$github_run" > "$TMP/applied-first.json"
check '9 first authorized comment succeeds' 0 "$?"
apply "$github_run" > "$TMP/applied-second.json"
check '9 identical authorized action succeeds again' 0 "$?"
check '9 rerun reports reused' 1 "$(grep -c reused "$TMP/applied-second.json" || true)"
cross_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" same-action-new-run)"
apply "$cross_run" > "$TMP/cross-run.json"
check '9 new snapshot reuses same authorized action' 0 "$(truth "$TMP/cross-run.json" '.status=="reused"')"
check '9 exactly one comment creation' 1 "$(grep -c '^issue comment ' "$WIT_LOG" || true)"
check 'direction 2 never creates tracker issues' 0 "$(grep -c '^issue create ' "$WIT_LOG" || true)"
jq '. + [last]' "$WIT_STATE/comments.json" > "$TMP/double-marker.json"
cp "$TMP/double-marker.json" "$WIT_STATE/comments.json"
apply "$github_run" > "$TMP/ambiguous.json" 2>/dev/null
check 'duplicate action markers return nonzero' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
check 'ambiguous markers remain visibly unresolved' 0 "$(truth "$TMP/ambiguous.json" '.status=="ambiguous"')"
incomplete_run="$(write_register "$TMP/missing-history.json" "$TMP/parity-decisions.json" missing-history)"
apply "$incomplete_run" > "$TMP/incomplete-apply.json" 2>/dev/null
check 'incomplete original history prevents mutation' 0 "$(truth "$TMP/incomplete-apply.json" '.status=="incomplete"')"
# Fresh runs isolate conflict and unknown-write checks from idempotency markers.
rm -f "$WIT_STATE/comments.json"
jq '.body="Concurrent-state assessment comment."' "$TMP/action.json" > "$TMP/new-action.json"
mv "$TMP/new-action.json" "$TMP/action.json"
jq '{actions:[.]}' "$TMP/action.json" > "$TMP/auth.json"
concurrent_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" concurrent)"
export WIT_MUTATION=concurrent
apply "$concurrent_run" > "$TMP/concurrent.json" 2>/dev/null
check 'concurrent tracker update stops dependent write' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
check 'concurrent update has visible unresolved result' 0 "$(truth "$TMP/concurrent.json" '.status=="stale"')"
export WIT_MUTATION=unknown
jq '.body="Uncertain-write assessment comment."' "$TMP/action.json" > "$TMP/new-action.json"
mv "$TMP/new-action.json" "$TMP/action.json"
jq '{actions:[.]}' "$TMP/action.json" > "$TMP/auth.json"
unknown_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" unknown)"
apply "$unknown_run" > "$TMP/unknown-first.json" 2>/dev/null
check 'unknown write returns nonzero' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
apply "$unknown_run" > "$TMP/unknown-second.json" 2>/dev/null
check 'unknown write is not retried blindly' 2 "$(grep -c '^issue comment ' "$WIT_LOG" || true)"
check 'unknown write remains visible' 0 "$(truth "$TMP/unknown-second.json" '.status=="unknown"')"
unknown_next_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" unknown-next-run)"
apply "$unknown_next_run" > "$TMP/unknown-next.json" 2>/dev/null
check 'unknown prior write remains unresolved across snapshots' 0 "$(truth "$TMP/unknown-next.json" '.status=="unknown"')"
check 'new snapshot never blindly retries unknown write' 2 "$(grep -c '^issue comment ' "$WIT_LOG" || true)"
export WIT_MUTATION=normal
jq -n '{item_id:"301",verb:"close",body:"Close verified tracking."}' > "$TMP/action.json"
jq '{actions:[.]}' "$TMP/action.json" > "$TMP/auth.json"
apply "$plane_run" --config "$TMP/plane.json" > "$TMP/unsupported.json" 2>/dev/null
check '11 missing close capability returns nonzero' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
check '11 missing close reports unsupported' 1 "$(grep -c unsupported "$TMP/unsupported.json" || true)"
# Repeated closure, real comment timeline events, and exact authorization.
rm -f "$WIT_STATE/comments.json"
close_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" close)"
apply "$close_run" > "$TMP/close-first.json"
check '9 first authorized closure succeeds with comment timeline' 0 "$?"
apply "$close_run" > "$TMP/close-second.json"
check '9 repeated closure is verified reused' 0 "$(truth "$TMP/close-second.json" '.status=="reused"')"
check '9 exactly one status change' 1 "$(grep -c '^issue close ' "$WIT_LOG" || true)"
rm -f "$WIT_STATE/comments.json" "$WIT_STATE/closed"
jq -n '{actions:[]}' > "$TMP/auth.json"
unauthorized_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" unauthorized)"
mutations_before="$(grep -c '^issue ' "$WIT_LOG" || true)"
apply "$unauthorized_run" > "$TMP/unauthorized.json" 2>/dev/null
check 'unauthorized action visibly refused' 0 "$(truth "$TMP/unauthorized.json" '.status=="unauthorized"')"
check 'unauthorized action performs no mutation' "$mutations_before" "$(grep -c '^issue ' "$WIT_LOG" || true)"
jq '{actions:[.]}' "$TMP/action.json" > "$TMP/auth.json"
# Equal timestamps and counts cannot hide edited decision history.
jq '.fixture_comments|.[0].body="Edited owner ruling"' "$FIX/github-parity.json" > "$WIT_STATE/comments.json"
edited_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" edited-history)"
apply "$edited_run" > "$TMP/edited.json" 2>/dev/null
check 'same-count edited history invalidates assessment' 0 "$(truth "$TMP/edited.json" '.status=="stale"')"
check 'changed history causes no mutation' "$mutations_before" "$(grep -c '^issue ' "$WIT_LOG" || true)"
printf '\n%d passed, %d failed\n'  "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'ALL GREEN\n'; else exit 1; fi
