# Mission-control generic pinned slots — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/mission-control.sh` slot handling N-slot generic: any slot with a `pinned` field continuously maintains that project; any slot without one walks the priority ladder. Two-slot `{A pinned, B ladder}` configs behave byte-identically (same pick order, same log lines).

**Architecture:** Pure refactor + generalization of one bash script. `pick_slot_a` → `pick_pinned <slot>` (parameterized), `pick_slot_b` → `pick_ladder` (rung 1 excludes ALL pinned projects), `cmd_tick` walks `.slots` keys (pinned slots sorted first, then ladder slots sorted) instead of hardcoded `for slot in A B`, `cmd_arm`/`cmd_status` go key-generic. Governor, wrapper, locks, dispatch records are already slot-name-parameterized — untouched.

**Tech Stack:** bash 4+, jq, flock; test harness = `MC_LIB_ONLY=1` sourcing + `*.tests.sh` files auto-run by `tests/run-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-07-17-mission-control-generic-pinned-slots-design.md` (approved). Read it before starting.

## Global Constraints

- Repo: `/mnt/data/ai/claude-plugins`, branch `feat/mission-control-generic-pinned-slots` (exists; spec commit a042168 is on it). All paths below relative to `plugins/mission-control/`.
- Backward compatibility is a hard requirement: with `{"A":{"pinned":X},"B":{}}` every log line, pick order, and exclusion must be identical to today. Generic log lines use `$slot`, which reproduces today's strings for A/B (`slot A idle`, `slot B reserve refused: ... — re-walking ladder without that engine`, ...).
- Slot semantics: `has("pinned")` on the slot object is the discriminator. `{}` = ladder slot. No cap on slot count.
- Slot keys must match `^[A-Za-z0-9_-]+$` (they become `slot-$X.lock` and dispatch-record basenames).
- Version bump 0.5.9 → 0.6.0 in **three** files: `plugins/mission-control/.claude-plugin/plugin.json`, `plugins/mission-control/.codex-plugin/plugin.json`, root `.claude-plugin/marketplace.json` (pre-push hook enforces sync; run `git config core.hooksPath .githooks` if not set).
- Repo rules: bash 4+/POSIX tools only, no project-specific values in plugin code, no comments restating code, keep both Claude and Codex plugin surfaces in sync.
- Full existing suite green: `bash plugins/mission-control/tests/run-tests.sh` (core, ladder, tick, admission, paused, skeleton, bus, notify, delivery-hold, digest-sections, exec-user, governor-*).
- Out of scope: steering-repo rollout config, Codex auth provisioning script, dev-container dispatch (spec "Out of scope" + rollout sections; owner steps listed at the end for handoff only).

## Known behavior deltas (accepted, from spec)

1. A config whose `.slots` lacks a `B` key no longer gets a phantom hardcoded B ladder walk (old `for slot in A B` ran B regardless of config). One test fixture relies on the phantom: `tick.tests.sh` `mkenv` declares only `slots:{A:{pinned:"alpha"}}` and three of its tests need the B ladder ("tick dispatches both slots", "second tick runs while a pass is live", "reserve refusal re-walks ladder") — Task 2 adds `B:{}` to that fixture (a no-op under the current hardcoded walk, so the suite stays green at every commit). `paused.tests.sh` already declares A+B; configs with `slots:{A:{}}` (`admission`, `exec-user`, `governor-*`, `delivery-hold`, `digest-sections`) never invoke `cmd_tick`.
2. `slots:{A:{}}` now means "ladder slot named A" instead of "pinned slot with no pin (always idle)". Same test-config audit applies: nothing observable changes in the suite.

---

### Task 1: Generic pick functions (`pick_pinned`, `pick_ladder`)

**Files:**
- Modify: `plugins/mission-control/scripts/mission-control.sh:63-67` (log comment), `:256-297` (pick functions), `:349-368` (two call sites only — names, not structure)
- Modify: `plugins/mission-control/tests/ladder.tests.sh` (rename call sites)
- Create: `plugins/mission-control/tests/slots-generic.tests.sh`

