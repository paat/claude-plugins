---
name: lawyer
description: On-demand legal analysis — queries the est-saas-datalake API and project context to produce Estonian-language legal compliance and risk analysis. Usage: /lawyer <topic>
user_invocable: true
---

# /lawyer — On-Demand Legal Analysis

The human investor requests legal analysis on a specific topic. You spawn the Lawyer agent to research and write analysis.

**The Lawyer is a one-shot consultant, NOT a loop participant.** It spawns, does its analysis, writes to `docs/legal/õiguslik-*.md`, and exits.

## Pre-Flight Checks (HARD FAIL — No Fallbacks)

Before spawning the Lawyer agent, ALL of the following must pass. If any check fails, stop with an error message and do NOT proceed.

### Check 1: Datalake API is reachable

```bash
curl --max-time 10 -s -o /dev/null -w "%{http_code}" https://datalake.r-53.com/api/v1/health/ready
```

**Must return:** `200`

**If not 200 or unreachable:**
> **Error:** est-saas-datalake API is not available at https://datalake.r-53.com/. The Lawyer requires the datalake for Estonian legal analysis. Fix the datalake service before running /lawyer.

### Check 2: Startup project exists

Verify that these files exist:
- `.startup/state.json`
- `docs/business/brief.md`

**If missing:**
> **Error:** No startup project found. Run /startup first to initialize the project before running /lawyer.

### Check 3: API key is available

Check for `EST_DATALAKE_API_KEY` environment variable:

```bash
echo "${EST_DATALAKE_API_KEY:?not set}" > /dev/null 2>&1
```

**If not set:**
> **Error:** EST_DATALAKE_API_KEY environment variable is not set. The Lawyer needs an API key to query the datalake. Set it with: export EST_DATALAKE_API_KEY=your-key

### Check 4: Law registry is valid (if present)

If `.startup/law-registry.json` exists, it must be valid JSON with `version: 2`. Missing file is fine — the command creates it on first use. (v0.29.x wrote `version: 1` but the feature never worked against the real API; v0.30.0 introduces v2 with corrected field names. If you have a v1 file from an earlier session, delete it — nothing it contained will be usable.)

```bash
if [ -f .startup/law-registry.json ]; then
  jq -e '.version == 2' .startup/law-registry.json >/dev/null 2>&1
fi
```

**If non-zero exit:**
> **Error:** `.startup/law-registry.json` is not valid JSON or is not version 2 (expected `{"version": 2, ...}`). If you have a v1 file from v0.29.x, delete it — that version's schema didn't match the real datalake API and no data in it is salvageable.

### Check 5: Laws directory is a directory (if present)

If `.startup/laws` exists, it must be a directory. Missing path is fine.

```bash
[ ! -e .startup/laws ] || [ -d .startup/laws ]
```

**If non-zero exit:**
> **Error:** `.startup/laws` exists but is not a directory. Remove or rename it before running /lawyer again.

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

## Register subcommand

Args: `register <slug> <act_id> <citation> <purpose>`

- `slug` — kebab-case identifier matching `[a-z0-9-]+`.
- `act_id` — **integer** from `GET /api/v1/laws/search?q=<act-name>` — the `.id` field, not `rt_id`, not the RT URL segment. Look it up first (for example: `curl -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$DATALAKE_URL/api/v1/laws/search?q=isikuandmete+kaitse&limit=5" | jq '.items[] | {id, rt_id, title}'`).
- `citation` — Estonian compound reference like `"§ 10 lõige 1 punkt 3"`. Parsed into `paragraph`/`section`/`point` before the API call (the citation endpoint rejects the compound string directly).
- `purpose` — one-line Estonian description of why this paragraph is load-bearing.

Behaviour:

