# Datalake API reference

Load this file only for endpoint work. The base is
`$DATALAKE_URL/api/v1/`; all calls require `X-API-Key:
$EST_DATALAKE_API_KEY` and `curl --max-time 30`.

## Legal research

- `POST /rag/query`, body `{"question":"..."}`: cited RAG answer. Respect
  `coverage_status`/`coverage_note`; partial coverage is not evidence for an
  omitted corpus.
- `GET /laws/search?q=...&status=valid&limit=N`: law results. Use result `.id`
  as `{act_id}`, not `rt_id` or an RT URL segment.
- `GET /laws/{act_id}/citation?paragraph=N&section=M&point=K`: provision text
  plus lifecycle fields. Require `status == "valid"` and `in_force == true`.
- `GET /laws/{act_id}/graph`: act metadata and related acts.
- `GET /laws/{act_id}/citing-decisions`: decisions citing the act.
- `POST /compliance/checklist`, body
  `{"business_type":"...","emtak_code":"..."}`: broad compliance audits;
  `business_type` is required.

Superscript qualifiers are load-bearing: `§ 14 lõige 1¹` is not lõige 1. Do
not concatenate citation URLs manually. Use the shared builder:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-common.sh"
url=$(lawyer_cite_url <act_id> <paragraph> <paragraph_qualifier> \
  <section> <section_qualifier> <point> <point_qualifier>)
curl --max-time 30 -s -H "X-API-Key: $EST_DATALAKE_API_KEY" "$url"
```

Qualifier arguments contain ordinary digits (`1` for `¹`); the helper
reattaches and URL-encodes the superscript.

## Conditional endpoints

- Currentness: `GET /changes/feed?since=<ISO>&limit=N` and
  `GET /changes/{change_id}/impact`.
- Company-specific research: `/companies/search`, `/companies/{code}`,
  `/board`, `/tax`, `/financials`, `/obligations`, `/profile/full`.
- Courts: `/court/search`, `/court/ecli/{ecli}`,
  `/court/decision/{decision_id}/citations`.
- EU metadata: `/eurlex/search`, `/eurlex/{celex}`, and
  `/eurlex/transpositions?celex=...`.
- EU article text: `GET /eurlex/{celex}/citation?article=N&language=EN`, with
  optional `paragraph` and `point`. Require `in_force == true`; preserve the
  returned HTTPS `source_url`, and filter output to the fields the decision
  needs. Metadata alone does not substitute for article text.

Use only endpoints activated by the topic. Never inventory every surface or
dump full API responses when a filtered field set answers the decision.