**Interfaces:**
- Produces: `pick_pinned <slot>` — stdout: project name or empty. `pick_ladder` — stdout: `"<rung> <name>"` or empty. `pinned_anywhere <name>` — exit 0 iff the project is pinned on any slot. Task 2's `cmd_tick` rewrite calls `pick_pinned "$slot"` and `pick_ladder` exactly as named here.

- [ ] **Step 1: Write the failing lib-level tests**

Create `plugins/mission-control/tests/slots-generic.tests.sh` (mkenv mirrors `ladder.tests.sh` style; `SD` set for later tasks):

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # $1: jq mutation, default identity — 3 slots: A pinned, B ladder, C pinned
  TD="$(mktemp -d)"
  mkdir -p "$TD/alpha" "$TD/beta" "$TD/gamma"
  jq -n --arg td "$TD" '{
    engines:{e:{pool:"p",cmd:"echo ran-{prompt} > MARKER"}}, pools:{p:{}},
    slots:{A:{pinned:"alpha"}, B:{}, C:{pinned:"gamma"}},
    projects:[
      {name:"alpha", container:"local", repo_path:($td+"/alpha"), stage:"live", engine:"e", command:"PA", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"beta",  container:"local", repo_path:($td+"/beta"),  stage:"live", engine:"e", command:"PB", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"gamma", container:"local", repo_path:($td+"/gamma"), stage:"live", engine:"e", command:"PC", hold:false, work_probe:"cat WORK 2>/dev/null"}
    ],
    admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' \
  | jq "${1:-.}" > "$TD/portfolio.json"
  SD="$TD/state"
}
lib() { MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" source "$MC"; }

mkenv; echo yes > "$TD/gamma/WORK"
t "pick_pinned is slot-parameterized (C -> gamma)" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_pinned C)" = gamma ] && [ -z "$(pick_pinned A)" ]'

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "ladder rung 1 excludes ALL pinned projects" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_ladder)" = "1 beta" ]'

mkenv; echo yes > "$TD/gamma/WORK"
t "only pinned work: ladder returns nothing" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  declare -F pick_ladder >/dev/null && [ -z "$(pick_ladder)" ]'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash plugins/mission-control/tests/slots-generic.tests.sh`
Expected: `FAIL` on all three, exit 1. (The third test needs the `declare -F` guard to fail honestly: `command not found` inside `$()` yields empty stdout, which `[ -z ... ]` would vacuously accept.)

- [ ] **Step 3: Implement the generic pick functions**

In `scripts/mission-control.sh`, replace `pick_slot_a()`/`pick_slot_b()` (lines 256–297) with:

```bash
pinned_anywhere() { # <name> — is this project pinned on any slot?
  jq -e --arg n "$1" '[.slots // {} | .[] | .pinned // empty] | index($n) != null' \
    "$MC_CONFIG" >/dev/null
}

pick_pinned() { # <slot>
  local slot="$1" p
  p="$(jq -r --arg s "$slot" '.slots[$s].pinned // empty' "$MC_CONFIG")"
  [ -n "$p" ] || return 0
  project_blocked "$p" && { log "slot $slot pinned $p blocked"; return 0; }
  engine_denied "$p" && return 0
  probe_work "$p" && echo "$p" || true
}

pick_ladder() {
  local n
  # rung 1: live incidents, excluding every pinned project
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pinned_anywhere "$n" && continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_incident "$n"; then state_set '.cursor["1"]=$n' --arg n "$n"; echo "1 $n"; return 0; fi
  done < <(rotate 1 $(names_by_stage live))
```

Rungs 2–4 are the current `pick_slot_b` lines 274–296 **byte-unchanged** (they select by stage; pinned projects are `live`, so no exclusion needed there — spec §"The code change" item 2). The local `pinned=` variable and its rung-1 comparison are gone.

Update the two call sites in `cmd_tick` by name only (structure unchanged in this task): line 351 `cand="$(pick_slot_a)"` → `cand="$(pick_pinned A)"`; line 360 `cand="$(pick_slot_b)"` → `cand="$(pick_ladder)"`.

Update the comment at line 65: `pick_slot_*` → `pick_pinned/pick_ladder`.