```bash
SLUG="$1"
ACT_ID="$2"
CITATION="$3"
PURPOSE="$4"
: "${DATALAKE_URL:=https://datalake.r-53.com}"

[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "Error: slug must match [a-z0-9-]+"; exit 1; }
[[ "$ACT_ID" =~ ^[0-9]+$ ]] || { echo "Error: act_id must be an integer — use /laws/search .id, not rt_id or RT URL segment"; exit 1; }

# Parse citation → (paragraph, section, point). Paragraph is required; others optional.
read -r PARAGRAPH SECTION POINT <<< "$(printf '%s' "$CITATION" | python3 -c '
import re, sys
t = sys.stdin.read()
p = re.search(r"§\s*(\d+)", t)
s = re.search(r"l[oõ]ige\s*(\d+)", t, re.IGNORECASE)
k = re.search(r"punkt\s*(\d+)", t, re.IGNORECASE)
print((p.group(1) if p else ""), (s.group(1) if s else ""), (k.group(1) if k else ""))
')"
[ -n "$PARAGRAPH" ] || { echo "Error: could not parse paragraph (§ N) from citation '$CITATION'"; exit 1; }

# Ensure registry files exist (schema v2)
[ -f .startup/law-registry.json ] || echo '{"version":2,"last_feed_check_at":null,"entries":{}}' > .startup/law-registry.json
mkdir -p .startup/laws

# Idempotency on (act_id, citation)
existing=$(jq -r --argjson act "$ACT_ID" --arg cit "$CITATION" \
  '.entries | to_entries[] | select(.value.act_id == $act and .value.citation == $cit) | .key' \
  .startup/law-registry.json)
if [ -n "$existing" ] && [ "$existing" != "$SLUG" ]; then
  echo "Entry (act_id=$ACT_ID, citation=$CITATION) already registered as '$existing'. Reusing; no action taken."
  exit 0
fi

# Resolve act metadata (rt_id, title, domains) via /laws/{act_id}/graph.
# The graph endpoint is cheap and returns the canonical act record — avoids the
# guesswork that v0.29.x did with RT URL segments.
graph_resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/laws/${ACT_ID}/graph")
graph_code=$(printf '%s' "$graph_resp" | tail -n1)
graph_body=$(printf '%s' "$graph_resp" | sed '$d')
if [ "$graph_code" != "200" ]; then
  echo "Error: /laws/${ACT_ID}/graph returned HTTP $graph_code — act_id is probably wrong"
  echo "       Try: $DATALAKE_URL/api/v1/laws/search?q=<act-name> to find the correct .id"
  exit 1
fi
RT_ID=$(echo "$graph_body" | jq -r '.act.rt_id // empty')
ACT_TITLE=$(echo "$graph_body" | jq -r '.act.title // "Teadmata seadus"')
ACT_TYPE=$(echo "$graph_body" | jq -r '.act.act_type // ""')
[ -n "$RT_ID" ] || { echo "Error: /laws/${ACT_ID}/graph has no .act.rt_id"; exit 1; }

# Fetch paragraph text via citation endpoint with parsed parts
cite_url="$DATALAKE_URL/api/v1/laws/${ACT_ID}/citation?paragraph=${PARAGRAPH}"
[ -n "$SECTION" ] && cite_url="${cite_url}&section=${SECTION}"
[ -n "$POINT" ] && cite_url="${cite_url}&point=${POINT}"
cite_resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$cite_url")
cite_code=$(printf '%s' "$cite_resp" | tail -n1)
cite_body=$(printf '%s' "$cite_resp" | sed '$d')
if [ "$cite_code" != "200" ]; then
  echo "Error: /laws/${ACT_ID}/citation returned HTTP $cite_code — citation '$CITATION' parses as paragraph=$PARAGRAPH section=$SECTION point=$POINT"
  exit 1
fi
text=$(echo "$cite_body" | jq -r '.text // empty')
REDAKTSIOON_URL=$(echo "$cite_body" | jq -r '.url // empty')
# Extract the redaktsioon ID (per-redaction RT identifier — numeric trailing segment of .url)
REDAKTSIOON_ID=""
if [ -n "$REDAKTSIOON_URL" ]; then
  tail_seg="${REDAKTSIOON_URL##*/akt/}"
  REDAKTSIOON_ID="${tail_seg%%[!0-9]*}"
fi
[ -n "$text" ] || { echo "Error: citation endpoint returned empty text"; exit 1; }

# Normalise (trim + NFC) and write snapshot first — on crash before index write,
# re-run sees orphan snapshot (warning), not orphan index entry.
normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
entry=$(jq -n \
  --argjson act "$ACT_ID" \
  --arg rt "$RT_ID" \
  --arg red "$REDAKTSIOON_ID" \
  --arg title "$ACT_TITLE" \
  --arg atype "$ACT_TYPE" \
  --arg cit "$CITATION" \
  --arg para "$PARAGRAPH" \
  --arg sec "$SECTION" \
  --arg pt "$POINT" \
  --arg rturl "$REDAKTSIOON_URL" \
  --arg now "$NOW" \
  --arg by "${REGISTERED_BY:-lawyer}" \
  --arg purp "$PURPOSE" \
  '{
    act_id: $act,
    rt_id: $rt,
    redaktsioon_id: (if $red == "" then null else $red end),
    act_title: $title,
    act_type: $atype,
    citation: $cit,
    citation_parts: { paragraph: $para, section: $sec, point: $pt },
    rt_url: $rturl,
    registered_at: $now,
    verified_at: $now,
    registered_by: $by,
    purpose: $purp,
    needs_review: false,
    change_detected_at: null,
    change: null,
    gh_issue_url: null
  }')

jq --arg slug "$SLUG" --argjson e "$entry" \
  '.entries[$slug] = $e' \
  .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

echo "Registered: $SLUG (act_id=$ACT_ID, rt_id=$RT_ID, $ACT_TITLE)"
echo "Lisa marker koodi: // LAW: $SLUG"
exit 0
```

