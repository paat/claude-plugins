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
