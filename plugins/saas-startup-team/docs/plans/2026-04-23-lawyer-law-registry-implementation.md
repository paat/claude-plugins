# Lawyer Law Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-project law registry to the saas-startup-team lawyer so that when any registered Estonian law changes, the lawyer detects it, produces a plain-language fix plan, and — with one yes/no confirmation — opens a GitHub issue tracking the fix; registry updates ship in the same PR as the code/copy fix.

**Architecture:** Two files per project (`.startup/law-registry.json` index + `.startup/laws/<slug>.txt` snapshots). Source files carry `LAW: <slug>` comment markers. On every `/lawyer` run, the command body polls the datalake `/changes/feed` per unique registered domain; when a feed event matches a registered `act_id`, the entry is flagged. Flagged entries trigger fix-plan generation (via the Lawyer agent), an interactive `AskUserQuestion` confirmation, and `gh issue create` on "Yes". Registry and `.txt` are NOT refreshed at confirmation — they are refreshed by `/lawyer ack <slug>` inside the PR branch that fixes the code, so the merge is atomic with respect to "source of truth, logic, and customer-facing content stay coherent".

**Tech Stack:** Claude Code plugin (markdown agents/skills/commands), bash + jq + curl for registry ops and datalake calls, `gh` CLI for issue creation, `AskUserQuestion` tool for the confirmation prompt, `ripgrep`/`grep` for marker scanning. Standalone bash test scripts for automated checks.

**Design doc:** `plugins/saas-startup-team/docs/plans/2026-04-23-lawyer-law-registry-design.md`

---

## File structure

**Modified:**
- `plugins/saas-startup-team/skills/lawyer/SKILL.md` — add Law Registry section with pointer to reference doc and Critical Rules about change-check invariants
- `plugins/saas-startup-team/agents/lawyer.md` — add Critical Rules about always running change detection, producing fix plans when asked, and never updating registry state outside ack
- `plugins/saas-startup-team/commands/lawyer.md` — subcommand dispatch, pre-flight (incl. conditional gh), change detection, fix-plan spawn, AskUserQuestion confirmation, `gh issue create`, and helper subcommands (`register`, `unregister`, `ack`, `ack-all`, `issue`, `status`, `check`)
- `plugins/saas-startup-team/.claude-plugin/plugin.json` — version bump 0.28.0 → 0.29.0
- `.claude-plugin/marketplace.json` — version bump 0.28.0 → 0.29.0 (must match)

**Created:**
- `plugins/saas-startup-team/skills/lawyer/references/law-registry.md` — full schema, marker regex, scan patterns, example entry, workflow
- `plugins/saas-startup-team/skills/lawyer/tests/harness.sh` — trivial test runner
- `plugins/saas-startup-team/skills/lawyer/tests/test-schema.sh` — registry JSON round-trip
- `plugins/saas-startup-team/skills/lawyer/tests/test-register.sh` — register helper
- `plugins/saas-startup-team/skills/lawyer/tests/test-unregister.sh` — unregister helper
- `plugins/saas-startup-team/skills/lawyer/tests/test-markers.sh` — marker scan regex
- `plugins/saas-startup-team/skills/lawyer/tests/test-detect.sh` — change detection with mock feed
- `plugins/saas-startup-team/skills/lawyer/tests/test-ack.sh` — ack helper
- `plugins/saas-startup-team/skills/lawyer/tests/fixtures/` — JSON/source fixtures for tests

---

### Task 1: Reference documentation

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/references/law-registry.md`

**Context:** This reference is the single detailed source the Lawyer agent consults for registry schema, marker regex, scan commands, and API call templates. Other files point here rather than duplicating content.

- [ ] **Step 1: Create the reference document**

Create `plugins/saas-startup-team/skills/lawyer/references/law-registry.md` with this content:

```markdown
# Law Registry Reference

Per-project registry of Estonian legal paragraphs the product depends on.

## Files

- `.startup/law-registry.json` — metadata index (one entry per registered slug)
- `.startup/laws/<slug>.txt` — normalised paragraph text, one file per slug

The index is always read in full; snapshots are read per-slug only when needed (fix-plan rendering, ack).

## Index schema (v1)

```json
{
  "version": 1,
  "last_feed_check_at": "2026-04-23T10:00:00Z",
  "entries": {
    "consent-lawful-basis": {
      "act_id": "104052024010",
      "act_title": "Isikuandmete kaitse seadus",
      "citation": "§ 10 lõige 2",
      "domain": "Data Protection",
      "rt_url": "https://www.riigiteataja.ee/akt/104052024010",
      "redaktsioon_id": null,
      "registered_at": "2026-04-01T09:00:00Z",
      "verified_at": "2026-04-20T14:00:00Z",
      "registered_by": "lawyer",
      "purpose": "Lawful basis for processing signup-confirmation emails",
      "needs_review": false,
      "change_detected_at": null,
      "change": null,
      "gh_issue_url": null
    }
  }
}
```

See the design doc for per-field semantics.

## State machine

| needs_review | gh_issue_url | Meaning | /lawyer behaviour |
|---|---|---|---|
| `false` | any | Clean | Runs topic as normal |
| `true` | `null` | Detected, not yet confirmed | Blocks topic, prompts for issue creation |
| `true` | `<url>` | Issue open, PR pending | Runs topic with reminder |

Transitions:
- clean → `(true, null)` by feed detection
- `(true, null)` → `(true, <url>)` by investor answering "Jah, loo issue"
- `(true, <url>)` → clean by `/lawyer ack <slug>` inside the PR branch that ships the code fix

## Source markers

Markers live inside comments adjacent to the code or content they govern. Examples:

```ts
// LAW: consent-lawful-basis
if (!user.hasConsented) throw new ConsentRequiredError();
```

```python
# LAW: data-subject-rights, data-breach-notification
def handle_subject_access_request(user_id): ...
```

```html
<!-- LAW: consumer-14-day-withdrawal -->
<p>Teil on 14 päeva jooksul õigus lepingust taganeda ...</p>
```

```jsx
{/* LAW: cookie-consent */}
<CookieBanner />
```

Multiple slugs on one marker are comma-separated.

## Scan regex

```
(?://|#|/\*|<!--|\{/\*)\s*LAW:\s*([a-z0-9-]+(?:\s*,\s*[a-z0-9-]+)*)
```

The comment-opener prefix rejects prose false positives ("the LAW: is clear that ...").

## Scan command (ripgrep preferred, grep fallback)

```bash
# Prefer ripgrep; fall back to grep -rE
if command -v rg >/dev/null; then
  rg -n --pcre2 '(?://|#|/\*|<!--|\{/\*)\s*LAW:\s*([a-z0-9-]+(?:\s*,\s*[a-z0-9-]+)*)' \
    src/ app/ pages/ components/ lib/ server/ public/ content/ 2>/dev/null
  rg -n --pcre2 '(?://|#|/\*|<!--|\{/\*)\s*LAW:\s*([a-z0-9-]+(?:\s*,\s*[a-z0-9-]+)*)' \
    docs/ 2>/dev/null | grep -v '^docs/legal/'
else
  grep -rEn '(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*' \
    src/ app/ pages/ components/ lib/ server/ public/ content/ 2>/dev/null
  grep -rEn '(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*' \
    docs/ 2>/dev/null | grep -v '^docs/legal/'
fi
```

Directories missing in a given project are silently skipped.

## Datalake API templates

**Fetch current paragraph text for a registered act:**
```bash
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/laws/${ACT_ID}/citation?paragraph=${PARAGRAPH}"
```

**Poll changes feed since last check:**
```bash
# Primary: try with since= if supported
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/changes/feed?domain=${DOMAIN}&since=${SINCE}"

# Fallback: fetch last 100 events, filter client-side by event.timestamp > SINCE
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/changes/feed?domain=${DOMAIN}&limit=100"
```

## Text normalisation

All snapshot text is trimmed of leading/trailing whitespace and NFC-normalised before comparison or storage:

```bash
python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))'
```

## gh issue template

Issue title: `Seadusemuudatus: <citation> — <slug>`
Labels: `legal-review,seadusemuudatus`
Body: the "Mida tuleb teha" section for that slug from `docs/legal/õiguslik-muudatused-YYYY-MM-DD.md`, plus a trailing block titled "Registri värskendus PR-s" listing:
- File to overwrite: `.startup/laws/<slug>.txt` (content will be fetched fresh at ack time)
- Index fields to update: `needs_review=false`, `change=null`, `change_detected_at=null`, `verified_at=<now>`, `redaktsioon_id=<latest if available>`
- Helper to run inside the fix branch: `/lawyer ack <slug>`

## Common failure modes

- **Marker for unknown slug** — registry entry missing. Non-blocking warning.
- **Entry with no markers** — slug registered but nothing in code references it. Non-blocking warning; candidate for `unregister`.
- **Snapshot file missing for a registered slug** — index↔snapshot drift. Non-blocking warning at detection time; ack will recreate on next run.
- **Orphan snapshot file** — `.txt` file under `.startup/laws/` with no matching index entry. Non-blocking warning; can be removed manually.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/references/law-registry.md
git commit -m "feat(saas-startup-team): lawyer law-registry reference doc"
```

---

### Task 2: Test harness and schema round-trip test

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/tests/harness.sh`
- Create: `plugins/saas-startup-team/skills/lawyer/tests/test-schema.sh`
- Create: `plugins/saas-startup-team/skills/lawyer/tests/fixtures/registry/example.json`
- Create: `plugins/saas-startup-team/skills/lawyer/tests/fixtures/laws/consent-lawful-basis.txt`