Failure: if either the graph or citation call fails, the helper hard-fails and does NOT leave a partial snapshot or index entry on disk (snapshot is written only after both API calls succeed).

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

## Marker Scan (internal helper)

Produces a `slug -> [file:line, ...]` map by scanning project source for `LAW:` markers. Used by the change-detection alert flow and the orphan-slug warning.

```bash
# Scope: source + customer-facing content; exclude docs/legal/ (lawyer output)
SCAN_DIRS=()
for d in src app pages components lib server public content docs; do
  [ -d "$d" ] && SCAN_DIRS+=("$d")
done

PATTERN='(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*'

# Guard: if no known source dirs exist, skip the scan entirely. Without this,
# rg/grep with no path args would recurse from the current working directory
# and spuriously match LAW: tokens inside docs/plans/, .startup/, node_modules,
# etc.
if [ ${#SCAN_DIRS[@]} -eq 0 ]; then
  raw=""
# Collect raw matches (rg preferred; grep fallback)
elif command -v rg >/dev/null 2>&1; then
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

## Change Detection

Runs at the start of every `/lawyer` invocation, after pre-flight and subcommand dispatch but before analysis. Reads only the index JSON; snapshot `.txt` files are never opened here.

One feed call per run (no per-domain loop) — we query without `?domain=` and match client-side by `rt_id`. The server's `?domain=` filter uses an undocumented enum that doesn't match the plugin's historical domain strings; filtering client-side is cheaper than negotiating that enum and keeps the plugin honest when new domain labels appear server-side.

```bash
: "${DATALAKE_URL:=https://datalake.r-53.com}"
[ -f .startup/law-registry.json ] || echo '{"version":2,"last_feed_check_at":null,"entries":{}}' > .startup/law-registry.json

RT_IDS=$(jq -r '.entries | to_entries[] | .value.rt_id // empty' .startup/law-registry.json | sort -u)

if [ -z "$RT_IDS" ]; then
  # Empty registry — nothing to match. Skip the call entirely.
  FEED_OK=1
