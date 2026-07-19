## Engineering principles

Follow KISS, YAGNI, and DRY on every change:

- **KISS** — simplest design that fully ships the product need. Prefer boring, managed infrastructure one founder can run alone. Do not add enterprise machinery (service splits, self-operated brokers, SSO/SAML/SCIM hierarchies, multi-region HA, heavyweight observability) unless `Done` or a concrete security, legal, reliability, or operability requirement needs it.
- **YAGNI** — no speculative features, premature abstractions, unused config, or defensive branches for states that cannot happen. Do not expand scope because a future idea might need it.
- **DRY** — remove *meaningful* duplication (copy-pasted logic or restated rules that will drift). Do not invent frameworks for two similar lines, and keep intentional decorrelated variants (e.g. independent review legs) separate.

These apply to product code, tests, docs, prompts, and agent workflows. Completeness of authentication, validation, payments/data correctness, backups/recovery, and honest failure states is never cut for "simplicity."
