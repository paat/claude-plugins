# Runbook #200 — migrate aruannik to Mission Control Slot A

Historical repository runbook; canonical execution tracking is now
[ai-dashboard #15](https://github.com/paat/ai-dashboard/issues/15).
Generic arming steps live in `plugins/mission-control/docs/runbook.md`; record
all rollout evidence on the dashboard issue.

## Preconditions

- [ ] claude-plugins clone on the cron host is at mission-control >= 0.5.5
      (`jq -r .version plugins/mission-control/.claude-plugin/plugin.json`)
- [x] [ai-dashboard PR #25](https://github.com/paat/ai-dashboard/pull/25)
      merged
- [ ] [ai-dashboard cutover #24](https://github.com/paat/ai-dashboard/issues/24)
      completed; keep every product entry at `hold: true` until then

## 1. Plugin upgrade (in the aruannik container)

- [ ] Update the marketplace clone and reinstall/refresh saas-startup-team to
      current. The epic's ~24
      manual merge-trigger turns are retired by the no-hold-tier policy +
      `templates/merge-policy.md` already in the plugin — no per-project config.
- [ ] `bash <plugin>/scripts/health-preflight.sh --require-gh --check-sync` green.
- [ ] Verify `SAAS_LESSON_SYNC_ENABLED=true` in the container environment (the
      lesson reach-back channel — epic hard requirement). If unset, set it in the
      container's persistent env (e.g. `/config/.profile` or compose env), then
      confirm the harvester files lesson-candidate issues to the plugin repo.

## 2. One-time memory reconciliation (one supervised session in aruannik)

Work through `/config/.claude/**/memory/` (or the project memory dir) and the
project CLAUDE.md:

- [ ] Auto-merge contradiction cluster: delete every per-run auto-merge grant
      memory and the `never-auto-merge`-style entries; replace with one pointer
      to the plugin's standing policy (`templates/merge-policy.md`). Do not
      restate the policy in memory.
- [ ] Legal-copy contradiction: keep the carve-out semantics — legal/compliance
      **interpretation** parks as needs-human; implementing a stated rule is
      autonomous. Delete whichever memory contradicts that.
- [ ] Retire the 5 dead one-off grant memories (expired scopes).
- [ ] Complaint-deadline entry: verify the real deadline; fix the date or delete
      the entry if lapsed.
- [ ] Drain the CLAUDE.md "Recent (unsorted)" staging block into proper sections
      (or delete items that no longer hold).
- [ ] Remove any memory that duplicates what the repo/plugin already records.

## 3. Register in portfolio.json (cron host)

- [ ] Add aruannik pinned to Slot A: `stage: "live"`, `engine: codex` (Codex is
      the default implementer pool),
      `command: "$saas-startup-team:maintain-loop --once"`, real
      container name + in-container repo path, `incident_labels` matching the
      repo's incident labels.
- [ ] Set top-level `docker_exec_user: "dev"`, use unrestricted ephemeral
      Codex, and set both `hold: true` and `delivery_hold: true`.
- [ ] After cutover #24 completes, change only aruannik to `hold: false`;
      leave both Slot B projects held.
- [ ] Disable the container's own standalone maintain/lessons cron lines —
      mission-control owns dispatch now (double-dispatch races the same locks).
- [ ] If mission-control delivers the digest, disable aruannik's own
      monitor-nightly digest send (two senders double-deliver — see arming
      runbook §9).
- [ ] `mission-control.sh arm --config <path>` validates; human installs/updates
      the single cron line (never an agent).

## 4. Acceptance (fresh 72-hour soak)

- [ ] `tick --dry-run` shows Slot A selecting aruannik; first real passes green
      in `state/mission-control.log`.
- [ ] >= 72 consecutive hours on the Slot A schedule with human turns limited to
      digest review + hard-human items (money, legal identity, credentials).
- [ ] Reconciliation checklist and evidence recorded on ai-dashboard #15.
- [ ] Post-deploy auto-revert path (#203) exercised once end-to-end on live: a
      `ui`-classified merge triggered a visual-smoke regression and the
      `revert/<pr-slug>` rollback restored a green deploy.
