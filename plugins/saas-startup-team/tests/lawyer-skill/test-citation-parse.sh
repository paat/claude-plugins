#!/usr/bin/env bash
set -euo pipefail

# Test: the citation parser extracts (paragraph, paragraph_qualifier, section,
# section_qualifier, point, point_qualifier) correctly from a handful of real
# Estonian compound references. Critical because the /laws/{act_id}/citation
# endpoint rejects the compound string and requires the parts as separate
# query params — and because superscript qualifiers (¹²³) distinguish
# different legal clauses (e.g. § 14 lg 1 vs § 14 lg 1¹ in RPS).
#
# Output is pipe-separated (non-whitespace) so empty fields survive `read -r`
# round-tripping into bash variables — tab/space would collapse adjacent
# empties under IFS whitespace rules.

parse() {
  printf '%s' "$1" | python3 -c '
import re, sys
SUP_TO_ASCII = str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹", "0123456789")
SUP = r"[⁰¹²³⁴-⁹]"
t = sys.stdin.read()
p = re.search(rf"§\s*(\d+)({SUP}*)", t)
s = re.search(rf"l[oõ]ige\s*(\d+)({SUP}*)", t, re.IGNORECASE)
k = re.search(rf"punkt\s*(\d+)({SUP}*)", t, re.IGNORECASE)
def parts(m):
    if not m: return ("", "")
    return (m.group(1), m.group(2).translate(SUP_TO_ASCII))
pb, pq = parts(p); sb, sq = parts(s); kb, kq = parts(k)
print("|".join([pb, pq, sb, sq, kb, kq]))
'
}

check() {
  local input="$1" want="$2"
  local got
  got=$(parse "$input")
  [ "$got" = "$want" ] || { echo "FAIL: '$input' → '$got' (expected '$want')"; exit 1; }
}

# Format: "<paragraph>|<paragraph_qual>|<section>|<section_qual>|<point>|<point_qual>"
check "§ 10"                          "10|||||"
check "§ 10 lõige 1"                  "10||1|||"
check "§ 10 lõige 1 punkt 3"          "10||1||3|"
check "§ 27 lõige 4 punkt 2"          "27||4||2|"
# ASCII fallback for 'loige' (no diacritic) — sometimes pasted that way
check "§ 5 loige 2"                   "5||2|||"
# Leading whitespace
check "  §  42   lõige  7  "          "42||7|||"
# Missing paragraph (should produce all empties — caller must reject)
check "lõige 1"                       "||1|||"

# --- Superscript qualifiers (regression for issue #18) ---
# Raamatupidamise seadus § 14 lõige 1¹ — micro-entity exemption (NOT lg 1)
check "§ 14 lõige 1¹"                 "14||1|1||"
# Võlaõigusseadus § 53 lõige 4 punkt 7¹ — digital-content exception
check "§ 53 lõige 4 punkt 7¹"         "53||4||7|1"
# Paragraph itself can be superscript (§ 14¹ is a distinct paragraph)
check "§ 14¹"                         "14|1||||"
# Combined: paragraph superscript + section superscript
check "§ 14¹ lõige 2²"                "14|1|2|2||"
# Double-digit base with superscript
check "§ 100 lõige 12³"               "100||12|3||"

# Round-trip into bash vars preserves empties (regression for tab-collapse bug)
IFS='|' read -r P PQ S SQ K KQ <<< "$(parse '§ 14 lõige 1¹')"
[ "$P" = "14" ] && [ "$PQ" = "" ] && [ "$S" = "1" ] && [ "$SQ" = "1" ] \
  && [ "$K" = "" ] && [ "$KQ" = "" ] \
  || { echo "FAIL: bash read round-trip (got P=[$P] PQ=[$PQ] S=[$S] SQ=[$SQ] K=[$K] KQ=[$KQ])"; exit 1; }

echo "PASS: test-citation-parse"
