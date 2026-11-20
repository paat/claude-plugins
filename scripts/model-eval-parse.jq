# Public response keys probed 2026-10-30; URLs and requests in model-eval-feeds.sh.
def required($ok; $what): if $ok then . else error("invalid " + $what) end;
def text: type == "string" and length > 0;
def number: type == "number";
def date: text and test("^\\d{4}-\\d{2}-\\d{2}");
def norm: ascii_downcase | gsub(" "; "-");
def options:
  capture("(?<suffix>\\((?<effort>Max|xHigh|High|Medium|Low|Minimal|None)(, (?<harness>[^()]+ Harness)|, [0-9]+)?\\))$"; "i")
  // capture("(?<suffix>\\((?<harness>[^()]+ Harness)\\))$") // {};
def vendor:
  ascii_downcase | if . == "xai" then "x-ai" elif . == "alibaba" then "qwen"
  elif . == "meta-llama" then "meta" else . end;
def preliminary:
  if has("preliminary") then
    .preliminary | required(type == "boolean"; "preliminary flag")
  else false end;
def common:
  required((.name|text) and (.vendor|type == "string") and (.value|number) and (.as_of|date); "row")
  | required(.ci_low == null or ((.ci_low|number) and (.ci_high|number)
      and .ci_low <= .value and .value <= .ci_high); "CI")
  | required(.rank == null or ((.rank|number) and .rank >= 1); "rank");

($aliases | split("\n") | map(select(length > 0 and (startswith("#")|not)) | split("\t")
  | {key: .[0], value: .[1]}) | from_entries) as $alias
