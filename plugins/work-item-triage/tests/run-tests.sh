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
mkdir "$TMP/bin"
export WIT_FIX="$FIX" WIT_LOG="$TMP/calls"
export WIT_MODE=worked WIT_NOW=2026-09-10T10:00:00Z
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
    if [ "$WIT_MODE" = history-detail ]; then
      printf '%s\n' '[{"event":"closed","created_at":"2026-09-09T00:00:00Z","body":"","rename":{"from":"Old title","to":"New title"},"assignee":{"login":"alice"},"milestone":{"title":"M1"},"state_reason":"completed","actor":{"login":"alice"}}]'
      exit
    fi
    if [ "$WIT_MODE" = history-scalar ]; then
      printf '%s\n' '[{"event":"labeled","created_at":"2026-09-09T00:00:00Z","body":"","label":"bug","assignee":7,"rename":"t","milestone":7,"actor":{"login":"alice"}}]'
      exit
    fi
    if [ "$WIT_MODE" = parity ]; then jq '.fixture_history' "$WIT_FIX/github-parity.json";
    else printf '[]\n'; fi
    exit
  fi
  if [[ "$endpoint" == *'/comments?'* ]]; then
    [ "$WIT_MODE" = missing-history ] && exit 1
    if [ "$WIT_MODE" = worked ]; then
      id="${endpoint#*/issues/}"; id="${id%%/*}"
      jq -s --argjson id "$id" '[.[]|select(.number==$id)|.fixture_comments[]?]' "$WIT_FIX"/{shipped-alert,future-database,upload-next-action,invoice-consolidation,conditional-successor,owner-permitted-behavior,rare-high-consequence,unavailable-incident-data,conditional-activation,changed-owner-ruling}.json 2>/dev/null || printf '[]\n'
    else jq '.fixture_comments // []' "$WIT_FIX/github-parity.json"; fi
    exit
  fi
  if [[ "$endpoint" == *'/issues?'* ]]; then
    case "$WIT_MODE" in
      qualified-body-reference)
        jq '[. + {body:"See other/project#12",relations:[]}]' "$WIT_FIX/github-parity.json" ;;
      body-reference|body-reference-403|body-reference-auth|body-reference-network|missing-relation|shared-relations)
        jq --arg mode "$WIT_MODE" '[. + {body:"Use #336699 for the banner. See also #12",relations:(if $mode=="missing-relation" then [{id:"336699",kind:"related"}] else [] end)}]' "$WIT_FIX/github-parity.json" ;;
      large) jq '[. + {body:("long evidence " * 12000)}]' "$WIT_FIX/github-parity.json" ;;
      worked) jq -s '[.[] | del(.fixture_comments)]' "$WIT_FIX"/{shipped-alert,future-database,upload-next-action,invoice-consolidation,conditional-successor,owner-permitted-behavior,rare-high-consequence,unavailable-incident-data,conditional-activation,changed-owner-ruling}.json ;;
      duplicate-pages)
        if [[ "$endpoint" == *'page=1' ]]; then jq '.[0].body="Page 1 observation"' "$WIT_FIX/github-page1.json";
        else jq '[.[0] + {body:"Page 2 observation"}]' "$WIT_FIX/github-page1.json"; fi ;;
      pages|truncated)
        if [[ "$endpoint" == *'page=1' ]]; then cat "$WIT_FIX/github-page1.json";
        elif [ "$WIT_MODE" = truncated ]; then cat "$WIT_FIX/github-page2-truncated.json"; exit 1;
        else jq '[. + {number:1101,title:"Final synthetic item",html_url:"https://tracker.example/items/1101"}]' "$WIT_FIX/github-parity.json"; fi ;;
      *) jq '[.]' "$WIT_FIX/github-parity.json" ;;
    esac
    exit
  fi
  if [[ "$endpoint" == *'/issues/'* ]]; then
    if [[ "$endpoint" == */issues/336699 ]]; then printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; fi
    if [[ "$endpoint" == */issues/12 ]]; then
      case "$WIT_MODE" in
        body-reference-403) printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2; exit 1 ;;
        body-reference-auth) printf 'gh: Bad credentials (HTTP 401)\n' >&2; exit 1 ;;
        body-reference-network) printf 'dial tcp: lookup api.github.com: no such host\n' >&2; exit 1 ;;
      esac
    fi
    if [[ "$endpoint" == */issues/12 ]]; then jq -n --arg url "https://github.com/${endpoint#repos/}" '{number:12,title:"Linked item",state:"open",html_url:$url}'; exit; fi
    if [[ "$endpoint" == */issues/302 ]]; then printf '%s\n' '{"number":302,"title":"Existing support policy","state":"open","html_url":"https://tracker.example/items/302"}'; exit; fi
    cat "$WIT_FIX/github-parity.json"
    exit
  fi
