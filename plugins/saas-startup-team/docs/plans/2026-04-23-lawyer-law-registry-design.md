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
| `needs_review` | bool | **Work-blocking flag.** Any entry with `true` stops normal `/lawyer` operation. Cleared only by explicit `ack`. |
| `change_detected_at` | ISO-8601 \| null | When the feed reported the change. |
| `change` | object \| null | `{feed_event_id, type, summary}`. `type` is `"amended" \| "repealed" \| "replaced" \| "other"`. The timestamp lives on `change_detected_at`. |

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

## Alert and Pause Flow

After change detection runs, if any entry has `needs_review == true` (whether
newly flagged this run or pending from a prior run):

1. **Lawyer does NOT proceed with the user's requested topic.** Analysis agent
   is not spawned.
2. **For each flagged slug, load both old and new paragraph text:**
   - Old text: read `.startup/laws/<slug>.txt` (the last-verified snapshot).
   - New text: `curl --max-time 30 GET /laws/{act_id}/citation?paragraph=…`
     against the datalake. Normalise (trim + NFC). This is ONE additional API
     call per flagged entry — not per entry overall. Do NOT overwrite the
     `.txt` file yet; the snapshot is only refreshed at ack time after the
     investor has confirmed the review.
   - If the new-text fetch fails (non-2xx or timeout), continue the alert flow
     with a placeholder "⚠ uut teksti ei õnnestunud laadida — kontrolli käsitsi"
     instead of the new-text block. Alert must still be written.
3. **Write/append the review document** at
   `docs/legal/õiguslik-muudatused-YYYY-MM-DD.md`. If the file exists, append a
   new section with the current timestamp. Structure:

   ```markdown
   # Seadusemuudatused — YYYY-MM-DD

   > ⚠ See on AI-põhine hoiatus, mitte õigusnõu.

   ## Muudatuste kokkuvõte

   | Slug | Seadus | Tüüp | Avastatud | Mõjutatud failid |
   |------|--------|------|-----------|------------------|
   | consent-lawful-basis | Isikuandmete kaitse seadus § 10 lõige 2 | amended | 2026-04-21 | 3 |

   ## Detailid

   ### consent-lawful-basis
   **Seadus:** Isikuandmete kaitse seadus § 10 lõige 2
   **Muudatuse tüüp:** amended
   **Avastatud:** 2026-04-21
   **Riskitase:** Keskmine

   **Feed'i kokkuvõte:**
   [summary from feed]

   **Eelmine tekst (salvestatud `verified_at`-ga 2026-04-20):**
   > Isikuandmete töötlemine on lubatud …

   **Uus tekst (datalake, 2026-04-23):**
   > Isikuandmete töötlemine on lubatud ning töötlejal on kohustus …

   **Muutunud osa:**
   ```diff
   - Isikuandmete töötlemine on lubatud …
   + Isikuandmete töötlemine on lubatud ning töötlejal on kohustus …
   ```

   **Mõjutatud failid:**
   - src/auth/consent.ts:42
   - app/privacy/page.tsx:18
   - docs/customer/privacy.md:10

   **Soovitatud tegevused:**
   1. Vaata üle loetletud failid — kas loogika/sõnastus vajab uuendamist?
   2. Pärast läbivaatust käivita /lawyer uuesti ja ütle, et oled muudatused
      üle vaadanud (nt `/lawyer olen muudatused üle vaadanud, jätka <topic>`).
   ```

4. **Print terminal alert:**

   ```
   ⚠ STOP: 1 seadus(t) on muutunud. Analüüsi <topic> ei alustata.

   - consent-lawful-basis (§ 10 lõige 2): amended on 2026-04-21
     Mõjutab: src/auth/consent.ts:42, app/privacy/page.tsx:18, docs/customer/privacy.md:10

   Täielik raport: docs/legal/õiguslik-muudatused-2026-04-23.md

   Pärast läbivaatust taaskäivita:
     /lawyer olen muudatused üle vaadanud, jätka <original topic>
   ```

5. **Exit.**

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

