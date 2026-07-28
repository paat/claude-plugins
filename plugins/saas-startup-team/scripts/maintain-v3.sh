#!/usr/bin/env bash
# Thin maintenance tick (#388). Default --shadow. No claims/compatibility receipts.
# Actions: inventory|select|shadow-compare|tick|lock|isolate|release-facts
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
usage() { cat >&2 <<'EOF'
usage: maintain-v3.sh inventory (--repo-root DIR [--allow-linked-worktrees]|--fixture-dir DIR)
       maintain-v3.sh select --inventory-file FILE [--human-gates-file FILE] [--queue-file FILE]
       maintain-v3.sh shadow-compare --v3-file FILE --legacy-file FILE
       maintain-v3.sh tick [--shadow|--mutate] (--repo-root DIR|--fixture-dir DIR)
         [--state-dir DIR] [--owner ID] [--allow-linked-worktrees] [--allow-serial-primary]
       maintain-v3.sh lock acquire|release|status --kind scheduler|issue|release
         --key KEY --state-dir DIR --owner ID [--ttl-seconds N]
       maintain-v3.sh isolate prepare|cleanup|status --repo-root DIR --issue N
         [--state-dir DIR] [--base-ref REF] [--allow-serial-primary]
       maintain-v3.sh release-facts show|record|recovery-step --repo-root DIR --issue N
         [--state-dir DIR] [--state S] [--pr-number N] [--head-sha SHA]
         [--merge-sha SHA] [--deploy-run-id ID] [--check-status STATUS]
EOF
  exit 2
}
die() { printf 'maintain-v3: %s\n' "$1" >&2; exit "${2:-1}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 required" 2; }
now_iso() { date -u +%FT%TZ; }
valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.@+:-]{0,127}$ ]]; }
safe_json() { [ -f "$1" ] && [ ! -L "$1" ] || die "bad json file: $1" 2; }

ACTION=${1:-}; [ -n "$ACTION" ] || usage; shift
REPO_ROOT=""; FIXTURE_DIR=""; STATE_DIR=""; OWNER=""
INVENTORY_FILE=""; HUMAN_GATES_FILE=""; QUEUE_FILE=""
V3_FILE=""; LEGACY_FILE=""; KIND=""; KEY=""; TTL=""
ISSUE=""; BASE_REF=""; FACT_STATE=""; PR_NUMBER=""
HEAD_SHA=""; MERGE_SHA=""; DEPLOY_RUN_ID=""; CHECK_STATUS=""
MODE=shadow; ALLOW_LINKED=0; ALLOW_SERIAL=0
SUB=""

case "$ACTION" in
  lock|isolate|release-facts)
    SUB=${1:-}; [ -n "$SUB" ] || usage; shift ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT=$2; shift 2 ;;
    --fixture-dir) FIXTURE_DIR=$2; shift 2 ;;
    --state-dir) STATE_DIR=$2; shift 2 ;;
    --owner) OWNER=$2; shift 2 ;;
    --inventory-file) INVENTORY_FILE=$2; shift 2 ;;
    --human-gates-file) HUMAN_GATES_FILE=$2; shift 2 ;;
    --queue-file) QUEUE_FILE=$2; shift 2 ;;
    --v3-file) V3_FILE=$2; shift 2 ;;
    --legacy-file) LEGACY_FILE=$2; shift 2 ;;
    --kind) KIND=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --ttl-seconds) TTL=$2; shift 2 ;;
    --issue) ISSUE=$2; shift 2 ;;
    --base-ref) BASE_REF=$2; shift 2 ;;
    --state) FACT_STATE=$2; shift 2 ;;
    --pr-number) PR_NUMBER=$2; shift 2 ;;
    --head-sha) HEAD_SHA=$2; shift 2 ;;
    --merge-sha) MERGE_SHA=$2; shift 2 ;;
    --deploy-run-id) DEPLOY_RUN_ID=$2; shift 2 ;;
    --check-status) CHECK_STATUS=$2; shift 2 ;;
    --shadow) MODE=shadow; shift ;;
    --mutate) MODE=mutate; shift ;;
    --allow-linked-worktrees) ALLOW_LINKED=1; shift ;;
    --allow-serial-primary) ALLOW_SERIAL=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