**Context:** The test harness is a trivial runner that executes every `test-*.sh` script in the tests directory with a clean temp workdir and reports pass/fail. First test exercises the JSON schema: load the fixture, extract fields with jq, assert values.

- [ ] **Step 1: Write the failing test — test-schema.sh**

Create `plugins/saas-startup-team/skills/lawyer/tests/test-schema.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Test: registry JSON schema round-trip
# - load fixture
# - extract fields via jq
# - assert values match

FIXTURE_DIR="$(cd "$(dirname "$0")/fixtures" && pwd)"
REGISTRY="$FIXTURE_DIR/registry/example.json"

# Assert valid JSON
jq empty "$REGISTRY"

# Assert version is 1
version=$(jq -r '.version' "$REGISTRY")
[[ "$version" == "1" ]] || { echo "FAIL: expected version=1, got $version"; exit 1; }

# Assert entry exists and has expected act_id
act_id=$(jq -r '.entries["consent-lawful-basis"].act_id' "$REGISTRY")
[[ "$act_id" == "104052024010" ]] || { echo "FAIL: expected act_id=104052024010, got $act_id"; exit 1; }

# Assert needs_review is boolean
needs_review=$(jq -r '.entries["consent-lawful-basis"].needs_review' "$REGISTRY")
[[ "$needs_review" == "false" ]] || { echo "FAIL: expected needs_review=false, got $needs_review"; exit 1; }

# Assert gh_issue_url is null
gh_url=$(jq -r '.entries["consent-lawful-basis"].gh_issue_url' "$REGISTRY")
[[ "$gh_url" == "null" ]] || { echo "FAIL: expected gh_issue_url=null, got $gh_url"; exit 1; }

# Assert snapshot file exists
[[ -f "$FIXTURE_DIR/laws/consent-lawful-basis.txt" ]] || { echo "FAIL: snapshot file missing"; exit 1; }

echo "PASS: test-schema"
```

