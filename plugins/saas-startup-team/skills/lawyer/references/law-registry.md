# Law Registry Reference

Per-project registry of Estonian legal paragraphs the product depends on.

## Files

- `.startup/law-registry.json` — metadata index (one entry per registered slug)
- `.startup/laws/<slug>.txt` — normalised paragraph text, one file per slug

The index is always read in full; snapshots are read per-slug only when needed (fix-plan rendering, ack).

## Schema history

| Version | Shipped in | Notes |
|---|---|---|
| 1 | v0.29.x | Field names didn't match the real datalake API; change-detection was a no-op. No user data expected in v1. |
| 2 | v0.30.0+ | Current. Matches real `/changes/feed` + `/laws/{act_id}/citation` responses. |

## Index schema (v2)

```json
{
  "version": 2,
  "last_feed_check_at": "2026-04-23T10:00:00Z",
  "entries": {
    "consent-credit-info": {
      "act_id": 30087,
      "rt_id": "1045568",
      "redaktsioon_id": "106032026010",
      "act_title": "Isikuandmete kaitse seadus",
      "act_type": "seadus",
      "citation": "§ 10 lõige 1",
      "citation_parts": {
        "paragraph": "10",
        "section": "1",
        "point": ""
      },
      "rt_url": "https://www.riigiteataja.ee/akt/106032026010",
      "registered_at": "2026-04-01T09:00:00Z",
      "verified_at": "2026-04-20T14:00:00Z",
      "registered_by": "lawyer",
      "purpose": "Lawful basis for processing credit-default disclosures",
      "needs_review": false,
      "change_detected_at": null,
      "change": null,
      "gh_issue_url": null
    }
  }
}
```

### Field semantics