else
  SINCE=$(jq -r '.last_feed_check_at // ""' .startup/law-registry.json)
  if [ -z "$SINCE" ]; then
    # First run against a non-empty registry — look back 90 days (server accepts ISO-8601 on `since`).
    SINCE=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  fi

  feed_url="$DATALAKE_URL/api/v1/changes/feed?since=${SINCE}&limit=500"
  resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$feed_url")
  body=$(printf '%s' "$resp" | sed '$d')
  code=$(printf '%s' "$resp" | tail -n1)

  FEED_OK=1
  if [ "$code" != "200" ]; then
    echo "⚠ Seaduste muudatuste kontroll ebaõnnestus ($code) — vaata üle käsitsi"
    FEED_OK=0
    events='[]'
  else
    events=$(echo "$body" | jq '.items // []')
  fi

  # Match feed events against registered rt_ids. Each event may carry multiple
  # domains — we ignore domain entirely and rely on rt_id as the act identity.
  rt_ids_json=$(printf '%s\n' "$RT_IDS" | jq -R . | jq -s .)
  matched=$(echo "$events" | jq --argjson rts "$rt_ids_json" '[.[] | select(.rt_id as $r | $rts | index($r))]')

  # Apply matches. Re-detection while an issue is already open (gh_issue_url != null)
  # updates the change info but does NOT create a fresh issue later — surfaced as a reminder.
  updated=$(jq --argjson matched "$matched" '
    reduce ($matched[]) as $e (.;
      .entries |= with_entries(
        if .value.rt_id == $e.rt_id then
          .value.needs_review = true
          | .value.change_detected_at = $e.detected_at
          | .value.change = {
              feed_event_id: $e.id,
              type: $e.change_type,
              summary: $e.description,
              effective_date: $e.effective_date
            }
        else . end
      )
    )
  ' .startup/law-registry.json)

  # Advance last_feed_check_at only on a clean feed query so a failed run retries the same window next time.
  if [ "$FEED_OK" = "1" ]; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$updated" | jq --arg now "$NOW" '.last_feed_check_at = $now' > .startup/law-registry.json
  else
    echo "$updated" > .startup/law-registry.json
  fi
fi
```

After this step, the index reflects all feed changes. Flagged entries are handled by the Fix-Plan and Confirmation flow below.

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
  # Ensure the labels used by the fix-tracking workflow exist in the repo.
  # --force is idempotent: creates if missing, updates colour/description if present.
  # Silenced because label provisioning is an internal detail, not user-facing progress.
  gh label create legal-review --color FFA500 --description "Õigusküsimus või seadusemuudatus" --force >/dev/null 2>&1 || true
  gh label create seadusemuudatus --color FF6B6B --description "Estonian law changed — fix pending" --force >/dev/null 2>&1 || true
fi
```

## Fix-Plan Generation

Runs only when the change-detection step produced at least one flagged-and-unacked entry (`needs_review=true AND gh_issue_url=null`). For entries where `gh_issue_url` is already set, skip — we don't re-produce a fix plan for an open issue.

### Step 1: Collect flagged-and-unacked slugs

```bash
FLAGGED_SLUGS=$(jq -r '
  .entries | to_entries[]
  | select(.value.needs_review == true and .value.gh_issue_url == null)
  | .key
' .startup/law-registry.json)
```

### Step 2: Fetch current paragraph text and stash old + new + change per slug

```bash
: "${DATALAKE_URL:=https://datalake.r-53.com}"
TMP=$(mktemp -d)
while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  act_id=$(jq -r --arg s "$slug" '.entries[$s].act_id' .startup/law-registry.json)
  paragraph=$(jq -r --arg s "$slug" '.entries[$s].citation_parts.paragraph // ""' .startup/law-registry.json)
  section=$(jq -r --arg s "$slug" '.entries[$s].citation_parts.section // ""' .startup/law-registry.json)
  point=$(jq -r --arg s "$slug" '.entries[$s].citation_parts.point // ""' .startup/law-registry.json)

  cite_url="$DATALAKE_URL/api/v1/laws/${act_id}/citation?paragraph=${paragraph}"
  [ -n "$section" ] && cite_url="${cite_url}&section=${section}"
  [ -n "$point" ] && cite_url="${cite_url}&point=${point}"

  resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$cite_url")
  new_text=$(echo "$resp" | jq -r '.text // ""')
  old_text=$(cat ".startup/laws/${slug}.txt" 2>/dev/null || echo "")

  # Pull the feed event's change_id (if present) and fetch /changes/{change_id}/impact
  # to augment the fix plan with the datalake's own impact analysis. Non-fatal if missing.
  change_id=$(jq -r --arg s "$slug" '.entries[$s].change.feed_event_id // empty' .startup/law-registry.json)
  impact="{}"
  if [ -n "$change_id" ]; then
    impact=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
      "$DATALAKE_URL/api/v1/changes/${change_id}/impact" 2>/dev/null || echo "{}")
    # Tolerate non-JSON (endpoint occasionally returns 404 for older events)
    echo "$impact" | jq empty 2>/dev/null || impact="{}"
  fi

  jq -n --arg slug "$slug" --arg old "$old_text" --arg new "$new_text" \
    --argjson change "$(jq -c --arg s "$slug" '.entries[$s].change' .startup/law-registry.json)" \
    --argjson impact "$impact" \
    '{slug:$slug, old_text:$old, new_text:$new, change:$change, impact:$impact}' \
    > "$TMP/${slug}.json"
done <<< "$FLAGGED_SLUGS"
```

### Step 3: Run the Marker Scan and stash results

Run the same logic as `## Marker Scan (internal helper)` above, redirecting its output to `$TMP/markers.tsv`. Output format per line: `<slug>\t<file>:<line>`.

```bash
SCAN_DIRS=()
for d in src app pages components lib server public content docs; do
  [ -d "$d" ] && SCAN_DIRS+=("$d")
done

if [ ${#SCAN_DIRS[@]} -eq 0 ]; then
  : > "$TMP/markers.tsv"
else
  PATTERN='(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*'
  if command -v rg >/dev/null 2>&1; then
    raw=$(rg -n --pcre2 "$PATTERN" "${SCAN_DIRS[@]}" 2>/dev/null | grep -v '^docs/legal/' || true)
  else
    raw=$(grep -rEn "$PATTERN" "${SCAN_DIRS[@]}" 2>/dev/null | grep -v '^docs/legal/' || true)
  fi

  printf '%s\n' "$raw" | awk -F: '
    {
      file=$1; line=$2
      tail=""
      for (i=3; i<=NF; i++) tail = tail (i==3?"":":") $i
      if (match(tail, /LAW:[[:space:]]*[a-z0-9,\- \t]+/) == 0) next
      slugs = substr(tail, RSTART+4)
      gsub(/\*\/.*/, "", slugs)
      gsub(/-->.*/, "", slugs)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", slugs)
      ns = split(slugs, arr, /[[:space:]]*,[[:space:]]*/)
      for (j=1; j<=ns; j++) {
        s = arr[j]
        if (s ~ /^[a-z0-9-]+$/) print s "\t" file ":" line
      }
    }
  ' > "$TMP/markers.tsv"
fi
```

### Step 4: Spawn the Lawyer agent

Invoke the Lawyer agent via the Task tool with the following brief:

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

### Step 5: Capture agent response

Capture the agent's response summary. The command body parses it for the AskUserQuestion prompt next step.

On agent failure (agent returns an error or crashes): fall back to a minimal fix plan generated in bash from the new-text diff, write a stub review doc, and continue. The investor can always improve the issue body by hand after creation.

## Confirmation and Issue Creation

If any entry has `needs_review=true AND gh_issue_url=null`:

### Step 1: AskUserQuestion prompt

Build the confirmation question using `AskUserQuestion`. The question text lists each flagged slug's one-sentence summary (from the agent's response in Fix-Plan Step 5):

