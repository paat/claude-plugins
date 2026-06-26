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

# --- Fixture: blank-line trimming (issue #92). A source with leading and
#     trailing blank lines around the body must render with those stripped, and
#     no "Broken pipe" must reach stderr from the SIGPIPE-safe trim helper. ------
REPO6="$TMP/trim"
mkdir -p "$REPO6/.agent-sync" "$REPO6/.claude/rules"

# Leading + trailing blank lines (and interior blanks that must be preserved).
printf '# Trimmed\n\n\n## First\nalpha\n\n\nbeta\n\n\n' > "$REPO6/.claude/rules/trim.md"

cat > "$REPO6/.agent-sync/sources.json" <<'JSON'
{"version":2,"files":{"t":".claude/rules/trim.md"},"outputs":[{"path":"AGENTS.md","sections":[{"id":"t","title":"Trimmed","source":"t","type":"full-body"}]}]}
JSON

TRIM_ERR="$REPO6/stderr.log"
bash "$GEN" --config "$REPO6/.agent-sync/sources.json" --root "$REPO6" >/dev/null 2>"$TRIM_ERR"
OUT6="$REPO6/AGENTS.md"

assert_line   "trim: body content present"            "$OUT6" "alpha"
assert_line   "trim: interior blank preserved"        "$OUT6" "beta"
assert_absent "trim: no broken pipe on stderr"        "$TRIM_ERR" "Broken pipe"
# The source's trailing triple-blank after "beta" must be stripped: without the
# trim, those would leak as a run of 3+ blank lines before the footer. Interior
# double-blanks (alpha .. beta) are preserved, so a max run of 2 is expected.
max_run="$(awk '/^[[:space:]]*$/{r++; if(r>m)m=r; next} {r=0} END{print m+0}' "$OUT6")"
if [[ "$max_run" -le 2 ]]; then
  echo "PASS: trim: trailing blank lines stripped (max blank run=$max_run)"; PASS=$((PASS+1))
else
  echo "FAIL: trim: trailing blank lines stripped — max blank run=$max_run (expected <=2)"; FAIL=$((FAIL+1))
  echo "----- actual $OUT6 -----"; cat "$OUT6"; echo "------------------------"
fi

# --- Fixture: --check prints a unified diff on drift (issue #92). After a
#     successful generate, mutate AGENTS.md and assert --check exits non-zero
#     AND emits a diff hunk naming the changed line. -----------------------------
DRIFT_ERR="$REPO6/check.log"
printf '\nMUTATED LINE\n' >> "$OUT6"
set +e
bash "$GEN" --config "$REPO6/.agent-sync/sources.json" --root "$REPO6" --check >/dev/null 2>"$DRIFT_ERR"
check_rc=$?
set -e 2>/dev/null || true

if [[ $check_rc -ne 0 ]]; then
  echo "PASS: check: drift exits non-zero"; PASS=$((PASS+1))
else
  echo "FAIL: check: drift exits non-zero — got rc=$check_rc"; FAIL=$((FAIL+1))
fi
assert_line   "check: drift message printed"   "$DRIFT_ERR" "[agent-sync] DRIFT: AGENTS.md is out of sync. Run: /agent-sync:generate"
if grep -q '^  @@' "$DRIFT_ERR" && grep -q 'MUTATED LINE' "$DRIFT_ERR"; then
  echo "PASS: check: unified diff names drifted line"; PASS=$((PASS+1))
else
  echo "FAIL: check: unified diff names drifted line"; FAIL=$((FAIL+1))
  echo "----- actual $DRIFT_ERR -----"; cat "$DRIFT_ERR"; echo "------------------------"
fi

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
