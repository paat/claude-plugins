#!/usr/bin/env bash
# Schema and contract validators for provider artifacts, policy gates, manifests, and arbitration.
# Sourced by scripts/collect-review-evidence.sh.

# $3/$4 optional authoritative base/head oids: when given, a review leg must
# have been stamped over exactly that range, so a well-formed leg for another
# revision cannot seal as ok (issue #487).
validate_provider() {
  local provider="$1" file="$2" want_base="${3:-}" want_head="${4:-}"
  jq -e --arg p "$provider" --arg want_base "$want_base" --arg want_head "$want_head" '
    def exact($allowed; $required):
      (type == "object") and ((keys - $allowed) | length == 0)
      and (($required - keys) | length == 0);
    def text: type == "string" and length > 0;
    def uint: type == "number" and . >= 0 and . == floor;
    def confidence: type == "number" and . >= 0 and . <= 1;
    def finding:
      exact(["severity","category","file","line","title","description","suggestion","confidence","line_check"];
            ["severity","category","file","line","title","description","suggestion","confidence"])
      and (.severity | IN("critical","high","medium","low"))
      and (.category | IN("logic","security","performance","quality","edge-case","architecture","testing"))
      and (.file | text and startswith("/") | not)
      and (.file | contains("../") | not)
      and (.line | type == "number" and . >= 1 and . == floor)
      and (.title | text) and (.description | text) and (.suggestion | text)
      and (.confidence | confidence)
      and ((has("line_check") | not) or (.line_check | text));
    def examined_path:
      text and (startswith("/") | not) and (contains("../") | not);
    def summary($fs):
      exact(["total_findings","critical","high","medium","low","quality_score","verdict","note"];
            ["total_findings","critical","high","medium","low","quality_score","verdict"])
      and (.total_findings | uint) and (.critical | uint) and (.high | uint)
      and (.medium | uint) and (.low | uint)
      and (.quality_score | type == "number" and . >= 0 and . <= 10)
      and (.verdict | IN("APPROVE","NEEDS_WORK","BLOCK"))
      and ((has("note") | not) or (.note | type == "string"))
      and .total_findings == ($fs | length)
      and .critical == ([$fs[] | select(.severity == "critical")] | length)
      and .high == ([$fs[] | select(.severity == "high")] | length)
      and .medium == ([$fs[] | select(.severity == "medium")] | length)
      and .low == ([$fs[] | select(.severity == "low")] | length)
      and ((.total_findings > 0) or (.verdict == "APPROVE"));
    def diff_stat:
      exact(["files_changed","insertions","deletions","base","base_oid","head_oid","truncated"];
            ["files_changed","insertions","deletions","base","base_oid","head_oid","truncated"])
      and (.files_changed | uint) and (.insertions | uint) and (.deletions | uint)
      and (.base | text) and (.truncated | type == "boolean")
      and (.base_oid | test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))
      and (.head_oid | test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))
      and ($want_base == "" or .base_oid == $want_base)
      and ($want_head == "" or .head_oid == $want_head);
    def grok_execution:
      exact(["verdict_phase","inspect_exit_code","requested_effort","verdict_effort"];
            ["verdict_phase","inspect_exit_code","requested_effort","verdict_effort"])
      and (.verdict_phase | . == null or IN("inspect","finalize"))
      and (.inspect_exit_code | . == null or (uint and . <= 255))
      and (.requested_effort | . == null or text)
      and (.verdict_effort | . == null or text)
      and (.verdict_phase != "finalize" or .verdict_effort == "low");
    .provider == $p and (
      (exact(["provider","status","note"];["provider","status","note"])
       and .status == "disabled" and (.note | text))
      or
      (exact(["provider","error"];["provider","error"])
       and (.error | text))
      or
      ((["provider","model","findings","summary","diff_stat","files_examined"]
          + (if $p == "grok" then ["grok_execution"] else [] end)) as $keys
       | exact($keys; $keys)
       and ($p != "grok" or (.grok_execution | grok_execution))
       and (.model | text) and (.findings | type == "array" and all(.[]; finding))
       and (.findings as $findings | .summary | summary($findings))
       and (.diff_stat | diff_stat)
       and (.files_examined | type == "array" and all(.[]; examined_path)))
    )
  ' "$file" >/dev/null
}