need jq

primary() {
  local r=$1
  [ -d "$r" ] || die "--repo-root must be a directory" 2
  if [ -x "$SCRIPT_DIR/maintain-leases.sh" ]; then
    bash "$SCRIPT_DIR/maintain-leases.sh" primary-root --repo-root "$r" || die "primary resolve failed" 2
  else
    (cd "$r" && pwd -P)
  fi
}
git_common() {
  local r=$1 c; c=$(git -C "$r" rev-parse --git-common-dir) || die "not a git repo"
  case "$c" in /*) ;; *) c="$r/$c" ;; esac
  (cd "$c" && pwd -P)
}
state_dir_for() {
  local r=$1
  if [ -n "$STATE_DIR" ]; then printf '%s\n' "$STATE_DIR"
  else printf '%s/saas-startup-team/maintain-v3\n' "$(git_common "$r")"
  fi
}
ensure_dir() {
  mkdir -p -- "$1" || die "cannot mkdir $1"
  [ -d "$1" ] && [ ! -L "$1" ] || die "unsafe dir $1"
  (cd "$1" && pwd -P)
}

# --- inventory / select / shadow ---------------------------------------------

inventory() {
  need jq
  if [ -n "$FIXTURE_DIR" ]; then
    [ -d "$FIXTURE_DIR" ] || die "bad fixture-dir" 2
    safe_json "$FIXTURE_DIR/wip.json"; safe_json "$FIXTURE_DIR/queue.json"
    local human='[]'
    [ -f "$FIXTURE_DIR/human-gates.json" ] && human=$(jq -c . "$FIXTURE_DIR/human-gates.json")
    jq -nc --slurpfile w "$FIXTURE_DIR/wip.json" --slurpfile q "$FIXTURE_DIR/queue.json" \
      --argjson human "$human" --arg at "$(now_iso)" \
      '{schema_version:1,engine:"maintain-v3",source:"fixture",observed_at:$at,
        wip:$w[0],queue:$q[0],human_gates:$human,claims:[],compatibility_receipts:[]}'
    return
  fi
  [ -n "$REPO_ROOT" ] || die "inventory needs --repo-root or --fixture-dir" 2
  local root wip_args=(inventory --repo-root) wip queue
  root=$(primary "$REPO_ROOT")
  wip_args+=("$root"); [ "$ALLOW_LINKED" -eq 1 ] && wip_args+=(--allow-linked-worktrees)
  wip=$(bash "$SCRIPT_DIR/maintain-wip.sh" "${wip_args[@]}") || die "wip failed"
  queue=$(bash "$SCRIPT_DIR/maintain-queue.sh" --default-branch \
    "$(jq -r .default_branch <<<"$wip")") || die "queue failed"
  jq -nc --argjson wip "$wip" --argjson queue "$queue" --arg root "$root" --arg at "$(now_iso)" \
    '{schema_version:1,engine:"maintain-v3",source:"live",repo_root:$root,observed_at:$at,
      wip:$wip,queue:$queue,human_gates:[],claims:[],compatibility_receipts:[]}'
}

select_work() {
  [ -n "$INVENTORY_FILE" ] || die "select needs --inventory-file" 2
  safe_json "$INVENTORY_FILE"
  local inv gates queue
  inv=$(jq -c . "$INVENTORY_FILE")
  if [ -n "$HUMAN_GATES_FILE" ]; then safe_json "$HUMAN_GATES_FILE"; gates=$(jq -c . "$HUMAN_GATES_FILE")
  else gates=$(jq -c '.human_gates//[]' <<<"$inv"); fi
  if [ -n "$QUEUE_FILE" ]; then safe_json "$QUEUE_FILE"; queue=$(jq -c . "$QUEUE_FILE")
  else queue=$(jq -c 'if (.queue|type)=="array" then .queue
    elif (.queue.eligible|type)=="array" then .queue.eligible
    elif (.queue.items|type)=="array" then .queue.items else [] end' <<<"$inv"); fi
  jq -nc --argjson inv "$inv" --argjson gates "$gates" --argjson queue "$queue" --arg at "$(now_iso)" '
    def gate($n): ([ $gates[]? | select((.issue//.number//0)==$n)]|.[0]//null);
    def parked($n): (gate($n) as $g | if $g==null then false
      elif ($g.park==true) then true elif (($g.action//"")=="park") then true else false end);
    def dirty: (.wip.dirty//{clean:true,action:"none"});
    def items: (.wip.items//[]);
    def first($a): ([.[]|select(.action==$a)]|.[0]//null);
    def qfirst: ([ $queue[]? | select((.excluded//false)|not)
      | select((.eligible//true)==true) | select(parked(.number//.issue//0)|not) ]|.[0]//null);
    ($inv) as $i |
    (if ($i|dirty|.action)=="resume" then
      {disposition:"resume_dirty",kind:"dirty",action:"resume",issue:null,pr_number:null,
       branch:null,deliver:true,reason:"dirty_primary"}
     elif (($i|items|first("resume"))!=null) then
      (($i|items|first("resume")) as $w |
       {disposition:"resume_wip",kind:($w.kind//"branch"),action:"resume",issue:($w.issue//null),
        pr_number:($w.pr_number//null),branch:($w.branch//null),title:($w.title//null),
        check_status:($w.check_status//null),deliver:true,reason:($w.reason//"wip_resume")})
     elif (($i|items|first("delete"))!=null) then
      (($i|items|first("delete")) as $w |
       {disposition:"delete_stale",kind:($w.kind//"branch"),action:"delete",issue:($w.issue//null),
        pr_number:($w.pr_number//null),branch:($w.branch//null),deliver:false,
        reason:($w.reason//"stale_branch")})
     elif (qfirst!=null) then
      (qfirst as $q |
       {disposition:"greenfield",kind:"issue",action:"deliver",issue:($q.number//$q.issue),
        pr_number:($q.pr_number//null),branch:null,title:($q.title//null),
        human_gate:gate($q.number//$q.issue//0),deliver:true,reason:"queue_select"})
     else
      {disposition:"no_op",kind:"none",action:"none",issue:null,pr_number:null,branch:null,
       deliver:false,reason:"empty"}
     end) as $sel |
    {schema_version:1,engine:"maintain-v3",observed_at:$at,selection:$sel,
     claims:[],compatibility_receipts:[]}'
}

shadow_compare() {
  [ -n "$V3_FILE" ] && [ -n "$LEGACY_FILE" ] || die "shadow-compare needs files" 2
  safe_json "$V3_FILE"; safe_json "$LEGACY_FILE"
  local out
  out=$(jq -nc --slurpfile v3 "$V3_FILE" --slurpfile legacy "$LEGACY_FILE" --arg at "$(now_iso)" '
    def sel($x): if ($x.selection|type)=="object" then $x.selection else $x end;
    def norm($s): {disposition:($s.disposition//$s.action//"unknown"),kind:($s.kind//"unknown"),
      issue:($s.issue//null),pr_number:($s.pr_number//null),branch:($s.branch//null),
      action:($s.action//null),check_status:($s.check_status//null),
      park:(if ($s.human_gate|type)=="object" then ($s.human_gate.park//false) else false end)};
    (norm(sel($v3[0]))) as $a | (norm(sel($legacy[0]))) as $b |
    {schema_version:1,engine:"maintain-v3",observed_at:$at,match:($a==$b),v3:$a,legacy:$b,
     intentional_differences:["v3_creates_no_claims","v3_prefers_worktree_isolation",
       "v3_short_locks_only","v3_default_shadow_no_mutation"]}')
  printf '%s\n' "$out"
  [ "$(jq -r .match <<<"$out")" = true ] || exit 1
}

# --- locks -------------------------------------------------------------------

lock_path() { local d=$1 k=$2 key=$3 s; s=$(printf '%s' "$key" | tr '/: ' '---' | tr -cd 'A-Za-z0-9._-'); [ -n "$s" ] || s=key; printf '%s/%s-%s.lock.json\n' "$d" "$k" "$s"; }
ttl_default() { case "$1" in scheduler) echo 120;; issue) echo 300;; release) echo 600;; *) echo 120;; esac; }

do_lock() {
  case "$KIND" in scheduler|issue|release) ;; *) die "bad --kind" 2;; esac
  [ -n "$KEY" ] && valid_id "$OWNER" || die "lock needs --key --owner" 2
  [ -n "$STATE_DIR" ] || die "lock needs --state-dir" 2
  local dir path now exp owner_live ttl_use fd
  dir=$(ensure_dir "$STATE_DIR"); path=$(lock_path "$dir" "$KIND" "$KEY")
  ttl_use=${TTL:-$(ttl_default "$KIND")}; [[ "$ttl_use" =~ ^[1-9][0-9]*$ ]] || die "bad ttl" 2
  now=$(date -u +%s)
  case "$SUB" in
    status)
      if [ ! -f "$path" ]; then jq -nc --arg kind "$KIND" --arg key "$KEY" '{held:false,kind:$kind,key:$key}'; return; fi
      jq -c --argjson now "$now" '{held:((.expires_at_epoch//0)>$now and (.owner//"")!=""),
        kind:.kind,key:.key,owner:.owner,expires_at:.expires_at,expired:((.expires_at_epoch//0)<=$now)}' "$path"
      ;;
    release)
      if [ -f "$path" ]; then
        owner_live=$(jq -r '.owner//empty' "$path")
        [ "$owner_live" = "$OWNER" ] || die "lock owned by ${owner_live:-none}" 3
        rm -f -- "$path"
      fi
      jq -nc --arg kind "$KIND" --arg key "$KEY" --arg owner "$OWNER" \
        '{released:true,kind:$kind,key:$key,owner:$owner}'
      ;;
    acquire)
      exec {fd}>"${path}.flock" || die "flock open failed"
      flock -n "$fd" || die "flock busy" 3
      if [ -f "$path" ]; then
        exp=$(jq -r '.expires_at_epoch//0' "$path"); owner_live=$(jq -r '.owner//empty' "$path")
        if [ "$exp" -gt "$now" ] && [ -n "$owner_live" ] && [ "$owner_live" != "$OWNER" ]; then
          flock -u "$fd" 2>/dev/null || true; exec {fd}>&-
          die "lock held by $owner_live" 3
        fi
      fi
      exp=$((now + ttl_use))
      local exp_iso; exp_iso=$(date -u -d "@$exp" +%FT%TZ 2>/dev/null || date -u -r "$exp" +%FT%TZ)
      jq -nc --arg kind "$KIND" --arg key "$KEY" --arg owner "$OWNER" --arg acquired "$(now_iso)" \
        --arg expires "$exp_iso" --argjson exp "$exp" --argjson ttl "$ttl_use" \
        '{schema_version:1,kind:$kind,key:$key,owner:$owner,acquired_at:$acquired,
          expires_at:$expires,expires_at_epoch:$exp,ttl_seconds:$ttl}' >"${path}.tmp"
      mv -f -- "${path}.tmp" "$path"
      flock -u "$fd" 2>/dev/null || true; exec {fd}>&-
      cat "$path"
      ;;
    *) usage ;;
  esac
}

# --- isolate -----------------------------------------------------------------

iso_meta() { printf '%s/isolate-issue-%s.json\n' "$1" "$2"; }

do_isolate() {
  [ -n "$REPO_ROOT" ] && valid_uint "$ISSUE" || die "isolate needs --repo-root --issue" 2
  local root dir meta path mode base worktree clone_path
  root=$(primary "$REPO_ROOT"); need git
  dir=$(ensure_dir "$(state_dir_for "$root")"); meta=$(iso_meta "$dir" "$ISSUE"); base=${BASE_REF:-HEAD}
  case "$SUB" in
    status) if [ -f "$meta" ]; then cat "$meta"; else jq -nc --argjson issue "$ISSUE" '{prepared:false,issue:$issue}'; fi ;;
    cleanup)
      if [ -f "$meta" ]; then
        mode=$(jq -r .mode "$meta"); path=$(jq -r .path "$meta")
        case "$mode" in
          worktree) [ -d "$path" ] && { git -C "$root" worktree remove --force "$path" 2>/dev/null || rm -rf -- "$path"; } ;;
          clone) [ -d "$path" ] && rm -rf -- "$path" ;;
        esac
        rm -f -- "$meta"
      fi
      jq -nc --argjson issue "$ISSUE" '{cleaned:true,issue:$issue}'
      ;;
    prepare)
      worktree="$dir/wt-issue-$ISSUE"
      if git -C "$root" worktree add --detach "$worktree" "$base" >/dev/null 2>&1; then
        jq -nc --argjson issue "$ISSUE" --arg path "$worktree" --arg base "$base" --arg root "$root" --arg at "$(now_iso)" \
          '{schema_version:1,prepared:true,issue:$issue,mode:"worktree",path:$path,base_ref:$base,
            primary:$root,mutates_primary:false,prepared_at:$at}' | tee "$meta"; return
      fi
      clone_path="$dir/clone-issue-$ISSUE"; rm -rf -- "$clone_path"
      if git clone --local --no-hardlinks --quiet "$root" "$clone_path" 2>/dev/null \
        && git -C "$clone_path" checkout --detach "$base" >/dev/null 2>&1; then
        jq -nc --argjson issue "$ISSUE" --arg path "$clone_path" --arg base "$base" --arg root "$root" --arg at "$(now_iso)" \
          '{schema_version:1,prepared:true,issue:$issue,mode:"clone",path:$path,base_ref:$base,
            primary:$root,mutates_primary:false,prepared_at:$at}' | tee "$meta"; return
      fi
      rm -rf -- "$clone_path"
      if [ "$ALLOW_SERIAL" -eq 1 ]; then
        jq -nc --argjson issue "$ISSUE" --arg path "$root" --arg base "$base" --arg root "$root" --arg at "$(now_iso)" \
          '{schema_version:1,prepared:true,issue:$issue,mode:"serial",path:$path,base_ref:$base,
            primary:$root,mutates_primary:true,prepared_at:$at,
            warning:"serial_primary_requires_exclusive_short_mutation_windows"}' | tee "$meta"; return
      fi
      die "isolation unavailable; pass --allow-serial-primary" 3
      ;;
    *) usage ;;
  esac
}

# --- release facts -----------------------------------------------------------

facts_path() { printf '%s/release-issue-%s.json\n' "$1" "$2"; }
# Canonical ordered recovery steps (index 0..N). Forward-only.
RECOVERY_STEPS=(
  selected revalidate_head authorize_merge merge_sha_pinned
  record_merge deploy_proof close_issue observe_closed done
)
recovery_rank() {
  local i s=$1
  for i in "${!RECOVERY_STEPS[@]}"; do
    [ "${RECOVERY_STEPS[$i]}" = "$s" ] && { printf '%s\n' "$i"; return 0; }
  done
  return 1
}
recovery_next() {
  local r
  r=$(recovery_rank "${1:-selected}") || return 1
  if [ "$r" -ge $((${#RECOVERY_STEPS[@]} - 1)) ]; then
    printf '%s\n' done
  else
    printf '%s\n' "${RECOVERY_STEPS[$((r + 1))]}"
  fi
}

do_facts() {
  [ -n "$REPO_ROOT" ] && valid_uint "$ISSUE" || die "release-facts needs --repo-root --issue" 2
  local root dir path current next prev old_merge old_head
  root=$(primary "$REPO_ROOT"); dir=$(ensure_dir "$(state_dir_for "$root")"); path=$(facts_path "$dir" "$ISSUE")
  case "$SUB" in
    show)
      if [ -f "$path" ]; then cat "$path"
      else jq -nc --argjson issue "$ISSUE" '{exists:false,issue:$issue,claims:false,compatibility_receipts:false}'; fi
      ;;
    recovery-step)
      current=selected; [ -f "$path" ] && current=$(jq -r '.recovery_step//"selected"' "$path")
      next=$(recovery_next "$current") || die "unknown step $current"
      jq -nc --argjson issue "$ISSUE" --arg current "$current" --arg next "$next" --arg at "$(now_iso)" \
        '{schema_version:1,issue:$issue,current_step:$current,next_step:$next,idempotent:true,observed_at:$at,
          crash_points:["revalidate_head","authorize_merge","merge_sha_pinned","record_merge",
            "deploy_proof","close_issue","observe_closed"]}'
      ;;
    record)
      [ -n "$FACT_STATE" ] || die "record needs --state" 2
      # Only canonical recovery steps; no alias states that brick recovery_next.
      recovery_rank "$FACT_STATE" >/dev/null || die "bad --state (not a recovery step)" 2
      [ -z "$HEAD_SHA" ] || valid_sha "$HEAD_SHA" || die "bad head-sha" 2
      [ -z "$MERGE_SHA" ] || valid_sha "$MERGE_SHA" || die "bad merge-sha" 2
      [ -z "$PR_NUMBER" ] || valid_uint "$PR_NUMBER" || die "bad pr-number" 2
      prev='{}'; [ -f "$path" ] && prev=$(cat "$path")
      local cur_step cur_rank new_rank
      cur_step=$(jq -r '.recovery_step//"selected"' <<<"$prev")
      cur_rank=$(recovery_rank "$cur_step" 2>/dev/null || echo 0)
      new_rank=$(recovery_rank "$FACT_STATE")
      # Forward-only: same step is idempotent re-record; earlier step fails closed.
      [ "$new_rank" -ge "$cur_rank" ] || die "backward recovery transition: $cur_step -> $FACT_STATE"
      if [ -f "$path" ]; then
        if [ -n "$MERGE_SHA" ]; then
          old_merge=$(jq -r '.merge_sha//empty' "$path")
          [ -z "$old_merge" ] || [ "$old_merge" = "$MERGE_SHA" ] || die "merge_sha conflict: $old_merge vs $MERGE_SHA"
        fi
        # head_sha immutable once merge_sha_pinned or later
        if [ -n "$HEAD_SHA" ] && [ "$cur_rank" -ge "$(recovery_rank merge_sha_pinned)" ]; then
          old_head=$(jq -r '.head_sha//empty' "$path")
          [ -z "$old_head" ] || [ "$old_head" = "$HEAD_SHA" ] || die "head_sha immutable after merge_sha_pinned"
        fi
        # deploy_run_id immutable once deploy_proof or later
        if [ -n "$DEPLOY_RUN_ID" ] && [ "$cur_rank" -ge "$(recovery_rank deploy_proof)" ]; then
          local old_deploy
          old_deploy=$(jq -r '.deploy_run_id//empty' "$path")
          [ -z "$old_deploy" ] || [ "$old_deploy" = "$DEPLOY_RUN_ID" ] \
            || die "deploy_run_id immutable after deploy_proof"
        fi
      fi
      jq -nc --argjson prev "$prev" --argjson issue "$ISSUE" --arg state "$FACT_STATE" \
        --arg pr "${PR_NUMBER:-}" --arg head "${HEAD_SHA:-}" --arg merge "${MERGE_SHA:-}" \
        --arg deploy "${DEPLOY_RUN_ID:-}" --arg checks "${CHECK_STATUS:-}" --arg at "$(now_iso)" '
        def keep($k;$v): if $v=="" then $prev[$k]//null else $v end;
        def kn($k;$v): if $v=="" then $prev[$k]//null else ($v|tonumber) end;
        $prev + {schema_version:1,issue:$issue,state:$state,recovery_step:$state,
          pr_number:kn("pr_number";$pr),head_sha:keep("head_sha";$head),
          merge_sha:keep("merge_sha";$merge),deploy_run_id:keep("deploy_run_id";$deploy),
          check_status:keep("check_status";$checks),claims:false,compatibility_receipts:false,
          updated_at:$at}' >"${path}.tmp"
      mv -f -- "${path}.tmp" "$path"; cat "$path"
      ;;
    *) usage ;;
  esac
}

# --- tick --------------------------------------------------------------------

tick() {
  local root dir owner inv sel sk inv_file disposition issue deliver iso facts pr_num note
  owner=${OWNER:-"tick-$$"}; valid_id "$owner" || die "bad owner" 2
  if [ -n "$FIXTURE_DIR" ]; then
    [ -z "$STATE_DIR" ] && STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mv3.XXXXXX")
    dir=$(ensure_dir "$STATE_DIR"); root=${REPO_ROOT:-$FIXTURE_DIR}
    inv=$(FIXTURE_DIR=$FIXTURE_DIR bash "$0" inventory --fixture-dir "$FIXTURE_DIR") || die "inv failed"
  else
    [ -n "$REPO_ROOT" ] || die "tick needs --repo-root or --fixture-dir" 2
    root=$(primary "$REPO_ROOT"); dir=$(ensure_dir "$(state_dir_for "$root")")
    local iargs=(inventory --repo-root "$root")
    [ "$ALLOW_LINKED" -eq 1 ] && iargs+=(--allow-linked-worktrees)
    inv=$(bash "$0" "${iargs[@]}") || die "inv failed"
  fi
  sk="maintain-v3:scheduler:$(printf '%s' "$root" | tr '/: ' '---')"
  bash "$0" lock acquire --kind scheduler --key "$sk" --state-dir "$dir" --owner "$owner" --ttl-seconds 120 >/dev/null \
    || die "scheduler lock refused" 3
  inv_file="$dir/last-inventory.json"; printf '%s\n' "$inv" >"$inv_file"
  local sargs=(select --inventory-file "$inv_file")
  [ -n "$HUMAN_GATES_FILE" ] && sargs+=(--human-gates-file "$HUMAN_GATES_FILE")
  sel=$(bash "$0" "${sargs[@]}") || die "select failed"
  printf '%s\n' "$sel" >"$dir/last-selection.json"
  bash "$0" lock release --kind scheduler --key "$sk" --state-dir "$dir" --owner "$owner" >/dev/null || true

  disposition=$(jq -r .selection.disposition <<<"$sel")
  issue=$(jq -r '.selection.issue//empty' <<<"$sel")
  deliver=$(jq -r .selection.deliver <<<"$sel")
  pr_num=$(jq -r '.selection.pr_number//empty' <<<"$sel")
  iso=null; facts=null; note=shadow_only

  if [ "$MODE" = mutate ] && [ "$deliver" = true ] && [ -n "$issue" ]; then
    bash "$0" lock acquire --kind issue --key "issue-$issue" --state-dir "$dir" --owner "$owner" --ttl-seconds 300 >/dev/null \
      || die "issue lock refused" 3
    local oargs=(isolate prepare --repo-root "$root" --issue "$issue" --state-dir "$dir")
    [ "$ALLOW_SERIAL" -eq 1 ] && oargs+=(--allow-serial-primary)
    iso=$(bash "$0" "${oargs[@]}") || die "isolate failed"
    local fargs=(release-facts record --repo-root "$root" --issue "$issue" --state-dir "$dir" --state selected)
    [ -n "$pr_num" ] && [ "$pr_num" != null ] && fargs+=(--pr-number "$pr_num")
    facts=$(bash "$0" "${fargs[@]}") || die "facts failed"
    bash "$0" lock release --kind issue --key "issue-$issue" --state-dir "$dir" --owner "$owner" >/dev/null || true
    note=isolated_ready_for_deliver
  fi

  jq -nc --argjson inv "$inv" --argjson sel "$sel" --argjson isolate "$iso" --argjson facts "$facts" \
    --arg mode "$MODE" --arg note "$note" --arg disposition "$disposition" \
    --arg at "$(now_iso)" --arg root "$root" --arg state_dir "$dir" '
    {schema_version:1,engine:"maintain-v3",mode:$mode,observed_at:$at,repo_root:$root,state_dir:$state_dir,
     disposition:$disposition,inventory:$inv,selection:$sel.selection,isolation:$isolate,
     release_facts:$facts,
     deliver_hint:(if $mode=="mutate" and ($sel.selection.deliver==true) then
       {skill:"skills/deliver/SKILL.md",entrypoint:"goal-deliver",
        worktree:($isolate.path//null),issue:($sel.selection.issue//null)} else null end),
     note:$note,claims:[],compatibility_receipts:[],locks_held_after_tick:[]}'
}

case "$ACTION" in
  inventory) inventory ;;
  select) select_work ;;
  shadow-compare) shadow_compare ;;
  lock) do_lock ;;
  isolate) do_isolate ;;
  release-facts) do_facts ;;
  tick) tick ;;
  *) usage ;;
esac