fi
printf 'Unexpected gh call: %s\n' "$*" >&2
exit 2
STUB
cat > "$TMP/bin/plane-stub" <<'STUB'
#!/usr/bin/env bash
printf 'plane %s\n' "$*" >> "$WIT_LOG"
case "$1" in
  list) [ "${2:-}" = 1 ] || exit 2; jq '{items:[.],next:false,complete:true}' "$WIT_FIX/plane-parity.json" ;;
  show) [ "${2:-}" = 301 ] || exit 2
    if [ "$WIT_MODE" = incomplete-source ]; then jq '. + {complete:false,comments_complete:true}' "$WIT_FIX/plane-parity.json";
    else cat "$WIT_FIX/plane-parity.json"; fi ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/gh" "$TMP/bin/plane-stub"
jq -n '{sources:[{name:"plane",list:"plane-stub list",show:"plane-stub show"}]}' > "$TMP/plane.json"
check 'tribunal T-024 YAML frontmatter adapter matches JSON with quotes comments and sibling key' "$(jq -cS '.sources[0] | {list,show}' "$TMP/plane.json")" "$(source "$SCRIPTS/wit-read.sh"; wit_config "$FIX/plane-config.md" plane list,show,search | jq -cS .)"
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
check 'queue explains necessity before priority within each section' 1 "$(grep -c 'Each section orders by necessity (required before discretionary), then smaller priority first' "$ordering_run/queue.md" || true)"
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
# Writer lock: kernel flock; leftover .writer-lock/ is private scratch, never steal a live holder.
mkdir -p "$TMP/leftover/work-item-triage/.writer-lock"
printf '{"run_id":"junk-prev"}\n' > "$TMP/leftover/work-item-triage/.writer-lock/previous.json"
printf '{"run_id":"junk-pointer"}\n' > "$TMP/leftover/work-item-triage/.writer-lock/pointer.json"
bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/worked.json" --decisions "$TMP/decisions.json" --output-dir "$TMP/leftover" --run-id leftover-ok >/dev/null 2>"$TMP/leftover.err"
check 'leftover writer state recovers' 0 "$?"
check 'leftover writer state stderr names cleanup' 1 "$(grep -c 'removing leftover writer state from an interrupted run' "$TMP/leftover.err" || true)"
check 'leftover writer state pointer names new run' leftover-ok "$(jq -r .run_id "$TMP/leftover/work-item-triage/pointer.json")"
check 'leftover writer state does not inherit junk previous_run_id' null "$(jq -r '.previous_run_id | tostring' "$TMP/leftover/work-item-triage/leftover-ok/register.json")"
check 'leftover writer state clears .writer-lock' 1 "$([ ! -e "$TMP/leftover/work-item-triage/.writer-lock" ] && echo 1 || echo 0)"
mkdir -p "$TMP/live-writer/work-item-triage"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(60)' \
  "$TMP/live-writer/work-item-triage/.writer.lock" "$TMP/live-writer-ready" &
live_helper=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
  [ -f "$TMP/live-writer-ready" ] && ready=1 && break
  sleep 0.1
