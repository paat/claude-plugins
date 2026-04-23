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

## Data Model

### File: `.startup/law-registry.json`

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
      "text_snapshot": "Isikuandmete töötlemine on lubatud …",
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

### Field semantics

| Field | Type | Notes |
|---|---|---|
| `version` | int | Schema version. Starts at `1`. Incremented only for breaking changes. |
| `last_feed_check_at` | ISO-8601 | Advanced on every successful feed query, independent of whether changes were detected. |
| `entries` | object | Keyed by slug (kebab-case, `[a-z0-9-]+`). Slug is what marker comments reference. |

### Entry fields

| Field | Type | Notes |
|---|---|---|
| `act_id` | string | Datalake act identifier (the form accepted by `/laws/{act_id}/citation`). |
| `act_title` | string | Human-readable act title in Estonian. Denormalised for readability. |
| `citation` | string | Estonian-style reference (`"§ 10 lõige 2 punkt 3"`). Stored as the form a human would recognise; the lawyer normalises it for the API call at registration and verification time. |
| `domain` | string | One of the datalake `/changes/feed` domains (e.g. `"Data Protection"`, `"Labor"`, `"Tax"`, `"Commercial"`). Used to decide which feeds to poll. |
| `rt_url` | string | Riigi Teataja URL for the act. For investor-facing links. |
| `redaktsioon_id` | string \| null | RT redaktsioon ID if the datalake exposes one on the citation endpoint. Optional; when present, enables cheap equality as a precision adjunct in the future. |
| `text_snapshot` | string | Normalised paragraph text (trimmed, NFC Unicode) at the most recent successful verification. Refreshed on registration and on `ack`. |
| `registered_at` | ISO-8601 | When the entry was first added. |
| `verified_at` | ISO-8601 | When the text was last confirmed against the datalake (registration or ack). |
| `registered_by` | string | `"lawyer"`, `"tech-founder"`, `"business-founder"`. Informational. |
| `purpose` | string | One-line description of why this paragraph is load-bearing. Free-form — source markers carry the per-site context. |
| `needs_review` | bool | **Work-blocking flag.** Any entry with `true` stops normal `/lawyer` operation. Cleared only by explicit `ack`. |
| `change_detected_at` | ISO-8601 \| null | When the feed reported the change. |
| `change` | object \| null | `{feed_event_id, type, summary}`. `type` is `"amended" \| "repealed" \| "replaced" \| "other"`. The timestamp lives on `change_detected_at`. |

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

```
1. Read .startup/law-registry.json. If missing, create empty file and skip to step 8.
2. If registry.entries is empty, skip to step 8.
3. Compute unique set D of entry.domain values.
4. Compute unique set A of entry.act_id values.
5. For each domain d in D:
     curl --max-time 30 GET /changes/feed?domain=d&since=<last_feed_check_at>
     (if last_feed_check_at is null, cap `since` at now-90d)
6. Collect feed events whose act_id is in A.
7. For each matched event E:
     for each entry e with e.act_id == E.act_id:
       e.needs_review = true
       e.change_detected_at = E.timestamp
       e.change = { feed_event_id: E.id, type: E.type, summary: E.summary }
8. If all feed queries succeeded, advance registry.last_feed_check_at = now
   (independent of whether changes were detected — detection is recorded per entry,
   not in the global timestamp).
9. Persist registry.
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
2. **Write/append the review document** at
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

   **Eelmine tekst (salvestatud registreerimisel):**
   > Isikuandmete töötlemine on lubatud …

   **Mõjutatud failid:**
   - src/auth/consent.ts:42
   - app/privacy/page.tsx:18
   - docs/customer/privacy.md:10

   **Soovitatud tegevused:**
   1. Võrdle uut redaktsiooni salvestatud tekstiga datalake'is:
      `GET /laws/104052024010/citation?paragraph=...`
   2. Vaata üle loetletud failid — kas loogika/sõnastus vajab uuendamist?
   3. Pärast läbivaatust kinnita: `/lawyer ack consent-lawful-basis`
   ```

3. **Print terminal alert:**

   ```
   ⚠ STOP: 1 seadus(t) on muutunud. Analüüsi <topic> ei alustata.

   - consent-lawful-basis (§ 10 lõige 2): amended on 2026-04-21
     Mõjutab: src/auth/consent.ts:42, app/privacy/page.tsx:18, docs/customer/privacy.md:10

   Täielik raport: docs/legal/õiguslik-muudatused-2026-04-23.md

   Pärast läbivaatust:
     /lawyer ack <slug>       — kinnita üks muudatus
     /lawyer ack-all          — kinnita kõik
     /lawyer <topic>          — jätka algse analüüsiga
   ```

4. **Exit.**

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
2. Look up `(act_id, citation)` — if an entry already exists under a different
   slug, reuse it; do not create a duplicate.
3. Fetch current paragraph text: `GET /laws/{act_id}/citation?paragraph=<normalised>`.
4. Normalise text (trim + NFC), populate `text_snapshot`, `verified_at`, `registered_by="lawyer"`.
5. Write entry to registry.
6. In the analysis doc, instruct: *"Lisa marker koodi / sisusse: `LAW: <slug>`"*
   with suggested locations.

### Path B — marker-first (founder-initiated)

Tech or business founder adds `// LAW: <new-slug>` in code while implementing a
feature whose correctness depends on a specific law:

1. On next `/lawyer` run, the marker scan finds `<new-slug>` with no registry entry.
2. Lawyer reports the orphan and offers two remediations:
   - `/lawyer register <slug> <act_id> "<citation>" "<purpose>"` — explicit
     registration, lawyer fetches text and populates entry.
   - Remove the marker if it was added in error.

