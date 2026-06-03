#!/usr/bin/env bash
# Test runner for agent-sync generator (generate.sh)
# Self-contained: bash 4+, jq, awk, sed.
# Usage: bash plugins/agent-sync/tests/run-generate-tests.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$PLUGIN_ROOT/scripts/generate.sh"
PASS=0
FAIL=0

# assert_contains NAME FILE EXACT_LINE — file must contain EXACT_LINE as a whole line.
assert_line() {
  local name="$1" file="$2" line="$3"
  if grep -Fxq -- "$line" "$file"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — expected exact line '$line' in $file"; FAIL=$((FAIL+1))
    echo "----- actual $file -----"; cat "$file"; echo "------------------------"
  fi
}

# assert_absent NAME FILE SUBSTRING — file must NOT contain SUBSTRING anywhere.
assert_absent() {
  local name="$1" file="$2" sub="$3"
  if grep -Fq -- "$sub" "$file"; then
    echo "FAIL: $name — unexpected substring '$sub' in $file"; FAIL=$((FAIL+1))
    echo "----- actual $file -----"; cat "$file"; echo "------------------------"
  else
    echo "PASS: $name"; PASS=$((PASS+1))
  fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- Fixture: full-body section whose source documents shell snippets with
#     '#' comments inside a fenced code block. -------------------------------
REPO="$TMP/full-body"
mkdir -p "$REPO/.agent-sync" "$REPO/.claude/rules"

cat > "$REPO/.claude/rules/security.md" <<'EOF'
# Security

## Environment Variables

```bash
# .env.local (frontend) - NEVER commit
VITE_API_URL=xxx

# appsettings.Development.json (.NET) - NEVER commit secrets
```

## Authentication
Use OAuth.
EOF

cat > "$REPO/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"sec":".claude/rules/security.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"s","title":"Security","source":"sec","type":"full-body"}]}]}
JSON

bash "$GEN" --config "$REPO/.agent-sync/sources.json" --root "$REPO" >/dev/null 2>&1
OUT="$REPO/AGENTS.md"

# Headings outside fences must still shift by +1 level.
assert_line "full-body: heading shifted (## -> ###)" "$OUT" "### Environment Variables"
assert_line "full-body: second heading shifted" "$OUT" "### Authentication"
# Comment lines INSIDE the fence must be emitted verbatim, not given an extra '#'.
assert_line "full-body: fenced comment preserved (line 1)" "$OUT" "# .env.local (frontend) - NEVER commit"
assert_line "full-body: fenced comment preserved (line 2)" "$OUT" "# appsettings.Development.json (.NET) - NEVER commit secrets"
assert_absent "full-body: fenced comment NOT promoted to heading" "$OUT" "## .env.local"

# --- Fixture: extract section. A fenced '#' comment inside the extracted
#     heading's body must not be read as a level-1 heading that truncates the
#     capture. ------------------------------------------------------------------
REPO2="$TMP/extract"
mkdir -p "$REPO2/.agent-sync" "$REPO2/.claude/rules"

cat > "$REPO2/.claude/rules/knowledge.md" <<'EOF'
# Knowledge

## Database
Use Postgres.

```bash
# db connection — do not commit
DB_URL=postgres://x
```

More database notes here.

## Caching
Use Redis.
EOF

cat > "$REPO2/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"kb":".claude/rules/knowledge.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"d","title":"Database","source":"kb","type":"extract","headings":["Database"]}]}]}
JSON

bash "$GEN" --config "$REPO2/.agent-sync/sources.json" --root "$REPO2" >/dev/null 2>&1
OUT2="$REPO2/AGENTS.md"

assert_line "extract: section intro captured" "$OUT2" "Use Postgres."
assert_line "extract: fenced comment preserved" "$OUT2" "# db connection — do not commit"
# The fenced '#' must not end the capture early — content after the fence survives.
assert_line "extract: content after fence not truncated" "$OUT2" "More database notes here."
# ...and must not leak the sibling section that follows.
assert_absent "extract: sibling section excluded" "$OUT2" "Use Redis."