done
check 'live writer helper became ready' 1 "$ready"
bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/worked.json" --decisions "$TMP/decisions.json" --output-dir "$TMP/live-writer" --run-id live-blocked >/dev/null 2>"$TMP/live-writer.err"
check 'live writer lock is not stolen' 1 "$([ "$?" -ne 0 ] && echo 1 || echo 0)"
check 'live writer stderr is another writer active' 1 "$(grep -c 'another writer is active' "$TMP/live-writer.err" || true)"
check 'live writer creates no run directory or pointer' 1 "$([ ! -e "$TMP/live-writer/work-item-triage/live-blocked" ] && [ ! -e "$TMP/live-writer/work-item-triage/pointer.json" ] && echo 1 || echo 0)"
kill "$live_helper" 2>/dev/null || true
wait "$live_helper" 2>/dev/null || true
mkdir -p "$TMP/hard-kill/work-item-triage"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(60)' \
  "$TMP/hard-kill/work-item-triage/.writer.lock" "$TMP/hard-kill-ready" &
hard_helper=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
  [ -f "$TMP/hard-kill-ready" ] && ready=1 && break
  sleep 0.1
done
check 'hard-kill helper became ready' 1 "$ready"
kill -9 "$hard_helper" 2>/dev/null || true
wait "$hard_helper" 2>/dev/null || true
bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/worked.json" --decisions "$TMP/decisions.json" --output-dir "$TMP/hard-kill" --run-id after-kill >/dev/null 2>"$TMP/hard-kill.err"
check 'hard kill releases writer lock' 0 "$?"
mkdir -p "$TMP/concurrent"
for i in 1 2 3 4 5; do
  (
    bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/worked.json" --decisions "$TMP/decisions.json" --output-dir "$TMP/concurrent" --run-id "c-$i" >/dev/null 2>"$TMP/concurrent-c-$i.err"
    printf '%s\n' "$?" > "$TMP/concurrent-c-$i.exit"
  ) &
done
wait
concurrent_ok=1
ok_runs=0
for i in 1 2 3 4 5; do
  rc=$(cat "$TMP/concurrent-c-$i.exit")
  if [ "$rc" = 0 ]; then
    ok_runs=$((ok_runs + 1))
  elif [ "$rc" = 1 ] && grep -q 'another writer is active' "$TMP/concurrent-c-$i.err"; then
    :
  else
    concurrent_ok=0
  fi
done
run_dirs=$(find "$TMP/concurrent/work-item-triage" -mindepth 1 -maxdepth 1 -type d ! -name '.writer-lock' ! -name '.snapshot.*' 2>/dev/null | wc -l | tr -d ' ')
check 'concurrent writers exit 0 or another-writer' 1 "$concurrent_ok"
check 'concurrent successful run dirs match exit-0 count' "$ok_runs" "$run_dirs"
chain_ok=1
visited=0
cur=$(jq -r .run_id "$TMP/concurrent/work-item-triage/pointer.json" 2>/dev/null || true)
seen='|'
while [ -n "$cur" ]; do
  case "$seen" in *"|$cur|"*) chain_ok=0; break ;; esac
  seen="$seen$cur|"
  visited=$((visited + 1))
  cur=$(jq -r '.previous_run_id // empty' "$TMP/concurrent/work-item-triage/$cur/register.json")
