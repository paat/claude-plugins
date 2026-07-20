# Datalake API reference

Load this file only for endpoint work. Base: `$DATALAKE_URL/api/v1/`. All calls
need `X-API-Key: $EST_DATALAKE_API_KEY` and `curl --max-time 30`. Never print or
persist credentials.

Routing (when/what/stop) lives in `datalake-routing.md`. This file owns paths,
params, and force/coverage fields only.

## Legal authority

- `POST /rag/query` body
  `{"question":"...","context_filter":{"municipality":"<exact name>"}}` —
  cited RAG. Respect `coverage_status`/`coverage_note`. Omit municipality for
  state default; with it, KOV only (exact name).
- `GET /laws/search` — query params: required `q`; optional `status` (use
  `valid`), `municipality` (exact KOV name; without it state-only), `act_type`,
  `date_from`, `date_to`, `limit`, `offset`. Use result `.id` as `{act_id}`, not
  `rt_id` or an RT URL segment.
- `GET /laws/{act_id}/citation` — optional `paragraph`, `section`, `point` (and
  qualifiers via shared builder). Require `status == "valid"` and
  `in_force == true`.
- `GET /laws/rt/{rtAktId}/source` — optional `format=html|text|json` (pick one).
- `GET /laws/{act_id}/graph`
- `GET /laws/{act_id}/citing-decisions`
- `POST /compliance/checklist` body
  `{"business_type":"...","emtak_code":"..."}` — `business_type` required.

Superscript qualifiers are load-bearing: `§ 14 lõige 1¹` is not lõige 1.

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-common.sh"
# KOV search — encode the exact municipality name
curl --max-time 30 -s -G -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  --data-urlencode "q=reklaam" \
  --data-urlencode "status=valid" \
  --data-urlencode "municipality=Tallinn" \
  "$DATALAKE_URL/api/v1/laws/search"
url=$(lawyer_cite_url <act_id> <paragraph> <paragraph_qualifier> \
  <section> <section_qualifier> <point> <point_qualifier>)
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$url"
```

Qualifier args use ordinary digits (`1` for `¹`); the helper reattaches and
URL-encodes the superscript.

## EU

- `GET /eurlex/search` — required `q`; optional `doc_type`, `in_force`, `limit`,
  `offset`
- `GET /eurlex/{celex}` — metadata
- `GET /eurlex/{celex}/citation` — required `article`; optional `paragraph`,
  `point`, `language` (default often EN). Require `in_force == true`; keep
  HTTPS `source_url`. Metadata is not article text.
- `GET /eurlex/transpositions` — query `celex`
- `GET /eurlex/changes`, `GET /eurlex/upcoming`

## Courts

- `GET /court/search` — required `q`; optional `court_code`, `proceeding_type`,
  `date_from`, `date_to`, `include_full_text` (bool), `limit`, `offset`
- `GET /court/ecli/{ecli}`
- `GET /court/case/{case_number}`
- `GET /court/decision/{decision_id}/citations`

## Change monitoring

- `GET /changes/feed` — optional `since` (ISO), `limit`, `domain` where domain
  is exactly one of `law` or `distress` (omit to mix). Label mixed events by
  `event_key` prefix `law:` / `distress:`. Respect `partial` and `warnings`.
- `GET /changes/{change_id}/impact`

## Company diligence

Full paths under `/companies/`:

- `GET /companies/search` — query `q` and pagination as provided by API
- `GET /companies/{registry_code}`
- `GET /companies/{registry_code}/profile/full` — aggregate compliance profile
- `GET /companies/{registry_code}/board`
- `GET /companies/{registry_code}/tax`
- `GET /companies/{registry_code}/financials`
- `GET /companies/{registry_code}/obligations`
- `GET /companies/{registry_code}/graph`
- `GET /companies/{registry_code}/licenses`
- `GET /companies/{registry_code}/impacts`
- `GET /companies/{registry_code}/distress` — 0–100 score with component
  evidence; not a credit rating, insolvency finding, or bankruptcy prediction.
  Check `available_weight` and component freshness.
- `GET /distress/screen` — optional `emtak`, `county`, `min_score`, `limit`,
  `offset`; HTTP 503 if snapshot missing/stale

## Enforcement

- `GET /enforcement/search` — optional `q`, `agency` one of `AKI`, `TTJA`,
  `KONKURENTSIAMET`, `registry_code`, `adverse`, `limit`, `offset`
- `GET /enforcement/stats`
- Confirmed eight-digit registry-code links only for attribution. TTJA coverage
  may be incomplete until authorized export — record as coverage gap.

## Grants / state aid

- `GET /grants/search` — optional `q`, `measure`, `emtak`, `date_from`, `limit`,
  `offset`
- `GET /grants/company/{registry_code}`
- `GET /grants/calls` — optional `status` one of `open`, `upcoming`, `closed`;
  `provider` one of `eis`, `kik`, `pria`
- `GET /grants/stats` — optional `emtak`
- Exact registry-code linkage; fail-closed until RTK+RAR snapshots ready; keep
  official `source_url`.

## Party finance

- `GET /party-finance/donations` — optional `donor`, `company_registry_code`,
  `year`, `confidence` one of `confirmed`, `possible`, `low`, plus pagination.
  Prefer `confidence=confirmed`. Not PEP proof or misconduct evidence.
- `GET /party-finance/campaign-expenses`

## Licences, tax debt, announcements, sanctions

- `GET /licenses/search` — optional `q`/`query`, `license_number`,
  `registry_code`, `license_type`/`type`, `status`, `emtak_code`, `domain`,
  `activity`, `include_inactive`, pagination
- `GET /licenses/company/{registry_code}` (alias path also under companies)
- `GET /tax-debt/company/{registry_code}`
- `GET /announcements/company/{registry_code}` — optional `category`
- Sanctions use `/v1` (not `/api/v1`): `GET /v1/sanctions/company/{registry_code}`,
  `GET /v1/sanctions/screen`

## Economic context

- `GET /statistics/search` — required `q`; optional `source` one of
  `statistics_estonia` or `eestipank`, `category`, pagination
- `GET /statistics/table/{table_code}`
- `GET /statistics/indicator/{table_code}/{indicator_code}`
- `GET /labor/wages` — optional `emtak`, `region` (native grains only)
- `GET /vacancies/search`, `GET /vacancies/stats` — monthly aggregates, not job
  ads; may 503 until NC use acknowledged (CC BY-NC)
- `GET /transactions/stats` — area aggregates; disclose `source_cutoff` when
  present
