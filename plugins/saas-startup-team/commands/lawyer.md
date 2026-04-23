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