| ($catalog | split("\n") | map(select(length > 0 and (startswith("#")|not)))) as $ids
| (if $feed == "openrouter" then
    required((.data|type == "array" and length > 0) and .total_count == (.data|length)
      and (.links|has("next")) and .links.next == null; "OpenRouter completeness")
    | .data[] | required((.id|text) and (.canonical_slug|text) and (.created|number); "OpenRouter keys")
    | {name: .id, vendor: (.id|split("/")[0]), metric: "created", value: .created,
       canonical_slug: .canonical_slug, as_of: $as_of, preliminary: preliminary}
  elif $feed == "arena-webdev" or $feed == "arena-agent" then
    required(type == "array" and length > 0; "Arena rows") | .[]
    | required((.model_name|text) and (.organization|type == "string") and (.category|text)
        and (.leaderboard_publish_date|date) and (.rank|number); "Arena keys")
    | . as $r | (.model_name | options) as $options
    | {name: .model_name, vendor: .organization, rank: .rank,
       lookup_name: (.model_name | if $options.suffix then rtrimstr($options.suffix) else . end | sub(" +$"; "")),
       metric: ($feed + ":" + .category), as_of: .leaderboard_publish_date,
       harness: ($options.harness // ""),
       preliminary: (preliminary or (.model_name|test("preliminary|preview"; "i"))),
       effort: ($options.effort // "" | ascii_downcase)}
    | if $feed == "arena-webdev" then
        . + {value: $r.rating, ci_low: $r.rating_lower, ci_high: $r.rating_upper}
      else . + {value: $r.score, ci_low: $r.score_ci_lower, ci_high: $r.score_ci_upper} end
    | required((.ci_low|number) and (.ci_high|number); "Arena CI keys")
  elif $feed == "terminal" then
    required(.leaderboard.name == "4-0-0" and .leaderboard.package == "terminal-bench/terminal-bench"
      and (.rows|type == "array" and length > 0); "Terminal-Bench envelope")
    | .rows[] | required((.status|text) and (.rank|number)
        and (.metadata.reasoning_effort|type == "string") and (.metadata.agent_display.label|text)
        and (.metrics.accuracy_ci95_half_width|number and . >= 0)
        and (.metrics.total_tokens|number) and (.metrics.total_cost_usd|number); "Terminal-Bench keys")
    | {name: .metadata.model_display.label, vendor: .metadata.model_org.label,
       metric: "accuracy", value: .metrics.accuracy,
       ci_low: ([0, (.metrics.accuracy - .metrics.accuracy_ci95_half_width)]|max),
       ci_high: ([100, (.metrics.accuracy + .metrics.accuracy_ci95_half_width)]|min),
       rank: .rank, effort: (.metadata.reasoning_effort|ascii_downcase), harness: .metadata.agent_display.label,
       preliminary: (preliminary or .status != "display"), as_of: $as_of,
       tokens: .metrics.total_tokens, cost_usd: .metrics.total_cost_usd}
  elif $feed == "bug-hunt" then
    # Input: CSV as arrays (model-eval-csv.jq). Runs of one model/effort/harness are
    # averaged into one row (the board's own "mean of N") so identities stay unique.
    ["run","board_row","row_status","model","vendor","harness","effort","date","fixed_of_105","fixed_of_45",
     "fixed_of_60","partial","claimed_only","extras","wall_min","cost_usd","cost_kind","turns","turns_repo1",
     "turns_repo2","model_id","harness_version","note"] as $columns
    | required(type == "array" and length > 1 and .[0] == $columns; "Bug Hunt header")
    | .[1:] | map(required(length == ($columns|length); "Bug Hunt field count") | . as $f
        | [$columns, $f] | transpose | map({key: .[0], value: .[1]}) | from_entries
        | required((.row_status == "live" or .row_status == "superseded")
            and (.model|text) and (.harness|text) and (.effort|text)
            and (.date|test("^\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\\d|3[01])$"))
            and (.fixed_of_105|test("^\\d{1,3}$")) and (.fixed_of_105|tonumber <= 105)
            and (.cost_usd|test("^(\\d+(\\.\\d+)?)?$")); "Bug Hunt row"))
    | required((map(.run) | all(text) and length == (unique|length)); "Bug Hunt run ids")
    | map(select(.row_status == "live"))
    | required(length > 0; "Bug Hunt live rows")
    | group_by([.model, .effort, .harness])[]
    # Real data has runs of one configuration under different model_ids (a "-contributor"
    # variant): never merge them; each id is its own row named "<model> (<model_id>)".
    | ([.[].model_id | select(. != "")] | unique | length > 1) as $split
    | (if $split then group_by(.model_id)[] else . end)
    | . as $runs | ($runs | map(.cost_usd | select(. != "") | tonumber)) as $costs
    | ($runs[0].model | norm) as $own | (($alias[$own] // $own) | IN($ids[])) as $named
    | {name: (if $split and $runs[0].model_id != "" then $runs[0].model + " (" + $runs[0].model_id + ")" else $runs[0].model end), vendor: $runs[0].vendor, metric: "fixed_of_105",
       value: ($runs | map(.fixed_of_105|tonumber) | add / length * 100 | round / 100),
       effort: $runs[0].effort, harness: $runs[0].harness, preliminary: false,
       as_of: ($runs | map(.date) | max),
       lookup_name: (if $named then $runs[0].model
         else ([$runs[].model_id | select(. != "")] | first // $runs[0].model) end),
       cost_usd: (if $costs|length > 0 then ($costs | add / length * 100 | round / 100) else null end)}
  else error("unknown feed") end)
| common
| .vendor |= vendor
| (.lookup_name // .name | split("/")[-1] | norm) as $name
| ($alias[$name] // $name) as $candidate
| .model = (if $ids | index($candidate) then $candidate else "" end)
| [.model, .name, .vendor, .metric, .value, .ci_low, .ci_high, .rank, (.effort // ""),
   .harness, .preliminary, .canonical_slug, $feed, .as_of, .tokens, .cost_usd]
| map(if type == "string" then gsub("[^A-Za-z0-9._:/@+() -]"; "") | .[:120] else . end) | @tsv
