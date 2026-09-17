# Card and register contract

The provider-neutral decision payload is `{"items": [card, ...]}`. IDs match snapshot item IDs;
use stable local draft IDs for proposed items. Exactly one card is required per snapshot item.
The same card fields apply to both directions; only prior-art lookup and disposition differ.

| Required field | Meaning / accepted values |
|---|---|
| `id` | String identifying the item within the source scope |
| `direction` | `existing` or `proposed` |
| `outcome` | Audience, trigger, consequence and coping path |
| `evidence` | Object with `class`; observations, counter-evidence and gaps when available |
| `necessity` | `required` or `discretionary`; explain obligations in the response |
| `readiness` | `ready`, `blocked` or `unknown`, independent of necessity; a non-empty snapshot `assignees` value is an ownership/readiness input (`Target owner` / prerequisites) |
| `response` | Smallest adequate intervention, retained acceptance, do-nothing consequence |
| `cost` | Qualitative marginal complexity/retrieval/review/operations burden |
| `disposition` | One token from the selected direction below |
| `priority` | Positive integer; required before discretionary, then smaller first |
| `prerequisites` | Array naming dependency, owner, review or evidence prerequisites |
| `next_task` | A concrete bounded task preserving minimum scope |
| `stop_condition` | When to stop or refresh instead of executing stale advice |
| `enforcement` | Object: `class` and actual `mechanism` |
| `code_refs` | Array of inspected source paths/ranges; empty for non-code work |

Evidence classes: `reproduced`, `source-reachable`, `hypothetical`, `unavailable`.
`outcome` and `cost` accept a non-empty string or object of non-empty string values.
An `unavailable` evidence object must omit `frequency`; do not substitute zero or “rare”.
Enforcement classes: `native`, `instruction-only`, `unavailable`.
Keep these fields concise; free-form prose belongs in the summary.

## Disposition by direction

| Existing item | Required qualification |
|---|---|
| `implement-minimally` | Proven need and minimum acceptance; readiness still controls eligibility |
| `consolidate-into` | Non-empty `target`; retain distinct obligations under the named owner |
| `verify-first` | Specify the decisive bounded check before building |
| `defer` | Non-empty `revisit_trigger`: `YYYY-MM-DD`, dependency `#N`, or `evidence: NAME` |
| `close-completed` | Acceptance satisfied at the relevant implementation/activation/verification stage |
| `close-duplicate` | Existing owner satisfies acceptance; preserve conditional closure and rationale |

| Proposed item | Required qualification |
|---|---|
| `do-not-file` | Explain why no durable tracked intervention is needed |
| `file-minimal` | `draft` {title, body}: minimal draft with evidence, acceptance, retained limitations; display “This draft has had no PII review.” |
| `append-to` | Non-empty `target`; existing item owns the same outcome |
| `fix-now-no-item` | Bounded already-authorized intervention recommended to the caller |
| `record-as-limitation` | Supported limitation permitted by policy, with accessible disclosure |

## Script-owned output

Resolve `WIT_ROOT` from `${CLAUDE_PLUGIN_ROOT}` in Claude Code or the installed plugin directory
containing this skill (`../..` relative to its directory) in Codex.

```bash
"$WIT_ROOT/scripts/wit-register.sh" --snapshot "$SNAPSHOT" --decisions "$DECISIONS" \
  --output-dir "$OUTPUT_DIR" --code-ref "$CODE_REFERENCE"
```

Omit `--code-ref` for non-code work; optional `--run-id ID` selects a run name.
The writer prints a new run directory under `OUTPUT_DIR/work-item-triage/`.
`WIT_NOW` permits a deterministic clock.
It refuses an existing run directory; never edit previous output to update an assessment.

Snapshots require `source: {system, scope}`, `fetched_at`, `completeness: complete|incomplete`,
`capability_limits: []` and `items: [{id, title, updatedAt, comments_fetched, completeness, ...}]`.
For drafts, copy lookup metadata without upgrading completeness, use null `updatedAt` and zero
`comments_fetched`, and reference existing matches in card evidence rather than inventing history.

`register.json` carries `schema_version`, `previous_run_id`, run metadata and validated `items`. Each row carries
source system/scope/item identity, fetch timestamp, source update timestamp, comments fetched,
completeness, inspected code commit and `supersedes: {run_id, disposition}` when previously assessed.
These facts come from the reader, git and prior register, never model-supplied provenance.
Source-specific raw fields stay outside the core card; provenance is a separate envelope.

The run also contains `summary.md` and `queue.md`; `pointer.json` identifies the
newest snapshot. The summary bounds detail to five cards by necessity, then priority; all decisions remain in the register.
Changing owner rulings or new evidence produce another run linked to the previous decision.
