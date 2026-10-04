# Lawyer Law Registry Design

**Date:** 2026-04-23
**Status:** Draft
**Supersedes:** Nothing; extends the 2026-02-25 Lawyer design.

## Problem

The current Lawyer agent re-queries Riigi Teataja and the est-saas-datalake on every
`/lawyer` run. Two recurring failure modes:

1. **Stale redaction reads.** The lawyer can land on an outdated paragraph text —
   either cached, superseded, or the wrong redaktsioon — and build analysis on it.
2. **Blind impact radius.** When a law changes, nothing tells the founder which
   lines of code, which customer-facing pages, or which ToS clauses depend on that
   paragraph. Each change triggers a full re-audit from scratch.

## Goal

Give each SaaS project a project-local **law registry**: a pinned list of the
specific legal paragraphs its code, customer-facing pages, and customer-facing
documents depend on. When any registered law changes, the lawyer detects it on its
next invocation, halts its normal work, and surfaces a concrete review list
(law → affected files).

## Non-Goals

- Continuous background monitoring. Detection is pull-based, on `/lawyer` invocation.
- Tracking law dependencies for internal analysis documents (`docs/legal/õiguslik-*.md`).
  Those are dated snapshots; re-run if stale.
- Tracking laws referenced in externally-hosted customer content (CMS, Crisp,
  Intercom). Known limitation — listed in Open Questions.
- Locking the registry file against concurrent writes. Same race risk that
  `.startup/state.json` already has; not solved here.

## Architecture

```
/lawyer <topic>
   │
   ▼
commands/lawyer.md  (pre-flight + subcommand dispatch)
   │
   ├─→ Pre-flight: datalake reachable, API key, project present
   │
   ├─→ Load .startup/law-registry.json (create if missing)
   │
   ├─→ FEED CHECK (if registry has entries):
   │     query /changes/feed per unique domain since last_feed_check_at
   │     filter events to registered act_ids
   │     mark matched entries: needs_review=true, change_detected_at, change={…}
   │     always advance last_feed_check_at
   │
   ├─→ If ANY entry has needs_review=true:
   │     write docs/legal/õiguslik-muudatused-YYYY-MM-DD.md
   │     (append new section if file exists)
   │     print terminal alert with affected files from marker grep
   │     EXIT — do NOT spawn analysis agent for user's topic
   │
   └─→ Else: dispatch subcommand or spawn Lawyer agent for user's topic
```

The registry is a **single source of truth** stored at
`.startup/law-registry.json`. Source files (code, customer-facing pages,
ToS/privacy docs in the repo) reference the registry only through comment
markers. Grepping the markers at check time is cheap and always-current — no
separate denormalised "affected files" list to go stale.

### Where law content lives

Storage is split across two locations to keep the metadata index small enough
to read in full without loading dozens of pages of legal prose into context:

- **Metadata index — `.startup/law-registry.json`.** All per-entry metadata
  (act_id, citation, domain, flags, timestamps, purpose) plus global state
  (`last_feed_check_at`). ~150–250 bytes per entry; a 100-entry project is
  roughly 20 KB. Safe to read in full on every `/lawyer` run.
- **Paragraph snapshots — `.startup/laws/<slug>.txt`.** One file per entry,
  containing the normalised paragraph text at last verification. Loaded only
  when the lawyer needs that specific slug's text (diff during change
  detection render, alert-doc generation, ack).

What's stored and what isn't:

- **Stored in the project:** per-entry metadata plus the normalised text of
  each registered paragraph, at its last-verified redaktsioon. One paragraph
  per `.txt` file.
- **Not stored in the project:** full law acts, other paragraphs of the same
  act that the product does not depend on, pre-amendment history, court
  decisions, RAG citations. Those remain in the datalake and are fetched on
  demand.

When the lawyer needs the *current* paragraph text (e.g. during change
detection or ack), it calls `/laws/{act_id}/citation` on the datalake.
The `.txt` snapshot is kept only as the diff baseline and forensics
reference — "this is what the paragraph said when we wired it into the
product."

The index JSON is the authoritative registry of which laws are in scope; the
`.txt` files are addressable by slug and always derived from it. Unregistering
a slug deletes both the JSON entry and its `.txt` file atomically (see
Registration Flow).

## Data Model