## Acknowledgement Flow

The investor's only interface is `/lawyer <natural-language topic>`.
Acknowledgement is signalled inside the topic string, not through a separate
subcommand. The Lawyer agent, on entering the run, inspects the topic:

- **Topic contains an ack phrase** (case-insensitive match on any of:
  `olen üle vaadanud`, `kinnita muudatused`, `muudatused on vaadatud`,
  `i have reviewed`, `reviewed the changes`, `acked`, `ack`, `acknowledged`,
  `proceed anyway`, `proceed with review`) → the agent runs ack logic for
  all currently flagged entries, then continues with whatever residual
  intent remains in the topic.
- **Topic also names specific slugs** (e.g. `olen üle vaadanud
  consent-lawful-basis`) → ack is limited to the named slugs.
- **No ack phrase and entries are still flagged** → the agent re-prints the
  alert and does not run analysis.

Ack logic, regardless of how it was triggered:

1. For each entry being acked:
   - Fetch fresh text via `/laws/{act_id}/citation`.
   - Normalise (trim + NFC) and overwrite `.startup/laws/<slug>.txt` with the
     new text.
   - On the index entry: if the response carries a `redaktsioon_id` (see Open
     Question 3), update that field; update `verified_at` to now; clear
     `needs_review`, `change_detected_at`, `change`.
2. Persist the index.
3. Print summary: `Kinnitatud: <n> kirjet. Jätkan analüüsiga: <residual topic>`.

Acknowledgement does NOT require that the investor has actually modified any
source files. The semantic is: "I have reviewed this change and confirmed the
product is still correct (or will address it separately)." Tracking "did the
user actually update src/auth/consent.ts?" would require heuristics weaker than
an explicit ack in the investor's own words.

The explicit `ack` subcommand below is plumbing that the lawyer agent invokes
internally (via bash) to do this work. It is also callable directly for
scripting or by other agents, but not part of the investor's expected UX.

## Command Surface

### Investor-facing UX

The investor interacts with only one form:

```
/lawyer <free-form topic, Estonian or English>
```

Everything — analysis requests, acknowledgement of detected changes, asking
for registry status, asking for a change re-check — is expressed inside the
topic string. The Lawyer agent interprets intent. Example topics:

- `analyze our ToS for GDPR gaps`
- `olen seadusemuudatused üle vaadanud, jätka DPA analüüsiga`
- `what's in the law registry?`
- `recheck for law changes`
- `register § 10 lõige 2 of the Data Protection Act — we use it for signup consent`

The investor is never expected to type subcommand tokens like `ack` or
`register` as the first argument, and the terminal alert prompts them with a
natural-language continuation, not a subcommand.

### Agent-facing helpers (internal plumbing)

The command file also dispatches a set of explicit subcommands used by
agents (the lawyer itself, or founder agents invoking the command
programmatically) and by anyone who wants scriptable, deterministic calls:

```
/lawyer register <slug> <act_id> <citation> <purpose>
                                        — register an entry (idempotent by (act,citation))
/lawyer unregister <slug>               — remove an entry
/lawyer ack <slug> [<slug> …]           — clear needs_review, refresh the .txt snapshot
/lawyer ack-all                         — ack every currently flagged entry
/lawyer status                          — print registry state: total entries, pending reviews, last feed check
/lawyer check                           — run feed re-check without spawning analysis
```

These are helpers, not the primary UX. They are not documented in
investor-facing help text. Agents call them via bash; humans may call them
if they want precise control, but nothing in the normal flow requires it.

### Subcommand vs. topic disambiguation

If `args[0]` matches the literal keyword set
`{register, unregister, ack, ack-all, status, check}`, treat as a subcommand;
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
4. **Manual integration** — in a scratch startup project, register a real
   paragraph, run `/lawyer check`, confirm no changes. Fabricate a needs_review
   state by editing the index JSON, run `/lawyer <topic>` — confirm alert doc
   written, topic skipped. Run `/lawyer olen muudatused üle vaadanud, jätka`,
   confirm flags clear and analysis proceeds.

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
