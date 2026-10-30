# Compare the same metric/harness/effort across dates; touching CIs overlap.
def rows: split("\n") | map(select(length > 0) | split("\t")) | .[1:];
def key: [.[1], .[3], .[8], .[9], .[12]] | tojson;
def unmapped_id:
  [(if .[12] == "openrouter" then (.[11] | sub(":[a-zA-Z0-9_-]+$"; "")) else .[1] end), .[12]];
($old | rows | group_by(key) | map({key: (.[0]|key), value: .}) | from_entries) as $before
| ($pool | split("\n") | map(select(startswith("#")|not) | split("\t") | .[2] // "")
   | map(if startswith("gpt-") then "openai" elif startswith("claude-") then "anthropic"
     elif startswith("gemini-") then "google" elif startswith("grok-") then "x-ai"
     elif startswith("muse-") then "meta" elif . == "default" then "qwen" else empty end) | unique) as $vendors
| ($old | rows | map(select(.[12] == "openrouter" or .[0] == "") | unmapped_id | tojson) | unique) as $unmapped
| ($old | rows | map(.[0]) | unique) as $models
| [$new | rows | group_by(key)[] | . as $group | .[] | . as $row
| $before[key] as $previous | $previous[0] as $prev
| if .[0] == "" and ($vendors | index($row[2])) != null and ($unmapped | index($row | unmapped_id | tojson)) == null then
    "unmapped\t" + ($row | join("\t"))
  elif .[0] != "" and ($models | index($row[0])) == null and ($vendors | index($row[2])) != null then
    "new_model\t" + ($row | join("\t"))
  elif $prev != null and ($group|length) == 1 and ($previous|length) == 1
    and .[10] != "true" and $prev[10] != "true" and .[7] != "" and $prev[7] != ""
    and .[7] != $prev[7] and .[5] != "" and .[6] != "" and $prev[5] != "" and $prev[6] != ""
    and ((.[5]|tonumber) > ($prev[6]|tonumber) or (.[6]|tonumber) < ($prev[5]|tonumber)) then
      "rank_before\t" + ($prev | join("\t")), "rank_after\t" + ($row | join("\t"))
  else empty end]
# Quote one representative row per new model/name, retaining both sides of rank changes.
| unique_by(split("\t") as $r | if $r[0] == "new_model" then [$r[0], $r[1]]
    elif $r[0] == "unmapped" then [$r[0], ($r[1:] | unmapped_id)] else [.] end)[]