done
[ "$visited" = "$ok_runs" ] || chain_ok=0
check 'concurrent previous_run_id chain visits each success once' 1 "$chain_ok"
bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/worked.json" --decisions "$TMP/decisions.json" --output-dir "$TMP/lock-release" --run-id release-a >/dev/null 2>&1
check 'release on success first run' 1 "$([ "$?" -eq 0 ] && [ ! -e "$TMP/lock-release/work-item-triage/.writer-lock" ] && echo 1 || echo 0)"
bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/worked.json" --decisions "$TMP/decisions.json" --output-dir "$TMP/lock-release" --run-id release-b >/dev/null 2>&1
check 'release on success second run' 1 "$([ "$?" -eq 0 ] && [ ! -e "$TMP/lock-release/work-item-triage/.writer-lock" ] && echo 1 || echo 0)"
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
jq '.items=[.items[0]]' "$TMP/truncated.json" > "$TMP/partial-census.json"
jq '.items=[.items[0]]' "$TMP/truncated-decisions.json" > "$TMP/partial-census-decisions.json"
partial_run="$(write_register "$TMP/partial-census.json" "$TMP/partial-census-decisions.json" partial-census)"
check 'tribunal T-016 incomplete census preserves complete item provenance' 0 "$(truth "$partial_run/register.json" '.completeness=="incomplete" and (.items|length)==1 and .items[0].provenance.completeness=="complete"')"
partial_now="$(awk '/^## Implement now/{emit=1;next} /^## /{emit=0} emit' "$partial_run/queue.md")"
check 'tribunal T-016 complete item remains under Implement now' 1 "$(grep -c '^- Priority .* — 1001:' <<< "$partial_now" || true)"
check 'tribunal T-016 summary retains census warning' 1 "$(grep -c '^INCOMPLETE: missing pages or history;' "$partial_run/summary.md" || true)"
export WIT_MODE=duplicate-pages
read_snapshot github > "$TMP/duplicate-pages.json"
check 'tribunal T-003 latest duplicate observation survives pagination' 0 "$(truth "$TMP/duplicate-pages.json" '.completeness=="complete" and (.items|length)==100 and ([.items[]|select(.id=="1001")|.body]==["Page 2 observation"])')"
# Parity uses identical authored decisions; provider normalization must not change them.
export WIT_MODE=parity
read_snapshot github > "$TMP/github.json"
read_snapshot plane --config "$TMP/plane.json" > "$TMP/plane-snapshot.json"
read_snapshot plane --config "$FIX/plane-config.md" > "$TMP/plane-yaml-snapshot.json"
check 'tribunal T-024 YAML config read succeeds' 0 "$?"
check 'tribunal T-024 YAML config snapshot matches JSON config snapshot' 0 "$(jq -e --slurpfile expected "$TMP/plane-snapshot.json" '. == $expected[0]' "$TMP/plane-yaml-snapshot.json" >/dev/null; printf '%s' "$?")"
jq '{items:[. + {id:"301",outcome:"Clarify existing support contact",response:"Update the existing support note",next_task:"Amend the contact note",code_refs:[]}]}' "$HERE/expected/upload-next-action.json" > "$TMP/parity-decisions.json"
github_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" github)"
plane_run="$(write_register "$TMP/plane-snapshot.json" "$TMP/parity-decisions.json" plane)"
check '10 GitHub and Plane normalize same non-code item' 0 "$(jq -e -s 'length==2 and (.[0].items|length)==1 and ((.[0].items|map({id,title,url,state,updatedAt,body,comments,history,comments_fetched,relations}))==(.[1].items|map({id,title,url,state,updatedAt,body,comments,history,comments_fetched,relations})))' "$TMP/github.json" "$TMP/plane-snapshot.json" >/dev/null 2>&1; echo $?)"
check 'tribunal T-001 missing complete retains complete default' 0 "$(truth "$TMP/plane-snapshot.json" '.completeness=="complete" and .items[0].completeness=="complete"')"
for provider in github plane; do
  args=(); [ "$provider" != plane ] || args=(--config "$TMP/plane.json")
  for detail in compact full; do
    full=(); [ "$detail" != full ] || full=(--full)
    read_snapshot "$provider" "${args[@]}" "${full[@]}" > "$TMP/authors.json"
    check "tribunal T-002 $provider $detail preserves known authors and omits unknown authors" 0 "$(truth "$TMP/authors.json" '.items[0] | .comments[0].author=="support-owner" and .history[0].author=="support-owner" and (.comments[1]|has("author")|not) and (.history[1]|has("author")|not)')"
  done