| Field | Type | Purpose |
|---|---|---|
| `act_id` | int | The `/laws/search` `.id`. What `/laws/{act_id}/*` expects as a path param. **Not** `rt_id`, **not** an RT URL segment. |
| `rt_id` | string | The terviktekst identifier (short digit string like `"1045568"`). Stable across non-breaking amendments. Used for **feed matching** — `ChangeEvent.rt_id` is the same ID. |
| `redaktsioon_id` | string \| null | Trailing numeric segment of the citation URL (e.g. `"106032026010"`). Per-redaction RT identifier. Useful for cheap equality at ack time. |
| `act_title` | string | Human-readable act title. |
| `act_type` | string | `"seadus"`, `"määrus"`, etc. |
| `citation` | string | Compound reference as a human writes it: `"§ 10 lõige 1 punkt 3"`. For display. |
| `citation_parts.paragraph` | string | Integer-as-string paragraph number. Passed to `/laws/{act_id}/citation?paragraph=`. |
| `citation_parts.section` | string | Integer-as-string `lõige` number, or empty. Passed as `section=`. |
| `citation_parts.point` | string | Integer-as-string `punkt` number, or empty. Passed as `point=`. |
| `rt_url` | string | Citation URL returned by the datalake — points at the current redaktsioon. |
| `needs_review` | bool | Feed reported a change that the code hasn't yet absorbed. Cleared by `/lawyer ack <slug>`. |
| `change_detected_at` | ISO-8601 \| null | Detection timestamp (mirrors the feed event's `detected_at`). |
| `change` | object \| null | `{feed_event_id(int), type(str), summary(str), effective_date(str\|null)}`. Cleared by ack. |
| `gh_issue_url` | string \| null | Set when investor confirms "Jah, loo issue". Preserved through ack as a historical pointer. |

## State machine

| needs_review | gh_issue_url | Meaning | /lawyer behaviour |
|---|---|---|---|
| `false` | any | Clean | Runs topic as normal |
| `true` | `null` | Detected, not yet confirmed | Blocks topic, prompts for issue creation |
| `true` | `<url>` | Issue open, PR pending | Runs topic with reminder |

Transitions:
- clean → `(true, null)` by feed detection (matches `ChangeEvent.rt_id` against `entry.rt_id`)
- `(true, null)` → `(true, <url>)` by investor answering "Jah, loo issue"
- `(true, <url>)` → clean by `/lawyer ack <slug>` inside the PR branch that ships the code fix

## Source markers

Markers live inside comments adjacent to the code or content they govern. Examples:

```ts
// LAW: consent-credit-info
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

**Look up an act's integer `act_id` from its Estonian name** (required before `register`):

```bash
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/laws/search?q=isikuandmete+kaitse&limit=5" \
  | jq '.items[] | {id, rt_id, title}'
```

**Resolve `rt_id` + title from a known `act_id`** (used during `register`):

```bash
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/laws/${ACT_ID}/graph" \
  | jq '.act | {id, title, rt_id, act_type, status}'
```

**Fetch paragraph text for a registered act** (parsed parts, not compound string):

```bash
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/laws/${ACT_ID}/citation?paragraph=${PARAGRAPH}&section=${SECTION}&point=${POINT}"
```

Response: `{act_id, act_title, paragraph, section, point, text, url}`. The trailing segment of `url` (after `/akt/`) is the per-redaction RT identifier — store as `redaktsioon_id`.

**Poll changes feed since last check** (one call per run, no per-domain loop):

```bash
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/changes/feed?since=${SINCE}&limit=500"
```

Response: `{items:[ChangeEvent], total}` where each event has `{id, change_type, act_title, rt_id, act_type, issuer, detected_at, effective_date, description, domains[]}`. Filter client-side: `select(.rt_id == registered_rt_id)`.

**Augment the fix-plan with the datalake's impact analysis** (optional):

```bash
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "$DATALAKE_URL/api/v1/changes/${CHANGE_ID}/impact"
```

## Text normalisation

All snapshot text is trimmed of leading/trailing whitespace and NFC-normalised before comparison or storage:

```bash
python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFC", sys.stdin.read().strip()))'
```

## Citation parsing

The compound Estonian citation is parsed into `paragraph`/`section`/`point` integers because the API rejects the compound string. Python regex used by the `register` subcommand:

```python
p = re.search(r"§\s*(\d+)", text)               # paragraph
s = re.search(r"lõige\s*(\d+)", text, re.I)     # section / lõige
k = re.search(r"punkt\s*(\d+)", text, re.I)     # point / punkt
```

`paragraph` is required; the other two default to empty.

## gh issue template

Issue title: `Seadusemuudatus: <citation> — <slug>`
Labels: `legal-review,seadusemuudatus`
Body: the "Mida tuleb teha" section for that slug from `docs/legal/õiguslik-muudatused-YYYY-MM-DD.md`, plus a trailing block titled "Registri värskendus PR-s" listing:
- File to overwrite: `.startup/laws/<slug>.txt` (content will be fetched fresh at ack time)
- Index fields to update: `needs_review=false`, `change=null`, `change_detected_at=null`, `verified_at=<now>`, `redaktsioon_id=<trailing segment of the new citation URL>`
- Helper to run inside the fix branch: `/lawyer ack <slug>`

## Common failure modes

- **Marker for unknown slug** — registry entry missing. Non-blocking warning.
- **Entry with no markers** — slug registered but nothing in code references it. Non-blocking warning; candidate for `unregister`.
- **Snapshot file missing for a registered slug** — index↔snapshot drift. Non-blocking warning at detection time; ack will recreate on next run.
- **Orphan snapshot file** — `.txt` file under `.startup/laws/` with no matching index entry. Non-blocking warning; can be removed manually.
- **Feed event's rt_id doesn't match any entry** — normal; the feed covers the whole legal corpus, most events are irrelevant to a given project.
- **Entry rt_id mismatches feed even for the right act** — possible if the terviktekst ID drifted (rare, happens on structural republications). Resolve by re-running `/lawyer register` with the same slug — it refreshes rt_id from `/laws/{act_id}/graph`.
