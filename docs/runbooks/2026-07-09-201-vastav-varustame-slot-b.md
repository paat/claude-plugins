# Runbook #201 — vastav + varustame into Slot B rotation

Executed after #200 has bedded in (>= 3 green days on Slot A). Refs
paat/claude-plugins#201. Same skeleton as the #200 runbook — only the deltas
and project specifics below. Tick boxes in a comment on #201.

## 1. Plugin upgrade (both containers)

- [ ] varustame: upgrade saas-startup-team v0.51.1 → current. The jump is ~24
      minor versions: after upgrade run the full preflight
      (`health-preflight.sh --require-gh --require-codex --check-sync`) and one
      supervised `/maintain --once` before trusting the schedule.
- [ ] vastav: same upgrade + preflight (smaller jump).
- [ ] Both: verify `SAAS_LESSON_SYNC_ENABLED=true` (reach-back channel).
- [ ] Both: memory pass — same checklist categories as #200 §2 (grant memories,
      contradictions, stale deadlines, unsorted CLAUDE.md staging).

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
      command `/maintain --once` (varustame: `/maintain-loop --once` if that is
      its current driver).
- [ ] Disable each container's standalone cron lines (mission-control owns
      dispatch; see #200 §3).
- [ ] Re-run `arm --config <path>`; human updates the cron line if it changed.

## 4. Acceptance

- [ ] Both projects receive scheduled Slot B passes with zero human kickoff
      (verify in `state/mission-control.log` over 2+ days).
- [ ] varustame launch-readiness doc correction merged.
- [ ] vastav executes a growth pass within rotation (after #204 lands).
- [ ] Checklist ticked on #201, then close #201.