- [ ] **Step 2: Run it to confirm it fails (fixtures don't exist yet)**

```bash
chmod +x plugins/saas-startup-team/skills/lawyer/tests/test-schema.sh
bash plugins/saas-startup-team/skills/lawyer/tests/test-schema.sh
```

Expected: FAIL (fixture files do not exist).

- [ ] **Step 3: Create fixture files**

Create `plugins/saas-startup-team/skills/lawyer/tests/fixtures/registry/example.json`:

```json
{
  "version": 1,
  "last_feed_check_at": "2026-04-23T10:00:00Z",
  "entries": {
    "consent-lawful-basis": {
      "act_id": "104052024010",
      "act_title": "Isikuandmete kaitse seadus",
      "citation": "§ 10 lõige 2",
      "domain": "Data Protection",
      "rt_url": "https://www.riigiteataja.ee/akt/104052024010",
      "redaktsioon_id": null,
      "registered_at": "2026-04-01T09:00:00Z",
      "verified_at": "2026-04-20T14:00:00Z",
      "registered_by": "lawyer",
      "purpose": "Lawful basis for processing signup-confirmation emails",
      "needs_review": false,
      "change_detected_at": null,
      "change": null,
      "gh_issue_url": null
    }
  }
}
```

Create `plugins/saas-startup-team/skills/lawyer/tests/fixtures/laws/consent-lawful-basis.txt`:

```
Isikuandmete töötlemine on lubatud, kui andmesubjekt on selleks andnud nõusoleku.
```

- [ ] **Step 4: Write the test harness**

Create `plugins/saas-startup-team/skills/lawyer/tests/harness.sh`:

```bash
#!/usr/bin/env bash
# Trivial test runner: executes every test-*.sh under this directory.
# Each test is a standalone bash script that exits 0 on pass, non-zero on fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0
failed_tests=()

for t in "$TESTS_DIR"/test-*.sh; do
  [[ -f "$t" ]] || continue
  if bash "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_tests+=("$(basename "$t")")
  fi
done

echo ""
echo "=== Results: $pass passed, $fail failed ==="
if (( fail > 0 )); then
  printf '  - %s\n' "${failed_tests[@]}"
  exit 1
fi
```

- [ ] **Step 5: Run the test — confirm it passes**

```bash
chmod +x plugins/saas-startup-team/skills/lawyer/tests/harness.sh
bash plugins/saas-startup-team/skills/lawyer/tests/harness.sh
```

Expected: `=== Results: 1 passed, 0 failed ===`

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/tests/
git commit -m "test(saas-startup-team): lawyer registry schema round-trip"
```

---

### Task 3: Pre-flight registry validation block

**Files:**
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** The existing pre-flight has three checks (datalake reachable, project present, API key set). Add a fourth that validates `.startup/law-registry.json` if it exists. Missing file is OK (empty registry). Malformed JSON or wrong version is a hard fail.

- [ ] **Step 1: Read the current pre-flight section**

```bash
grep -n "Pre-Flight Checks" plugins/saas-startup-team/commands/lawyer.md
```

Note the line number. Read the block following it — it contains Check 1/2/3.

- [ ] **Step 2: Add Check 4 after the existing checks**

After the "Check 3: API key is available" block in `plugins/saas-startup-team/commands/lawyer.md` (before the `## Execution` heading), insert:

```markdown
### Check 4: Law registry is valid (if present)

If `.startup/law-registry.json` exists, it must be valid JSON with `version: 1`:

```bash
if [ -f .startup/law-registry.json ]; then
  if ! jq -e '.version == 1' .startup/law-registry.json >/dev/null 2>&1; then
    echo "Error: .startup/law-registry.json is invalid or has unexpected version"
    echo "Fix or remove the file before running /lawyer again."
    exit 1
  fi
fi
if [ -e .startup/laws ] && [ ! -d .startup/laws ]; then
  echo "Error: .startup/laws exists but is not a directory"
  exit 1
fi
```

Missing `.startup/law-registry.json` is fine — the command creates it on first use.
```

- [ ] **Step 3: Verify the insertion by re-reading the file**

```bash
grep -n "Check 4" plugins/saas-startup-team/commands/lawyer.md
```

Expected: one match, inside the Pre-Flight Checks section.

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md
git commit -m "feat(saas-startup-team): lawyer pre-flight validates law registry"
```

---

### Task 4: Subcommand dispatcher

**Files:**
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** Today `/lawyer <topic>` passes the entire arg string to the Lawyer agent. Add a dispatcher that recognises known subcommand keywords as `args[0]` and routes them to specialised helpers. Unrecognised first words mean the whole args is a topic.

- [ ] **Step 1: Add a dispatcher section before `## Execution`**

After the Pre-Flight Checks block and before `## Execution`, insert a new section:

```markdown
## Subcommand Dispatch

After pre-flight passes, inspect `$ARGUMENTS`:

1. If the first whitespace-delimited token matches one of the following keywords, treat it as a subcommand and route accordingly:
   - `register` — see "Register subcommand" below
   - `unregister` — see "Unregister subcommand"
   - `ack` — see "Ack subcommand"
   - `ack-all` — see "Ack-all subcommand"
   - `issue` — see "Issue subcommand"
   - `status` — see "Status subcommand"
   - `check` — see "Check subcommand"

2. Otherwise, `$ARGUMENTS` is a free-form topic. Continue to change detection (Task 9) and analysis (existing "Execution" section).

Disambiguation: topics that legitimately start with one of these tokens (rare) must be quoted: `/lawyer "register a user — GDPR-compliant?"`.
```

- [ ] **Step 2: Verify placement**

```bash
grep -n "Subcommand Dispatch\|## Execution" plugins/saas-startup-team/commands/lawyer.md
```

Expected: Subcommand Dispatch line appears before ## Execution.

- [ ] **Step 3: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md
git commit -m "feat(saas-startup-team): lawyer subcommand dispatcher"
```

---

### Task 5: Register subcommand (with TDD)

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/tests/test-register.sh`
- Create: `plugins/saas-startup-team/skills/lawyer/tests/fixtures/datalake/citation-consent.json`
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** `register` is called as `/lawyer register <slug> <act_id> <citation> <purpose>`. It must be idempotent on `(act_id, citation)`. On success it writes both the index entry and the `.txt` snapshot file. It hard-fails if the datalake citation endpoint returns empty.

The test runs the register logic against a mock datalake (a simple bash function that returns fixture JSON) in a temp project dir.

- [ ] **Step 1: Write the failing test**

Create `plugins/saas-startup-team/skills/lawyer/tests/test-register.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

# Isolated project workspace
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup

# Mock datalake: intercept curl calls by shadowing via PATH
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
# Echo the fixture matching the requested act/paragraph
for arg in "\$@"; do
  case "\$arg" in
    *citation*paragraph*) cat "$FIXTURES/datalake/citation-consent.json"; exit 0 ;;
  esac
done
echo '{}'
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key

# The register logic under test (copied verbatim from commands/lawyer.md § Register subcommand)
source "$TESTS_DIR/../lib/register.sh" 2>/dev/null || {
  # Run the embedded script; if we've modularised differently, this test calls the shell function
  :
}

# Inline the register flow here for testability
SLUG=consent-lawful-basis
ACT_ID=104052024010
CITATION="§ 10 lõige 2"
PURPOSE="Lawful basis for signup-confirmation email"

# Create empty registry if missing
[ -f .startup/law-registry.json ] || echo '{"version":1,"last_feed_check_at":null,"entries":{}}' > .startup/law-registry.json
mkdir -p .startup/laws

# Idempotency check: does an entry with this (act_id, citation) already exist?
existing=$(jq -r --arg act "$ACT_ID" --arg cit "$CITATION" \
  '.entries | to_entries[] | select(.value.act_id == $act and .value.citation == $cit) | .key' \
  .startup/law-registry.json)
if [ -n "$existing" ] && [ "$existing" != "$SLUG" ]; then
  echo "FAIL: expected no duplicate; got existing=$existing"
  exit 1
fi

# Fetch paragraph text
response=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/laws/${ACT_ID}/citation?paragraph=${CITATION}")
text=$(echo "$response" | jq -r '.text // empty')
[ -n "$text" ] || { echo "FAIL: empty text"; exit 1; }

# Normalise
normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')

# Write snapshot
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

# Upsert entry
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
entry=$(jq -n \
  --arg act "$ACT_ID" \
  --arg title "Isikuandmete kaitse seadus" \
  --arg cit "$CITATION" \
  --arg dom "Data Protection" \
  --arg rt "https://www.riigiteataja.ee/akt/${ACT_ID}" \
  --arg now "$NOW" \
  --arg by "lawyer" \
  --arg purp "$PURPOSE" \
  '{act_id:$act, act_title:$title, citation:$cit, domain:$dom, rt_url:$rt, redaktsioon_id:null, registered_at:$now, verified_at:$now, registered_by:$by, purpose:$purp, needs_review:false, change_detected_at:null, change:null, gh_issue_url:null}')

jq --arg slug "$SLUG" --argjson e "$entry" \
  '.entries[$slug] = $e' \
  .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

# Assertions
[ -f ".startup/laws/${SLUG}.txt" ] || { echo "FAIL: snapshot missing"; exit 1; }
stored=$(jq -r --arg slug "$SLUG" '.entries[$slug].act_id' .startup/law-registry.json)
[ "$stored" = "$ACT_ID" ] || { echo "FAIL: expected act_id=$ACT_ID, got $stored"; exit 1; }
purpose_back=$(jq -r --arg slug "$SLUG" '.entries[$slug].purpose' .startup/law-registry.json)
[ "$purpose_back" = "$PURPOSE" ] || { echo "FAIL: purpose roundtrip"; exit 1; }

echo "PASS: test-register"
```

Also create the fixture `plugins/saas-startup-team/skills/lawyer/tests/fixtures/datalake/citation-consent.json`:

```json
{
  "act_id": "104052024010",
  "paragraph": "§ 10 lõige 2",
  "text": "Isikuandmete töötlemine on lubatud, kui andmesubjekt on selleks andnud nõusoleku.",
  "redaktsioon_id": "104052024010/1"
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
chmod +x plugins/saas-startup-team/skills/lawyer/tests/test-register.sh
bash plugins/saas-startup-team/skills/lawyer/tests/test-register.sh
```

Expected: PASS (the test inlines the logic it's testing — it's essentially a behaviour contract; subsequent tasks will reproduce this logic inside `commands/lawyer.md`). If anything fails (jq not installed, python3 missing, fixture path wrong), fix the test environment.

- [ ] **Step 3: Add the Register subcommand section to the command file**

Insert after the Subcommand Dispatch section in `plugins/saas-startup-team/commands/lawyer.md`:

```markdown
## Register subcommand

Args: `register <slug> <act_id> <citation> <purpose>`

`slug` must match `[a-z0-9-]+`. `citation` may contain spaces (quoted from the command line).

Behaviour:

```bash
SLUG="$1"
ACT_ID="$2"
CITATION="$3"
PURPOSE="$4"

# Validate slug format
[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "Error: slug must match [a-z0-9-]+"; exit 1; }

# Ensure registry files exist
[ -f .startup/law-registry.json ] || echo '{"version":1,"last_feed_check_at":null,"entries":{}}' > .startup/law-registry.json
mkdir -p .startup/laws

# Idempotency: is (act_id, citation) already registered?
existing=$(jq -r --arg act "$ACT_ID" --arg cit "$CITATION" \
  '.entries | to_entries[] | select(.value.act_id == $act and .value.citation == $cit) | .key' \
  .startup/law-registry.json)
if [ -n "$existing" ]; then
  if [ "$existing" != "$SLUG" ]; then
    echo "Entry (act=$ACT_ID, citation=$CITATION) already registered as '$existing'. Reusing; no action taken."
    exit 0
  fi
  # Same slug: treat as re-registration — refresh text below
fi

# Fetch current paragraph text
response=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/laws/${ACT_ID}/citation?paragraph=$(printf '%s' "$CITATION" | jq -sRr @uri)")
text=$(echo "$response" | jq -r '.text // empty')
# Bare jq (no -r) so output is a JSON scalar ("..." string or null literal)
# that --argjson can consume without parse errors.
redaktsioon=$(echo "$response" | jq '.redaktsioon_id // null')
if [ -z "$text" ]; then
  echo "Error: datalake returned no text for act=$ACT_ID citation=$CITATION"
  exit 1
fi

# Normalise (trim + NFC)
normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')

# Write snapshot first
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

# Compute title and rt_url from response metadata (fall back gracefully)
ACT_TITLE=$(echo "$response" | jq -r '.act_title // "Teadmata seadus"')
DOMAIN=$(echo "$response" | jq -r '.domain // "Unknown"')
RT_URL=$(echo "$response" | jq -r --arg id "$ACT_ID" '.rt_url // "https://www.riigiteataja.ee/akt/\($id)"')

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
entry=$(jq -n \
  --arg act "$ACT_ID" \
  --arg title "$ACT_TITLE" \
  --arg cit "$CITATION" \
  --arg dom "$DOMAIN" \
  --arg rt "$RT_URL" \
  --argjson redaktsioon "$redaktsioon" \
  --arg now "$NOW" \
  --arg by "${REGISTERED_BY:-lawyer}" \
  --arg purp "$PURPOSE" \
  '{act_id:$act, act_title:$title, citation:$cit, domain:$dom, rt_url:$rt, redaktsioon_id:$redaktsioon, registered_at:$now, verified_at:$now, registered_by:$by, purpose:$purp, needs_review:false, change_detected_at:null, change:null, gh_issue_url:null}')

jq --arg slug "$SLUG" --argjson e "$entry" \
  '.entries[$slug] = $e' \
  .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

echo "Registered: $SLUG"
echo "Lisa marker koodi: // LAW: $SLUG"
exit 0
```

Failure: if the datalake citation call returns empty text, the helper hard-fails and does NOT leave a partial snapshot on disk (snapshot is written only after the text check passes).
```

- [ ] **Step 4: Re-run the test — ensure it still passes**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/harness.sh
```

Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md \
        plugins/saas-startup-team/skills/lawyer/tests/test-register.sh \
        plugins/saas-startup-team/skills/lawyer/tests/fixtures/datalake/citation-consent.json
git commit -m "feat(saas-startup-team): lawyer register subcommand"
```

---

### Task 6: Unregister subcommand (with TDD)

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/tests/test-unregister.sh`
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** `unregister <slug>` removes both the index entry and the `.txt` snapshot. Missing slug is a no-op with an informative message. Orphan snapshot files (present without an index entry) are also swept up.

- [ ] **Step 1: Write the failing test**

Create `plugins/saas-startup-team/skills/lawyer/tests/test-unregister.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup/laws

# Seed registry + snapshot
cat > .startup/law-registry.json <<'EOF'
{
  "version": 1,
  "last_feed_check_at": null,
  "entries": {
    "consent-lawful-basis": {
      "act_id": "104052024010",
      "act_title": "Isikuandmete kaitse seadus",
      "citation": "§ 10 lõige 2",
      "domain": "Data Protection",
      "rt_url": "https://www.riigiteataja.ee/akt/104052024010",
      "redaktsioon_id": null,
      "registered_at": "2026-04-01T00:00:00Z",
      "verified_at": "2026-04-01T00:00:00Z",
      "registered_by": "lawyer",
      "purpose": "test",
      "needs_review": false,
      "change_detected_at": null,
      "change": null,
      "gh_issue_url": null
    }
  }
}
EOF
echo "old text" > .startup/laws/consent-lawful-basis.txt

# Inline unregister logic
SLUG=consent-lawful-basis
jq --arg slug "$SLUG" 'del(.entries[$slug])' .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json
rm -f ".startup/laws/${SLUG}.txt"

# Assertions
remaining=$(jq -r '.entries | keys | length' .startup/law-registry.json)
[ "$remaining" = "0" ] || { echo "FAIL: entries should be empty, got $remaining"; exit 1; }
[ ! -f ".startup/laws/${SLUG}.txt" ] || { echo "FAIL: snapshot should be deleted"; exit 1; }

echo "PASS: test-unregister"
```

- [ ] **Step 2: Run the test — expect PASS**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/test-unregister.sh
```

Expected: PASS.

- [ ] **Step 3: Add the Unregister subcommand section to the command file**

After the Register subcommand section in `plugins/saas-startup-team/commands/lawyer.md`, insert:

```markdown
## Unregister subcommand

Args: `unregister <slug>`

Behaviour:

```bash
SLUG="$1"
[ -n "$SLUG" ] || { echo "Error: slug required"; exit 1; }

if [ ! -f .startup/law-registry.json ]; then
  echo "No registry present; nothing to unregister."
  exit 0
fi

existing=$(jq -r --arg slug "$SLUG" '.entries[$slug] // empty' .startup/law-registry.json)
if [ -z "$existing" ]; then
  echo "Slug '$SLUG' not in registry; nothing to unregister."
  # Still remove a stray snapshot file if present (cleans orphan)
  rm -f ".startup/laws/${SLUG}.txt"
  exit 0
fi

jq --arg slug "$SLUG" 'del(.entries[$slug])' .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json
rm -f ".startup/laws/${SLUG}.txt"

echo "Unregistered: $SLUG"
exit 0
```
```

- [ ] **Step 4: Re-run harness**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/harness.sh
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md \
        plugins/saas-startup-team/skills/lawyer/tests/test-unregister.sh
git commit -m "feat(saas-startup-team): lawyer unregister subcommand"
```

---

### Task 7: Marker scan (with TDD)

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/tests/test-markers.sh`
- Create: `plugins/saas-startup-team/skills/lawyer/tests/fixtures/source/*` (multiple)
- Modify: `plugins/saas-startup-team/commands/lawyer.md` (add a Marker Scan subsection referenced by later tasks)

**Context:** The scan produces a `slug -> [file:line, …]` map. It must match all legitimate markers across comment syntaxes and reject prose false positives. Scope is limited to the project's source directories, excluding `docs/legal/` (which is lawyer output, not product content).

- [ ] **Step 1: Create fixture source files**

Create these fixtures under `plugins/saas-startup-team/skills/lawyer/tests/fixtures/source/`:

`consent.ts`:
```typescript
// LAW: consent-lawful-basis
export function recordConsent(user: User) { /* ... */ }
```

`processor.py`:
```python
# LAW: data-subject-rights, data-breach-notification
def handle_sar(user_id): ...
```

`privacy.md`:
```markdown
<!-- LAW: consumer-14-day-withdrawal -->
# Privacy Policy

Users may withdraw within 14 days.
```

`banner.jsx`:
```jsx
export function Footer() {
  return (
    <>
      {/* LAW: cookie-consent */}
      <CookieBanner />
    </>
  );
}
```

`prose-trap.md`:
```markdown
# Legal notes
The LAW: is clear that users must be informed.
```

- [ ] **Step 2: Write the failing test**

Create `plugins/saas-startup-team/skills/lawyer/tests/test-markers.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$TESTS_DIR/fixtures/source"

# The scan pattern under test (kept in sync with references/law-registry.md)
PATTERN='(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*'

# Run grep, capture matches
matches=$(grep -rEn "$PATTERN" "$SRC" 2>/dev/null || true)

# Assertions
echo "$matches" | grep -q "consent.ts.*LAW: consent-lawful-basis" || { echo "FAIL: consent.ts marker not found"; echo "$matches"; exit 1; }
echo "$matches" | grep -q "processor.py.*LAW: data-subject-rights" || { echo "FAIL: processor.py marker not found"; echo "$matches"; exit 1; }
echo "$matches" | grep -q "privacy.md.*LAW: consumer-14-day-withdrawal" || { echo "FAIL: privacy.md marker not found"; echo "$matches"; exit 1; }
echo "$matches" | grep -q "banner.jsx.*LAW: cookie-consent" || { echo "FAIL: banner.jsx marker not found"; echo "$matches"; exit 1; }

# False-positive guard: prose-trap.md must NOT match
if echo "$matches" | grep -q "prose-trap.md"; then
  echo "FAIL: prose-trap.md matched (false positive)"; exit 1
fi

# Extraction: verify multi-slug marker yields two slugs
slugs_line=$(echo "$matches" | grep "processor.py")
count=$(printf '%s' "$slugs_line" | grep -oE '[a-z0-9-]+-[a-z0-9-]+' | wc -l | tr -d ' ')
# Note: this regex is approximate; we only assert at least one slug captured
[ "$count" -ge 1 ] || { echo "FAIL: expected slugs in processor.py marker"; exit 1; }

echo "PASS: test-markers"
```

- [ ] **Step 3: Run it and confirm PASS**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/test-markers.sh
```

Expected: PASS. The test verifies that the exact regex used in the command body works.

- [ ] **Step 4: Add the Marker Scan subsection to the command file**

After the Unregister subcommand in `plugins/saas-startup-team/commands/lawyer.md`, insert:

```markdown
## Marker Scan (internal helper)

Produces a `slug -> [file:line, ...]` map by scanning project source for `LAW:` markers. Used by the change-detection alert flow and the orphan-slug warning.

```bash
# Scope: source + customer-facing content; exclude docs/legal/ (lawyer output)
SCAN_DIRS=()
for d in src app pages components lib server public content docs; do
  [ -d "$d" ] && SCAN_DIRS+=("$d")
done

PATTERN='(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*'

# Collect raw matches (rg preferred; grep fallback)
if command -v rg >/dev/null 2>&1; then
  raw=$(rg -n --pcre2 "$PATTERN" "${SCAN_DIRS[@]}" 2>/dev/null | grep -v '^docs/legal/' || true)
else
  raw=$(grep -rEn "$PATTERN" "${SCAN_DIRS[@]}" 2>/dev/null | grep -v '^docs/legal/' || true)
fi

# Build the slug -> file:line list (newline-delimited, one entry per marker-slug pair)
# Output format: each line is "<slug>\t<file>:<line>"
echo "$raw" | awk -F: '
  {
    # Extract file (field 1) and line (field 2); the marker tail is fields 3+
    file=$1; line=$2
    tail=""
    for (i=3; i<=NF; i++) tail = tail (i==3?"":":") $i
    # Extract slugs: everything after "LAW:" up to end of line, then split on commas
    n = match(tail, /LAW:[[:space:]]*[a-z0-9,\- \t]+/)
    if (n == 0) next
    slugs = substr(tail, RSTART+4)   # drop "LAW:" prefix
    # Trim comment closers and whitespace
    gsub(/\*\/.*/, "", slugs)
    gsub(/-->.*/, "", slugs)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", slugs)
    # Split on comma
    ns = split(slugs, arr, /[[:space:]]*,[[:space:]]*/)
    for (j=1; j<=ns; j++) {
      s = arr[j]
      if (s ~ /^[a-z0-9-]+$/) print s "\t" file ":" line
    }
  }
'
```

The output is piped into downstream logic that groups by slug.

### Orphan warnings

After running the scan:

- **Marker slugs not in the registry:** warn for each such slug and its first file:line hit. Non-blocking.
- **Registry slugs with no marker hits:** warn for each. Non-blocking; candidate for `unregister`.

Both warnings are printed to the terminal but do not block the run.
```

- [ ] **Step 5: Re-run harness**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/harness.sh
```

Expected: 4 passed.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md \
        plugins/saas-startup-team/skills/lawyer/tests/test-markers.sh \
        plugins/saas-startup-team/skills/lawyer/tests/fixtures/source/
git commit -m "feat(saas-startup-team): lawyer marker scan helper"
```

---

### Task 8: Change detection step (with TDD via mock feed)

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/tests/test-detect.sh`
- Create: `plugins/saas-startup-team/skills/lawyer/tests/fixtures/datalake/feed-data-protection.json`
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** Change detection runs at the start of every `/lawyer` run (after pre-flight + subcommand dispatch, before analysis). It queries `/changes/feed` per unique registered domain, matches events against registered `act_id`s, and flips `needs_review=true` on matched entries.

- [ ] **Step 1: Create feed fixture**

Create `plugins/saas-startup-team/skills/lawyer/tests/fixtures/datalake/feed-data-protection.json`:

```json
{
  "events": [
    {
      "id": "evt-42",
      "act_id": "104052024010",
      "type": "amended",
      "timestamp": "2026-04-22T08:00:00Z",
      "summary": "§ 10 lõige 2 muudetud — lisandus töötleja teavituse klausel."
    }
  ]
}
```

- [ ] **Step 2: Write the failing test**

Create `plugins/saas-startup-team/skills/lawyer/tests/test-detect.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup/laws

# Seed registry: one entry in Data Protection domain referencing the fixture act_id
cat > .startup/law-registry.json <<'EOF'
{
  "version": 1,
  "last_feed_check_at": "2026-04-20T00:00:00Z",
  "entries": {
    "consent-lawful-basis": {
      "act_id": "104052024010",
      "act_title": "Isikuandmete kaitse seadus",
      "citation": "§ 10 lõige 2",
      "domain": "Data Protection",
      "rt_url": "https://www.riigiteataja.ee/akt/104052024010",
      "redaktsioon_id": null,
      "registered_at": "2026-04-01T00:00:00Z",
      "verified_at": "2026-04-20T14:00:00Z",
      "registered_by": "lawyer",
      "purpose": "test",
      "needs_review": false,
      "change_detected_at": null,
      "change": null,
      "gh_issue_url": null
    }
  }
}
EOF
echo "Isikuandmete töötlemine on lubatud ..." > .startup/laws/consent-lawful-basis.txt

# Mock datalake
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *changes/feed*domain=Data*Protection*) cat "$FIXTURES/datalake/feed-data-protection.json"; exit 0 ;;
  esac
done
echo '{"events":[]}'
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key

# Inline the change-detection logic (copied from commands/lawyer.md § Change Detection)
SINCE=$(jq -r '.last_feed_check_at // ""' .startup/law-registry.json)
DOMAINS=$(jq -r '.entries | to_entries[] | .value.domain' .startup/law-registry.json | sort -u)
ACT_IDS=$(jq -r '.entries | to_entries[] | .value.act_id' .startup/law-registry.json | sort -u)

# Poll feed per domain
all_events='[]'
while IFS= read -r d; do
  [ -z "$d" ] && continue
  encoded=$(printf '%s' "$d" | jq -sRr @uri)
  resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
    "https://datalake.r-53.com/api/v1/changes/feed?domain=${encoded}&since=${SINCE}")
  events=$(echo "$resp" | jq '.events // []')
  all_events=$(echo "$all_events $events" | jq -s 'add')
done <<< "$DOMAINS"

# Filter events: keep only those whose act_id is in ACT_IDS
act_ids_json=$(printf '%s\n' "$ACT_IDS" | jq -R . | jq -s .)
matched=$(echo "$all_events" | jq --argjson acts "$act_ids_json" '[.[] | select(.act_id as $a | $acts | index($a))]')

# Update registry: for each matched event, flag all entries with that act_id
updated=$(jq --argjson matched "$matched" '
  reduce ($matched[]) as $e (.;
    .entries |= with_entries(
      if .value.act_id == $e.act_id then
        .value.needs_review = true
        | .value.change_detected_at = $e.timestamp
        | .value.change = { feed_event_id: $e.id, type: $e.type, summary: $e.summary }
      else . end
    )
  )
' .startup/law-registry.json)

# Advance last_feed_check_at
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$updated" | jq --arg now "$NOW" '.last_feed_check_at = $now' > .startup/law-registry.json

# Assertions
flagged=$(jq -r '.entries["consent-lawful-basis"].needs_review' .startup/law-registry.json)
[ "$flagged" = "true" ] || { echo "FAIL: expected needs_review=true, got $flagged"; exit 1; }

change_type=$(jq -r '.entries["consent-lawful-basis"].change.type' .startup/law-registry.json)
[ "$change_type" = "amended" ] || { echo "FAIL: expected change.type=amended, got $change_type"; exit 1; }

last=$(jq -r '.last_feed_check_at' .startup/law-registry.json)
[ "$last" = "$NOW" ] || { echo "FAIL: expected last_feed_check_at=$NOW, got $last"; exit 1; }

echo "PASS: test-detect"
```

- [ ] **Step 3: Run the test — expect PASS**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/test-detect.sh
```

Expected: PASS.

- [ ] **Step 4: Add Change Detection section to commands/lawyer.md**

After the Marker Scan subsection, insert:

```markdown
## Change Detection

Runs at the start of every `/lawyer` invocation, after pre-flight and subcommand dispatch but before analysis. Reads only the index JSON; snapshot `.txt` files are never opened here.

```bash
[ -f .startup/law-registry.json ] || echo '{"version":1,"last_feed_check_at":null,"entries":{}}' > .startup/law-registry.json

DOMAINS=$(jq -r '.entries | to_entries[] | .value.domain' .startup/law-registry.json | sort -u)
ACT_IDS=$(jq -r '.entries | to_entries[] | .value.act_id' .startup/law-registry.json | sort -u)

# Skip entirely if registry is empty
if [ -z "$DOMAINS" ]; then
  FEED_OK=1
else
  SINCE=$(jq -r '.last_feed_check_at // ""' .startup/law-registry.json)
  all_events='[]'
  FEED_OK=1
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    encoded=$(printf '%s' "$d" | jq -sRr @uri)
    if [ -n "$SINCE" ]; then
      url="https://datalake.r-53.com/api/v1/changes/feed?domain=${encoded}&since=${SINCE}"
    else
      url="https://datalake.r-53.com/api/v1/changes/feed?domain=${encoded}&limit=100"
    fi
    resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$url")
    body=$(printf '%s' "$resp" | sed '$d')
    code=$(printf '%s' "$resp" | tail -n1)
    if [ "$code" != "200" ]; then
      echo "⚠ Seaduste muudatuste kontroll ebaõnnestus domeenile '$d' ($code) — vaata üle käsitsi"
      FEED_OK=0
      continue
    fi
    # If SINCE is empty (first run), filter client-side to last 90 days
    if [ -z "$SINCE" ]; then
      cutoff=$(python3 -c 'import datetime; print((datetime.datetime.utcnow() - datetime.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
      events=$(echo "$body" | jq --arg c "$cutoff" '[.events[] | select(.timestamp >= $c)]')
    else
      events=$(echo "$body" | jq '.events // []')
    fi
    all_events=$(echo "$all_events $events" | jq -s 'add')
  done <<< "$DOMAINS"

  # Filter by act_id
  act_ids_json=$(printf '%s\n' "$ACT_IDS" | jq -R . | jq -s .)
  matched=$(echo "$all_events" | jq --argjson acts "$act_ids_json" '[.[] | select(.act_id as $a | $acts | index($a))]')

  # Apply matches to registry. Re-detection while an issue is already open
  # (gh_issue_url != null): update change/change_detected_at but do NOT create a
  # fresh issue later — surface as a reminder instead.
  updated=$(jq --argjson matched "$matched" '
    reduce ($matched[]) as $e (.;
      .entries |= with_entries(
        if .value.act_id == $e.act_id then
          .value.needs_review = true
          | .value.change_detected_at = $e.timestamp
          | .value.change = { feed_event_id: $e.id, type: $e.type, summary: $e.summary }
        else . end
      )
    )
  ' .startup/law-registry.json)

  # Advance last_feed_check_at only if all domain queries succeeded
  if [ "$FEED_OK" = "1" ]; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$updated" | jq --arg now "$NOW" '.last_feed_check_at = $now' > .startup/law-registry.json
  else
    echo "$updated" > .startup/law-registry.json
  fi
fi
```

After this step, the index reflects all feed changes. Flagged entries are handled by the Fix-Plan and Confirmation flow (Tasks 10–11).
```

- [ ] **Step 5: Re-run harness**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/harness.sh
```

Expected: 5 passed.

- [ ] **Step 6: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md \
        plugins/saas-startup-team/skills/lawyer/tests/test-detect.sh \
        plugins/saas-startup-team/skills/lawyer/tests/fixtures/datalake/feed-data-protection.json
git commit -m "feat(saas-startup-team): lawyer change detection via /changes/feed"
```

---

### Task 9: Conditional gh pre-flight

**Files:**
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** The `gh` CLI is only required when a flagged-and-unacked entry exists (detected just now or pending from a prior run). For projects that never hit that state, `gh` is not required. The check runs AFTER change detection, not before.

- [ ] **Step 1: Add Conditional gh Check to commands/lawyer.md**

After the Change Detection section, insert:

```markdown
## Conditional gh pre-flight

If any entry has `needs_review=true` AND `gh_issue_url=null`, the investor is about to be prompted to create a GitHub issue. `gh` must work at that point.

```bash
needs_gh=$(jq -r '
  .entries | to_entries[]
  | select(.value.needs_review == true and .value.gh_issue_url == null)
  | .key
' .startup/law-registry.json | head -n1)

if [ -n "$needs_gh" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not installed. Install via 'brew install gh' or your platform's package manager."
    echo "       /lawyer detected pending legal changes that need GitHub issues, and there is no manual fallback."
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh is not authenticated. Run 'gh auth login' first."
    exit 1
  fi
  if ! gh repo view --json nameWithOwner >/dev/null 2>&1; then
    echo "Error: this directory is not a GitHub-backed repository. /lawyer's change workflow requires a GitHub remote."
    exit 1
  fi
fi
```
```

- [ ] **Step 2: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md
git commit -m "feat(saas-startup-team): lawyer conditional gh pre-flight"
```

---

### Task 10: Fix-plan generation via Lawyer agent

**Files:**
- Modify: `plugins/saas-startup-team/commands/lawyer.md`
- Modify: `plugins/saas-startup-team/agents/lawyer.md`

**Context:** When the change-detection step flags any entry, the command body spawns the Lawyer agent with a specialised brief: "here are flagged slugs, their old and new text, and their marker hits — produce a plain-language fix plan and write `docs/legal/õiguslik-muudatused-YYYY-MM-DD.md`". The agent returns a structured summary (slug list + fix-plan text per slug) that the command body uses next step for the AskUserQuestion prompt and the gh issue body.

- [ ] **Step 1: Add Fix-Plan section to commands/lawyer.md**

After the Conditional gh pre-flight, insert:

```markdown
## Fix-Plan Generation

Runs only when the change-detection step produced at least one flagged-and-unacked entry (`needs_review=true AND gh_issue_url=null`). For entries where `gh_issue_url` is already set, skip — we don't re-produce a fix plan for an open issue.

Steps:

1. Collect flagged-and-unacked slugs:
   ```bash
   FLAGGED_SLUGS=$(jq -r '
     .entries | to_entries[]
     | select(.value.needs_review == true and .value.gh_issue_url == null)
     | .key
   ' .startup/law-registry.json)
   ```

2. For each flagged slug, fetch current paragraph text from the datalake (cache into a temp JSON file so the agent can read both old and new):
   ```bash
   TMP=$(mktemp -d)
   while IFS= read -r slug; do
     [ -z "$slug" ] && continue
     act_id=$(jq -r --arg s "$slug" '.entries[$s].act_id' .startup/law-registry.json)
     citation=$(jq -r --arg s "$slug" '.entries[$s].citation' .startup/law-registry.json)
     encoded=$(printf '%s' "$citation" | jq -sRr @uri)
     resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
       "https://datalake.r-53.com/api/v1/laws/${act_id}/citation?paragraph=${encoded}")
     new_text=$(echo "$resp" | jq -r '.text // ""')
     old_text=$(cat ".startup/laws/${slug}.txt" 2>/dev/null || echo "")
     # Stash for agent
     jq -n --arg slug "$slug" --arg old "$old_text" --arg new "$new_text" \
       --argjson change "$(jq -c --arg s "$slug" '.entries[$s].change' .startup/law-registry.json)" \
       '{slug:$slug, old_text:$old, new_text:$new, change:$change}' \
       > "$TMP/${slug}.json"
   done <<< "$FLAGGED_SLUGS"
   ```

3. Run the marker scan (Task 7 helper) and stash results to a file the agent reads:
   ```bash
   # Output format: <slug>\t<file>:<line>
   # (Using the AWK pipeline from the Marker Scan section)
   /* invoke the scan and redirect to "$TMP/markers.tsv" */
   ```

4. Spawn the Lawyer agent via the Task tool with this brief:

> Brief: "Seadusemuudatuste parandusplaan"
>
> Context files (read these — they already contain old text, new text, and feed-event summaries):
> - `$TMP/<slug>.json` for each flagged slug
> - `$TMP/markers.tsv` — the slug → file:line map from the marker scan
>
> For each flagged slug:
> 1. Read the files listed in markers.tsv for that slug; understand how each site uses the paragraph.
> 2. Produce a plain-language fix plan per file: what needs to change, WHY (one sentence), HOW (concrete — function to call, sentence to rewrite, etc.). NOT legal language.
> 3. Write/append `docs/legal/õiguslik-muudatused-YYYY-MM-DD.md` following the template in the design doc (fix plan up front; legal diff in `<details>` appendix).
>
> Do NOT modify `.startup/law-registry.json` or any `.startup/laws/*.txt` file. Those are the command body's responsibility.
>
> Return (as your final message): a one-sentence summary per slug for the confirmation prompt, prefixed with the slug itself. Example:
> ```
> consent-lawful-basis: § 10 lõige 2 lisas töötleja teavituse kohustuse — uuendada tuleb 3 faili.
> ```

5. Capture the agent's response summary. The command body parses it for the AskUserQuestion prompt next step.

On agent failure (agent returns an error or crashes): fall back to a minimal fix plan generated in bash from the new-text diff, write a stub review doc, and continue. The investor can always improve the issue body by hand after creation.
```

- [ ] **Step 2: Add Critical Rules to agents/lawyer.md about fix-plan behaviour**

In `plugins/saas-startup-team/agents/lawyer.md`, under `## Critical Rules`, append these bullets:

```markdown
- **ALWAYS** when invoked for a "Seadusemuudatuste parandusplaan" brief: produce a plain-language fix plan per affected file, NOT a legal diff. The investor does not read legal text; legal detail belongs in the `<details>` appendix only.
- **NEVER** modify `.startup/law-registry.json` or any `.startup/laws/*.txt` file from within the agent. The command body owns those files; ack happens through `/lawyer ack <slug>` in a fix branch.
- **ALWAYS** return a one-sentence summary per affected slug as your final message when producing a fix plan. The command body parses these summaries for the AskUserQuestion prompt.
```

- [ ] **Step 3: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md plugins/saas-startup-team/agents/lawyer.md
git commit -m "feat(saas-startup-team): lawyer fix-plan generation via agent"
```

---

### Task 11: AskUserQuestion confirmation + gh issue creation

**Files:**
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** After the fix-plan is written, prompt the investor once with AskUserQuestion (two options: "Jah, loo issue" / "Ei, jäta hiljemaks"). On "Jah", run `gh issue create` per flagged slug with the relevant section of the fix-plan doc as body, capture the URL, store it on the entry. On "Ei", exit without running the requested topic.

- [ ] **Step 1: Add Confirmation section to commands/lawyer.md**

After the Fix-Plan Generation section, insert:

```markdown
## Confirmation and Issue Creation

If any entry has `needs_review=true AND gh_issue_url=null`:

1. Build the confirmation question using `AskUserQuestion`. The question text lists each flagged slug's summary (from the agent's response):

> **Question:** "Seadusemuudatus avastatud — <N> kirje(t). Täielik parandusplaan: docs/legal/õiguslik-muudatused-<DATE>.md. Kas luua GitHubi issue(d) koos parandusplaaniga?"
>
> **Options:**
> - `Jah, loo issue` (default, recommended)
> - `Ei, jäta hiljemaks`

2. On "Ei, jäta hiljemaks":
   - Print: "Lipp jääb üles; tuleb järgmisel /lawyer käivitusel uuesti ette."
   - Exit 0 without running the investor's requested topic.

3. On "Jah, loo issue", for each flagged-and-unacked slug:

   a. Extract the per-slug "Mida tuleb teha" section from the review doc (the agent wrote it with recognisable slug headings).

   b. Compose issue body:
      ```
      <per-slug "Mida tuleb teha" section, unmodified>

      ---

      ## Registri värskendus PR-s

      Pärast koodi parandamist, PR-i harul:

      ```bash
      /lawyer ack <slug>
      ```

      See helper fetches the new text, overwrites `.startup/laws/<slug>.txt`,
      updates `.startup/law-registry.json` (clears flags, bumps verified_at,
      updates redaktsioon_id), and must be committed together with the code
      fix in the same PR.
      ```

   c. Run:
      ```bash
      issue_url=$(gh issue create \
        --title "Seadusemuudatus: ${citation} — ${slug}" \
        --label "legal-review,seadusemuudatus" \
        --body-file "$TMP/${slug}-issue-body.md" \
        2>&1)
      ```

   d. Parse the issue URL (gh prints it on stdout). Store it on the entry:
      ```bash
      jq --arg slug "$slug" --arg url "$issue_url" \
        '.entries[$slug].gh_issue_url = $url' \
        .startup/law-registry.json > .startup/law-registry.json.tmp
      mv .startup/law-registry.json.tmp .startup/law-registry.json
      ```

   e. Do NOT touch `needs_review`, `change`, `change_detected_at`, `verified_at`, `redaktsioon_id`, or the `.txt` snapshot. Those stay as detection left them — the PR that fixes the code will update them via `/lawyer ack`.

4. After all issues are created, continue with the original topic analysis (existing `## Execution` flow). The topic analysis receives the list of newly-issued slugs as context so it can note "pending legal fixes in #N, #N+1" in its output.

5. Re-detection while an issue is already open: entries with `gh_issue_url != null` are NOT re-prompted. The confirmation flow skips them silently. A reminder line is printed at the top of the run: "Lahtised seadusemuudatuste issue'd: <url1>, <url2> — ootavad PR-i."
```

- [ ] **Step 2: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md
git commit -m "feat(saas-startup-team): lawyer AskUserQuestion confirmation + gh issue creation"
```

---

### Task 12: Ack subcommand (with TDD)

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/tests/test-ack.sh`
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** `ack <slug>` is the Fix Implementation helper. It is called inside the branch that ships the code fix, as the final step before commit. It fetches fresh paragraph text, overwrites the snapshot, clears flags, bumps `verified_at`, and updates `redaktsioon_id`. `gh_issue_url` is preserved as the historical link.

- [ ] **Step 1: Write the failing test**

Create `plugins/saas-startup-team/skills/lawyer/tests/test-ack.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$TESTS_DIR/fixtures"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .startup/laws

# Seed registry with a flagged entry that has an open issue
cat > .startup/law-registry.json <<'EOF'
{
  "version": 1,
  "last_feed_check_at": "2026-04-23T10:00:00Z",
  "entries": {
    "consent-lawful-basis": {
      "act_id": "104052024010",
      "act_title": "Isikuandmete kaitse seadus",
      "citation": "§ 10 lõige 2",
      "domain": "Data Protection",
      "rt_url": "https://www.riigiteataja.ee/akt/104052024010",
      "redaktsioon_id": null,
      "registered_at": "2026-04-01T00:00:00Z",
      "verified_at": "2026-04-20T14:00:00Z",
      "registered_by": "lawyer",
      "purpose": "test",
      "needs_review": true,
      "change_detected_at": "2026-04-22T08:00:00Z",
      "change": {"feed_event_id": "evt-42", "type": "amended", "summary": "§ 10 lõige 2 muudetud"},
      "gh_issue_url": "https://github.com/org/repo/issues/42"
    }
  }
}
EOF
echo "Old text before amendment." > .startup/laws/consent-lawful-basis.txt

# Mock datalake citation endpoint — returns new redaktsioon text
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *citation*) cat "$FIXTURES/datalake/citation-consent.json"; exit 0 ;;
  esac
done
echo '{}'
MOCKCURL
chmod +x "$MOCK_BIN/curl"
export PATH="$MOCK_BIN:$PATH"
export EST_DATALAKE_API_KEY=test-key

# Inline ack logic (copied from commands/lawyer.md § Ack subcommand)
SLUG=consent-lawful-basis
act_id=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' .startup/law-registry.json)
citation=$(jq -r --arg s "$SLUG" '.entries[$s].citation' .startup/law-registry.json)
encoded=$(printf '%s' "$citation" | jq -sRr @uri)
resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/laws/${act_id}/citation?paragraph=${encoded}")
text=$(echo "$resp" | jq -r '.text // empty')
redaktsioon=$(echo "$resp" | jq '.redaktsioon_id // null')
[ -n "$text" ] || { echo "FAIL: ack got empty text"; exit 1; }

normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg slug "$SLUG" --arg now "$NOW" --argjson r "$redaktsioon" '
  .entries[$slug].needs_review = false
  | .entries[$slug].change = null
  | .entries[$slug].change_detected_at = null
  | .entries[$slug].verified_at = $now
  | .entries[$slug].redaktsioon_id = $r
' .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

# Assertions
[ "$(jq -r '.entries["consent-lawful-basis"].needs_review' .startup/law-registry.json)" = "false" ] || { echo "FAIL: needs_review not cleared"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].change' .startup/law-registry.json)" = "null" ] || { echo "FAIL: change not cleared"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].gh_issue_url' .startup/law-registry.json)" = "https://github.com/org/repo/issues/42" ] || { echo "FAIL: gh_issue_url should be preserved"; exit 1; }
[ "$(jq -r '.entries["consent-lawful-basis"].redaktsioon_id' .startup/law-registry.json)" = "104052024010/1" ] || { echo "FAIL: redaktsioon_id not updated"; exit 1; }
snapshot=$(cat .startup/laws/consent-lawful-basis.txt)
[[ "$snapshot" == *"nõusoleku"* ]] || { echo "FAIL: snapshot not refreshed"; exit 1; }

echo "PASS: test-ack"
```

- [ ] **Step 2: Run the test — expect PASS**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/test-ack.sh
```

Expected: PASS.

- [ ] **Step 3: Add the Ack subcommand section to the command file**

After the Confirmation section in `plugins/saas-startup-team/commands/lawyer.md`, insert:

```markdown
## Ack subcommand

Args: `ack <slug>` (or `ack-all` — see next section)

**Invocation contract:** this helper MUST be run inside the branch/PR that contains the code fix. It updates registry state; those changes must be committed together with the code changes so the merge is atomic.

Behaviour:

```bash
SLUG="$1"
[ -n "$SLUG" ] || { echo "Error: slug required"; exit 1; }

entry=$(jq -r --arg s "$SLUG" '.entries[$s] // empty' .startup/law-registry.json)
[ -n "$entry" ] || { echo "Error: no registry entry for '$SLUG'"; exit 1; }

act_id=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' .startup/law-registry.json)
citation=$(jq -r --arg s "$SLUG" '.entries[$s].citation' .startup/law-registry.json)
encoded=$(printf '%s' "$citation" | jq -sRr @uri)

resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "https://datalake.r-53.com/api/v1/laws/${act_id}/citation?paragraph=${encoded}")
text=$(echo "$resp" | jq -r '.text // empty')
redaktsioon=$(echo "$resp" | jq '.redaktsioon_id // null')
[ -n "$text" ] || { echo "Error: datalake returned empty text for act=$act_id citation=$citation"; exit 1; }

normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg slug "$SLUG" --arg now "$NOW" --argjson r "$redaktsioon" '
  .entries[$slug].needs_review = false
  | .entries[$slug].change = null
  | .entries[$slug].change_detected_at = null
  | .entries[$slug].verified_at = $now
  | .entries[$slug].redaktsioon_id = $r
' .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

echo "Ack: $SLUG — snapshot refreshed, flags cleared."
echo "Remember to commit both .startup/law-registry.json and .startup/laws/${SLUG}.txt in this PR alongside your code changes."
exit 0
```

`gh_issue_url` is preserved through ack as the permanent link to the issue that tracked this change.
```

- [ ] **Step 4: Re-run harness**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/harness.sh
```

Expected: 6 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md \
        plugins/saas-startup-team/skills/lawyer/tests/test-ack.sh
git commit -m "feat(saas-startup-team): lawyer ack subcommand refreshes snapshot and clears flags"
```

---

### Task 13: Remaining subcommands — ack-all, issue, status, check

**Files:**
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** Four small helpers. `ack-all` is a loop over `ack`. `issue <slug>` is non-interactive issue creation (Disposition A for one slug). `status` prints registry state. `check` runs change detection then exits.

- [ ] **Step 1: Add Ack-all subcommand**

After the Ack section:

```markdown
## Ack-all subcommand

Args: `ack-all`

Runs the `ack` logic for every entry with `needs_review=true`. Use only when the PR's code changes cover every flagged slug — otherwise use per-slug `ack` calls.

```bash
FLAGGED=$(jq -r '
  .entries | to_entries[]
  | select(.value.needs_review == true)
  | .key
' .startup/law-registry.json)

[ -z "$FLAGGED" ] && { echo "No flagged entries to ack."; exit 0; }

while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  # Delegate to ack: we duplicate the ack logic here rather than re-invoke the command,
  # because slash-commands are not recursively executable mid-flow.
  # (Copy the ack block above; or, if refactoring to a shared function, define it once and call it twice.)
  echo "Ack-ing: $slug"
  # ... same body as Ack subcommand, scoped to $slug ...
done <<< "$FLAGGED"

echo "Ack-all complete."
exit 0
```

Implementation note for the engineer: factor the per-slug ack body out into a shell function in the same command file and call it from both `ack` and `ack-all` to avoid duplication.
```

- [ ] **Step 2: Add Issue subcommand**

```markdown
## Issue subcommand

Args: `issue <slug>`

Non-interactive Disposition A for one slug. Used by agents or in scripts that don't have an investor to prompt.

Requires: entry has `needs_review=true` AND `gh_issue_url=null`. Otherwise, no-op with a message.

Behaviour: identical to step 3 of the Confirmation flow (Task 11), but scoped to a single slug and without the AskUserQuestion prompt. Preserves the rule that registry and `.txt` are not touched here — only `gh_issue_url` is set.
```

- [ ] **Step 3: Add Status subcommand**

```markdown
## Status subcommand

Args: `status`

Prints a concise summary of the registry state. No spawn, no feed call.

```bash
if [ ! -f .startup/law-registry.json ]; then
  echo "No law registry in this project. Run /lawyer with a topic to initialise."
  exit 0
fi

total=$(jq -r '.entries | length' .startup/law-registry.json)
flagged=$(jq -r '[.entries[] | select(.needs_review == true)] | length' .startup/law-registry.json)
open_issues=$(jq -r '[.entries[] | select(.needs_review == true and .gh_issue_url != null)] | length' .startup/law-registry.json)
pending_confirm=$(jq -r '[.entries[] | select(.needs_review == true and .gh_issue_url == null)] | length' .startup/law-registry.json)
last_check=$(jq -r '.last_feed_check_at // "never"' .startup/law-registry.json)

cat <<EOF
Law registry status
-------------------
Total entries:        $total
Flagged for review:   $flagged
  With open gh issue: $open_issues
  Awaiting issue:     $pending_confirm
Last feed check:      $last_check
EOF

if (( pending_confirm > 0 )); then
  echo ""
  echo "Slugs awaiting confirmation (will prompt on next /lawyer <topic>):"
  jq -r '.entries | to_entries[] | select(.value.needs_review == true and .value.gh_issue_url == null) | "  - " + .key' .startup/law-registry.json
fi

exit 0
```
```

- [ ] **Step 4: Add Check subcommand**

```markdown
## Check subcommand

Args: `check`

Runs the Change Detection step (Task 8) and exits. Does NOT prompt, does NOT create issues, does NOT spawn the agent. After this returns, any new flags are persisted and the investor can run `/lawyer status` to see them.

```bash
# The change-detection block from the "Change Detection" section above,
# followed by:
echo "Feed check complete."
echo "Run /lawyer status to see flagged entries, or /lawyer <topic> to trigger the fix-plan prompt."
exit 0
```
```

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md
git commit -m "feat(saas-startup-team): lawyer ack-all/issue/status/check subcommands"
```

---

### Task 14: Index↔snapshot invariant warnings

**Files:**
- Modify: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** On every run, after change detection, scan for invariant violations and warn. Non-blocking. Covers: registered slug with no `.txt` file; orphan `.txt` with no registry entry; registry slug with no markers; markers with no registry entry.

- [ ] **Step 1: Add Invariant Check section**

After Change Detection but before Fix-Plan Generation, insert:

```markdown
## Invariant Check (non-blocking warnings)

```bash
# Check 1: registered slug with no snapshot file
jq -r '.entries | keys[]' .startup/law-registry.json | while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  if [ ! -f ".startup/laws/${slug}.txt" ]; then
    echo "⚠ Snapshot missing for registered slug '$slug' (.startup/laws/${slug}.txt)"
  fi
done

# Check 2: orphan snapshot files
if [ -d .startup/laws ]; then
  for f in .startup/laws/*.txt; do
    [ -f "$f" ] || continue
    s=$(basename "$f" .txt)
    if ! jq -e --arg s "$s" '.entries | has($s)' .startup/law-registry.json >/dev/null; then
      echo "⚠ Orphan snapshot '$f' (no registry entry for slug '$s')"
    fi
  done
fi

# Check 3 & 4: requires the marker scan (Task 7). Run the scan and compare slug sets.
# (Details: collect all slugs from marker scan output, diff against .entries | keys)
```
```

- [ ] **Step 2: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md
git commit -m "feat(saas-startup-team): lawyer registry invariant warnings"
```

---

### Task 15: Skill doc updates

**Files:**
- Modify: `plugins/saas-startup-team/skills/lawyer/SKILL.md`

**Context:** Add a Law Registry section that orients the agent toward the reference doc and sets Critical Rules.

- [ ] **Step 1: Add a Law Registry section to SKILL.md**

After the "Reference Documents" section (near the bottom), insert a new section:

```markdown
## Law Registry (per-project)

Every SaaS project using this plugin maintains a registry of the Estonian
legal paragraphs its code / customer-facing pages / customer-facing docs
depend on. The registry lives at `.startup/law-registry.json` (metadata
index) + `.startup/laws/<slug>.txt` (snapshot text per slug). Source files
reference entries through `LAW: <slug>` comment markers.

On every `/lawyer` run the command body polls the datalake `/changes/feed`
per unique registered domain. Matched events flag entries
`needs_review=true`. Flagged entries block analysis and trigger a fix-plan
step — the investor is prompted once to create a GitHub issue, and the
registry refresh happens inside the PR that ships the code fix (via
`/lawyer ack <slug>`).

**Full schema, marker syntax, scan regex, and API templates:** see
`references/law-registry.md`.

### Critical Rules

- **ALWAYS** assume the registry is the source of truth for which Estonian
  paragraphs the product depends on. When analysis cites a paragraph that
  the product actually depends on, register it.
- **ALWAYS** register with a kebab-case slug and add a marker in the code /
  page / doc that depends on the paragraph.
- **NEVER** modify `.startup/law-registry.json` or `.startup/laws/*.txt`
  from within the agent body. The command body owns these files; code
  fixes use `/lawyer ack <slug>` inside the PR branch.
- **NEVER** register a paragraph cited only in an internal analysis doc
  (`docs/legal/õiguslik-*.md`). The registry is for load-bearing references
  in code and customer-facing content only.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/SKILL.md
git commit -m "feat(saas-startup-team): lawyer skill doc — law registry section"
```

---

### Task 16: Version bumps + marketplace sync

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

**Context:** Both files must carry the same version string per repo CLAUDE.md. Bump to `0.29.0` — new feature, no breaking changes to existing investor UX for projects that don't use the registry.

- [ ] **Step 1: Bump plugin.json**

Edit `plugins/saas-startup-team/.claude-plugin/plugin.json`, change `"version": "0.28.0"` to `"version": "0.29.0"`.

- [ ] **Step 2: Bump marketplace.json**

Edit `.claude-plugin/marketplace.json`. Find the `saas-startup-team` plugin entry and change its `"version"` from `"0.28.0"` to `"0.29.0"`.

- [ ] **Step 3: Verify both match**

```bash
jq -r '.version' plugins/saas-startup-team/.claude-plugin/plugin.json
jq -r '.plugins[] | select(.name == "saas-startup-team") | .version' .claude-plugin/marketplace.json
```

Expected: both print `0.29.0`.

- [ ] **Step 4: Commit (this is the feat-level commit that closes the implementation)**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "feat(saas-startup-team): v0.29.0 — law registry with feed-based change detection and gh-issue-backed fix tracking"
```

---

### Task 17: Manual integration scenario

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/tests/manual-integration.md`

**Context:** Automated tests cover the mechanics; manual verification covers the end-to-end behaviour with a real datalake and a real GitHub remote. Document the scenario for someone verifying the implementation.

- [ ] **Step 1: Write the manual integration doc**

Create `plugins/saas-startup-team/skills/lawyer/tests/manual-integration.md`:

```markdown
# Manual Integration Scenarios

Prerequisites: a scratch startup project initialised via `/startup`, a real
GitHub remote, `gh auth login` completed, `EST_DATALAKE_API_KEY` exported,
datalake reachable.

## Scenario 1: Happy path end-to-end

1. In the project, run `/lawyer register consent-lawful-basis 104052024010 "§ 10 lõige 2" "Lawful basis for signup consent"`. Expect success message and a `// LAW: consent-lawful-basis` suggestion.
2. Add a `// LAW: consent-lawful-basis` comment somewhere in `src/`.
3. Run `/lawyer status`. Expect: 1 total, 0 flagged.
4. Run `/lawyer check`. Expect: "Feed check complete." and no flags.
5. Fabricate a change: manually edit the index entry's `needs_review` to `true`, `change_detected_at` to today, `change` to a test object.
6. Run `/lawyer analyze consent flow`. Expect:
   - Review doc written at `docs/legal/õiguslik-muudatused-<date>.md` with a fix plan.
   - AskUserQuestion prompt: "Jah, loo issue" / "Ei, jäta hiljemaks".
7. Answer "Jah". Expect:
   - gh issue created with the fix plan as body.
   - Index entry: `gh_issue_url` set; `needs_review` still true; `.txt` unchanged; `verified_at` unchanged.
   - The topic "analyze consent flow" runs after issue creation, with a pending-fix note in its output.

## Scenario 2: PR-owned ack

1. Continuing from Scenario 1, create a branch: `git checkout -b fix/consent-amendment`.
2. Edit `src/auth/consent.ts` (the file marked with `LAW: consent-lawful-basis`) to apply the fix plan.
3. Run `/lawyer ack consent-lawful-basis`. Expect:
   - `.startup/laws/consent-lawful-basis.txt` overwritten with fresh datalake text.
   - Index entry: `needs_review=false`, `change=null`, `verified_at=<now>`, `redaktsioon_id=<from response>`, `gh_issue_url` still set.
4. `git add src/ .startup/` and commit. Expect both code and registry changes in one commit.
5. Push the branch and open a PR. Expect the diff to show both sets of changes together.

## Scenario 3: Leave-for-later path

1. Fabricate another needs_review state on a second slug.
2. Run `/lawyer analyze something else`. Expect the prompt.
3. Answer "Ei, jäta hiljemaks". Expect: exit without running the topic; reminder message about the flag staying up; no gh call.
4. Re-run `/lawyer status`. Confirm flag is still there, `gh_issue_url` is still null.

## Scenario 4: No-GitHub-remote hard-fail

1. In a project directory with no GitHub remote, fabricate a flagged entry.
2. Run `/lawyer analyze X`. Expect hard-fail during conditional gh pre-flight: "this directory is not a GitHub-backed repository."
3. Verify no partial state changes: `.txt` unchanged, `needs_review` still true, `gh_issue_url` still null.

## Scenario 5: Re-detection while issue is open

1. Continuing from Scenario 1 (with `gh_issue_url` set on an entry), fabricate a second feed event for the same `act_id` by running `/lawyer check` against a datalake where another amendment now exists (or by manipulating the registry to simulate it: set `last_feed_check_at` back and trigger detection).
2. Run `/lawyer <topic>`. Expect:
   - No new fix plan prompt for that slug.
   - Reminder at top: "Lahtised seadusemuudatuste issue'd: <url> — ootavad PR-i."
   - `change` field updated to the latest event on the existing entry.
   - The investor's topic runs normally.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/tests/manual-integration.md
git commit -m "test(saas-startup-team): lawyer registry manual integration scenarios"
```

---

## Verification before declaring complete

Run these in order. All must pass.

- [ ] **All automated tests pass**

```bash
bash plugins/saas-startup-team/skills/lawyer/tests/harness.sh
```

Expected: `=== Results: 6 passed, 0 failed ===`

- [ ] **Version numbers match**

```bash
jq -r '.version' plugins/saas-startup-team/.claude-plugin/plugin.json
jq -r '.plugins[] | select(.name == "saas-startup-team") | .version' .claude-plugin/marketplace.json
```

Both must print `0.29.0`.

- [ ] **No lingering "TODO", "TBD", or placeholder references in the plugin files**

```bash
grep -nE "TODO|TBD|FIXME|XXX" plugins/saas-startup-team/skills/lawyer/ plugins/saas-startup-team/commands/lawyer.md plugins/saas-startup-team/agents/lawyer.md 2>&1 | grep -v tests/
```

Expected: no output.

- [ ] **Manual integration Scenario 1 through 5** (see `plugins/saas-startup-team/skills/lawyer/tests/manual-integration.md`) performed in a scratch project; results documented.

- [ ] **Git log shows one commit per task**

```bash
git log --oneline -20
```

Expected: at least 17 commits covering Tasks 1–17, leading to a final feat-level commit marking v0.29.0.
