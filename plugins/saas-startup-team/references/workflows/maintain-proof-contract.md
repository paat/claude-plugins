# Maintain delivery proof contract

Read this file only while recording QA, tribunal, or live evidence. Never write
`passed` fields directly into a delivery receipt; `maintain-delivery.sh` alone
captures, validates, and binds proof to the active delivery.

## QA

For a non-browser diff, call:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-delivery.sh" record-proof \
  --repo-root "$WT" --issue "$N" --role "$ROLE" \
  --kind qa --not-applicable
```

The helper rejects this when the exact base-to-head diff contains a browser/UI
surface. Otherwise it emits a bound `no-browser-surface` assertion itself.

For browser-visible work, pass an existing regular, non-symlinked project smoke
script that is tracked unchanged at the receipt head. The helper runs it for at
most 30 minutes with these environment variables:

`MAINTAIN_PROOF_KIND`, `MAINTAIN_ISSUE_NUMBER`, `MAINTAIN_PR_NUMBER`, and
`MAINTAIN_HEAD_SHA`.

The script must print one JSON object and exit zero:

```json
{
  "schema_version": 1,
  "kind": "qa",
  "issue_number": 1,
  "pr_number": 1,
  "head_sha": "<receipt-head>",
  "status": "passed",
  "reason_code": "browser-acceptance",
  "observed_at": "<current-UTC-second>",
  "assertions": [
    {"id": "<stable-code>", "status": "passed", "detail_digest": "<sha256>"}
  ]
}
```

Every assertion must be concrete and the array nonempty. A bare success exit or
`{"status":"passed"}` is invalid.

The helper materializes the exact receipt commit into disposable `0700` roots,
then runs the tracked command under the active lease and a fail-closed Landlock
filesystem policy. Repository state, user configuration, agent credentials, and
container sockets are outside that policy. If a command needs project runtime
credentials, set the applicable controller session variable before starting the
workflow. Its value is a space-separated list of environment variable names:

```bash
export SAAS_MAINTAIN_QA_PROOF_ENV='APP_TEST_KEY APP_API_URL'
export SAAS_MAINTAIN_LIVE_PROOF_ENV='APP_MONITOR_KEY APP_API_URL'
```

This configuration must come from the controller session, never repository content.
Known infrastructure-authority families are rejected. Configure only
least-privilege project runtime variables; missing configured variables stop the
proof.

## Tribunal

Before arbitration, let the delivery helper run and retain the provider panel:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-delivery.sh" collect-tribunal \
  --repo-root "$WT" --issue "$N" --role "$ROLE" \
  --tribunal-plugin-root "$TRIBUNAL_PLUGIN_ROOT"
```

Read the retained collection and produce the exact arbitration JSON required by
the `tribunal-review` output contract. Then record it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-delivery.sh" record-proof \
  --repo-root "$WT" --issue "$N" --role "$ROLE" --kind tribunal \
  --artifact "$ARBITRATION_JSON" --tribunal-plugin-root "$TRIBUNAL_PLUGIN_ROOT"
```

The helper accepts only its own fresh PR/head-bound collection from the pinned
runner bundle, finalizes it through `tribunal-review`, and retains the proof digest.
The decision must be `APPROVE`, with no critical/high finding or
`must-remove-before-merge` scope finding. Raw provider files, a narrow verdict,
or a different arbitration on retry are invalid.

## Live

When `monitor.custom_checks` is configured, reuse that tracked monitor hook. Its
known plugin contract avoids a project-only proof wrapper:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-delivery.sh" record-proof \
  --repo-root "$WT" --issue "$N" --role "$ROLE" --kind live \
  --deploy-run-id "$DEPLOY_RUN_ID" --live-target-source "$TARGET_SOURCE" \
  --command-file "$CUSTOM_CHECKS" --live-command-contract monitor-hook
```

The helper requires the command to equal the single tracked `custom_checks`
binding, validates its findings JSONL, and records only stdout/stderr byte counts
and digests. Exit zero with no **release-blocking** findings proves the configured
monitor completed cleanly for deploy proof. Ambient product/ops metrics that are
not SHA-correlated (`funnel:drop:*`, fleet-wide `ops:llm-gap:failure`) are ignored
for the release gate (they remain `/monitor-nightly` signals). Any other finding
stops release and reports its blocking count plus stdout digest.

When the monitor hook cannot exercise the required acceptance, pass an existing
tracked live smoke script with the default `structured` contract. The script receives
`MAINTAIN_ISSUE_NUMBER`, `MAINTAIN_MERGE_SHA`, `MAINTAIN_DEPLOY_RUN_ID`, and
`MAINTAIN_LIVE_TARGET_SOURCE`, and must print:

```json
{
  "schema_version": 1,
  "kind": "live",
  "issue_number": 1,
  "merge_sha": "<receipt-merge>",
  "deploy_run_id": "<numeric-run-id>",
  "target_source": "<stable-code>",
  "status": "passed",
  "observed_at": "<UTC-second-after-deploy>",
  "assertions": [
    {"id": "<stable-code>", "status": "passed", "detail_digest": "<sha256>"}
  ]
}
```

The helper identifies the single merge-tracked deploy workflow and queries its
exact successful run before proof and again before release; `headSha` must equal
the recorded merge. Live proof expires after ten minutes before release.
The command and output are bounded, retained, and digested. Any changed command,
output, target, workflow, run, head, merge, timestamp, or assertion fails closed.