> **Question:** "Seadusemuudatus avastatud — <N> kirje(t). Täielik parandusplaan: docs/legal/õiguslik-muudatused-<DATE>.md. Kas luua GitHubi issue(d) koos parandusplaaniga?"
>
> **Options:**
> - `Jah, loo issue` (default, recommended)
> - `Ei, jäta hiljemaks`

### Step 2: On "Ei, jäta hiljemaks"

- Print: "Lipp jääb üles; tuleb järgmisel /lawyer käivitusel uuesti ette."
- Exit 0 without running the investor's requested topic.

### Step 3: On "Jah, loo issue"

For each flagged-and-unacked slug:

#### Step 3a: Extract per-slug section from review doc

Extract the per-slug "Mida tuleb teha" section from `docs/legal/õiguslik-muudatused-<DATE>.md` (the agent wrote it with recognisable slug headings).

#### Step 3b: Compose issue body

Write `$TMP/${slug}-issue-body.md` with the following content (shown here as indented prose; write it without the leading indentation):

    <per-slug "Mida tuleb teha" section, unmodified>

    ---

    ## Registri värskendus PR-s

    Pärast koodi parandamist, PR-i harul:

        /lawyer ack <slug>

    See helper fetches the new text, overwrites `.startup/laws/<slug>.txt`,
    updates `.startup/law-registry.json` (clears flags, bumps verified_at,
    updates redaktsioon_id), and must be committed together with the code
    fix in the same PR.

#### Step 3c: Create the GitHub issue

Capture stdout (URL) separately from stderr (errors) and verify exit code. A non-zero exit or any error in `$TMP/gh-err-${slug}` leaves the slug flagged — next `/lawyer` run re-prompts — rather than storing the error text as a fake URL.

```bash
if ! issue_url=$(gh issue create \
  --title "Seadusemuudatus: ${citation} — ${slug}" \
  --label "legal-review,seadusemuudatus" \
  --body-file "$TMP/${slug}-issue-body.md" 2>"$TMP/gh-err-${slug}"); then
  echo "Error: gh issue create failed for '${slug}':"
  cat "$TMP/gh-err-${slug}"
  echo "  Slug remains flagged; next /lawyer run will re-prompt."
  continue
fi
```

