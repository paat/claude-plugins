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

If `.startup/law-registry.json` exists, it must be valid JSON with `version: 1`. Missing file is fine — the command creates it on first use.

```bash
if [ -f .startup/law-registry.json ]; then
  jq -e '.version == 1' .startup/law-registry.json >/dev/null 2>&1
fi
```

**If non-zero exit:**
> **Error:** `.startup/law-registry.json` is not valid JSON or is not version 1 (expected `{"version": 1, ...}`). Fix or remove the file before running /lawyer again.

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
# Use bare jq (no -r) so the output is a JSON scalar — either a quoted string
# like "104052024010/1" or the literal null — which --argjson can consume.
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

### Step 3: Run the Marker Scan and stash results

```bash
# Output format: <slug>\t<file>:<line>
# Run the Marker Scan logic above and redirect its output to "$TMP/markers.tsv"
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

```bash
issue_url=$(gh issue create \
  --title "Seadusemuudatus: ${citation} — ${slug}" \
  --label "legal-review,seadusemuudatus" \
  --body-file "$TMP/${slug}-issue-body.md" \
  2>&1)
```

#### Step 3d: Store the issue URL

Parse the issue URL (gh prints it on stdout). Store it on the entry — write only `gh_issue_url`; leave all other fields untouched:

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

issue_url=$(gh issue create \
  --title "Seadusemuudatus: ${citation} — ${SLUG}" \
  --label "legal-review,seadusemuudatus" \
  --body-file "$TMP/${SLUG}-issue-body.md" \
  2>&1)

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

Runs the Change Detection step (Task 8) and exits. Does NOT prompt, does NOT create issues, does NOT spawn the agent. After this returns, any new flags are persisted and the investor can run `/lawyer status` to see them.

```bash
# The change-detection block from the "Change Detection" section above,
# followed by:
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
