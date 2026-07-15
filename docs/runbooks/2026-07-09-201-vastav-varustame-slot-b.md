# Runbook #201 — vastav + varustame into Slot B rotation

Execute only after the fresh Slot A soak in
[ai-dashboard #15](https://github.com/paat/ai-dashboard/issues/15) passes.
Canonical Slot B tracking is
[ai-dashboard #16](https://github.com/paat/ai-dashboard/issues/16). This file
retains only the project-specific runbook deltas.

## 1. Plugin upgrade (both containers)

- [ ] varustame: upgrade saas-startup-team to current, run the full preflight
      (`health-preflight.sh --require-gh --require-codex --check-sync`) and one
      supervised `$saas-startup-team:maintain-loop --once` before trusting the
      schedule.
- [ ] vastav: same upgrade + preflight (smaller jump).
- [ ] Both: verify `SAAS_LESSON_SYNC_ENABLED=true` (reach-back channel).
- [ ] Both: memory pass — same checklist categories as the Slot A runbook §2
      (grant memories, contradictions, stale deadlines, unsorted CLAUDE.md
      staging).

## 2. Project-specific corrections

- [ ] varustame: the external sign-off blocker stays parked as `needs-human`
      (per the merge-policy carve-outs); confirm the loop continues with the
      remaining backlog instead of stopping at the gate.
- [ ] varustame: apply the recorded sign-off-body correction to the
      launch-readiness doc — this is the sweep-back pilot case; note on #201
      how the correction was found so #196's sweep-back automation can copy it.
- [ ] vastav: once #204 (spend envelope) is in the container's plugin version,
      include growth passes in its rotation command mix.

## 3. Register in portfolio.json (cron host)

- [ ] Add both projects WITHOUT a slot pin — Slot B rotates by the priority
      ladder (live incidents > admitted pre-launch > validation > meta):
      vastav `stage: "live"`, varustame `stage: "pre-launch"`, engine `codex`,
      command `$saas-startup-team:maintain-loop --once`.
- [ ] Keep both projects at `hold: true` until Slot A acceptance passes. Then
      set `hold: false` while retaining `delivery_hold: true`; use the
      top-level `docker_exec_user: "dev"` and unrestricted ephemeral Codex.
- [ ] Disable each container's standalone cron lines (mission-control owns
      dispatch; see the Slot A runbook §3).
- [ ] Re-run `arm --config <path>`; human updates the cron line if it changed.

## 4. Acceptance

- [ ] Both projects receive scheduled Slot B passes with zero human kickoff
      (verify in `state/mission-control.log` over 2+ days).
- [ ] varustame launch-readiness doc correction merged.
- [ ] vastav executes a growth pass within rotation.
- [ ] Checklist and evidence recorded on ai-dashboard #16.