#### Step 3d: Store the issue URL

Only reached on success. Store `gh_issue_url`; leave all other fields untouched:

```bash
jq --arg slug "$slug" --arg url "$issue_url" \
  '.entries[$slug].gh_issue_url = $url' \
  .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json
```

#### Step 3e: Fields not touched here

Do NOT touch `needs_review`, `change`, `change_detected_at`, `verified_at`, `redaktsioon_id`, or the `.txt` snapshot. Those stay as detection left them — the PR that fixes the code will update them via `/lawyer ack`.

### Step 4: Continue with topic analysis

After all issues are created, continue with the original topic analysis (existing `## Execution` flow). The topic analysis receives the list of newly-issued slugs as context so it can note "pending legal fixes in #N, #N+1" in its output.

### Step 5: Re-detection while issue is open

Entries with `gh_issue_url != null` are NOT re-prompted by the confirmation flow — they are skipped silently. A reminder line is printed at the top of the run:

> "Lahtised seadusemuudatuste issue'd: <url1>, <url2> — ootavad PR-i."

No duplicate issue is created for these entries.

## Ack subcommand

Args: `ack <slug>` (or `ack-all` — see next section)

**Invocation contract:** this helper MUST be run inside the branch/PR that contains the code fix. It updates registry state; those changes must be committed together with the code changes so the merge is atomic.

Behaviour:

```bash
: "${DATALAKE_URL:=https://datalake.r-53.com}"
SLUG="$1"
[ -n "$SLUG" ] || { echo "Error: slug required"; exit 1; }

entry=$(jq -r --arg s "$SLUG" '.entries[$s] // empty' .startup/law-registry.json)
[ -n "$entry" ] || { echo "Error: no registry entry for '$SLUG'"; exit 1; }

act_id=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' .startup/law-registry.json)
paragraph=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.paragraph // ""' .startup/law-registry.json)
section=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.section // ""' .startup/law-registry.json)
point=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.point // ""' .startup/law-registry.json)

cite_url="$DATALAKE_URL/api/v1/laws/${act_id}/citation?paragraph=${paragraph}"
[ -n "$section" ] && cite_url="${cite_url}&section=${section}"
[ -n "$point" ] && cite_url="${cite_url}&point=${point}"

resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$cite_url")
text=$(echo "$resp" | jq -r '.text // empty')
cite_url_resp=$(echo "$resp" | jq -r '.url // empty')
red=""
if [ -n "$cite_url_resp" ]; then
  tail_seg="${cite_url_resp##*/akt/}"
  red="${tail_seg%%[!0-9]*}"
fi
[ -n "$text" ] || { echo "Error: datalake returned empty text for act_id=$act_id paragraph=$paragraph"; exit 1; }

normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')
printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg slug "$SLUG" --arg now "$NOW" --arg red "$red" --arg rturl "$cite_url_resp" '
  .entries[$slug].needs_review = false
  | .entries[$slug].change = null
  | .entries[$slug].change_detected_at = null
  | .entries[$slug].verified_at = $now
  | .entries[$slug].redaktsioon_id = (if $red == "" then null else $red end)
  | .entries[$slug].rt_url = (if $rturl == "" then .entries[$slug].rt_url else $rturl end)
' .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

echo "Ack: $SLUG — snapshot refreshed, flags cleared."
echo "Remember to commit both .startup/law-registry.json and .startup/laws/${SLUG}.txt in this PR alongside your code changes."
exit 0
```

`gh_issue_url` is preserved through ack as the permanent link to the issue that tracked this change.

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

