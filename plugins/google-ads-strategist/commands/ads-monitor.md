---
name: ads-monitor
description: "Read live Google Ads metrics without repository or account writes. Requires a Google Ads user with server-enforced read-only access. Usage: /ads-monitor [campaign] [--range 7d|30d]"
user_invocable: true
allowed-tools: Task, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/run-monitor-preflight.sh:*)
argument-hint: "[campaign] [--range 7d|30d]"
codex-role: read-only
---

# /ads-monitor — Read-only live metrics

Use this for autonomous observation. Its only shell capability is the bundled read-only preflight; it has no general Bash, Read, Glob, Write, or Edit surface and delegates to a reader with no filesystem-write tools. The authenticated Google Ads principal must have the server-enforced **Read only** role; otherwise stop. On Codex, keep the role semantically read-only while the agent runs unrestricted inside the development-container security boundary.

## Preflight

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/run-monitor-preflight.sh` once, passing only the separately shell-quoted campaign and `--range` arguments supplied by the user. Never interpolate raw arguments into shell syntax. The wrapper defaults to `7d`, resolves a sole campaign when omitted, validates all arguments, and runs the read-only campaign gate.
- The wrapper reports every handled outcome as one JSON line. Expected prerequisite failures use `{"status":"blocked","terminal":true,"diagnostic":"..."}` with exit zero so they cannot be mistaken for recoverable tool errors. When `terminal` is true, relay only the decoded `diagnostic` verbatim and return immediately. Make no subsequent tool call: do not inspect files, infer another gap, retry, or dispatch the reader.
- Continue only when the result is valid JSON with `status` exactly `ready` and `terminal` exactly `false`. Use only its normalized campaign, range, and IDs. Any malformed output or tool failure is terminal and must not trigger another tool call.
- The persisted access field is a declaration, not proof: the reader must still verify the signed-in Ads user's role in the UI.

Any failure is a no-op: report it and do not open Google Ads.

## Dispatch

Spawn `google-ads-strategist:ads-metrics-reader` with `preflight_status=ready`, the campaign, range, normalized customer ID, and numeric campaign ID. Do not load `browser-verification`; its persistent screenshot contract belongs to `/ads-metrics`.

The reader first verifies the signed-in user has Google Ads **Read only** access for the exact customer ID. If that role is not visible/verifiable, or is Standard/Admin, it stops before campaign navigation. It then reads only the exact campaign ID and returns visible overview, ad-group, Search Terms, and Auction Insights metrics plus baseline/prior deltas, dominant symptom, and wait-gate status.

## Relay

Render a metrics table only after the reader confirms read-only access, both IDs, and required overview metrics. Otherwise relay the exact access/evidence gap only. Never render false success, recommend an iteration, or write any artifact after a partial run.

## Terminal response invariant

When the preflight JSON has `terminal: true`, the entire next and final assistant message must equal the decoded `diagnostic` byte-for-byte. Add no label, punctuation, Markdown, explanation, or remediation. End the turn immediately after that diagnostic. This invariant overrides normal response style.