- [ ] **Step 4: Update ladder.tests.sh call sites**

```bash
sed -i 's/pick_slot_a/pick_pinned A/g; s/pick_slot_b/pick_ladder/g' plugins/mission-control/tests/ladder.tests.sh
```

(9 call sites; behavior assertions unchanged — that IS the regression check for the rename.)

- [ ] **Step 5: Run the affected suites**

Run: `bash plugins/mission-control/tests/slots-generic.tests.sh && bash plugins/mission-control/tests/ladder.tests.sh && bash plugins/mission-control/tests/tick.tests.sh && bash plugins/mission-control/tests/core.tests.sh`
Expected: all `pass=N fail=0`.

- [ ] **Step 6: Commit**

```bash
git add plugins/mission-control/scripts/mission-control.sh plugins/mission-control/tests/ladder.tests.sh plugins/mission-control/tests/slots-generic.tests.sh
git commit -m "refactor(mission-control): pick_pinned/pick_ladder — slot-generic pick, all-pins rung-1 exclusion"
```

---

### Task 2: Generic slot walk in `cmd_tick`

**Files:**
- Modify: `plugins/mission-control/scripts/mission-control.sh:111-113` (`slot_free` comment), `:334-371` (`cmd_tick`)
- Modify: `plugins/mission-control/tests/slots-generic.tests.sh` (append tick-level tests)

**Interfaces:**
- Consumes: `pick_pinned <slot>`, `pick_ladder` from Task 1.
- Produces: `slot_names <pinned|ladder>` — stdout: slot keys of that class, one per line, sorted. Task 3 does not consume it, but keep the name stable (status/arm stay on plain jq).

- [ ] **Step 1: Append the failing tick-level tests**

Append to `tests/slots-generic.tests.sh` **before** the final `echo "pass=..."` line (helpers mirror `tick.tests.sh`):

```bash
tick() { bash "$MC" tick --config "$TD/portfolio.json" "$@"; }
wait_outcomes() { # <count> — wait up to 5s for N outcome files
  local i=0
  while [ "$(ls "$SD/dispatches/"*.json 2>/dev/null | wc -l)" -lt "$1" ]; do
    i=$((i + 1)); [ "$i" -lt 50 ] || return 1; sleep 0.1
  done
}

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "three slots each dispatch their project on one tick" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 3 || exit 1
  grep -q ran-PA "$TD/alpha/MARKER" && grep -q ran-PB "$TD/beta/MARKER" && grep -q ran-PC "$TD/gamma/MARKER" || exit 1
  for s in A B C; do ls "$SD/dispatches/"*"-$s-"*.json >/dev/null || exit 1; done'

mkenv '.slots = {B:{}, C:{pinned:"gamma"}}'
echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "pinned-first: with quota 1 the pinned slot beats the ladder" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  cat > "$TD/gov.sh" <<'"'"'GOV'"'"'
governor_reserve() {
  ( flock -w 5 8 || exit 1
    local n; n="$(cat "$MC_STATE_DIR/q" 2>/dev/null || echo 0)"
    [ "$n" -lt 1 ] || exit 1
    echo $((n + 1)) > "$MC_STATE_DIR/q"
  ) 8>>"$MC_STATE_DIR/q.lock"
}
governor_envelope() { echo 1; }
governor_report() { if [ "$3" -eq 0 ]; then echo ok; else echo error; fi; }
governor_daily() { return 0; }
GOV
  MC_GOVERNOR="$TD/gov.sh" tick && wait_outcomes 1 || exit 1
  sleep 0.5
  [ -f "$TD/gamma/MARKER" ] && [ ! -f "$TD/beta/MARKER" ] &&
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 1 ] &&
  jq -e '"'"'.slot == "C" and .project == "gamma"'"'"' "$SD"/dispatches/*.json'

mkenv '.slots = {B:{}, D:{}}'
echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "multi-ladder smoke: two ladder slots pick different candidates" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 2 || exit 1
  [ -f "$TD/beta/MARKER" ] && [ -f "$TD/gamma/MARKER" ] &&
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 2 ]'

mkenv '.slots = {C:{pinned:"gamma"}, B:{}, A:{pinned:"alpha"}}'
echo yes > "$TD/alpha/WORK"; echo yes > "$TD/gamma/WORK"
t "within-class sort: slot A beats slot C under quota 1 despite C-first declaration" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  cat > "$TD/gov.sh" <<'"'"'GOV'"'"'
governor_reserve() {
  ( flock -w 5 8 || exit 1
    local n; n="$(cat "$MC_STATE_DIR/q" 2>/dev/null || echo 0)"
    [ "$n" -lt 1 ] || exit 1
    echo $((n + 1)) > "$MC_STATE_DIR/q"
  ) 8>>"$MC_STATE_DIR/q.lock"
}
governor_envelope() { echo 1; }
governor_report() { if [ "$3" -eq 0 ]; then echo ok; else echo error; fi; }
governor_daily() { return 0; }
GOV
  MC_GOVERNOR="$TD/gov.sh" tick && wait_outcomes 1 || exit 1
  sleep 0.5
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 1 ] &&
  jq -e '"'"'.slot == "A" and .project == "alpha"'"'"' "$SD"/dispatches/*.json'

mkenv '.slots = {A:{pinned:"alpha"}, B:{}}'
echo yes > "$TD/alpha/WORK"
t "legacy two-slot config: decision log lines byte-identical" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 1 || exit 1
  cut -d" " -f2- "$SD/mission-control.log" | grep -E "^(dispatch slot=|slot [A-Za-z0-9_-]+ )" > "$TD/got"
  printf "dispatch slot=A project=alpha engine=e envelope=90m\nslot B idle\n" | diff - "$TD/got"'
```