### File: `.startup/law-registry.json` (index)

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
      "redaktsioon_id": "104052024010/1",
      "registered_at": "2026-04-01T09:00:00Z",
      "verified_at": "2026-04-20T14:00:00Z",
      "registered_by": "lawyer",
      "purpose": "Lawful basis for processing signup-confirmation emails",
      "needs_review": false,
      "change_detected_at": null,
      "change": null
    }
  }
}
```

### File: `.startup/laws/<slug>.txt` (paragraph snapshot)

Plain text, normalised (trim + NFC Unicode), one file per registered slug.
The filename is exactly `<slug>.txt`; slugs are kebab-case `[a-z0-9-]+` so
they are filesystem-safe. Example `.startup/laws/consent-lawful-basis.txt`:

```
Isikuandmete töötlemine on lubatud …
```

One paragraph per file. No frontmatter, no metadata — all of that lives in
the index JSON. The file is the *last-verified* text of the paragraph and is
refreshed on registration and on ack.

### Index fields

| Field | Type | Notes |
|---|---|---|
| `version` | int | Schema version. Starts at `1`. Incremented only for breaking changes. |
| `last_feed_check_at` | ISO-8601 | Advanced on every successful feed query, independent of whether changes were detected. |
| `entries` | object | Keyed by slug (kebab-case, `[a-z0-9-]+`). Slug is what marker comments and `.txt` filenames both reference. |

### Entry fields (in index)

| Field | Type | Notes |
|---|---|---|
| `act_id` | string | Datalake act identifier (the form accepted by `/laws/{act_id}/citation`). |
| `act_title` | string | Human-readable act title in Estonian. Denormalised for readability. |
| `citation` | string | Estonian-style reference (`"§ 10 lõige 2 punkt 3"`). Stored as the form a human would recognise; the lawyer normalises it for the API call at registration and verification time. |
| `domain` | string | One of the datalake `/changes/feed` domains (e.g. `"Data Protection"`, `"Labor"`, `"Tax"`, `"Commercial"`). Used to decide which feeds to poll. |
| `rt_url` | string | Riigi Teataja URL for the act. For investor-facing links. |
| `redaktsioon_id` | string \| null | RT redaktsioon ID if the datalake exposes one on the citation endpoint. Optional; when present, enables cheap equality as a precision adjunct in the future. |
| `registered_at` | ISO-8601 | When the entry was first added. |
| `verified_at` | ISO-8601 | When the text was last confirmed against the datalake (registration or ack). |
| `registered_by` | string | `"lawyer"`, `"tech-founder"`, `"business-founder"`. Informational. |
| `purpose` | string | One-line description of why this paragraph is load-bearing. Free-form — source markers carry the per-site context. |
| `needs_review` | bool | **Work-pending flag.** `true` means the feed has reported a change that is not yet reflected in the `.txt` snapshot or in the code. Cleared by `ack`, which is called inside the PR that ships the code fix. Interaction with `gh_issue_url`: while `needs_review=true` AND `gh_issue_url=null`, /lawyer blocks analysis and prompts. Once `gh_issue_url` is set, /lawyer proceeds with a reminder — the fix is tracked elsewhere. |
| `change_detected_at` | ISO-8601 \| null | When the feed reported the change. Cleared by `ack`. |
| `change` | object \| null | `{feed_event_id, type, summary}`. `type` is `"amended" \| "repealed" \| "replaced" \| "other"`. Cleared by `ack`. The timestamp lives on `change_detected_at`. |
| `gh_issue_url` | string \| null | Set when the investor confirms "Jah, loo issue". Preserved through `ack` as the permanent link to the GitHub issue that tracked this change. Pure reference — registry never reads the issue back; it only points at it. |

### Invariant: index ↔ snapshot files

For every slug `X` in `entries`, a file `.startup/laws/X.txt` MUST exist, and
no orphan `.txt` file may exist without a matching index entry. All writes
that touch one must also touch the other:

- **register** writes the index entry and the `.txt` file.
- **unregister** deletes the `.txt` file and removes the index entry.
- **ack** updates the `.txt` file content, bumps `verified_at`, clears the
  review flags — all in one operation.

Invariant violations (orphan files, missing files) are surfaced as
non-blocking warnings on every `/lawyer` run, same as orphan markers.

## Source Markers

### Marker syntax

A marker is any comment containing the token `LAW:` followed by one or more
registry slugs.

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

### Scan rule

A marker is recognised only when `LAW:` is preceded on the same line by a
comment-opener from `{ //, #, /*, <!--, {/* }`. This avoids false positives on
prose that happens to contain the word "LAW:".

Scan regex (Perl-compatible):

```
(?://|#|/\*|<!--|\{/\*)\s*LAW:\s*([a-z0-9-]+(?:\s*,\s*[a-z0-9-]+)*)
```

Multiple slugs per marker are comma-separated. The scan tool deduplicates
slugs and produces a `slug -> [file:line, …]` map.

### Scope of scanning

The lawyer greps these directories for markers (adjust per project as needed):
`src/`, `app/`, `pages/`, `components/`, `lib/`, `server/`, `public/`,
`content/`, `docs/` (excluding `docs/legal/`).

### Orphaned markers and orphaned entries

- **Marker referencing a slug not in the registry** → non-blocking warning on
  every `/lawyer` run: "Marker `LAW: foo` at src/x.ts:42 references unknown
  registry slug. Register with `/lawyer register foo …` or remove the marker."
- **Registry entry with zero markers** → non-blocking warning: "Entry `foo`
  has no markers in source. Remove with `/lawyer unregister foo` if no longer
  load-bearing."

## Change Detection Flow

Runs at the start of every `/lawyer` invocation, before any subcommand dispatch.
This step reads ONLY the index (`.startup/law-registry.json`), never the per-slug
`.txt` snapshot files — those are pulled later only for entries that get flagged.

```
1. Read .startup/law-registry.json (index only). If missing, create empty
   file with {version:1, last_feed_check_at:null, entries:{}} and skip to step 8.
2. If index.entries is empty, skip to step 8.
3. Compute unique set D of entry.domain values from the index.
4. Compute unique set A of entry.act_id values from the index.
5. For each domain d in D:
     curl --max-time 30 GET /changes/feed?domain=d&since=<last_feed_check_at>
     (if last_feed_check_at is null, cap `since` at now-90d)
6. Collect feed events whose act_id is in A.
7. For each matched event E:
     for each index entry e with e.act_id == E.act_id:
       e.needs_review = true
       e.change_detected_at = E.timestamp
       e.change = { feed_event_id: E.id, type: E.type, summary: E.summary }
8. If all feed queries succeeded, advance index.last_feed_check_at = now
   (independent of whether changes were detected — detection is recorded per
   entry, not in the global timestamp).
9. Persist index JSON. Do NOT touch any .txt file in this step.
```

### Feed unreachable

If any `/changes/feed` call returns a non-2xx or times out: **soft warn, continue**.
Print a prominent warning "⚠ Seaduste muudatuste kontroll ebaõnnestus — vaata üle
käsitsi" and proceed to the subcommand. Do NOT advance `last_feed_check_at` when
any query failed, so the next run re-attempts the same window.

### Feed returns partial information

If the feed reports a change at act-level only (no paragraph metadata), every
registered entry for that act_id is marked `needs_review`. Acceptable false
positive — the human review decides per-paragraph relevance.

## Fix-Plan and Confirmation Flow

After change detection runs, if any entry has `needs_review == true` (whether
newly flagged this run or pending from a prior run):

1. **Command body does NOT proceed with the user's requested topic.** Instead
   it spawns the Lawyer agent with a specific brief: "changes have been
   detected on slugs [...]; produce a plain-language fix plan and ask the
   investor how to proceed."
2. **The Lawyer agent, for each flagged slug, loads both old and new paragraph text:**
   - Old text: read `.startup/laws/<slug>.txt` (the last-verified snapshot).
   - New text: `curl --max-time 30 GET /laws/{act_id}/citation?paragraph=…`
     against the datalake. Normalise (trim + NFC). This is ONE additional API
     call per flagged entry — not per entry overall. Do NOT overwrite the
     `.txt` file yet; the snapshot is only refreshed at confirmation time.
   - If the new-text fetch fails (non-2xx or timeout), continue with a
     placeholder "⚠ uut teksti ei õnnestunud laadida — kontrolli käsitsi"
     instead of the new-text block; the fix plan will be less precise but
     not absent.
3. **The Lawyer agent reads the affected source files** (from the marker grep),
   understands how each site uses the paragraph, and synthesises a
   **plain-language fix plan** per file. The fix plan describes what needs to
   change in product terms, not legal terms — the investor is explicitly not
   expected to read the legal diff to understand what to do.
4. **Write/append the review document** at
   `docs/legal/õiguslik-muudatused-YYYY-MM-DD.md`. If the file exists, append a
   new section with the current timestamp. Structure (fix plan first, legal
   diff as appendix):

   ```markdown
   # Seadusemuudatused — YYYY-MM-DD

   > ⚠ See on AI-põhine hoiatus, mitte õigusnõu.

   ## Muudatuste kokkuvõte

   | Slug | Seadus | Tüüp | Avastatud | Mõjutatud failid |
   |------|--------|------|-----------|------------------|
   | consent-lawful-basis | Isikuandmete kaitse seadus § 10 lõige 2 | amended | 2026-04-21 | 3 |

   ## Mida tuleb teha

   ### consent-lawful-basis — Keskmine

   Lühidalt: § 10 lõige 2 lisas uue kohustuse andmetöötleja teavitamiseks
   andmesubjekti nõusoleku muutumisest. Praegune voog ainult salvestab
   nõusoleku, aga ei saada teavitust töötlejale.

   **Parandused failide kaupa:**

   - `src/auth/consent.ts:42` — `recordConsent()` järele lisa kutse
     `notifyProcessor(consentChange)`. Funktsioon `notifyProcessor` on vaja
     kirjutada (pakuti välja `src/auth/processor-notify.ts`).
   - `app/privacy/page.tsx:18` — uuenda loetelu "Mida me andmetega teeme"
     nii, et see nimetab töötleja teavitust, kui nõusolek muutub.
   - `docs/customer/privacy.md:10` — sama muudatus avalikus privaatsuspoliitikas,
     sõnastus sama mis app/privacy/page.tsx.

   ## Lisa — õiguslik detail (audit trail)

   <details>
   <summary>§ 10 lõige 2 — eelmine vs. uus tekst</summary>

   **Eelmine tekst (salvestatud `verified_at`-ga 2026-04-20):**
   > Isikuandmete töötlemine on lubatud …

   **Uus tekst (datalake, 2026-04-23):**
   > Isikuandmete töötlemine on lubatud ning töötlejal on kohustus …

   ```diff
   - Isikuandmete töötlemine on lubatud …
   + Isikuandmete töötlemine on lubatud ning töötlejal on kohustus …
   ```
   </details>
   ```

5. **Ask the investor interactively** via `AskUserQuestion` (in the command
   body, in the same run — no /lawyer re-invocation required):

   ```
   Seadusemuudatus avastatud — 1 kirje (consent-lawful-basis § 10 lõige 2).
   Täielik parandusplaan: docs/legal/õiguslik-muudatused-2026-04-23.md

   Kas luua GitHubi issue koos parandusplaaniga?

     [1] Jah, loo issue        (soovitatud)
     [2] Ei, jäta hiljemaks
   ```

6. **Handle the answer** (see Confirmation Flow below). Registry and `.txt`
   are NOT touched yet in either branch — those updates happen in the PR that
   ships the code fix, not here.

### Risk level heuristic for the alert doc

| Feed event type | Default risk level |
|---|---|
| `repealed` | Kõrge |
| `replaced` | Kõrge |
| `amended` | Keskmine |
| `other` | Madal |

The lawyer MAY upgrade a risk level based on context but MUST NOT downgrade.

## Registration Flow

Two paths register an entry.

### Path A — lawyer-initiated (during analysis)

When the Lawyer agent produces an analysis that cites a paragraph the product
depends on, it registers an entry as part of the analysis output:

1. Pick a kebab-case slug (clear, short, domain-meaningful).
2. Look up `(act_id, citation)` in the index — if an entry already exists under
   a different slug, reuse it; do not create a duplicate.
3. Fetch current paragraph text: `GET /laws/{act_id}/citation?paragraph=<normalised>`.
4. Normalise text (trim + NFC).
5. Write `.startup/laws/<slug>.txt` with the normalised text.
6. Write the index entry to `.startup/law-registry.json` with `verified_at=now`,
   `registered_by="lawyer"`, flags cleared.
7. In the analysis doc, instruct: *"Lisa marker koodi / sisusse: `LAW: <slug>`"*
   with suggested locations.

### Path B — marker-first (founder-initiated)

A tech or business founder adds `// LAW: <new-slug>` in code while implementing
a feature whose correctness depends on a specific law:

1. On next `/lawyer` run, the marker scan finds `<new-slug>` with no registry
   entry.
2. The Lawyer agent, given the surrounding code/comment context and the
   founder's original handoff, attempts to identify which Estonian law the
   marker refers to (datalake RAG + `/laws/search`). When confident, it
   registers the entry automatically (internal call to the `register` helper).
3. When not confident, the Lawyer surfaces the unresolved orphan in its run
   output and asks the investor — in the next `/lawyer` topic — to provide
   enough context to resolve it (e.g. "the consent check in auth/consent.ts
   is based on § 10 of IKS").

### Explicit helper subcommand

`/lawyer register <slug> <act_id> <citation> <purpose>` is the internal helper
that Paths A and B call through. It is not part of investor UX; it exists so
the command body has a deterministic entry point callable from bash.

- Idempotent on `(act_id, citation)`: if an entry with that pair exists, print
  its current slug and exit without creating a new entry.
- Fails hard if the citation endpoint returns 404 or the response is empty.
  Neither the index entry nor the `.txt` file is created on failure — registry
  is not polluted with placeholder entries.
- On success, writes the `.txt` snapshot file first, then the index entry. If
  a crash happens between, a re-run sees the orphan `.txt` (warning) and the
  next registration attempt recovers.

## Confirmation Flow

Confirmation happens in the **same run** as detection, via an
`AskUserQuestion` prompt from the command body. The investor answers once;
the flow continues without needing a /lawyer re-invocation. There are only
two answers — there is no manual-handling escape hatch. Registry and `.txt`
updates never happen at confirmation time; they are owned by the PR that
fixes the code (see Fix Implementation below).

### Disposition A — "Jah, loo issue" (investor confirms)

**Command body actions, per currently-flagged entry:**

1. Compose issue body from the review doc's "Mida tuleb teha" section for
   that slug (the plain-language fix plan, not the legal appendix) plus a
   trailing block titled "Registri värskendus PR-s" that lists the exact
   changes the PR must also include (see Fix Implementation).
2. `gh issue create --title "Seadusemuudatus: <citation> — <slug>" \
   --label "legal-review,seadusemuudatus" --body "$BODY"`.
3. Capture the issue URL from `gh`'s stdout.
4. On the index entry: set `gh_issue_url=<url>`. Do NOT touch
   `needs_review`, `change`, `change_detected_at`, `verified_at`, or the
   `.txt` file. Those remain as detection left them.
5. Persist index.

After all flagged entries are issued, the run **proceeds with the
investor's original topic** — issue creation is a sufficient acknowledgement
for analysis to continue. The topic analysis receives the list of flagged
slugs as context so it can note in its output "pending legal fixes tracked
in #123, #124".

### Disposition B — "Ei, jäta hiljemaks" (investor declines)

- No `gh` call. Registry and `.txt` untouched. `needs_review` stays `true`,
  `gh_issue_url` stays `null`.
- Run exits without running the requested topic.
- Next /lawyer run will re-prompt.

### Hard dependency on `gh`

Because there is no manual-handling path, `gh issue create` must succeed for
flagged entries to be acknowledged. The command's pre-flight therefore adds
a conditional check: **only when any entry has `needs_review=true` AND
`gh_issue_url=null`**, verify `gh auth status` passes and
`gh repo view --json nameWithOwner` returns a result. On failure, hard-fail
with:

> **Error:** /lawyer detected pending legal changes that need GitHub issues,
> but `gh` is unavailable (<reason>). Install and authenticate the `gh` CLI,
> or ensure this repo has a GitHub remote. There is no manual-handling
> fallback — registry coherence requires that each change be tracked in an
> issue and fixed via a PR.

For projects that are never going to use GitHub, the whole registry
workflow is unusable. Documented as a known limitation below.

### Re-detection while an issue is already open

If, on a later /lawyer run, the feed reports a NEW change for an entry
that already has `gh_issue_url` set (i.e. a second amendment arrived before
the first PR landed):

- Update `change` and `change_detected_at` to the latest event.
- Do NOT create a second issue.
- Surface a reminder: "Issue #N is still open for this slug; lisa kommentaar
  uue muudatuse kohta."
- Proceed with the topic (the existing issue is already acknowledgement).

### Why `.txt` is NOT overwritten at confirmation

The `.txt` snapshot represents the *last-known-good* text the product is
aligned with. If we overwrote it at confirmation time, the source of truth
would briefly diverge from the code (code still references the old redaktsioon
semantics until the PR ships). The user's invariant — "logic, information on
pages, and source of truth must be coherent" — requires `.txt` refresh to
happen atomically with the code fix. That's done in the PR, not here.

## Fix Implementation (owned by the PR)

The GitHub issue contains a plain-language fix plan. Whoever implements it
(tech founder agent via /improve, or a human) must ship these changes in a
**single PR**:

1. **Code / copy changes** per the fix plan — the files listed under each
   entry in the review doc.
2. **Registry snapshot update** — overwrite `.startup/laws/<slug>.txt` with
   the new normalised paragraph text (fetched via
   `/laws/{act_id}/citation`).
3. **Registry index update** — on the index entry: clear `needs_review`,
   clear `change`, clear `change_detected_at`, set `verified_at=now`,
   update `redaktsioon_id` if present. `gh_issue_url` is preserved
   (it's the historical link to the issue this PR closed).

Step 2 and 3 are what the `/lawyer ack <slug>` helper does mechanically.
The tech founder agent is expected to run it as the last step of its work
inside the branch, before committing. Bash only — no analysis re-run.

All three items land in the same commit (or at least in the same PR), so
the merge is atomic with respect to registry coherence: before merge, code
references old semantics and `.txt` holds old text; after merge, both are
new. There is never a window where the repository is internally
inconsistent.

### Helper subcommands (internal plumbing)

The command file exposes the mechanical operations as helpers. None of them
is part of investor UX; they're called by the Lawyer agent, by other
agents, or in scripts:

- `/lawyer ack <slug>` — Fix Implementation steps 2+3 for one slug. Must be
  called inside the branch that contains the code fix. Fetches new text,
  overwrites `.txt`, updates index.
- `/lawyer ack-all` — `ack` applied to every slug with `needs_review=true`.
  Use with care — only correct if the PR's code changes cover every flagged
  slug.
- `/lawyer issue <slug>` — Disposition A for one slug, skipping the
  interactive prompt. For agent use.
- `/lawyer status` — print registry state: total entries, flagged entries,
  entries with open gh issues, last feed check.
- `/lawyer check` — run feed re-check without producing fix plans or
  prompts. For scripting.
- `/lawyer register ...`, `/lawyer unregister <slug>` — registration and
  removal.

## Command Surface

### Investor-facing UX

The investor interacts with only one form:

```
/lawyer <free-form topic, Estonian or English>
```

Everything — analysis requests, asking for registry status, asking for a
change re-check — is expressed inside the topic string. The Lawyer agent
interprets intent. Example topics:

- `analyze our ToS for GDPR gaps`
- `what's in the law registry?`
- `recheck for law changes`
- `register § 10 lõige 2 of the Data Protection Act — we use it for signup consent`

When a change is detected mid-run, the command body prompts the investor
interactively via `AskUserQuestion` with two options: *"Jah, loo issue"* /
*"Ei, jäta hiljemaks"*. The investor answers once; the flow continues in the
same run. Re-invocation is not required. The investor is never expected to
type subcommand tokens like `ack` or `register`.

### Agent-facing helpers (internal plumbing)

The command file also dispatches a set of explicit subcommands used by
agents (the lawyer itself, or founder agents invoking the command
programmatically) and by anyone who wants scriptable, deterministic calls:

```
/lawyer register <slug> <act_id> <citation> <purpose>
                                        — register an entry (idempotent by (act,citation))
/lawyer unregister <slug>               — remove an entry
/lawyer ack <slug> [<slug> …]           — Fix Implementation: refresh .txt + clear flags.
                                          Must be called inside the PR branch that contains
                                          the code fix.
/lawyer ack-all                         — ack every currently flagged slug (use only if
                                          the PR's code changes cover all of them)
/lawyer issue <slug>                    — create a GitHub issue for one slug (non-interactive)
/lawyer status                          — print registry state
/lawyer check                           — run feed re-check without prompting or analysis
```

These are helpers, not the primary UX. They are not documented in
investor-facing help text. Agents call them via bash; humans may call them
if they want precise control, but nothing in the normal flow requires it.

### Subcommand vs. topic disambiguation

If `args[0]` matches the literal keyword set
`{register, unregister, ack, ack-all, issue, status, check}`, treat as a subcommand;
otherwise treat the full `args` as a free-form topic for the Lawyer agent.

Free-form topics are very unlikely to begin with those exact tokens. If they
ever do, quoting (`/lawyer "register a user account — is this GDPR-compliant?"`)
disambiguates.

### Subcommand execution model

- `status`, `ack`, `ack-all`, `register`, `unregister` — run directly in the
  command body (bash + jq). No agent spawn. Fast.
- `check` — runs the change-detection flow then exits; no agent spawn.
- free-form topic — runs the change-detection flow; if clean (or if the topic
  itself contains ack phrasing that clears the flags), spawns the Lawyer
  agent with the topic.

### Updated pre-flight checks

The existing three pre-flight checks (datalake reachable, API key present,
startup project present) remain unchanged. Added:

- If `.startup/law-registry.json` exists, verify it parses as valid JSON and
  has `version == 1`. On parse failure, hard-fail with an error telling the
  user which line is broken. Do not overwrite on parse failure.
- If `.startup/laws/` exists, verify it is a directory. On a surprise file at
  that path, hard-fail.
- Index ↔ snapshot invariant check is deferred to the change-detection step
  (surfaced as non-blocking warning), not pre-flight — missing `.txt` files
  should not prevent ack or unregister from running.
- **Conditional gh check:** after change detection, if any entry now has
  `needs_review=true AND gh_issue_url=null`, verify `gh auth status` passes
  and `gh repo view --json nameWithOwner` returns a result. On failure,
  hard-fail (see Hard dependency on `gh` above). If no entry is in that
  state, the gh check is skipped — repos that never have flagged entries
  don't need `gh` installed.

### Context discipline

The index JSON is bounded (roughly 20 KB at 100 entries) and always read in
full. Snapshot `.txt` files are read per-slug and only when a specific flow
requires the paragraph text (alert render, ack). The agent MUST NOT
concatenate all snapshot files into a single read — that would defeat the
purpose of the split.

## Skill / Agent / Command Changes

Concrete file changes:

1. **`skills/lawyer/SKILL.md`** — add "Law Registry" section covering the data
   model link, marker syntax, change-detection summary, and workflow pointers
   to the reference doc.
2. **`skills/lawyer/references/law-registry.md`** *(new)* — full schema, marker
   regex, scan commands (`rg` and `grep` fallbacks), API call templates for
   registration/verification, example entries, common failure modes.
3. **`agents/lawyer.md`** — add Critical Rules:
   - ALWAYS run the change-detection step at the start of every run;
   - NEVER write analysis if any entry has `needs_review == true`;
   - ALWAYS register new law dependencies when analysis reveals them.
4. **`commands/lawyer.md`** — subcommand dispatch, extended pre-flight,
   change-detection step before agent spawn.
5. **`.claude-plugin/plugin.json`** and root **`.claude-plugin/marketplace.json`** —
   version bump to `0.29.0` (both must stay in sync per repo CLAUDE.md).

No changes to `/improve`, `/tweak`, `/startup`, or the founder loop. The
registry is a lawyer-local concern; other roles touch it only by writing
`LAW: <slug>` markers.

## Migration

- **New projects:** index is created empty on first `/lawyer` run. The
  `.startup/laws/` directory is created lazily on the first `register` call.
- **Existing projects:** absence of `.startup/law-registry.json` is a valid
  state. The change-detection step becomes a no-op until the first entry is
  added.
- **No data migration**, no breaking changes to existing `/lawyer <topic>`
  behaviour.

## Testing

Lightweight, matching the plugin's existing testing posture (markdown + bash):

1. **Schema smoke test** — a bash script that constructs a minimal index +
   snapshot pair, round-trips through the change-detection code path with a
   mocked feed response (local JSON fixture served by `python -m http.server`),
   and asserts `needs_review` transitions correctly. Also asserts that change
   detection does NOT read any `.txt` file.
2. **Marker scan test** — a fixture directory with markers in `.ts`, `.py`,
   `.md`, `.jsx`, plus a prose false-positive ("the LAW: is clear that ...").
   The scan must match all legitimate markers and reject the prose.
3. **Invariant test** — register a slug, delete its `.txt` file, run
   `/lawyer check`; confirm the run surfaces a non-blocking warning and does
   not crash. Unregister the slug; confirm both the index entry and any
   remaining `.txt` file are removed.
4. **Manual integration** — in a scratch startup project with a GitHub
   remote:
   a. Register a real paragraph, run `/lawyer check`, confirm no changes.
   b. Fabricate a needs_review state by editing the index JSON. Run
      `/lawyer <topic>` — confirm the fix-plan doc is written and the
      interactive "Jah/Ei" prompt appears.
   c. Answer "Jah" — confirm a gh issue is created, `gh_issue_url` is set
      on the entry, `needs_review` remains `true`, and the topic analysis
      runs with a reminder about the pending fix.
   d. Create a branch, edit the marker-referenced code, run
      `/lawyer ack <slug>` inside the branch — confirm `.txt` is
      refreshed, flags clear, `verified_at` bumped. Commit all changes
      in one commit and verify the diff includes code + registry
      together.
   e. On a separate project with no GitHub remote, fabricate a
      needs_review state and run `/lawyer <topic>` — confirm the
      pre-flight hard-fails with the "gh unavailable" error.

## Open Questions (resolved at implementation time)

1. **Does `/laws/{act_id}/citation` accept `paragraph=<number>` only, or a
   compound Estonian citation like `"§ 10 lõige 2"`?** Affects how
   `citation` is passed to the API. Fallback: fetch the whole paragraph and
   let the lawyer scan for the subsection.
2. **Does the datalake `/changes/feed` response expose `act_id` and paragraph
   metadata per event?** If paragraph-level, detection is precise; if
   act-level only, detection is coarser (acceptable).
3. **Does the datalake expose a `redaktsioon_id` on the citation endpoint?**
   If yes, `redaktsioon_id` is stored in the index entry and compared at ack
   time as an adjunct precision check (cheap equality before any text diff).
   If no, the field is simply left `null` and the snapshot `.txt` file
   remains the only diff baseline.
4. **Does `/changes/feed` accept a `since=<timestamp>` parameter?** The
   existing skill documents only `?domain=...&limit=N`. If `since` is not
   supported, fall back to fetching `?domain=d&limit=100` and filtering feed
   events client-side where `event.timestamp > last_feed_check_at`. Either
   strategy fits the detection flow without schema changes.

These are investigation items for the first implementation task. The design
accommodates either answer in each case.

## Known Limitations

- **Not compatible with non-GitHub repositories.** The confirmation flow
  depends on `gh issue create` — flagged entries can only be acknowledged by
  opening a GitHub issue, and there is no manual fallback. Projects hosted
  elsewhere (GitLab, self-hosted git, etc.) cannot use this workflow as
  designed. Adapting the `issue` helper to call other forges is a future
  extension; not in scope for v1.
- **Externally-hosted customer content** (CMS articles, Crisp canned replies,
  Intercom saved responses, landing pages built in a site builder) cannot carry
  `LAW:` markers. Those surfaces are not covered by the registry. A future
  extension could add an `external_surfaces: [url, …]` array per entry that
  humans must review manually. Not in scope for v1.
- **Concurrent writes** to `.startup/law-registry.json` or to any file under
  `.startup/laws/` by two simultaneous `/lawyer` invocations can race. Same
  risk as `.startup/state.json`. Out of scope.
- **Partial writes across the two files** (index written, `.txt` not, or vice
  versa) leave an invariant violation. Mitigated by doing snapshot writes
  first and index writes second, and by surfacing index↔snapshot drift as a
  warning on every run. Not fully transactional — explicit non-goal.
- **Detection latency** is bounded by `/lawyer` invocation frequency. If the
  investor does not run `/lawyer` for two weeks and a relevant law changes on
  day three, the alert fires on day fourteen. Acceptable by design — continuous
  monitoring was explicitly out of scope.
- **Feed blind spots.** Change detection trusts `/changes/feed` as the source of
  truth. If the feed is late in picking up a new redaktsioon, miscategorises
  it under a domain the project doesn't have entries in, or reports a text
  correction that the datalake doesn't classify as an amendment, the
  amendment is silently missed: the snapshot `.txt` stays stale, the lawyer
  proceeds with old text as reference, no alert fires. The only mechanism
  that refreshes `.txt` outside an explicit alert is `ack`. Mitigation paths
  if this proves to bite: (a) add an opt-in `/lawyer recheck all texts` that
  re-fetches every entry and diffs against the snapshot — full N-call cost,
  run manually as needed; (b) add a staleness warning when `verified_at` is
  older than some threshold (e.g. 90 days). Neither is in v1.