# --- Fixture: a full-body source whose body opens with a fenced block (no H1
#     title). The leading fenced '#' comment must not be stripped as the title. -
REPO3="$TMP/no-title"
mkdir -p "$REPO3/.agent-sync" "$REPO3/.claude/rules"

cat > "$REPO3/.claude/rules/snippets.md" <<'EOF'
```bash
# leading comment — file opens with a fence, no title heading
X=1
```

## Notes
Body text.
EOF

cat > "$REPO3/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"sn":".claude/rules/snippets.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"n","title":"Snippets","source":"sn","type":"full-body"}]}]}
JSON

bash "$GEN" --config "$REPO3/.agent-sync/sources.json" --root "$REPO3" >/dev/null 2>&1
OUT3="$REPO3/AGENTS.md"

assert_line "no-title: leading fenced comment not stripped as title" "$OUT3" "# leading comment — file opens with a fence, no title heading"
assert_line "no-title: heading still shifted" "$OUT3" "### Notes"

# --- Fixture: mawk interval-portability edge cases (issue #33). The heading
#     regexes use match()/RLENGTH instead of ERE intervals; assert the boundary
#     behaviour those guards exist to preserve, on the default awk (mawk here). --
REPO4="$TMP/mawk-shift-edges"
mkdir -p "$REPO4/.agent-sync" "$REPO4/.claude/rules"

cat > "$REPO4/.claude/rules/edges.md" <<'EOF'
# Edges

## Level Two
###### Level Six
####### Seven Hashes Not A Heading
#nospace-not-a-heading
EOF

cat > "$REPO4/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"e":".claude/rules/edges.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"e","title":"Edges","source":"e","type":"full-body"}]}]}
JSON

bash "$GEN" --config "$REPO4/.agent-sync/sources.json" --root "$REPO4" >/dev/null 2>&1
OUT4="$REPO4/AGENTS.md"

# Levels 1-5 demote by +1; level 6 must NOT gain a 7th '#'.
assert_line   "mawk-shift: level-2 demoted to level-3"        "$OUT4" "### Level Two"
assert_line   "mawk-shift: level-6 NOT demoted to level-7"    "$OUT4" "###### Level Six"
assert_absent "mawk-shift: no 7-hash heading from level-6"    "$OUT4" "####### Level Six"
# A 7-hash line is not a valid heading: untouched (not demoted).
assert_line   "mawk-shift: 7-hash line preserved verbatim"    "$OUT4" "####### Seven Hashes Not A Heading"
# A '#' run with no following space is not a heading: untouched.
assert_line   "mawk-shift: hash-without-space preserved"      "$OUT4" "#nospace-not-a-heading"

# --- Fixture: extract path must also cap at level 6 — a 7-hash line inside the
#     captured body is content, not a heading boundary (issue #33 / tribunal T-001). -
REPO5="$TMP/mawk-extract-edges"
mkdir -p "$REPO5/.agent-sync" "$REPO5/.claude/rules"

cat > "$REPO5/.claude/rules/doc.md" <<'EOF'
# Doc

## Section
intro line
####### deep marker not a heading
tail line

## Other
Other body.
EOF

cat > "$REPO5/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"d":".claude/rules/doc.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"s","title":"Section","source":"d","type":"extract","headings":["Section"]}]}]}
JSON

bash "$GEN" --config "$REPO5/.agent-sync/sources.json" --root "$REPO5" >/dev/null 2>&1
OUT5="$REPO5/AGENTS.md"

assert_line   "mawk-extract: section intro captured"          "$OUT5" "intro line"
assert_line   "mawk-extract: 7-hash line kept as content"     "$OUT5" "####### deep marker not a heading"
assert_line   "mawk-extract: content after 7-hash survives"   "$OUT5" "tail line"
assert_absent "mawk-extract: sibling section excluded"        "$OUT5" "Other body."

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