- [ ] **Step 2: Update the tick.tests.sh fixture (loses its phantom slot B)**

In `tests/tick.tests.sh` `mkenv()`, change `slots:{A:{pinned:"alpha"}},` to `slots:{A:{pinned:"alpha"}, B:{}},`. Three of its tests dispatch via the B ladder, which today exists only because `cmd_tick` hardcodes `for slot in A B`; after this task, undeclared slots don't run. Under the current code the added `B:{}` is ignored, so this edit is a no-op now — commit-by-commit the suite stays green.

Run: `bash plugins/mission-control/tests/tick.tests.sh`
Expected: `pass=N fail=0` (unchanged behavior).

- [ ] **Step 3: Run to verify the new tests fail**

Run: `bash plugins/mission-control/tests/slots-generic.tests.sh`
Expected: Task-1 tests still `ok`; "three slots" FAILs (only A and B dispatch — C is never walked by the hardcoded loop); "pinned-first" FAILs (no slot C); "multi-ladder smoke" FAILs (no slot D); "within-class sort" FAILs (no slot C); "legacy" passes already (it is a pure regression guard — if it fails, the harness snippet is wrong, fix the test).

- [ ] **Step 4: Implement the generic walk**

Add `slot_names` next to `names_by_stage` (line 199):

```bash
slot_names() { # <pinned|ladder> — slot keys of that class, sorted
  jq -r --arg w "$1" '.slots // {} | to_entries | sort_by(.key)[]
    | select((.value | has("pinned")) == ($w == "pinned")) | .key' "$MC_CONFIG"
}
```

In `cmd_tick`, replace the `for slot in A B; do ... done` block (lines 347–369) with:

```bash
  local slot cand tries
  for slot in $(slot_names pinned); do
    if ! slot_free "$slot"; then log "slot $slot busy"; continue; fi
    cand="$(pick_pinned "$slot")"
    if [ -n "$cand" ]; then
      dispatch "$slot" "$cand" || { DENIED_ENGINES+=("$(pj "$cand" '.engine')"); log "slot $slot reserve refused: $cand"; }
    else
      log "slot $slot idle"
    fi
  done
  for slot in $(slot_names ladder); do
    if ! slot_free "$slot"; then log "slot $slot busy"; continue; fi
    tries=0
    while :; do
      cand="$(pick_ladder)"
      [ -n "$cand" ] || { log "slot $slot idle"; break; }
      dispatch "$slot" "${cand#* }" && break
      DENIED_ENGINES+=("$(pj "${cand#* }" '.engine')")
      log "slot $slot reserve refused: $cand — re-walking ladder without that engine"
      tries=$((tries + 1))
      [ "$tries" -lt 4 ] || break
    done
  done
```

