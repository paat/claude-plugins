---
name: ads-monitor
description: Read live Google Ads metrics without repository or account writes. Requires a Google Ads user with server-enforced read-only access. Usage: /ads-monitor [campaign] [--range 7d|30d]
user_invocable: true
allowed-tools: Task, Read, Glob, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/check-metrics-preflight.sh:*)
argument-hint: [campaign] [--range 7d|30d]
codex-sandbox: read-only
---

# /ads-monitor — Read-only live metrics

Use this for autonomous observation. Its only shell capability is the bundled read-only preflight; it has no general Bash, Write, or Edit surface and delegates to a reader with no filesystem-write tools. The authenticated Google Ads principal must have the server-enforced **Read only** role; otherwise stop. On Codex, run the reader in a read-only sandbox or stop if that boundary is unavailable.

## Preflight

- Default range: `7d`; accept only `7d` or `30d`; reject other arguments.
- Resolve one campaign from `docs/ads/*/brief.md`; if ambiguous, ask. Reject unexpected arguments.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/check-metrics-preflight.sh --require-read-only docs/ads/<campaign>` directly. This read-only gate verifies lexical and physical path containment, symlinks, one real ISO launch timestamp, one unambiguous legacy/current ID pair, and exactly one `Google Ads metrics access: read-only` field.
- Use only the normalized IDs printed by the gate. The access field is a declaration, not proof: the reader must still verify the signed-in Ads user's role in the UI.

Any failure is a no-op: report it and do not open Google Ads.

## Dispatch

Spawn `google-ads-strategist:ads-metrics-reader` with the campaign, range, normalized customer ID, and numeric campaign ID. Do not load `browser-verification`; its persistent screenshot contract belongs to `/ads-metrics`.

The reader first verifies the signed-in user has Google Ads **Read only** access for the exact customer ID. If that role is not visible/verifiable, or is Standard/Admin, it stops before campaign navigation. It then reads only the exact campaign ID and returns visible overview, ad-group, Search Terms, and Auction Insights metrics plus baseline/prior deltas, dominant symptom, and wait-gate status.

## Relay

Render a metrics table only after the reader confirms read-only access, both IDs, and required overview metrics. Otherwise relay the exact access/evidence gap only. Never render false success, recommend an iteration, or write any artifact after a partial run.
