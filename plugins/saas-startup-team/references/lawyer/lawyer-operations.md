# Lawyer registry operations

Load only the section selected by `/lawyer`. Scripts run from the project root
and own `.startup/law-registry.json` plus `.startup/laws/`.

## Subcommands

- `register <slug> <act_id> <citation> <purpose> [--force]`

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-register.sh" \
    <slug> <act_id> "<citation>" "<purpose>" [--force]
  ```

  `slug` is kebab-case. `act_id` is integer search-result `.id`, not `rt_id` or
  an RT URL segment. Preserve superscript qualifiers. The script refuses
  non-valid/non-in-force provisions unless explicit `--force` is supplied and
  leaves no partial registry/snapshot write on failure.

- `unregister <slug>`:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-unregister.sh" <slug>`
- `ack <slug>`:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-ack.sh" <slug>`
- `ack-all`:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-ack-all.sh"`
- `issue <slug>`:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-issue.sh" <slug>`
- `status`:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-status.sh"`
- `check`:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/lawyer-check.sh"`

`ack`/`ack-all` belong inside the PR that updates every dependent `LAW:` file.
They re-fetch source text and refuse to bless a repealed/superseded provision.
`issue` is an explicit external mutation and requires authenticated `gh`.

## Interactive backlog review

Use this only when immediate user confirmation is available and
`lawyer-check.sh` found `needs_review=true` entries with no issue URL.

1. Run `lawyer-marker-scan.sh`. Warn about orphan registry entries/markers; do
   not auto-delete them.
2. Check every flagged slug's marker paths and stored `dependent_files`. Report
   missing snapshots, missing files, and marker mismatches as non-blocking
   warnings in the prompt.
3. If any unfiled flag exists, require `gh auth status`, a Git worktree, and an
   origin repository. Stop the interactive issue branch if these fail; the
   requested topic may still continue.
4. Run `lawyer-fixplan-collect.sh` for the exact affected files/snapshots. Spawn
   one Lawyer fix-plan task, not one per slug. It may write only a concise
   `docs/legal/õiguslik-*.md` plan and must not mutate registry/source.
5. Ask once whether to create deduplicated issues. “No” keeps every flag and
   continues the topic. “Yes” runs `lawyer-issue.sh <slug>` for each unfiled
   slug; the script records the URL only after successful creation.
6. Never acknowledge a flag in this flow. A later code-fix PR owns `ack`.

Filed flags produce a compact reminder with their URLs. A newly detected
change while an issue is open updates the durable registry signal but does not
silently rewrite the existing issue.

## State meanings

- `needs_review=false`: clean.
- `needs_review=true`, no URL: detected; interactive flow may offer issue
  creation, autonomous topic warns once and continues.
- `needs_review=true`, URL set: issue open; topic continues with a reminder.
- Only a verified `ack` in the corresponding fix branch returns the entry to
  clean.