Notes locking this in: unquoted `$(slot_names ...)` word-splitting is the existing codebase idiom (`rotate 1 $(names_by_stage live)`), safe because arm (Task 3) rejects slot keys outside `[A-Za-z0-9_-]`. `DENIED_ENGINES` accumulates across ALL slots within the tick — same cross-slot semantics as today's A→B carry-over. Update the `slot_free` comment `# <A|B>` → `# <slot>`.

- [ ] **Step 5: Run the suites**

Run: `bash plugins/mission-control/tests/slots-generic.tests.sh && bash plugins/mission-control/tests/tick.tests.sh && bash plugins/mission-control/tests/paused.tests.sh && bash plugins/mission-control/tests/ladder.tests.sh`
Expected: all `pass=N fail=0`.

- [ ] **Step 6: Commit**

```bash
git add plugins/mission-control/scripts/mission-control.sh plugins/mission-control/tests/slots-generic.tests.sh plugins/mission-control/tests/tick.tests.sh
git commit -m "feat(mission-control): cmd_tick walks .slots generically — pinned slots first, then ladder slots"
```

---

### Task 3: Generic `cmd_arm` validation + `cmd_status`

**Files:**
- Modify: `plugins/mission-control/scripts/mission-control.sh:401-405` (arm slot validation), `:426-430` (status slot loop)
- Modify: `plugins/mission-control/tests/slots-generic.tests.sh` (append arm/status tests)

**Interfaces:**
- Consumes: nothing new. Arm error-message prefix style stays `mission-control: ...` + `exit 2`.

- [ ] **Step 1: Append the failing arm/status tests**

Append before the final `echo "pass=..."` line:

```bash
mkenv
t "arm accepts three-slot config" bash -c 'bash "$0" arm --config "$1/portfolio.json" | grep -q "mission-control.sh tick --config"' "$MC" "$TD"
t "arm rejects unknown pinned on any slot" bash -c '
  jq ".slots.C.pinned=\"nope\"" "$1/portfolio.json" > "$1/bad.json"
  ! bash "$0" arm --config "$1/bad.json"' "$MC" "$TD"
t "arm rejects bad slot name" bash -c '
  jq ".slots[\"C/x\"]={}" "$1/portfolio.json" > "$1/bad.json"
  ! bash "$0" arm --config "$1/bad.json"' "$MC" "$TD"
t "arm rejects one project pinned on two slots" bash -c '
  jq ".slots.C.pinned=\"alpha\"" "$1/portfolio.json" > "$1/bad.json"
  ! bash "$0" arm --config "$1/bad.json"' "$MC" "$TD"
t "status lists every configured slot" bash -c '
  out="$(bash "$0" status --config "$1/portfolio.json")"
  grep -q "slot A" <<<"$out" && grep -q "slot B" <<<"$out" && grep -q "slot C" <<<"$out"' "$MC" "$TD"
```

- [ ] **Step 2: Run to verify failures**

Run: `bash plugins/mission-control/tests/slots-generic.tests.sh`
Expected: "arm rejects unknown pinned on any slot" FAILs (today only `.slots.A.pinned` is checked), "arm rejects bad slot name" FAILs, "arm rejects one project pinned on two slots" FAILs, "status lists every configured slot" FAILs (no `slot C` line). "arm accepts three-slot config" already passes.

- [ ] **Step 3: Implement**

In `cmd_arm`, replace the A-only pinned block (lines 401–405):

```bash
  bad="$(jq -r '.slots // {} | keys[] | select(test("^[A-Za-z0-9_-]+$") | not)' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: slot names must match ^[A-Za-z0-9_-]+$: $bad" >&2; exit 2; fi
  bad="$(jq -r '. as $c | .slots // {} | to_entries[] | select(.value | has("pinned"))
                | .value.pinned as $pin
                | select(($pin | type) != "string"
                         or ([$c.projects[].name] | index($pin)) == null)
                | "slots.\(.key).pinned \($pin) is not a project"' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: $bad" >&2; exit 2; fi
  bad="$(jq -r '[.slots // {} | .[] | .pinned // empty] | group_by(.)[] | select(length > 1) | .[0]' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: project pinned on more than one slot: $bad" >&2; exit 2; fi
```

