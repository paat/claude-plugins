#!/usr/bin/env bash
set -euo pipefail

# Test: the citation parser extracts (paragraph, section, point) correctly
# from a handful of real Estonian compound references. Critical because the
# /laws/{act_id}/citation endpoint rejects the compound string and requires
# the three parts as separate integer query params.

parse() {
  printf '%s' "$1" | python3 -c '
import re, sys
t = sys.stdin.read()
p = re.search(r"§\s*(\d+)", t)
s = re.search(r"l[oõ]ige\s*(\d+)", t, re.IGNORECASE)
k = re.search(r"punkt\s*(\d+)", t, re.IGNORECASE)
print((p.group(1) if p else ""), (s.group(1) if s else ""), (k.group(1) if k else ""))
'
}

check() {
  local input="$1" want="$2"
  local got
  got=$(parse "$input")
  [ "$got" = "$want" ] || { echo "FAIL: '$input' → '$got' (expected '$want')"; exit 1; }
}

check "§ 10"                          "10  "
check "§ 10 lõige 1"                  "10 1 "
check "§ 10 lõige 1 punkt 3"          "10 1 3"
check "§ 27 lõige 4 punkt 2"          "27 4 2"
# ASCII fallback for 'loige' (no diacritic) — sometimes pasted that way
check "§ 5 loige 2"                   "5 2 "
# Leading whitespace
check "  §  42   lõige  7  "          "42 7 "
# Missing paragraph (should produce all empties — caller must reject)
check "lõige 1"                       " 1 "

echo "PASS: test-citation-parse"
