# Legal Analysis Verdict Frontmatter Schema

Every written `docs/legal/õiguslik-*.md` document starts with this YAML frontmatter shape, validated by `scripts/legal-verdict-gate.sh --validate <doc>`:

```yaml
verdict: CONFIRMED | UNCONFIRMED | UNVERIFIABLE-IN-CORPUS
evidence_tier: A | B | C
blocking_human_tasks: []
claims:
  - id: <slug>
    verdict: CONFIRMED | UNCONFIRMED | UNVERIFIABLE-IN-CORPUS
    evidence_tier: A | B | C
    value: "<decision-relevant value>"
    source_url: <checked URL>
    quote: "<complete operative sentence>"
    verified_at: YYYY-MM-DD
    review_by: YYYY-MM-DD
```

## Field Rules

- `blocking_human_tasks`: Every launch-blocking approval, signature, filing, counsel review, or other manual decision listed under `## Inimülesanded` must appear verbatim in `blocking_human_tasks`, and vice versa.
- Use `[]` only when no blocking human tasks exist. Otherwise use an inline JSON string array or double-quoted, non-empty YAML block items.
- `quote`: Complete verbatim operative sentence (no `...`, `…`, `[...]`, or `[…]` omissions; never reconstruct missing words).
- `source_url`: Verified HTTPS primary source URL for `CONFIRMED` Tier A claims.
