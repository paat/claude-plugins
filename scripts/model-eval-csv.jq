# Strict RFC 4180 subset: `jq -Rs -f` turns CSV text into an array of string arrays.
# A line that is not fully well-formed (stray quote, quoted newline) rejects the feed.
def field: "\"(?:[^\"]|\"\")*\"|[^,\"]*";
ltrimstr("﻿") | split("\n") | if .[-1] == "" then .[:-1] else . end
| map(sub("\r$"; "")
  # Each field is anchored to its leading comma, so an empty first field cannot be skipped.
  | "," + . | if test("^(," + "(" + field + "))+$") then
    [scan("," + "(" + field + ")") | .[0]
     | if startswith("\"") then .[1:-1] | gsub("\"\""; "\"") else . end]
  else error("malformed CSV line") end)
