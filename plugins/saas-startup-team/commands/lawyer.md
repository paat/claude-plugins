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
