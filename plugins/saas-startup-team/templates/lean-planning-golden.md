# Lean Direct-Feature Planning Golden Eval

This model-facing fixture checks that a concrete internal feature produces a reuse-first
solo-founder plan without a questionnaire or a parallel delivery platform.

## Evaluation Request

Add a weekly internal operations report to an existing SaaS product. The repository
already has a scheduled-job ritual, a report renderer, an internal notification adapter,
workflow specifications, access-control helpers, and CI deployment checks. Include the
small privacy note required for the report's existing operational data. Produce an
implementation plan.

## Expected Plan

- Discovery: make one targeted pass over the existing job, report, notification,
  workflow-spec, privacy, and test entrypoints; do not launch discovery agents.
- Scope: derive `Done`, `Preserve`, and `Out of Scope` from the request and existing
  behavior. No mandatory user questions are needed because cadence, audience, delivery,
  and data source already have repository conventions.
- Implementation: Reuse the existing scheduled-job ritual, report renderer, and internal
  notification adapter. Add only the report-specific composition and registration needed
  by those interfaces; do not add another scheduler, delivery framework, evidence store,
  or control plane.
- Evidence: inspect only the privacy rules relevant to the operational fields and internal
  recipients. Do not start a product-wide legal, market, or data audit.
- Verification: cover report contents and failure handling, authorization and redaction,
  the affected workflow specification, regression checks, CI deployment, and the existing
  rollback procedure.

## Rejected Output

- Mandatory product or operating questions whose answers are already established by the
  repository.
- Multiple discovery agents or a general market/legal audit.
- A new scheduling service, orchestration layer, evidence database, generic delivery
  framework, or heavyweight observability stack without a requirement or triggered gate.
- An MVP shortcut that drops privacy, correctness, regression, recovery, or deployment
  verification.