(The duplicate-pin check is an addition beyond the spec's validation list — Codex review recommended dropping it for spec purity. Kept deliberately: two slots pinning one project would run two concurrent maintenance passes against the same repo (slot locks are per-slot, not per-project), and the spec's own pinned-slot definition — "continuous maintenance of that one project" — implies uniqueness. One jq line + one test; call it out in the PR body so the owner can veto at merge.)

In `cmd_status`, replace `for s in A B; do`:

```bash
  local s
  for s in $(jq -r '.slots // {} | keys[]' "$MC_CONFIG"); do
    if slot_free "$s"; then echo "slot $s: free"; else echo "slot $s: RUNNING"; fi
  done
```

(`keys` is jq-sorted → A, B order preserved for legacy configs.)

- [ ] **Step 4: Run the suites**

Run: `bash plugins/mission-control/tests/slots-generic.tests.sh && bash plugins/mission-control/tests/core.tests.sh`
Expected: all `pass=N fail=0` (core.tests.sh exercises legacy arm+status strings).

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts/mission-control.sh plugins/mission-control/tests/slots-generic.tests.sh
git commit -m "feat(mission-control): arm validates all slots (pins, key charset, dup pins); status iterates .slots"
```

---

### Task 4: Version 0.6.0 + description/docs sync

**Files:**
- Modify: `plugins/mission-control/.claude-plugin/plugin.json` (version, description)
- Modify: `plugins/mission-control/.codex-plugin/plugin.json` (version, description, interface.shortDescription, interface.longDescription)
- Modify: `.claude-plugin/marketplace.json` (root — mission-control entry: version, description)
- Modify: `plugins/mission-control/README.md` (intro paragraph)

**Interfaces:** none (metadata only).

- [ ] **Step 1: Bump versions and descriptions**

New version: `0.6.0`. New description (all four description fields get the same string):

```
Portfolio supervisor: N-slot scheduler (pinned maintenance slots + priority-ladder slots) + budget governor keeping autonomous SaaS loops running 24/7 from one human-installed cron line, spending zero LLM tokens on scheduling
```

README.md intro paragraph (lines 3–8) becomes:

```markdown
Portfolio supervisor for autonomous SaaS loops: N concurrent loop slots
(lockfile-enforced), armed by one human-installed cron line, spending zero
LLM tokens on scheduling. A slot with a `pinned` project continuously
maintains it, optionally on a dedicated engine subscription; slots without a
pin rotate by priority ladder: live incidents > pre-launch delivery > demand
validation > lessons-deliver. A budget governor (quotas, rate-limit backoff,
pass envelopes) guards the per-pool subscription budgets.
```

Add this spec to the README "Design:" line: `...2026-07-17-mission-control-generic-pinned-slots-design.md`.

- [ ] **Step 2: Verify nothing was missed**

Run: `cd /mnt/data/ai/claude-plugins && grep -rn "0\.5\.9\|two-slot" plugins/mission-control/ .claude-plugin/marketplace.json .agents/plugins/marketplace.json --include="*.json" --include="README.md"`
Expected: no hits in manifests/marketplaces/README. Historical specs/plans under `docs/superpowers/` legitimately mention `0.5.9` and old wording — do NOT rewrite them; only manifest/marketplace version fields and current product wording (README, descriptions) change.

Run: `bash plugins/mission-control/tests/skeleton.tests.sh`
Expected: `pass=N fail=0` (example config untouched — legacy A/B example remains valid and demonstrates back-compat).

- [ ] **Step 3: Commit**

```bash
git add plugins/mission-control/.claude-plugin/plugin.json plugins/mission-control/.codex-plugin/plugin.json .claude-plugin/marketplace.json plugins/mission-control/README.md
git commit -m "chore(mission-control): 0.6.0 — N-slot scheduler wording, README slot semantics"
```

---

### Task 5: Full verification + PR

**Files:** none new.

- [ ] **Step 1: Full suite**

Run: `bash plugins/mission-control/tests/run-tests.sh`
Expected: every file ends `pass=N fail=0`, overall exit 0.

- [ ] **Step 2: Manual smoke (dry-run, three slots)**

```bash
TD="$(mktemp -d)"; mkdir -p "$TD/x"
jq -n --arg td "$TD" '{engines:{e:{pool:"p",cmd:"echo {prompt}"}},pools:{p:{}},
  slots:{A:{pinned:"x1"},B:{},C:{pinned:"x2"}},
  projects:[{name:"x1",container:"local",repo_path:($td+"/x"),stage:"live",engine:"e",command:"c",hold:false,work_probe:"echo w"},
            {name:"x2",container:"local",repo_path:($td+"/x"),stage:"live",engine:"e",command:"c",hold:false,work_probe:"echo w"}],
  admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/p.json"