validate_ignored_paths() {
  jq -e '
    type == "array" and length > 0
    and all(.[];
      type == "object" and keys == ["line","path","pattern","source"]
      and (.path | type == "string" and length > 0 and (startswith("/") | not))
      and (.path | contains("../") | not)
      and (.pattern | type == "string" and length > 0)
      and (.source | type == "string" and length > 0)
      and (.line | type == "number" and . >= 1 and . == floor))
    and ([.[].path] | length) == ([.[].path] | unique | length)
  ' "$1" >/dev/null
}

validate_deleted_paths() {
  jq -e '
    type == "array" and length > 0
    and all(.[];
      type == "object" and keys == ["glob","path"]
      and (.path | type == "string" and length > 0 and (startswith("/") | not))
      and (.path | contains("../") | not)
      and (.glob | type == "string" and length > 0))
    and ([.[].path] | length) == ([.[].path] | unique | length)
  ' "$1" >/dev/null
}

validate_mutation_gate() {
  jq -e '
    type == "array" and length > 0
    and all(.[];
      type == "object" and keys == ["command","exit_code","path","result"]
      and (.path | type == "string" and length > 0 and (startswith("/") | not))
      and (.path | contains("../") | not)
      and (.command | type == "string" and length > 0)
      and (.exit_code | type == "number" and . >= 0 and . == floor)
      and (.result | IN("RED","vacuous"))
      and ((.result == "vacuous") == (.exit_code == 0))
      and ((.result == "RED") == (.exit_code != 0)))
    and ([.[].path] | length) == ([.[].path] | unique | length)
    and . == ([.[] | .] | sort_by(.path))
  ' "$1" >/dev/null
}

validate_prior_rejections() {
  jq -se '
    length == 1 and (.[0] | type == "array" and all(.[];
      type == "object" and keys == ["file","reason","title"]
      and (.title | type == "string" and length > 0)
      and (.file | type == "string")
      and (.reason | type == "string" and length > 0)))
  ' "$1" >/dev/null
}

