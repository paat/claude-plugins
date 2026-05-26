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

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