bash plugins/mission-control/scripts/mission-control.sh tick --config "$TD/p.json" --dry-run
bash plugins/mission-control/scripts/mission-control.sh status --config "$TD/p.json"
rm -rf "$TD"
```

Expected: dry-run prints `DRY: would dispatch slot=A project=x1 ...` then `slot=C project=x2` then `slot B idle` (in that order — pinned first); status lists slots A, B, C.

- [ ] **Step 3: Push + PR**

```bash
git push -u origin feat/mission-control-generic-pinned-slots
gh pr create --title "mission-control 0.6.0: generic pinned slots (N-slot scheduler)" --body "$(cat <<'EOF'
Implements docs/superpowers/specs/2026-07-17-mission-control-generic-pinned-slots-design.md.

- pick_slot_a/pick_slot_b -> pick_pinned <slot> / pick_ladder; ladder rung 1 now excludes every pinned project
- cmd_tick walks .slots keys: pinned slots (sorted) first, then ladder slots (sorted) — legacy {A pinned, B ladder} configs behave identically, same log lines
- cmd_arm validates all slots: pins must name projects, slot keys ^[A-Za-z0-9_-]+$, one project cannot be pinned twice (dup-pin check is a deliberate one-line extension beyond the spec's validation list — two slots pinning one project would run concurrent passes on the same repo; veto here if unwanted); cmd_status iterates .slots
- new tests/slots-generic.tests.sh (3-slot dispatch, all-pins rung-1 exclusion, pinned-first under quota 1, within-class sort order, multi-ladder smoke, arm rejections, byte-exact legacy decision-log regression); full suite green
- 0.5.9 -> 0.6.0 in both plugin manifests + marketplace.json

Verified: bash plugins/mission-control/tests/run-tests.sh (all pass), 3-slot dry-run smoke.
EOF
)"
```

Expected: PR URL printed. Merge follows the PR #307 flow (tests green → merge).

## Post-merge rollout (owner steps — NOT tasks in this plan, listed for handoff)

The spec's auth-provisioning script cannot live in this plugin repo (repo rule: no hardcoded project names/paths in plugin code — the script is aruannik-specific). It is a **steering-repo deliverable for the rollout session**, not left undefined: author `scripts/run-codex-aruannik-auth.sh` in `/mnt/data/ai/steering` per the staged-script convention (human types exactly one line; verification inside the script). It must: copy `$CODEX_HOME/auth.json` (+ `config.toml` if present) out of the `est-biz-aruannik-dev` container into `/config/.codex-aruannik/` (dir 0700, files 0600, owner abc), then run a `CODEX_HOME=/config/.codex-aruannik codex login status` check and print one PASS/FAIL line.

Rollout order per spec: (1) merge PR, fast-forward the webtop checkout that cron runs from; (2) owner edits steering-repo `portfolio.json` — add slot `C` pinned to est-biz-aruannik, `codex-aruannik` engine (`CODEX_HOME=/config/.codex-aruannik ...`) and pool (`daily_pass_quota: 12`), set aruannik's `engine`; (3) human runs the staged auth one-liner and sees PASS. Next :00/:30 tick starts Slot C; no re-arm needed.