: "${DATALAKE_URL:=https://datalake.r-53.com}"
while IFS= read -r SLUG; do
  [ -z "$SLUG" ] && continue
  echo "Ack-ing: $SLUG"

  act_id=$(jq -r --arg s "$SLUG" '.entries[$s].act_id' .startup/law-registry.json)
  paragraph=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.paragraph // ""' .startup/law-registry.json)
  section=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.section // ""' .startup/law-registry.json)
  point=$(jq -r --arg s "$SLUG" '.entries[$s].citation_parts.point // ""' .startup/law-registry.json)

  cite_url="$DATALAKE_URL/api/v1/laws/${act_id}/citation?paragraph=${paragraph}"
  [ -n "$section" ] && cite_url="${cite_url}&section=${section}"
  [ -n "$point" ] && cite_url="${cite_url}&point=${point}"

  resp=$(curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$cite_url")
  text=$(echo "$resp" | jq -r '.text // empty')
  cite_url_resp=$(echo "$resp" | jq -r '.url // empty')
  red=""
  if [ -n "$cite_url_resp" ]; then
    tail_seg="${cite_url_resp##*/akt/}"
    red="${tail_seg%%[!0-9]*}"
  fi
  if [ -z "$text" ]; then
    echo "Error: datalake returned empty text for act_id=$act_id paragraph=$paragraph — skipping $SLUG"
    continue
  fi

  normalised=$(printf '%s' "$text" | python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))')
  printf '%s\n' "$normalised" > ".startup/laws/${SLUG}.txt"

  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg slug "$SLUG" --arg now "$NOW" --arg red "$red" --arg rturl "$cite_url_resp" '
    .entries[$slug].needs_review = false
    | .entries[$slug].change = null
    | .entries[$slug].change_detected_at = null
    | .entries[$slug].verified_at = $now
    | .entries[$slug].redaktsioon_id = (if $red == "" then null else $red end)
    | .entries[$slug].rt_url = (if $rturl == "" then .entries[$slug].rt_url else $rturl end)
  ' .startup/law-registry.json > .startup/law-registry.json.tmp
  mv .startup/law-registry.json.tmp .startup/law-registry.json
done <<< "$FLAGGED"

echo "Ack-all complete. Remember to commit .startup/law-registry.json and .startup/laws/*.txt in this PR alongside your code changes."
exit 0
```

## Issue subcommand

Args: `issue <slug>`

Non-interactive Disposition A for one slug. Used by agents or in scripts that don't have an investor to prompt.

Requires: entry has `needs_review=true` AND `gh_issue_url=null`. Otherwise, no-op with a message.

Behaviour: identical to step 3 of the Confirmation flow (Task 11), but scoped to a single slug and without the AskUserQuestion prompt. Preserves the rule that registry and `.txt` are not touched here — only `gh_issue_url` is set.

```bash
SLUG="$1"
[ -n "$SLUG" ] || { echo "Error: slug required"; exit 1; }

entry=$(jq -r --arg s "$SLUG" '.entries[$s] // empty' .startup/law-registry.json)
[ -n "$entry" ] || { echo "Error: no registry entry for '$SLUG'"; exit 1; }

needs_review=$(jq -r --arg s "$SLUG" '.entries[$s].needs_review' .startup/law-registry.json)
gh_issue_url=$(jq -r --arg s "$SLUG" '.entries[$s].gh_issue_url // empty' .startup/law-registry.json)

if [ "$needs_review" != "true" ]; then
  echo "No-op: '$SLUG' does not have needs_review=true."
  exit 0
fi
if [ -n "$gh_issue_url" ]; then
  echo "No-op: '$SLUG' already has an open issue: $gh_issue_url"
  exit 0
fi

# Same as Confirmation flow Step 3b–3d, scoped to this slug
TMP=$(mktemp -d)
citation=$(jq -r --arg s "$SLUG" '.entries[$s].citation' .startup/law-registry.json)

# Build minimal issue body (no fix-plan doc available in non-interactive mode)
cat > "$TMP/${SLUG}-issue-body.md" <<ISSUEBODY
Seadusemuudatus tuvastatud: ${citation} (${SLUG})

Palun vaata muudatus üle ja uuenda vastavat koodiosa.
Pärast parandamist käivita PR-i harul:

    /lawyer ack ${SLUG}
ISSUEBODY

if ! issue_url=$(gh issue create \
  --title "Seadusemuudatus: ${citation} — ${SLUG}" \
  --label "legal-review,seadusemuudatus" \
  --body-file "$TMP/${SLUG}-issue-body.md" 2>"$TMP/gh-err"); then
  echo "Error: gh issue create failed for '${SLUG}':"
  cat "$TMP/gh-err"
  echo "  Slug remains flagged; gh_issue_url left null. Fix the gh problem and retry."
  exit 1
fi

jq --arg slug "$SLUG" --arg url "$issue_url" \
  '.entries[$slug].gh_issue_url = $url' \
  .startup/law-registry.json > .startup/law-registry.json.tmp
mv .startup/law-registry.json.tmp .startup/law-registry.json