done
check 'h1 GitHub labeled history keeps detail and omits empty detail' 0 "$(truth "$TMP/github.json" '.items[0].history as $h | ($h|map(select(.event=="labeled"))|length)==1 and ($h[]|select(.event=="labeled")|.detail=={"label":"support"}) and all($h[]|select(.event!="labeled"); (has("detail")|not))')"
export WIT_MODE=history-detail
read_snapshot github > "$TMP/history-detail.json"
check 'h2 GitHub rename assignee milestone state_reason map to flat detail' 0 "$(truth "$TMP/history-detail.json" '.items[0].history[0].detail == {"rename_from":"Old title","rename_to":"New title","assignee":"alice","milestone":"M1","state_reason":"completed"}')"
export WIT_MODE=history-scalar
read_snapshot github > "$TMP/history-scalar.json"
check 'h3 scalar nested history containers exit 0 without detail' 0 "$(truth "$TMP/history-scalar.json" '.items[0].history|length==1 and all(.[]; has("detail")|not)')"
export WIT_MODE=incomplete-source
for operation in list show; do
  args=(); [ "$operation" != show ] || args=(--id 301)
  read_snapshot plane --config "$TMP/plane.json" "${args[@]}" > "$TMP/incomplete-source.json"
  check "tribunal T-001 $operation honors explicit incomplete with complete comments" 0 "$(truth "$TMP/incomplete-source.json" '.completeness=="incomplete" and .items[0].completeness=="incomplete" and .items[0].comments_fetched==2')"
done
export WIT_MODE=parity
check '10 identical decision payload retains provider parity' 0 "$(jq -e -s 'length==2 and (.[0].items|length)==1 and ((.[0].items|map({disposition,necessity,response}))==(.[1].items|map({disposition,necessity,response})))' "$github_run/register.json" "$plane_run/register.json" >/dev/null 2>&1; echo $?)"
chain_run="$(write_register "$TMP/github.json" "$TMP/parity-decisions.json" github-again)"
check '7 interleaved provider retains matching prior provenance' 0 "$(truth "$chain_run/register.json" '.items[0].supersedes.run_id=="github"')"
check '10 core contains no provider-specific keys'  0 "$(truth "$plane_run/register.json" '[..|objects|keys[]|select(.=="number" or .=="sequence_id" or .=="html_url" or .=="description_stripped")]|length==0')"
read_snapshot plane --config "$TMP/plane.json" --search recovery > "$TMP/search.json"
check '11 absent optional search reports local-match limit' 0 "$(truth "$TMP/search.json" '.capability_limits|join(" ")|test("search|local";"i")')"
export WIT_MODE=body-reference
read_snapshot github > "$TMP/body-reference.json"
check 'confirmed 404 body reference is dropped without poisoning completeness' 0 "$(truth "$TMP/body-reference.json" '.completeness=="complete" and .items[0].completeness=="complete" and ([.items[0].relations[].id]==["12"])')"
check 'tribunal T-015 bare #12 still resolves in current scope' 0 "$(truth "$TMP/body-reference.json" '.items[0].relations | length==1 and .[0].url=="https://github.com/sample/project/issues/12" and .[0].resolution=="resolved"')"
export WIT_MODE=qualified-body-reference
links_before=$(grep -c '^api repos/sample/project/issues/12$' "$WIT_LOG" || true)
read_snapshot github > "$TMP/qualified-body-reference.json"
check 'tribunal T-015 other/project#12 resolves against other/project' 0 "$(truth "$TMP/qualified-body-reference.json" '.completeness=="complete" and (.items[0].relations | length==1 and .[0].id=="12" and .[0].url=="https://github.com/other/project/issues/12" and .[0].resolution=="resolved")')"
check 'tribunal T-015 qualified reference never fetches existing local issue 12' 0 "$(($(grep -c '^api repos/sample/project/issues/12$' "$WIT_LOG") - links_before))"
for failure in 403 auth network; do
  export WIT_MODE="body-reference-$failure"
  read_snapshot github > "$TMP/body-reference-$failure.json" 2> "$TMP/body-reference-$failure.err"
  check "body reference $failure failure retains unavailable link and incomplete history" 0 "$(truth "$TMP/body-reference-$failure.json" '.completeness=="incomplete" and .items[0].completeness=="incomplete" and (.items[0].relations|length)==1 and .items[0].relations[0].id=="12" and .items[0].relations[0].resolution=="unavailable"')"
