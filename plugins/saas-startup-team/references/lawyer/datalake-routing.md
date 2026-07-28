# Datalake routing for Lawyer

Load this file when any of these may change the decision: municipal/KOV law,
courts/case law, enforcement, named-company diligence, change monitoring,
grants (history or open calls), political finance, or economic context.
Pure **state-law** statute questions use RAG + citation only — skip this file.
KOV is not pure state-law statute work; load this file for municipal research.

For request parameters and response fields, load `datalake-api.md` only when
calling an endpoint. This file owns **when/what/stop**; the API ref owns params.

## Capability overview

| Capability | Class | SaaS lawyer priority |
|---|---|---|
| State law RAG / citation | authority | high (default path) |
| KOV / municipal law | authority | high when locality named |
| EUR-Lex + transposition | authority | high when EU-derived |
| Courts (ECLI / full text) | interpretation | high for practice |
| Change feed + impact | authority ops | high for currentness |
| Enforcement (AKI/TTJA/Competition) | intelligence | high for privacy/consumer |
| Company profile/full, graph | intelligence | high for named counterparties |
| Distress 0–100 | intelligence | medium (labelled signal) |
| Grants / state aid | intelligence | medium when funding in scope |
| Party finance (ERJK) | intelligence | low; topic-triggered only |
| Statistics / labour wages | context | low–medium; topic-triggered |
| Licences, tax-debt, announcements, sanctions | intelligence | situational diligence |

Real-estate transaction aggregates are not routed for ordinary SaaS work.

## Routing

| Pattern | Primary | Support | Stop |
|---|---|---|---|
| What does EE law require? | RAG + laws search + citation | EUR-Lex if EU-derived | after Tier A for decisive claims |
| Municipal / KOV rule | laws/RAG **with municipality** | state law only if national default needed | named KOV act cited, or name/coverage gap recorded |
| Enforcement practice | enforcement search (AKI/TTJA/Competition) | courts; agency primary pages if partial | relevant adverse decisions or coverage gap |
| Named counterparty diligence | company `profile/full` | distress; enforcement by code; tax-debt; announcements; licences; sanctions | after profile + optional one drill |
| Law change / currentness | changes feed `domain=law` + impact | registry check; parliament only if pipeline risk | feed + impact for in-scope acts |
| EU instrument / transposition | EUR-Lex + citation | national implementing act | operative article + force check |
| Company grant / state-aid history | grants company (or search by code) | profile grants block | exact-code hits or fail-closed note |
| Open funding opportunities | grants **calls** (status/provider) | grants search only if needed | listed open/upcoming calls or fail-closed |
| Political finance (only if topic names it) | party-finance donations (`confidence=confirmed`) | — | never as PEP proof |
| Market / employment context | statistics; labour only if needed | — | disclose NC licence / freshness |
| Board / ownership | company graph or board | profile | confirmed entities only |
| Courts / case law / ECLI | court search or ECLI/case lookup | citing-decisions; Tier A statute for duties | practice labelled; statute for obligations |

Intelligence endpoints never alone make a claim `CONFIRMED`.

## Playbooks

### Municipal compliance

1. Require an explicit municipality name from the topic or brief.
2. Query laws/RAG **with** that municipality; bare search is state-only.
3. Municipality filter is **exact name** equality. Zero rows may mean name
   mismatch (e.g. Tallinn vs Tallinna linn), not absent law — verify the
   canonical name before a coverage-gap claim.
4. Verify decisive provisions at Tier A (`valid` + `in_force`).
5. Record partial coverage; do not retry nationwide as if it answered KOV.

### Litigation / case-law research

1. Frame the legal question and forum if known.
2. Court search by topic; filter court/proceeding/date when useful.
3. Prefer ECLI or case number for a known decision; full text only when needed.
4. Use decisions as interpretation/practice, not statute substitutes.
5. Pair with Tier A statute for any operative obligation claim.

### Counterparty due diligence

1. Use an eight-digit registry code; do not invent one from a name match.
2. Call `profile/full` first; drill once (distress, enforcement, tax-debt,
   announcements, licences, sanctions) only if the decision needs it.
3. Treat only **confirmed** registry-code links as company evidence.
4. Distress is a transparent early-warning score, not a credit rating,
   insolvency finding, or bankruptcy prediction.
5. Never infer misconduct, PEP status, or legal liability from scores or media.

### Regulatory-change monitoring

1. Prefer existing registry ops (`lawyer-check`, register/ack) for load-bearing
   project provisions — see `lawyer-operations.md` / `law-registry.md`.
2. For ad-hoc currentness: changes feed with `domain=law` + impact.
3. Mixed feeds interleave law and distress; label by `event_key` (`law:` /
   `distress:`). Distress events are not statutory amendments.
4. Record `partial` / `warnings` when one domain is unavailable.
5. Future-effective acts may need the RT watch path (registry), not feed alone.

### Enforcement check

1. Statute Tier A first for the duty under review.
2. Enforcement search with agency (AKI / TTJA / KONKURENTSIAMET) and topic.
3. Company attribution only with confirmed registry-code links.
4. TTJA may be incomplete until authorized export — record coverage gap.
5. Label decisions as practice signals, never automatic violations.

## Freshness, coverage, provenance, linkage

Before relying on a datalake intelligence result:

- [ ] Note snapshot / coverage timestamps or `available_weight` when present
- [ ] Respect `coverage_status`, `partial`, `warnings`, and HTTP 503 fail-closed
- [ ] Prefer returned primary `source_url`
- [ ] Confirmed eight-digit registry code for company attribution
- [ ] Canonical exact municipality name for KOV (zero rows ≠ no law)
- [ ] Disclose aggregation, privacy suppression, and licence limits (e.g. labour CC BY-NC)

## Answer format

When intelligence or multi-source work ran, structure the Estonian brief body:

1. `## Kinnitatud õigus` — Tier A only
2. `## Tõendav materjal` — Tier B signals; linkage confidence + freshness
3. `## Lüngad` — partial coverage, stale data, name mismatch, export gaps
4. `## Inimülesanded` — **required** for launch-blocking human actions; copy
   verbatim into frontmatter `blocking_human_tasks` (or `[]` if none). The
   verdict gate matches this heading only (`Inimülesanded` / `Human Tasks`).
5. Optional `## Järgmised sammud` — non-blocking follow-ups only; never put
   blocking tasks here and never substitute it for `## Inimülesanded`.

Pure state-law runs may omit §§2–3. All sections count against the 150-line
gate cap. YAML frontmatter schema is unchanged.

## Safeguards

- HTTP 200 ≠ in force: require `status == "valid"` and `in_force == true`.
- KOV needs explicit municipality; default search is state law.
- Confirmed registry-code links only for company evidence.
- Do not infer wrongdoing, PEP status, insolvency, or liability from risk
  signals, ERJK, media, grants, or distress bands.
- Distress is not a credit rating or bankruptcy prediction.
- Disclose partial coverage, stale datasets, aggregation, and licensing.
- Cite underlying primary sources when the datalake provides them.
- Prefer `profile/full` over inventorying every company sub-endpoint.
- Never inventory OpenAPI or dump full API responses.