echo "Issue created: $issue_url"
exit 0
```

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

## Check subcommand

Args: `check`

Runs the Change Detection step and exits. Does NOT prompt, does NOT create issues, does NOT spawn the agent. After this returns, any new flags are persisted and the investor can run `/lawyer status` to see them.

The body is the full Change Detection logic inlined — prose reference alone would run as a bash comment and silently no-op (same failure mode caught in the ack-all fixup).

```bash
: "${DATALAKE_URL:=https://datalake.r-53.com}"
[ -f .startup/law-registry.json ] || echo '{"version":2,"last_feed_check_at":null,"entries":{}}' > .startup/law-registry.json

RT_IDS=$(jq -r '.entries | to_entries[] | .value.rt_id // empty' .startup/law-registry.json | sort -u)

if [ -z "$RT_IDS" ]; then
  echo "Registry is empty; nothing to check."
else
  SINCE=$(jq -r '.last_feed_check_at // ""' .startup/law-registry.json)
  if [ -z "$SINCE" ]; then
    SINCE=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  fi

  feed_url="$DATALAKE_URL/api/v1/changes/feed?since=${SINCE}&limit=500"
  resp=$(curl --max-time 30 -s -w '\n%{http_code}' -H "X-API-Key: $EST_DATALAKE_API_KEY" "$feed_url")
  body=$(printf '%s' "$resp" | sed '$d')
  code=$(printf '%s' "$resp" | tail -n1)

  FEED_OK=1
  if [ "$code" != "200" ]; then
    echo "⚠ Seaduste muudatuste kontroll ebaõnnestus ($code) — vaata üle käsitsi"
    FEED_OK=0
    events='[]'
  else
    events=$(echo "$body" | jq '.items // []')
  fi

  rt_ids_json=$(printf '%s\n' "$RT_IDS" | jq -R . | jq -s .)
  matched=$(echo "$events" | jq --argjson rts "$rt_ids_json" '[.[] | select(.rt_id as $r | $rts | index($r))]')

  updated=$(jq --argjson matched "$matched" '
    reduce ($matched[]) as $e (.;
      .entries |= with_entries(
        if .value.rt_id == $e.rt_id then
          .value.needs_review = true
          | .value.change_detected_at = $e.detected_at
          | .value.change = {
              feed_event_id: $e.id,
              type: $e.change_type,
              summary: $e.description,
              effective_date: $e.effective_date
            }
        else . end
      )
    )
  ' .startup/law-registry.json)

  if [ "$FEED_OK" = "1" ]; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$updated" | jq --arg now "$NOW" '.last_feed_check_at = $now' > .startup/law-registry.json
  else
    echo "$updated" > .startup/law-registry.json
  fi
fi

echo "Feed check complete."
echo "Run /lawyer status to see flagged entries, or /lawyer <topic> to trigger the fix-plan prompt."
exit 0
```

## Execution

### Step 0: Reset active_role

Overwrite `active_role` in `.startup/state.json` before spawning the Lawyer. The `enforce-delegation` hook fires only when `active_role=="team-lead"`; a stale value from a prior `/startup` session would otherwise block the Lawyer's writes. `/lawyer` is never a team-lead context.

```bash
if [ -f .startup/state.json ]; then
  jq '.active_role = "lawyer"' .startup/state.json \
    > .startup/state.json.tmp && mv .startup/state.json.tmp .startup/state.json
fi
```

### Step 1: Load Lawyer Skill

```
Skill('saas-startup-team:lawyer')
```

### Step 2: Gather Project Context

Read the following files to build context for the Lawyer:
1. `docs/business/brief.md` — what SaaS is being built
2. `.startup/state.json` — current project phase and iteration
3. Latest files in `docs/` — research, legal, architecture docs
4. Latest handoff in `.startup/handoffs/` — current state of implementation

### Step 3: Spawn Lawyer Agent

Use `Task` tool to spawn the Lawyer as a one-shot agent:

Pass the following to the Lawyer agent:
- The investor's topic/question (from the command arguments)
- Project context summary (from Step 2)
- Reminder: write analysis to `docs/legal/õiguslik-*.md` in Estonian
- Reminder: query datalake API first, web search second
- Reminder: include disclaimers and cite all sources

### Step 4: Report to Investor

After the Lawyer completes, summarize the findings for the investor in English:
- Which analysis documents were written
- Key risk findings (high/medium/low)
- Any human tasks identified (e.g., "hire a lawyer for DPA review")
- Where to find the full analysis: `docs/legal/õiguslik-*.md`