done
export WIT_MODE=missing-relation
read_snapshot github > "$TMP/missing-relation.json"
check 'unresolved tracker-declared link still marks history incomplete' 0 "$(truth "$TMP/missing-relation.json" '.completeness=="incomplete" and .items[0].completeness=="incomplete" and any(.items[0].relations[]; .id=="336699" and .resolution=="unavailable")')"
export WIT_MODE=shared-relations
links_before=$(grep -c '^api repos/sample/project/issues/12$' "$WIT_LOG" || true)
read_snapshot github > "$TMP/shared-relations.json"
check 'body and timeline link dedupe retains distinct repository scopes' 0 "$(truth "$TMP/shared-relations.json" '.completeness=="complete" and (.items[0].relations|length)==2 and ([.items[0].relations[].url]|unique|length)==2 and all(.items[0].relations[]; .id=="12" and .kind=="related" and .resolution=="resolved")')"
check 'body and timeline duplicate makes one lookup per scope' 1 "$(($(grep -c '^api repos/sample/project/issues/12$' "$WIT_LOG") - links_before))"
check '8 source has no mutating verbs' 0 "$(grep -Eic 'issue (close|edit|comment)|pr (merge|close)|(--method[ =]+|-X[ =]*)(POST|PATCH|DELETE|PUT)' "$SCRIPTS"/*.sh | awk -F: '{n+=$NF} END {print n+0}')"
export WIT_MODE=large
read_snapshot github > "$TMP/large.json"
check 'large tracker body normalizes without argv overflow' 0 "$?"
check 'compact packet bounds large body honestly' 0 "$(truth "$TMP/large.json" '(.items[0].body|length)==600 and .items[0].text_truncated==true')"
read_snapshot github --full > "$TMP/large-full.json"
check 'full evidence preserves large tracker body' 0 "$(truth "$TMP/large-full.json" '(.items[0].body|length)>131072 and .items[0].text_truncated==false')"
export WIT_MODE=parity
jq '.items[0].code_refs=["README.md"]' "$TMP/parity-decisions.json" > "$TMP/pinned.json"
git init -q "$TMP/code"
printf 'Committed evidence\n' > "$TMP/code/README.md"
git -C "$TMP/code" add README.md
git -C "$TMP/code" -c user.name=Test -c user.email=test@example.invalid commit -qm 'Fixture evidence'
pinned_run="$(bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/github.json" --decisions "$TMP/pinned.json" --output-dir "$TMP/output" --run-id pinned --code-ref "$TMP/code")"
check '7 code references pinned to actual HEAD' "$(git -C "$TMP/code" rev-parse HEAD)" "$(jq -r '.items[0].provenance.code_refs[0].commit' "$pinned_run/register.json")"
check 'tribunal T-004 clean evidence records dirty false' 0 "$(truth "$pinned_run/register.json" '.items[0].provenance.code_refs[0].dirty==false')"
for change in modified staged untracked; do
  git -C "$TMP/code" reset --hard -q HEAD
  if [ "$change" = untracked ]; then printf 'New evidence\n' > "$TMP/code/new.txt";
  else printf 'Edited evidence\n' >> "$TMP/code/README.md"; fi
  [ "$change" != staged ] || git -C "$TMP/code" add README.md
  dirty_run="$(bash "$SCRIPTS/wit-register.sh" --snapshot "$TMP/github.json" --decisions "$TMP/pinned.json" --output-dir "$TMP/output" --run-id "dirty-$change" --code-ref "$TMP/code")"
  check "tribunal T-004 $change evidence records dirty true and retains commit" 0 "$(truth "$dirty_run/register.json" ".items[0].provenance.code_refs[0] | .dirty==true and .commit==\"$(git -C "$TMP/code" rev-parse HEAD)\"")"
