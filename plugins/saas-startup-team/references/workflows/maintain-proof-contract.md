# Maintain proof contract (v3)

Proof and release evidence are recorded as immutable terminal fields on
`scripts/maintain-v3.sh release-facts`, not compatibility delivery receipts.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" release-facts record \
  --repo-root "$ROOT" --issue "$N" --state deploy_proof \
  --deploy-run-id "$DEPLOY_RUN_ID" --head-sha "$HEAD" --merge-sha "$MERGE"
```

Recovery steps (forward-only):

```
selected → revalidate_head → authorize_merge → merge_sha_pinned
  → record_merge → deploy_proof → close_issue → observe_closed → done
```

Do not trust an earlier green check: revalidate head before merge.
Tribunal / QA evidence IDs stay in PR comments or harness files; release-facts
store only SHAs, PR number, deploy run id, and recovery_step.
