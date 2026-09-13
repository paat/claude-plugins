#!/usr/bin/env bash
# Fetch one bounded snapshot; configured commands are trusted local configuration.
set -euo pipefail
wit_config() {
  python3 - "$1" "$2" "$3" <<'PY'
import json,re,sys
path,name,keys=sys.argv[1:]; text=open(path).read()
try:
    data=json.loads(text)
except ValueError:
    rows=[]; row=None; active=False; base=0
    for line in text.splitlines():
        if re.match(r'^\s*sources:\s*$',line):
            active=True; base=len(line)-len(line.lstrip()); continue
        if not active or not line.strip() or line.lstrip().startswith('#'): continue
        if len(line)-len(line.lstrip()) <= base: break
        match=re.match(r'\s*(-\s+)?(name|list|show|search):\s*(.*?)\s*$',line)
        if not match: raise SystemExit('Unsupported sources syntax; use JSON or quoted scalar YAML entries')
        entry,key,value=match.groups()
        if entry:
            row={}; rows.append(row)
        if row is None: raise SystemExit('sources must be a list of named entries')
        if value.startswith('"'):
            parsed,end=json.JSONDecoder().raw_decode(value)
            if value[end:].strip() and not value[end:].lstrip().startswith('#'): raise SystemExit('Invalid scalar suffix')
            value=parsed
        elif value.startswith("'"):
            quoted=re.fullmatch(r"'((?:[^']|'')*)'\s*(?:#.*)?",value)
            if not quoted: raise SystemExit('Invalid single-quoted scalar')
            value=quoted[1].replace("''", "'")
        elif key == 'name': value=re.sub(r'\s+#.*$', '', value)
        else: raise SystemExit('Quote source commands or use JSON')
        row[key]=value
    data={'sources':rows}
rows=[r for r in data.get('sources',[]) if r.get('name')==name]
if len(rows)!=1: raise SystemExit('Expected exactly one named source')
print(json.dumps({k:rows[0][k] for k in keys.split(',') if k in rows[0]}))
PY
}
wit_command() { local command; command=$(jq -r --arg k "$1" '.[$k] // empty' <<< "$adapter"); shift; [[ -n $command ]] && bash -c "$command \"\$@\"" wit "$@"; }
wit_json() { local filter=$1; shift; printf '%s\n' "$@" | jq -cs "$filter"; }
wit_read_main() {
  local system=github scope='' config='' id='' query='' full=false max_pages=100 verb=list
  while (($#)); do
    case "$1" in
      --system) system=$2; shift 2;; --scope) scope=$2; shift 2;; --config) config=$2; shift 2;;
      --id) id=$2; shift 2;; --search) query=$2; shift 2;; --full) full=true; shift;;
      --max-pages) max_pages=$2; shift 2;; --help) echo 'wit-read.sh --system NAME --scope SCOPE [--config FILE] [--id ID | --search QUERY] [--full] [--max-pages N]'; return;;
      *) echo "Unknown argument: $1" >&2; return 2;;
    esac
  done
  [[ -n $scope && $max_pages =~ ^[1-9][0-9]*$ && ( -z $id || -z $query ) ]] || return 2
  local tmp adapter='{}' complete=true limits='[]' records='[]' page payload count endpoint verb next raw iid comments timeline item
  tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
  if [[ $system != github ]]; then
    [[ -n $config ]] || { echo 'Configured source requires --config' >&2; return 2; }
    adapter=$(wit_config "$config" "$system" 'list,show,search')
    jq -e '.list and .show' <<< "$adapter" >/dev/null || { echo 'Source requires list and show commands' >&2; return 2; }
  fi
  if [[ -n $id ]]; then
    if [[ $system == github ]]; then payload=$(gh api "repos/$scope/issues/$id") || return 1
    else payload=$(wit_command show "$id") || return 1; fi
    records=$(jq -cs '.' <<< "$payload")
  else
    verb=list
    if [[ -n $query && $system != github ]]; then
      if jq -e '.search' <<< "$adapter" >/dev/null; then verb=search
      else limits='["search unavailable: duplicate lookup uses bounded list + local text matching; semantic duplicates and closed items may be missed"]'; fi
    fi
    : > "$tmp/pages"
    for ((page=1;page<=max_pages;page++)); do
      if [[ $system == github ]]; then
        endpoint="repos/$scope/issues?state=open&per_page=100&page=$page"
        [[ -z $query ]] || endpoint="search/issues?q=$(jq -rn --arg q "$query repo:$scope is:issue" '$q|@uri')&per_page=100&page=$page"
        if ! payload=$(gh api "$endpoint"); then complete=false; break; fi
        if ! jq -e 'type=="array" or (.items|type=="array")' <<< "$payload" >/dev/null; then complete=false; break; fi
        count=$(jq 'if type=="array" then length else .items|length end' <<< "$payload")
        [[ $(jq -r 'if type=="object" then .incomplete_results // false else false end' <<< "$payload") == false ]] || complete=false
        payload=$(jq 'if type=="array" then . else .items end | map(select(.pull_request == null))' <<< "$payload")
        next=false; ((count<100)) || next=true
      else
        if [[ $verb == search ]]; then payload=$(wit_command "$verb" "$query" "$page") || { complete=false; break; }
        else payload=$(wit_command "$verb" "$page") || { complete=false; break; }; fi
        if ! jq -e '(.items|type=="array") and (.next|type=="boolean") and (.complete|type=="boolean")' <<< "$payload" >/dev/null; then complete=false; break; fi
        next=$(jq -r '.next' <<< "$payload"); [[ $(jq -r '.complete' <<< "$payload") == true ]] || complete=false
        payload=$(jq '.items' <<< "$payload")
      fi
      printf '%s\n' "$payload" >> "$tmp/pages"
      [[ $next == true ]] || break
      ((page<max_pages)) || complete=false
    done
    records=$(jq -cs 'add // []' "$tmp/pages")
  fi
  # A repeated id is not a second work item; retain the latest observation.
  records=$(jq 'reverse | unique_by((.id // .number)|tostring)' <<< "$records")
  : > "$tmp/items"
  while IFS= read -r raw; do
    iid=$(jq -r '(.number // .id)|tostring' <<< "$raw")
    local item_complete=true
    comments='[]'; timeline='[]'
    if [[ $system == github ]]; then
      for endpoint in comments timeline; do
        local collected='[]'
        : > "$tmp/collected"
        for ((page=1;page<=max_pages;page++)); do
          if ! payload=$(gh api "repos/$scope/issues/$iid/$endpoint?per_page=100&page=$page") || ! jq -e 'type=="array"' <<< "$payload" >/dev/null; then item_complete=false; break; fi
          printf '%s\n' "$payload" >> "$tmp/collected"
          count=$(jq length <<< "$payload"); ((count<100)) && break
          ((page<max_pages)) || item_complete=false
        done
        collected=$(jq -cs 'add // []' "$tmp/collected")
        if [[ $endpoint == comments ]]; then comments=$collected; else timeline=$collected; fi
      done
      [[ $(jq length <<< "$comments") -ge $(jq '.comments // 0' <<< "$raw") ]] || item_complete=false
    else
      if [[ -z $id ]]; then payload=$(wit_command show "$iid") && raw=$payload || item_complete=false; fi
      comments=$(jq '.comments // []' <<< "$raw"); timeline=$(jq '.history // []' <<< "$raw")
      [[ $(jq -r '.comments_complete // false' <<< "$raw") == true ]] || item_complete=false
      [[ $(jq -r 'if has("complete") then .complete else true end' <<< "$raw") == true ]] || item_complete=false
    fi
    local relations relation linked_scope linked_id details
    relations=$(wit_json '.[0] as $r | .[1] as $t | $r.relations // [] | . + [$t[]|select(.source.issue? != null)|.source.issue|{id:(.number|tostring),url:(.html_url // ""),kind:(if .pull_request then "delivery" else "related" end)}]' "$raw" "$timeline")
    if [[ $system == github ]]; then
      relations=$(wit_json '
        .[0] as $relations | .[1] as $r | .[2] as $scope |
        ($relations | map(. + {_body_candidate:false})) +
        [(($r.body // "")|scan("([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]+)"))|{id:.[1],_scope:(.[0] // $scope),kind:"referenced",_body_candidate:true}] |
        map(. as $r | ((.url // "" | capture("^https://github.com/(?<scope>[^/]+/[^/]+)/(issues|pull)/(?<id>[0-9]+)$")?) //
          {scope:(._scope // $scope),id:(.id|tostring)}) as $link | $r + {id:$link.id,_scope:$link.scope}) |
        unique_by([._scope,.id])' "$relations" "$raw" "$(jq -n --arg scope "$scope" '$scope')")
      : > "$tmp/relations"
      while IFS= read -r relation; do
        linked_scope=$(jq -r "._scope" <<< "$relation"); linked_id=$(jq -r '.id' <<< "$relation")
        if [[ ! $linked_id =~ ^[0-9]+$ ]] || ! details=$(gh api "repos/$linked_scope/issues/$linked_id" 2> "$tmp/relation-error"); then
          if [[ $linked_id =~ ^[0-9]+$ ]]; then
            if [[ $(jq -r "._body_candidate" <<< "$relation") == true ]] && grep -Eq '^gh: .*\(HTTP 404\)$' "$tmp/relation-error"; then continue; fi
            cat "$tmp/relation-error" >&2
          fi
          item_complete=false; relation=$(jq '. + {resolution:"unavailable"}' <<< "$relation")
        else
          relation=$(wit_json '.[0] as $r | .[1] as $d | $r + {title:($d.title // ""),state:($d.state // "unknown"),url:($d.html_url // $r.url // ""),resolution:"resolved"}' "$relation" "$details")
          if jq -e '.pull_request' <<< "$details" >/dev/null || [[ $(jq -r '.kind' <<< "$relation") == delivery ]]; then
            if details=$(gh api "repos/$linked_scope/pulls/$linked_id"); then
              relation=$(wit_json '.[0] as $r | .[1] as $d | $r + {kind:"delivery",mergedAt:($d.merged_at // null),baseRef:($d.base.ref // null),headCommit:($d.head.sha // null)}' "$relation" "$details")
            else item_complete=false; relation=$(jq '. + {resolution:"unavailable"}' <<< "$relation"); fi
          fi
        fi
        jq -c 'del(._body_candidate,._scope)' <<< "$relation" >> "$tmp/relations"
      done < <(jq -c '.[]' <<< "$relations")
      relations=$(jq -s '.' "$tmp/relations")
    fi
    [[ $item_complete == true ]] || complete=false
    local digest
    digest=$(wit_json '.[0] as $r | .[1] as $c | .[2] as $t | {title:($r.title // $r.name),state:$r.state,labels:($r.labels // []),relations:.[3],body:($r.body // $r.description_stripped // $r.description // ""),comments:$c,history:$t}' "$raw" "$comments" "$timeline" "$relations" | jq -cS . | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
    printf '%s\n' "$raw" "$comments" "$timeline" "$relations" > "$tmp/input"
    item=$(jq -cs --arg query "$query" --arg digest "$digest" --argjson full "$full" --argjson ok "$item_complete" '
      .[0] as $r | .[1] as $c | .[2] as $t | .[3] as $relations |
      def clip: if $full then . else .[0:600] end;
      def attribution($who): if $who == null then {} else {author:$who} end;
      def history_detail:
        . as $e
        | def field($o; $k): if ($o|type) == "object" then $o[$k] else null end;
        (($e.detail | if type == "object" then . else {} end)
         + ({label:field($e.label; "name"), assignee:field($e.assignee; "login"),
             rename_from:field($e.rename; "from"), rename_to:field($e.rename; "to"),
             milestone:field($e.milestone; "title"), state_reason:$e.state_reason}
            | with_entries(select(.value | type == "string" and test("\\S"))))
         | with_entries(select(.value | type == "string" and test("\\S"))))
        | if length > 0 then {detail:.} else {} end;
      {history_digest:$digest,id:(($r.number // $r.id)|tostring), title:($r.title // $r.name // ""), url:($r.html_url // $r.url // ""),
       state:(($r.state | if type=="object" then .name else . end) // "unknown" | ascii_downcase), updatedAt:($r.updatedAt // $r.updated_at // null),
       body:(($r.body // $r.description_stripped // $r.description // "")|clip), labels:[($r.labels // [])[]|if type=="object" then .name else . end],
       comments:[$c[]|{id:(.id|tostring),body:((.body // .comment // "")|clip),updatedAt:(.updated_at // .updatedAt // "")} + attribution(.user.login // .author)], comments_fetched:($c|length),
       history:[$t[]|{event:(.event // .type // "decision"),at:(.created_at // .createdAt // ""),body:((.body // "")|clip)} + attribution(.actor.login // .author) + history_detail],
       completeness:(if $ok then "complete" else "incomplete" end), text_truncated:(((($r.body // $r.description_stripped // $r.description // "")|length)>600 or any($c[]; ((.body // .comment // "")|length)>600) or any($t[]; ((.body // "")|length)>600)) and ($full|not)),
       lookup_match:(((($r.title // $r.name // "")+" "+($r.body // $r.description_stripped // $r.description // ""))|ascii_downcase)|contains($query|ascii_downcase)),relations:$relations }' "$tmp/input")
    printf '%s\n' "$item" >> "$tmp/items"
  done < <(jq -c '.[]' <<< "$records")
  jq -s --arg system "$system" --arg scope "$scope" --arg now "${WIT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" --argjson ok "$complete" --argjson limits "$limits" --arg query "$query" --argjson fallback "$([[ $system != github && -n $query && $verb == list ]] && echo true || echo false)" '
    {source:{system:$system,scope:$scope},fetched_at:$now,completeness:(if $ok then "complete" else "incomplete" end),capability_limits:$limits,
     items:((if $fallback then map(select(.lookup_match)) else . end)|map(del(.lookup_match)))}' "$tmp/items"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then wit_read_main "$@"; fi
