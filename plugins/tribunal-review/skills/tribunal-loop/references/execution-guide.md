# Tribunal Loop Execution Guide

Shell mechanics for standalone runs and sealed PR delivery runs of `tribunal-loop`.

## Plugin Root & Preflight

```bash
TRIBUNAL_PLUGIN_ROOT="${TRIBUNAL_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${PLUGIN_ROOT:-${GROK_PLUGIN_ROOT:-${MUSE_PLUGIN_ROOT:-}}}}}}"
# When unset (e.g. agy skill runs where PLUGIN_ROOT is hook/MCP-only), set to ../.. of SKILL.md:
[ -f "$TRIBUNAL_PLUGIN_ROOT/scripts/preflight.sh" ] || { echo "Set TRIBUNAL_PLUGIN_ROOT to this plugin's root directory" >&2; exit 1; }
RUN_DIR="$(mktemp -d)"                          # collects one JSON file per leg
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/preflight.sh"
```

- Preflight resolves the repository default branch (`defaultBranchRef`, `git remote show origin`, then `origin/HEAD`), honors `TRIBUNAL_BASE_BRANCH` and `TRIBUNAL_BASE_REF`, refuses to review the default branch, verifies a diff with `git diff "$BASE_REF"...HEAD`, checks enabled CLIs/model registry entries, and reports usable/skipped/disabled active reviewer legs.
- Stop if preflight exits non-zero; otherwise report the base ref and active reviewer leg status before launching review.
- When the caller names a risk tier, prefix preflight and every review command with `TRIBUNAL_RISK=<T1..T4>` (shell environment does not persist between calls).
- Set `TRIBUNAL_SMOKE_PROBE=on` when CLI presence/auth is insufficient evidence; it makes one minimal bounded request through each usable default transport and removes failed probes from quorum.

## Parallel Review Invocation (Standalone)

Run the provider scripts as parallel shell calls, not Task agents. Each wrapper manages its own scratch dir, capped `AGENTS.md` / `reachability.md` injection, base-ref overrides, disabled markers, timeout, and output normalization:

```bash
mkdir -p "$RUN_DIR"
. "$TRIBUNAL_PLUGIN_ROOT/scripts/lib.sh" && tribunal_select_panel
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-codex-review.sh" > "$RUN_DIR/codex.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-gemini-review.sh" > "$RUN_DIR/gemini.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-deepseek-review.sh" > "$RUN_DIR/deepseek.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-qwen-review.sh" > "$RUN_DIR/qwen.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-grok-review.sh" > "$RUN_DIR/grok.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-muse-review.sh" > "$RUN_DIR/muse.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-claude-review.sh" > "$RUN_DIR/claude.json" &
wait
```

## Sealed PR Delivery Collect & Finalize

For a merge gate, standalone shell calls are not authoritative evidence. The delivery controller pins and validates `integrity/runner-bundle.json` with `scripts/check-runner-bundle.sh --expected-manifest-sha256 SHA` before collection, then invokes the aggregate runner:

```bash
collection_json="$(bash "$TRIBUNAL_PLUGIN_ROOT/scripts/collect-review-evidence.sh" collect \
  --repo-root "$REPO_ROOT" --pr "$PR_NUMBER" --output "$CONTROLLER_OWNED_COLLECTION")"
manifest_sha="$(printf '%s' "$collection_json" | jq -r .manifest_sha256)"
```

- For later rounds, pass `--prior-rejections FILE` (built per `closing-tribunal-loop`).
- The controller retains `manifest_sha`; never take it back from model output.
- The runner launches wrappers, assigns provider identity/status, and seals repository, PR body/base/head/diff, runner/wrapper provenance, provider artifacts, and timestamps. Read the retained provider files for Step 3.

After Step 3 inline arbitration, save the JSON to `arbitration.json` and finalize from the same unchanged plugin root (`TRIBUNAL_PLUGIN_ROOT` selects the script path; it cannot switch an invoked script's bundle):

```bash
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/collect-review-evidence.sh" finalize \
  --collection "$CONTROLLER_OWNED_COLLECTION" \
  --expected-manifest-sha256 "$manifest_sha" \
  --arbitration arbitration.json
```

Only the emitted `tribunal-proof/v1` digest is a delivery proof. Retrying with identical arbitration returns the retained proof; conflicting arbitration for that collection fails.

## Optional Scope Lens Guidance

When `TRIBUNAL_SCOPE_LENS=on`, judge changed files and hunks against the visible task, issue, plan, branch name, PR body, commit messages, and user instructions. Flag unrelated files, opportunistic refactors, unnecessary abstractions, defensive branches for impossible internal states, rename/reformat churn, and tests asserting unrelated implementation details. Do not reject an intentional refactor explicitly requested by the task.

Required `scope_findings` fields (full schema in `references/output-contract.md`): `id` (`S-001`), `path`, `why_out_of_scope`, `disposition` (`must-remove-before-merge` or `follow-up-only`), `conflicting_task_text` (when available), and `smallest_acceptable_diff`.