validate_manifest_shape() {
  local manifest="$1"
  jq -e --arg schema "$SCHEMA_COLLECTION" '
    def exact($a;$r): (type=="object") and ((keys-$a)|length==0) and (($r-keys)|length==0);
    def text: type=="string" and length>0;
    def sha: type=="string" and test("^[0-9a-f]{64}$");
    def oid: type=="string" and test("^[0-9a-f]{40}$");
    def uint: type=="number" and .>=0 and .==floor;
    def identity: type=="string" and test("^[0-9]+:[0-9]+$");
    def snapshot: exact(["sha256","bytes","mode"];["sha256","bytes","mode"])
      and (.sha256|sha) and (.bytes|uint) and (.mode|type=="string" and test("^[0-7]{3,4}$"));
    def stamp: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    exact(["schema","started_at","completed_at","repository","git_surface","pull_request","diff","runner","providers","ignored_paths","sensitive_paths","deleted_paths","mutation_gate","panel_policy","containment","grok_recovery","prior_rejections"];
          ["schema","started_at","completed_at","repository","git_surface","pull_request","diff","runner","providers","grok_recovery"])
    and (.grok_recovery | IN("permit","reject"))
    and .schema==$schema and (.started_at|stamp) and (.completed_at|stamp) and .started_at<=.completed_at
    and (if has("containment") then
      all(.providers[]; .containment|IN("pid-namespace","session"))
      and .containment == (if all(.providers[]; .containment == "pid-namespace") then "pid-namespace" else "session" end)
      else all(.providers[]; has("containment")|not) end)
    and (.git_surface | exact(["schema","root_git","git_dir","git_dir_identity","common_dir","common_dir_identity","commondir","config"];
                              ["schema","root_git","git_dir","git_dir_identity","common_dir","common_dir_identity","commondir","config"])
         and .schema=="tribunal-git-surface/v2"
         and (.git_dir|text and startswith("/")) and (.common_dir|text and startswith("/"))
         and (.git_dir_identity|identity) and (.common_dir_identity|identity)
         and (.root_git | exact(["kind","identity","file"];["kind","identity","file"])
              and (.identity|identity) and ((.kind=="directory" and .file==null) or (.kind=="file" and (.file|snapshot))))
         and (.commondir==null or (.commondir|snapshot)) and (.config|snapshot))
    and (.repository | exact(["root","host","name_with_owner","url"];
                             ["root","host","name_with_owner","url"])
         and (.root|text and startswith("/")) and (.host|test("^[A-Za-z0-9.-]+$"))
         and (.name_with_owner|test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
         and (.url|test("^https://")))
    and (.pull_request | exact(["number","url","state","base_ref","base_oid","head_ref","head_oid","body"];
                               ["number","url","state","base_ref","base_oid","head_ref","head_oid","body"])
         and (.number|uint and .>0) and (.url|test("^https://")) and .state=="OPEN" and (.base_ref|text)
         and (.base_oid|oid) and (.head_ref|text) and (.head_oid|oid)
         and (.body|exact(["path","sha256","bytes"];["path","sha256","bytes"])
              and .path=="pr-body.txt" and (.sha256|sha) and (.bytes|uint)))
    and (.diff | exact(["path","sha256","bytes"];["path","sha256","bytes"])
         and .path=="review.diff" and (.sha256|sha) and (.bytes|uint and .>0))
    and ((has("prior_rejections")|not) or
         (.prior_rejections | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="prior-rejections.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and ((has("ignored_paths")|not) or
         (.ignored_paths | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="ignored-paths.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and (has("ignored_paths") == has("sensitive_paths"))
    and ((has("sensitive_paths")|not) or
         (.sensitive_paths | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="sensitive-paths.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and ((has("deleted_paths")|not) or
         (.deleted_paths | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="deleted-paths.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and ((has("mutation_gate")|not) or
         (.mutation_gate | exact(["path","sha256","bytes"];["path","sha256","bytes"])
          and .path=="mutation-gate.json" and (.sha256|sha) and (.bytes|uint and .>0)))
    and ((has("panel_policy")|not) or
         (.panel_policy | exact(["min_ok_legs","panel_size","panel","source"];["min_ok_legs","panel_size","panel","source"])
          and (.min_ok_legs|type=="number" and .>=2 and .<=7 and .==floor)
          and (.panel_size|type=="number" and .>=2 and .<=7 and .==floor)
          and (.panel|type=="array"
               and ([.[].provider]|length)==([.[].provider]|unique|length)
               and all(.[]; exact(["provider","model","effort"];["provider","model","effort"])
                 and (.provider|IN("codex","gemini","deepseek","qwen","grok","muse","claude"))
                 and (.model|text)
                 and (.effort == null or (.effort|text))))
          and .source=="env"))
    and (.runner | exact(["path","sha256","library_path","library_sha256","bundle_manifest_path","bundle_manifest_sha256"];
                         ["path","sha256","library_path","library_sha256","bundle_manifest_path","bundle_manifest_sha256"])
         and (.path|text and startswith("/")) and (.sha256|sha)
         and (.library_path|text and startswith("/")) and (.library_sha256|sha)
         and (.bundle_manifest_path|text and startswith("/")) and (.bundle_manifest_sha256|sha))
    and (.providers|type=="array" and length==7
         and ([.[].provider]|sort)==(["claude","codex","deepseek","gemini","grok","muse","qwen"])
         and all(.[];
           exact(["provider","status","wrapper","artifact","started_at","finished_at","exit_code","stderr","containment"];
                 ["provider","status","wrapper","artifact","started_at","finished_at","exit_code","stderr"])
           and (.provider|IN("codex","gemini","deepseek","qwen","grok","muse","claude"))
           and (.status|IN("ok","failed","disabled"))
           and (.wrapper|exact(["path","sha256"];["path","sha256"])
                and (.path|text and startswith("/")) and (.sha256|sha))
           and (.artifact|exact(["path","sha256","bytes"];["path","sha256","bytes"])
                and (.path|test("^providers/[a-z]+\\.json$")) and (.sha256|sha) and (.bytes|uint and .>0))
           and (.started_at|stamp) and (.finished_at|stamp) and .started_at<=.finished_at and (.exit_code|uint)
           and (.stderr|exact(["sha256","bytes"];["sha256","bytes"])
                and (.sha256|sha) and (.bytes|uint))))
  ' "$manifest" >/dev/null
}

validate_arbitration() {
  local arbitration="$1" manifest="$2" statuses dir evidence ignored_paths deleted_paths mutation_gate sensitive_paths
  local min_ok_legs
  statuses="$(jq -c '[.providers[]|{key:.provider,value:.status}]|from_entries' "$manifest")"
  # Sealed floor only — never re-read ambient TRIBUNAL_MIN_OK_LEGS (issue #519); a 1-leg APPROVE is never allowed.
  min_ok_legs="$(jq '[(.panel_policy.min_ok_legs // 2), 2] | max' "$manifest")"
  dir="$(dirname "$manifest")"
  evidence="$(jq -nc \
    --slurpfile codex "$dir/providers/codex.json" --slurpfile gemini "$dir/providers/gemini.json" \
    --slurpfile deepseek "$dir/providers/deepseek.json" \
    --slurpfile qwen "$dir/providers/qwen.json" --slurpfile grok "$dir/providers/grok.json" \
    --slurpfile muse "$dir/providers/muse.json" \
    --slurpfile claude "$dir/providers/claude.json" \
    '{codex:$codex[0],gemini:$gemini[0],deepseek:$deepseek[0],qwen:$qwen[0],grok:$grok[0],muse:$muse[0],claude:$claude[0]}')"
  if jq -e 'has("ignored_paths")' "$manifest" >/dev/null; then
    ignored_paths="$(jq -c . "$dir/ignored-paths.json")"
  else
    ignored_paths="[]"
  fi
  if jq -e 'has("deleted_paths")' "$manifest" >/dev/null; then
    deleted_paths="$(jq -c . "$dir/deleted-paths.json")"
  else
    deleted_paths="[]"
  fi
  if jq -e 'has("mutation_gate")' "$manifest" >/dev/null; then
    mutation_gate="$(jq -c . "$dir/mutation-gate.json")"
  else
    mutation_gate="[]"
  fi
  sensitive_paths="[]"
  if jq -e 'has("ignored_paths")' "$manifest" >/dev/null; then
    sensitive_paths="$(jq -c . "$dir/sensitive-paths.json")"
  fi
  jq -e --argjson statuses "$statuses" --argjson min_ok_legs "$min_ok_legs" --argjson evidence "$evidence" \
    --argjson ignored_paths "$ignored_paths" --argjson deleted_paths "$deleted_paths" \
    --argjson mutation_gate "$mutation_gate" \
    --argjson sensitive_paths "$sensitive_paths" '
    def exact($a;$r): (type=="object") and ((keys-$a)|length==0) and (($r-keys)|length==0);
    def text: type=="string" and length>0;
    def uint: type=="number" and .>=0 and .==floor;
    def conf: type=="number" and .>=0 and .<=1;
    def finding:
      exact(["id","consensus","providers","severity","category","file","line","title","description","suggestion","confidence","blocking_proof","arbiter_notes"];
            ["id","consensus","providers","severity","category","file","line","title","description","suggestion","confidence","arbiter_notes"])
      and (.id|test("^T-[0-9]{3,}$")) and (.consensus|IN("CONSENSUS","SINGLE_PROVIDER"))
      and (. as $finding | .providers|type=="array" and length>0 and length==([.[]]|unique|length)
           and all(.[]; . as $p
             | if $p == "repository-policy" then
                 ($ignored_paths | any(.[]; .path == $finding.file))
                 or ($deleted_paths | any(.[]; .path == $finding.file))
                 or ($mutation_gate | any(.[]; .path == $finding.file))
               else
                 ($p | IN("codex","gemini","deepseek","qwen","grok","muse","claude"))
                 and $statuses[$p] == "ok"
                 and (($evidence[$p].findings // []) | any(.[]; .file == $finding.file))
               end))
      and ((.providers|length)>=2) == (.consensus=="CONSENSUS")
      and (.severity|IN("critical","high","medium","low"))
      and (.category|IN("logic","security","performance","quality","edge-case","architecture","testing"))
      and (.file|text and startswith("/")|not) and (.file|contains("../")|not)
      and (.line|type=="number" and .>=1 and .==floor)
      and (.title|text) and (.description|text) and (.suggestion|text) and (.confidence|conf)
      and (.arbiter_notes|type=="string")
      and (if (.severity|IN("critical","high")) then
        (.blocking_proof|exact(["reachable_path","material_impact","caused_by_change"];
                               ["reachable_path","material_impact","caused_by_change"])
         and all(.[];text))
        else (has("blocking_proof")|not) or
          (.blocking_proof|exact(["reachable_path","material_impact","caused_by_change"];
                                 ["reachable_path","material_impact","caused_by_change"])
           and all(.[];text)) end);
    def scope:
      exact(["id","path","why_out_of_scope","disposition","conflicting_task_text","smallest_acceptable_diff"];
            ["id","path","why_out_of_scope","disposition","conflicting_task_text","smallest_acceptable_diff"])
      and (.id|test("^S-[0-9]{3,}$")) and (.path|text)
      and (.why_out_of_scope|text) and (.disposition|IN("must-remove-before-merge","follow-up-only"))
      and (.conflicting_task_text|type=="string") and (.smallest_acceptable_diff|text);
    def assessment($p;$final):
      exact(["findings_accepted","findings_rejected","false_positives","status"];
            ["findings_accepted","findings_rejected","false_positives","status"])
      and (.findings_accepted|uint) and (.findings_rejected|uint)
      and (.false_positives|type=="array" and all(.[];type=="string"))
      and .status==$statuses[$p]
      and .findings_accepted == ([$final[] | select(.providers | index($p))] | length)
      and (.findings_accepted + .findings_rejected) <= (($evidence[$p].findings // []) | length)
      and (.false_positives | length) <= .findings_rejected;
    exact(["tribunal_verdict","findings","scope_findings","provider_assessment","conflicts_resolved","summary"];
          ["tribunal_verdict","findings","scope_findings","provider_assessment","conflicts_resolved","summary"])
    and (.tribunal_verdict|exact(["decision","confidence","rationale"];
                                ["decision","confidence","rationale"])
         and (.decision|IN("APPROVE","NEEDS_WORK","BLOCK")) and (.confidence|conf) and (.rationale|text))
    and (.findings|type=="array" and all(.[];finding) and ([.[].id]|length)==([.[].id]|unique|length))
    and (.findings as $findings | $ignored_paths | all(.[]; .path as $path
      | any($findings[]; .file == $path and (.providers | index("repository-policy")))))
    and (.findings as $findings | $deleted_paths | all(.[]; .path as $path
      | any($findings[]; .file == $path and (.providers | index("repository-policy")))))
    and (.findings as $findings | [$mutation_gate[] | select(.result == "vacuous")] | all(.[]; .path as $path
      | any($findings[]; .file == $path and (.providers | index("repository-policy")))))
    and (.findings as $findings | $sensitive_paths | all(.[]; . as $path
      | any($findings[]; .file == $path and (.providers | index("repository-policy"))
          and .severity == "high")))
    and (.scope_findings|type=="array" and all(.[];scope) and ([.[].id]|length)==([.[].id]|unique|length))
    and (.findings as $final_findings | .provider_assessment
         | exact(["codex","gemini","deepseek","qwen","grok","muse","claude"];
                 ["codex","gemini","deepseek","qwen","grok","muse","claude"])
         and (.codex|assessment("codex";$final_findings))
         and (.gemini|assessment("gemini";$final_findings))
         and (.deepseek|assessment("deepseek";$final_findings))
         and (.qwen|assessment("qwen";$final_findings)) and (.grok|assessment("grok";$final_findings))
         and (.muse|assessment("muse";$final_findings))
         and (.claude|assessment("claude";$final_findings)))
    and (.conflicts_resolved|type=="array" and all(.[];type=="string")) and (.summary|text)
    and (if .tribunal_verdict.decision=="APPROVE" then
      (([$statuses[]|select(.=="ok")]|length) >= $min_ok_legs)
      and (if ($statuses | any(.[]; .=="failed")) then
        .tribunal_verdict.confidence > 0 and .tribunal_verdict.confidence < 0.95
      else .tribunal_verdict.confidence==0.95 end)
      and ([.findings[]|select(.severity=="critical" or .severity=="high")]|length)==0
      and ([.scope_findings[]|select(.disposition=="must-remove-before-merge")]|length)==0
      else true end)
    and (if ([$statuses[]|select(.=="ok")]|length)==0
      then .tribunal_verdict.decision=="NEEDS_WORK" and .tribunal_verdict.confidence==0 else true end)
    and (if ([$statuses[]|select(.=="ok")]|length) >= $min_ok_legs
            and ($statuses | all(.[]; .=="ok" or .=="disabled"))
            and ([$evidence[]|(.findings // [])[]]|length)==0
            and ([.findings[]|select(.providers==["repository-policy"])]|length)==0
            and ([.scope_findings[]|select(.disposition=="must-remove-before-merge")]|length)==0
            and ([$mutation_gate[] | select(.result == "vacuous")] | length) == 0
      then .tribunal_verdict.decision=="APPROVE" and .tribunal_verdict.confidence==0.95 else true end)
  ' "$arbitration" >/dev/null
}
