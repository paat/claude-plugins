# Mutation ownership

Workers edit product source, tests, and canonical workflow specs but do not commit. Set a non-empty `SAAS_PHASE` for every worker so `hooks-paused.sh` makes automatic commit, handoff-index, compaction, and learning hooks no-op during the worker phase.

After the worker returns:

1. Run `delivery-route.sh check-diff --base "$BASE_SHA"` to classify and contain the diff.
2. Run any workflow-specific mechanical firewall.
3. Use `supervisor-commit.sh --message TEXT [--check PATH] [--firewall-script PATH]` to run the canonical product check, stage all product changes except `.startup/**`, and commit with normal Git hooks enabled.
4. Assert the new commit's parent is the expected base.
5. Open the PR and run the required tribunal before merge.

Leases provide temporal ownership before commit, and tribunal remains the independent post-commit review gate.