done
# Both direction enums share one validated card mechanism; no tracker item exists yet.
jq ' .items=[{id:"draft-1",title:"Proposed support note",updatedAt:null,comments_fetched:0,completeness:.completeness,comments:[],relations:[]}]' "$TMP/github.json" > "$TMP/proposed-snapshot.json"
jq --arg disposition file-minimal '.items[0] += {id:"draft-1",direction:"proposed",disposition:$disposition,target:"88"}' "$TMP/parity-decisions.json" > "$TMP/proposed-no-draft.json"
write_register "$TMP/proposed-snapshot.json" "$TMP/proposed-no-draft.json" proposed-file-minimal-missing-draft >/dev/null 2>&1
check 'd1 proposed file-minimal without draft is rejected' 2 "$?"
for disposition in do-not-file file-minimal append-to fix-now-no-item record-as-limitation; do
  jq --arg disposition "$disposition" '
    .items[0] += {id:"draft-1",direction:"proposed",disposition:$disposition,target:"88"}
    | if $disposition == "file-minimal" then
        .items[0].draft = {title:"Support note draft",body:"Evidence, acceptance, and retained limitations."}
      else . end
  ' "$TMP/parity-decisions.json" > "$TMP/proposed.json"
  proposed_run="$(write_register "$TMP/proposed-snapshot.json" "$TMP/proposed.json" "proposed-$disposition")"
  check "1 proposed disposition $disposition" 0 "$(truth "$proposed_run/register.json" ".items[0].direction==\"proposed\" and .items[0].disposition==\"$disposition\"")"
done
check 'd2 file-minimal draft is durable and summarized with PII line' 0 "$(
  jq -e '.items[0].draft == {"title":"Support note draft","body":"Evidence, acceptance, and retained limitations."}' \
    "$TMP/output/work-item-triage/proposed-file-minimal/register.json" >/dev/null 2>&1 || { echo 1; exit 0; }
  awk '
    /Draft title: Support note draft/ {title=1; next}
    title && !body && $0=="Evidence, acceptance, and retained limitations." {body=1; next}
    body && $0=="This draft has had no PII review." {pii=1}
    END {print (title && body && pii) ? 0 : 1}
  ' "$TMP/output/work-item-triage/proposed-file-minimal/summary.md"
)"
for disposition in fix-now-no-item record-as-limitation; do
  jq --slurpfile item "$FIX/$disposition.json" '.items=$item' "$TMP/github.json" > "$TMP/proposed-snapshot.json"
  jq '{items:[.]}' "$HERE/expected/proposed/$disposition.json" > "$TMP/proposed.json"
  proposed_run="$(write_register "$TMP/proposed-snapshot.json" "$TMP/proposed.json" "worked-$disposition")"
  check "direction 2 worked $disposition preserves decision and local provenance" 0 "$(jq -e --slurpfile want "$HERE/expected/proposed/$disposition.json" '.items[0] | . as $row | all($want[0]|del(.code_refs)|keys[]; $row[.] == $want[0][.]) and .provenance.item_id==$want[0].id and .provenance.updatedAt==null and .provenance.comments_fetched==0 and .url==null' "$proposed_run/register.json" >/dev/null 2>&1; echo $?)"
done
proposed_fix_now_queue="$(awk '/^## Implement now/{emit=1;next} /^## /{emit=0} emit' "$TMP/output/work-item-triage/worked-fix-now-no-item/queue.md")"
check 'tribunal T-008 proposed ready fix-now-no-item renders under implement-now' 1 "$(grep -c 'Priority 1 — draft-contact-link: Correct the anchor in the existing support note and verify the link.' <<< "$proposed_fix_now_queue" || true)"
check 'direction 2 file draft warns explicitly no PII review' 1 "$(grep -c 'WARNING: .*draft.*no PII review' "$TMP/output/work-item-triage/proposed-file-minimal/summary.md" || true)"
export WIT_MODE=missing-history
read_snapshot github --id 301 > "$TMP/missing-history.json"
check '3 unavailable comment history is incomplete' 0 "$(truth "$TMP/missing-history.json" '.completeness=="incomplete" and .items[0].completeness=="incomplete"')"
check '8 every analysis call is a read call' 0 "$(awk '!/^api repos\/[^/ ]+\/[^/ ]+\/(issues|pulls)(\/[0-9]+(\/(comments|timeline))?)?(\?[^ ]*)?$/ && !/^api search\/issues\?[^ ]+$/ && !/^plane (list [0-9]+|show [^ ]+)$/ {bad++} END {print bad+0}' "$WIT_LOG")"
printf '\n%d passed, %d failed\n'  "$pass" "$fail"
if [ "$fail" -eq 0 ]; then printf 'ALL GREEN\n'; else exit 1; fi
