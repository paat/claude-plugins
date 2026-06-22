#!/usr/bin/env bash
set -euo pipefail

# Test: the citation-URL builder turns parsed citation parts into a
# /laws/{act_id}/citation query string that PRESERVES superscript qualifiers
# (¹²³) as URL-encoded unicode (e.g. section=1¹ → section=1%C2%B9).
#
# This is the analysis-path regression for issue #68: the agent analysis
# workflow must construct citation URLs with the same superscript-aware builder
# the `register` subcommand uses (commands/lawyer.md). Building bare-integer
# params (section=1 instead of section=1%C2%B9) silently fetches a DIFFERENT
# legal clause with a 200 OK — § 14 lõige 1 (general rule) vs § 14 lõige 1¹
# (micro-entity exemption) are different rules.
#
# The builder is mirrored here from commands/lawyer.md (same pattern as
# test-citation-parse.sh mirrors the parser) so the canonical construction
# documented for the analysis path has an executable regression guard.

# build <act_id> <paragraph> <paragraph_q> <section> <section_q> <point> <point_q>
# Emits the citation query string (path + query) for DATALAKE base "BASE".
build() {
  python3 -c '
import sys, urllib.parse
base, act, para, pq, sec, sq, pt, kq = sys.argv[1:9]
SUP = {"0":"⁰","1":"¹","2":"²","3":"³","4":"⁴","5":"⁵","6":"⁶","7":"⁷","8":"⁸","9":"⁹"}
def enc(v, q): return urllib.parse.quote(v + "".join(SUP[c] for c in q))
parts = ["paragraph=" + enc(para, pq)]
if sec: parts.append("section=" + enc(sec, sq))
if pt:  parts.append("point="   + enc(pt,  kq))
print(f"{base}/api/v1/laws/{act}/citation?" + "&".join(parts))
' "BASE" "$@"
}

check() {
  local want="$1"; shift
  local got
  got=$(build "$@")
  [ "$got" = "$want" ] || { echo "FAIL: build($*) → '$got' (expected '$want')"; exit 1; }
}

# Args:           act para pq sec sq pt kq   Expected URL
# Plain paragraph
check "BASE/api/v1/laws/30087/citation?paragraph=10"                       30087 10 "" ""  ""  "" ""
# Paragraph + section, no qualifiers
check "BASE/api/v1/laws/30087/citation?paragraph=10&section=1"             30087 10 "" 1   ""  "" ""
# Paragraph + section + point
check "BASE/api/v1/laws/30087/citation?paragraph=10&section=1&point=3"     30087 10 "" 1   ""  3  ""

# --- Superscript qualifiers (regression for issue #68) ---
# RPS § 14 lõige 1¹ — micro-entity tegevusaruanne exemption (NOT lg 1).
# section qualifier "1" must encode to 1¹ → 1%C2%B9, never bare 1.
check "BASE/api/v1/laws/123/citation?paragraph=14&section=1%C2%B9"         123   14 "" 1   1   "" ""
# VÕS § 53 lõige 4 punkt 7¹ — point qualifier preserved
check "BASE/api/v1/laws/222/citation?paragraph=53&section=4&point=7%C2%B9" 222   53 "" 4   ""  7  1
# § 14¹ — paragraph itself superscript
check "BASE/api/v1/laws/333/citation?paragraph=14%C2%B9"                   333   14 1  ""  ""  "" ""
# § 14¹ lõige 2² — both paragraph and section superscript
check "BASE/api/v1/laws/444/citation?paragraph=14%C2%B9&section=2%C2%B2"   444   14 1  2   2   "" ""

# Guard against the bug: the lg 1¹ URL must NOT collapse to bare section=1
got=$(build 123 14 "" 1 1 "" "")
case "$got" in
  *"section=1%C2%B9"*) : ;;
  *) echo "FAIL: § 14 lõige 1¹ built '$got' — superscript qualifier dropped (would fetch wrong clause)"; exit 1 ;;
esac

echo "PASS: test-citation-url"