### Explicit subcommand

`/lawyer register <slug> <act_id> <citation> <purpose>`

- Idempotent on `(act_id, citation)`: if an entry with that pair exists, print
  its current slug and exit without creating a new entry.
- Fails hard if the citation endpoint returns 404 or the response is empty.
  Registry is not polluted with placeholder entries.

## Acknowledgement Flow

`/lawyer ack <slug...>` and `/lawyer ack-all` clear `needs_review` after the
investor has reviewed the change:

1. For each slug to ack:
   - Fetch fresh text via `/laws/{act_id}/citation`.
   - Update `text_snapshot` to the new normalised text.
   - If the response carries a `redaktsioon_id` (see Open Question 3), update
     that field on the entry.
   - Update `verified_at` to now.
   - Clear `needs_review`, `change_detected_at`, `change`.
2. Persist registry.
3. Print summary: `Kinnitatud: <n> kirjet. Saad jätkata: /lawyer <topic>`.

`ack-all` is shorthand for acking every currently flagged entry.

Acknowledgement does NOT require that the user has actually modified any source
files. The semantic is: "I have reviewed this change and confirmed the product
is still correct (or will address it separately)." Tracking "did the user
actually update src/auth/consent.ts?" would require heuristics that are weaker
than a user's explicit ack.

## Command Surface

Updated `/lawyer` subcommand dispatch in `commands/lawyer.md`:

```
/lawyer <topic>                         — analysis (existing behaviour), gated by change check
/lawyer register <slug> <act_id> <citation> <purpose>
                                        — register an entry (idempotent by (act,citation))
/lawyer unregister <slug>               — remove an entry
/lawyer ack <slug> [<slug> …]           — clear needs_review, refresh text_snapshot
/lawyer ack-all                         — ack every currently flagged entry
/lawyer status                          — print registry state: total entries, pending reviews, last feed check
/lawyer check                           — force a feed re-check without running analysis
```

### Subcommand vs. topic disambiguation

If `args[0]` matches the literal keyword set
`{register, unregister, ack, ack-all, status, check}`, treat as subcommand;
otherwise treat full `args` as the topic string passed to the analysis agent.

Topics in practice are free-form Estonian/English phrases and are very unlikely
to begin with those literal tokens. If a genuine topic collides (e.g. a user
literally wants to analyse the verb "register"), quote the topic.

### Subcommand execution model

- `status`, `ack`, `ack-all`, `register`, `unregister` — run directly in the
  command body (bash + jq). No analysis agent spawn. Fast.
- `check` — runs the change-detection flow then exits; no agent spawn.
- `<topic>` — runs the change-detection flow; if clean, spawns the Lawyer
  agent with the topic (existing behaviour).

### Updated pre-flight checks

The existing three pre-flight checks (datalake reachable, API key present,
startup project present) remain unchanged. Added:

- If `.startup/law-registry.json` exists, verify it parses as valid JSON and
  has `version == 1`. On parse failure, hard-fail with an error telling the
  user which line is broken. Do not overwrite on parse failure.

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

- **New projects:** registry is created empty on first `/lawyer` run.
- **Existing projects:** absence of `.startup/law-registry.json` is a valid
  state. The change-detection step becomes a no-op until the first entry is
  added.
- **No data migration**, no breaking changes to existing `/lawyer <topic>`
  behaviour.

## Testing

Lightweight, matching the plugin's existing testing posture (markdown + bash):

1. **Schema smoke test** — a bash script that constructs a minimal registry,
   round-trips through the change-detection code path with a mocked feed
   response (local JSON fixture served by `python -m http.server`), and asserts
   `needs_review` transitions correctly.
2. **Marker scan test** — a fixture directory with markers in `.ts`, `.py`,
   `.md`, `.jsx`, plus a prose false-positive ("the LAW: is clear that ...").
   The scan must match all legitimate markers and reject the prose.
3. **Manual integration** — in a scratch startup project, register a real
   paragraph, run `/lawyer check`, confirm no changes. Fabricate a needs_review
   state by editing the JSON, run `/lawyer <topic>` — confirm alert doc
   written, topic skipped. Run `/lawyer ack-all`, run `/lawyer <topic>` —
   confirm analysis proceeds.

## Open Questions (resolved at implementation time)

1. **Does `/laws/{act_id}/citation` accept `paragraph=<number>` only, or a
   compound Estonian citation like `"§ 10 lõige 2"`?** Affects how
   `citation` is passed to the API. Fallback: fetch the whole paragraph and
   let the lawyer scan for the subsection.
2. **Does the datalake `/changes/feed` response expose `act_id` and paragraph
   metadata per event?** If paragraph-level, detection is precise; if
   act-level only, detection is coarser (acceptable).
3. **Does the datalake expose a `redaktsioon_id` on the citation endpoint?**
   If yes, `redaktsioon_id` is stored and compared at ack time as an adjunct
   precision check (cheap equality before full text comparison). If no, the
   field is simply left `null` and `text_snapshot` comparison remains primary.
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
- **Concurrent writes** to `.startup/law-registry.json` by two simultaneous
  `/lawyer` invocations can race. Same risk as `.startup/state.json`. Out of
  scope.
- **Detection latency** is bounded by `/lawyer` invocation frequency. If the
  investor does not run `/lawyer` for two weeks and a relevant law changes on
  day three, the alert fires on day fourteen. Acceptable by design — continuous
  monitoring was explicitly out of scope.
