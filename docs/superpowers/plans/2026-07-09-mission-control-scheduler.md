# Mission Control Scheduler (#198) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** New generic `plugins/mission-control` plugin: a zero-LLM-token bash scheduler that keeps at most two autonomous loops running across a portfolio, per `docs/superpowers/specs/2026-07-09-mission-control-scheduler-design.md` (read it first; it is the authority on semantics).

**Architecture:** One dispatcher script (`mission-control.sh`) with subcommands `tick|arm|status|wrapper`, sourcing a governor library (stub in this plan; #199 fills it). Per-host `portfolio.json` config; flock-enforced slots; mechanical `gh` probes via `docker exec`; detached pass wrappers inheriting the slot-lock FD.

**Tech Stack:** bash 4+, jq, flock, GNU date, docker CLI, gh (inside containers). No LLM calls anywhere in this plugin's scripts.

## Global Constraints

- Plugin code fully generic: no real project/container names anywhere except `examples/` placeholder values and docs prose (test enforces).
- All state mutations of `state.json` happen under `state.lock` via tmp-file + `mv`.
- `--dry-run` mutates nothing and dispatches nothing.
- The tick spends zero LLM tokens; busy-slot and all-local ticks make zero docker calls.
- `arm` prints; it never installs cron entries or writes outside the state dir.
- Version `0.1.0` in BOTH `plugins/mission-control/.claude-plugin/plugin.json` AND root `.claude-plugin/marketplace.json`.
- Shell style: `set -euo pipefail`, absolute paths, quote everything; non-login `bash -c` for all container/local execs.
- Commit after each task; messages `mission-control: <what>` — no `Closes #198` until the final task.

---

### Task 1: Plugin skeleton, manifests, example config, test harness

**Files:**
- Create: `plugins/mission-control/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json` (append plugin entry)
- Create: `plugins/mission-control/README.md`
- Create: `plugins/mission-control/examples/portfolio.example.json`
- Create: `plugins/mission-control/tests/run-tests.sh`
- Create: `plugins/mission-control/tests/skeleton.tests.sh`

**Interfaces:**
- Produces: `examples/portfolio.example.json` — the config shape every later task parses; test helper conventions (`t`, `setup`) reused by later test files.

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/skeleton.tests.sh`:

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

t "plugin.json parses"          jq -e '.name == "mission-control" and .version == "0.1.0"' "$PLUGIN/.claude-plugin/plugin.json"
t "marketplace entry exists"    jq -e '.plugins[] | select(.name == "mission-control") | .version == "0.1.0"' "$REPO_ROOT/.claude-plugin/marketplace.json"
t "example config parses"       jq -e '.engines and .pools and .slots and .projects and .admission' "$PLUGIN/examples/portfolio.example.json"
t "example engines have pool+cmd" jq -e '[.engines[] | has("pool") and has("cmd")] | all' "$PLUGIN/examples/portfolio.example.json"
t "example projects complete"   jq -e '[.projects[] | has("name") and has("container") and has("repo_path") and has("stage") and has("engine") and has("command") and has("hold")] | all' "$PLUGIN/examples/portfolio.example.json"
t "README has Installation"     grep -q '^## Installation' "$PLUGIN/README.md"
t "no real project names"       bash -c '! grep -rEiq "aruannik|varustame|vastav|reklaamivaht|est-biz" "$0"/scripts "$0"/commands "$0"/tests "$0"/examples 2>/dev/null' "$PLUGIN"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

`plugins/mission-control/tests/run-tests.sh`:

```bash
#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
rc=0
for f in ./*.tests.sh; do
  echo "== $f"
  bash "$f" || rc=1
done
exit $rc
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/mission-control/tests/run-tests.sh`
Expected: FAIL lines for every check (files missing).

- [ ] **Step 3: Create the manifests, example config, and README**

`plugins/mission-control/.claude-plugin/plugin.json`:

```json
{
  "name": "mission-control",
  "version": "0.1.0",
  "description": "Portfolio supervisor: two-slot scheduler + budget governor keeping at most two autonomous SaaS loops running 24/7 from one human-installed cron line, spending zero LLM tokens on scheduling",
  "author": {
    "name": "Andre Paat"
  },
  "repository": "https://github.com/paat/claude-plugins",
  "license": "MIT",
  "keywords": [
    "scheduler",
    "autonomous-loops",
    "portfolio",
    "budget-governor",
    "cron"
  ]
}
```

Append to `.plugins` array in root `.claude-plugin/marketplace.json` (keep existing entries untouched):

```json
{
  "name": "mission-control",
  "description": "Portfolio supervisor: two-slot scheduler + budget governor keeping at most two autonomous SaaS loops running 24/7 from one human-installed cron line, spending zero LLM tokens on scheduling",
  "version": "0.1.0",
  "author": {
    "name": "Andre Paat"
  },
  "source": "./plugins/mission-control",
  "category": "development",
  "homepage": "https://github.com/paat/claude-plugins"
}
```

`plugins/mission-control/examples/portfolio.example.json` (placeholder names only):

```json
{
  "timezone": "Europe/Tallinn",
  "docker_cmd": "sudo docker",
  "notify_env": "MC_NTFY_URL",
  "digest_hour": 7,
  "retention_days": 14,
  "engines": {
    "claude-opus": {
      "pool": "claude",
      "cmd": "claude --model opus --dangerously-skip-permissions -p '{prompt}'"
    },
    "codex": {
      "pool": "codex",
      "cmd": "codex exec --dangerously-bypass-approvals-and-sandbox '{prompt}'"
    }
  },
  "pools": {
    "claude": { "daily_pass_quota": 6 },
    "codex": { "daily_pass_quota": 8 }
  },
  "slots": {
    "A": { "pinned": "project-a" },
    "B": {}
  },
  "projects": [
    {
      "name": "project-a",
      "container": "project-a-dev",
      "repo_path": "/workspace/project-a",
      "stage": "live",
      "engine": "codex",
      "command": "/maintain --once",
      "hold": false,
      "incident_labels": ["incident", "production", "critical"]
    },
    {
      "name": "project-b",
      "container": "project-b-dev",
      "repo_path": "/workspace/project-b",
      "stage": "pre-launch",
      "engine": "codex",
      "command": "/maintain-loop --once",
      "hold": false
    },
    {
      "name": "plugin-repo",
      "container": "local",
      "repo_path": "/path/to/plugin-repo",
      "stage": "meta",
      "engine": "claude-opus",
      "command": "/lessons-deliver --once",
      "hold": false
    }
  ],
  "admission": { "wip_cap": 1, "confidence_min": 0.7, "veto_hours": 72 }
}
```

`plugins/mission-control/README.md`:

```markdown
# mission-control

Portfolio supervisor for autonomous SaaS loops: at most two 24/7 loop slots
(lockfile-enforced), armed by one human-installed cron line, spending zero
LLM tokens on scheduling. Slot A continuously maintains a pinned live
product; Slot B rotates by priority ladder: live incidents > pre-launch
delivery > demand validation > lessons-deliver. A budget governor (quotas,
rate-limit backoff, pass envelopes) guards two subscription pools.

Design: `docs/superpowers/specs/2026-07-09-mission-control-scheduler-design.md`
and `...-governor-design.md` in this repository.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install mission-control@paat-plugins`
- **Install for all collaborators on this repository** (project scope) —
  commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in
  `.claude/settings.local.json`.

The scheduler itself runs from cron, not from a Claude session: see
`docs/runbook.md` for the one-time arming procedure.

## Dependencies

- bash 4+, `jq`, `flock` (util-linux), GNU `date`, `curl` (push notifications)
- `docker` CLI reaching the project dev containers (set `docker_cmd` to
  `sudo docker` if the cron user lacks docker socket group membership)
- `gh` CLI authenticated *inside each project container* (probes run there)

## Configuration

Copy `examples/portfolio.example.json` to a host path of your choice (e.g.
`~/.config/mission-control/portfolio.json`) and edit. The file is per-host
and never committed to this repo. Schema: see the design spec table. State
lives in a sibling `state/` directory (override with `state_dir`).

## Engine routing

Stated once, here: Codex is the default `engine` for every product entry;
`claude-opus` is reserved for `meta` (lessons-deliver) and entries the owner
marks for architecture, UX, or Estonian-language judgment. Slots and pools
are decoupled — the governor charges each pass to the pool of the engine
that actually ran.

## Commands

- `/mission-status` — read-only view of slots, quotas, backoffs, admissions,
  and recent dispatch outcomes.

## Scripts

- `scripts/mission-control.sh {tick|arm|status} --config <path> [--dry-run]`
- `scripts/governor.sh` — budget policy library sourced by the dispatcher
- `scripts/notify.sh <ENV_VAR_NAME> <title>` — minimal push sender, body on
  stdin; no-op when the env var is unset
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/run-tests.sh`
Expected: `pass=7 fail=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control .claude-plugin/marketplace.json
git commit -m "mission-control: plugin skeleton, manifests, example config, test harness"
```

---

### Task 2: notify.sh

**Files:**
- Create: `plugins/mission-control/scripts/notify.sh`
- Create: `plugins/mission-control/tests/notify.tests.sh`

**Interfaces:**
- Produces: `notify.sh <ENV_VAR_NAME> <title>` reading body from stdin; exit 0 always (push failures must never fail a tick); no-op when env var unset/empty.

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/notify.tests.sh`:

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/bin"
cat > "$TD/bin/curl" <<'SH'
#!/bin/bash
echo "curl $*" >> "$CURL_CALLS"
cat >> "$CURL_CALLS"
exit "${CURL_RC:-0}"
SH
chmod +x "$TD/bin/curl"
export PATH="$TD/bin:$PATH" CURL_CALLS="$TD/curl.calls"
: > "$CURL_CALLS"

unset MC_TEST_URL || true
t "unset env var: exit 0, no curl" bash -c 'echo body | bash "$0/scripts/notify.sh" MC_TEST_URL title && [ ! -s "$CURL_CALLS" ]' "$PLUGIN"

export MC_TEST_URL="https://ntfy.example/topic"
t "set env var: curl called with URL and title" bash -c 'echo hello | bash "$0/scripts/notify.sh" MC_TEST_URL "mc: test" && grep -q "ntfy.example/topic" "$CURL_CALLS" && grep -q "mc: test" "$CURL_CALLS" && grep -q "^hello$" "$CURL_CALLS"' "$PLUGIN"

CURL_RC=22 t "curl failure still exits 0" bash -c 'echo x | bash "$0/scripts/notify.sh" MC_TEST_URL t' "$PLUGIN"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/mission-control/tests/notify.tests.sh`
Expected: FAIL (script missing).

- [ ] **Step 3: Write notify.sh**

`plugins/mission-control/scripts/notify.sh`:

```bash
#!/bin/bash
# notify.sh <ENV_VAR_NAME> <title> — POST stdin body to the URL held in the
# named env var (ntfy/webhook contract). Unset var = silent no-op. Never
# fails the caller: push loss must not break a scheduler tick.
set -uo pipefail
VAR="${1:?usage: notify.sh ENV_VAR_NAME TITLE}"
TITLE="${2:?usage: notify.sh ENV_VAR_NAME TITLE}"
URL="${!VAR:-}"
[ -n "$URL" ] || exit 0
curl -fsS -m 15 -H "Title: $TITLE" --data-binary @- "$URL" >/dev/null 2>&1 || true
exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/notify.tests.sh`
Expected: `pass=3 fail=0`.

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts/notify.sh plugins/mission-control/tests/notify.tests.sh
git commit -m "mission-control: minimal push sender"
```

---

### Task 3: mission-control.sh core — config/state/lock helpers, governor stub, arm, status

**Files:**
- Create: `plugins/mission-control/scripts/mission-control.sh`
- Create: `plugins/mission-control/scripts/governor.sh`
- Create: `plugins/mission-control/tests/core.tests.sh`

**Interfaces:**
- Produces (used by every later task): globals `MC_CONFIG`, `MC_STATE_DIR` (exported), `DOCKER_CMD`, `TZCFG`, `DRY_RUN`; functions `cfg <jq-filter>`, `state_get <jq-filter>`, `state_set <jq-prog> [jq-opts…]`, `now`, `today`, `log <msg>`, `alert <key> <msg>`, `run_in <container> <repo_path> <snippet> <timeout_s>`, `docker_check`, `slot_free <A|B>`; governor stub functions `governor_reserve <engine>`, `governor_envelope <engine> <project>`, `governor_report <engine> <project> <exit_code> <log_path>`, `governor_daily`.
- Produces: `MC_LIB_ONLY=1 source mission-control.sh` loads helpers without executing a subcommand (test seam, also used by #199's tests). `MC_GOVERNOR=<path>` overrides which governor file is sourced. `MC_NOW_EPOCH` overrides `now` for deterministic tests.

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/core.tests.sh`:

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
jq -n '{engines:{e:{pool:"p",cmd:"echo {prompt}"}}, pools:{p:{}}, slots:{A:{pinned:"alpha"}},
        projects:[{name:"alpha",container:"local",repo_path:"'"$TD"'",stage:"live",engine:"e",command:"true",hold:false}],
        admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/portfolio.json"

# lib seam loads helpers without running a subcommand
t "lib seam"        bash -c 'MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" && type cfg state_set governor_reserve >/dev/null' "$MC" "$TD"
t "state dir created" bash -c 'MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" && [ -d "$1/state/dispatches" ] && jq -e . "$1/state/state.json"' "$MC" "$TD"
t "state_set atomic + persisted" bash -c 'MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" && state_set ".x=\$v" --arg v hi && [ "$(state_get .x)" = hi ]' "$MC" "$TD"
t "MC_NOW_EPOCH overrides now" bash -c 'MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" MC_NOW_EPOCH=1000 source "$0" && [ "$(now)" = 1000 ]' "$MC" "$TD"
t "slot_free true then false" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="$1/portfolio.json" source "$0" || exit 1
  slot_free A || exit 1
  ( flock 9; sleep 2 ) 9>>"$MC_STATE_DIR/slot-A.lock" &
  sleep 0.3
  ! slot_free A' "$MC" "$TD"

# arm: validates and prints, writes nothing outside state
t "arm prints cron line" bash -c 'bash "$0" arm --config "$1/portfolio.json" | grep -q "mission-control.sh tick --config"' "$MC" "$TD"
t "arm mentions crontab file + lessons removal" bash -c 'out="$(bash "$0" arm --config "$1/portfolio.json")"; grep -q "crontab" <<<"$out" && grep -qi "lessons-deliver" <<<"$out"' "$MC" "$TD"
t "arm rejects unknown engine" bash -c '
  jq ".projects[0].engine=\"nope\"" "$1/portfolio.json" > "$1/bad.json"
  ! bash "$0" arm --config "$1/bad.json"' "$MC" "$TD"

# status runs read-only
t "status prints slots" bash -c 'bash "$0" status --config "$1/portfolio.json" | grep -q "slot A"' "$MC" "$TD"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/mission-control/tests/core.tests.sh`
Expected: FAIL (scripts missing).

- [ ] **Step 3: Write governor.sh (stub) and mission-control.sh core**

`plugins/mission-control/scripts/governor.sh`:

```bash
#!/bin/bash
# governor.sh — budget policy library sourced by mission-control.sh AFTER its
# helpers are defined; may use cfg/state_get/state_set/now/today/alert and
# the exported MC_CONFIG / MC_STATE_DIR. This is the #198 STUB: permissive,
# stateless. #199 replaces the bodies; the signatures are the contract.

# Atomic check-and-reserve for one pass on this engine's pool. Exit 0 = may
# dispatch (reservation taken), exit 1 = refused. Stub: always allow.
governor_reserve() { # <engine>
  return 0
}

# Print the pass wall-clock envelope in minutes.
governor_envelope() { # <engine> <project>
  echo 90
}

# Post-pass accounting; print the outcome word (ok|rate-limit|timeout|error).
governor_report() { # <engine> <project> <exit_code> <log_path>
  if [ "$3" -eq 0 ]; then echo ok; else echo error; fi
}

# Daily digest/housekeeping; owns its own once-per-day guard. Stub: no-op.
governor_daily() {
  return 0
}
```

`plugins/mission-control/scripts/mission-control.sh` (core; ladder/dispatch/tick bodies arrive in Tasks 4–6 — include the placeholders exactly as shown so later tasks replace them):

```bash
#!/bin/bash
# mission-control.sh — portfolio scheduler. Deterministic bash: the tick
# spends zero LLM tokens; only dispatched passes think.
# Usage: mission-control.sh {tick|arm|status} --config <path> [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: mission-control.sh {tick|arm|status} --config <path> [--dry-run]" >&2; exit 2; }

# ---------- argument parsing (skipped when sourced as a library) ----------
CMD=""; MC_CONFIG="${MC_CONFIG:-}"; DRY_RUN=0
declare -A WRAP=()
if [ "${MC_LIB_ONLY:-0}" != 1 ]; then
  CMD="${1:-}"; shift || usage
  while [ $# -gt 0 ]; do
    case "$1" in
      --config)    MC_CONFIG="${2:?--config needs a value}"; shift 2 ;;
      --dry-run)   DRY_RUN=1; shift ;;
      --slot|--project|--engine|--container|--repo-path|--envelope|--base|--cmd)
                   WRAP[${1#--}]="${2:?$1 needs a value}"; shift 2 ;;
      *) usage ;;
    esac
  done
fi

[ -n "$MC_CONFIG" ] && [ -f "$MC_CONFIG" ] || { echo "mission-control: config not found: '$MC_CONFIG'" >&2; exit 2; }

# ---------- config / state helpers ----------
cfg() { jq -r "$1" "$MC_CONFIG"; }

MC_STATE_DIR="$(cfg '.state_dir // empty')"
[ -n "$MC_STATE_DIR" ] || MC_STATE_DIR="$(cd "$(dirname "$MC_CONFIG")" && pwd)/state"
export MC_CONFIG MC_STATE_DIR
mkdir -p "$MC_STATE_DIR/dispatches" "$MC_STATE_DIR/digests"
[ -f "$MC_STATE_DIR/state.json" ] || echo '{}' > "$MC_STATE_DIR/state.json"

DOCKER_CMD="$(cfg '.docker_cmd // "docker"')"
TZCFG="$(cfg '.timezone // empty')"

now() { echo "${MC_NOW_EPOCH:-$(date +%s)}"; }
today() {
  if [ -n "$TZCFG" ]; then TZ="$TZCFG" date -d "@$(now)" +%F; else date -d "@$(now)" +%F; fi
}
hour_now() {
  local h
  if [ -n "$TZCFG" ]; then h="$(TZ="$TZCFG" date -d "@$(now)" +%H)"; else h="$(date -d "@$(now)" +%H)"; fi
  echo "${h#0}"
}

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$MC_STATE_DIR/mission-control.log"
  if [ "$DRY_RUN" = 1 ]; then echo "$*"; fi
}

state_get() { jq -r "$1" "$MC_STATE_DIR/state.json"; }
state_set() { # <jq-program> [jq options...]  — atomic under state.lock
  local prog="$1"; shift
  (
    flock -w 10 9 || { echo "mission-control: state.lock timeout" >&2; exit 1; }
    jq "$@" "$prog" "$MC_STATE_DIR/state.json" > "$MC_STATE_DIR/.state.tmp"
    mv "$MC_STATE_DIR/.state.tmp" "$MC_STATE_DIR/state.json"
  ) 9>>"$MC_STATE_DIR/state.lock"
}

alert() { # <key> <message> — log always; push at most once per 24h per key
  local key="$1" msg="$2" last t
  t="$(now)"
  log "ALERT[$key] $msg"
  [ "$DRY_RUN" = 1 ] && return 0
  last="$(state_get ".alerts[\"$key\"] // 0")"
  [ $((t - last)) -ge 86400 ] || return 0
  state_set '.alerts[$k] = ($n|tonumber)' --arg k "$key" --arg n "$t"
  local var; var="$(cfg '.notify_env // empty')"
  [ -z "$var" ] || printf '%s\n' "$msg" | bash "$SCRIPT_DIR/notify.sh" "$var" "mission-control: $key"
}

# ---------- exec plumbing ----------
DOCKER_OK=""
docker_check() { # lazy: only called right before the tick's first docker use
  [ -z "$DOCKER_OK" ] || return 0
  if $DOCKER_CMD info >/dev/null 2>&1; then DOCKER_OK=1; return 0; fi
  alert docker-preflight "docker unreachable via '$DOCKER_CMD'"
  return 1
}

run_in() { # <container> <repo_path> <snippet> <timeout_s> — non-login bash -c
  local c="$1" rp="$2" snip="$3" t="${4:-30}"
  if [ "$c" = "local" ]; then
    timeout "$t" bash -c "cd $(printf %q "$rp") && $snip"
  else
    docker_check || return 1
    timeout "$t" $DOCKER_CMD exec "$c" bash -c "cd $(printf %q "$rp") && $snip"
  fi
}

slot_free() { # <A|B> — test-acquire without holding
  ( flock -n 9 ) 9>>"$MC_STATE_DIR/slot-$1.lock"
}

# project helpers: pj <name> <jq-filter over the project object>
pj() { jq -r --arg n "$1" ".projects[] | select(.name == \$n) | $2" "$MC_CONFIG"; }

# ---------- governor ----------
# shellcheck source=governor.sh
source "${MC_GOVERNOR:-$SCRIPT_DIR/governor.sh}"

[ "${MC_LIB_ONLY:-0}" = 1 ] && return 0

# ---------- subcommand bodies ----------
# LADDER-FUNCTIONS-PLACEHOLDER (Task 4)
# ADMISSION-FUNCTIONS-PLACEHOLDER (Task 5)
# DISPATCH-FUNCTIONS-PLACEHOLDER (Task 6)

cmd_tick() {
  echo "mission-control: tick not implemented yet" >&2; exit 3
}

cmd_arm() {
  # Validate config, then PRINT the arming instructions. Never installs.
  jq -e . "$MC_CONFIG" >/dev/null
  local bad
  bad="$(jq -r '. as $c | .projects[] | select(($c.engines[.engine] // null) == null) | .name' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: unknown engine on project(s): $bad" >&2; exit 2; fi
  bad="$(jq -r '.projects[].name | select(test("^[A-Za-z0-9_-]+$") | not)' "$MC_CONFIG")"
  if [ -n "$bad" ]; then echo "mission-control: project names must match ^[A-Za-z0-9_-]+$: $bad" >&2; exit 2; fi
  local pinned
  pinned="$(cfg '.slots.A.pinned // empty')"
  if [ -n "$pinned" ] && [ -z "$(pj "$pinned" '.name')" ]; then
    echo "mission-control: slots.A.pinned '$pinned' is not a project" >&2; exit 2
  fi
  local script; script="$(cd "$SCRIPT_DIR" && pwd)/mission-control.sh"
  cat <<EOF
mission-control is NOT armed by agents. A human installs ONE cron line, once.

1. Edit your persistent crontab file (on LinuxServer-style containers:
   /config/crontabs/<user> — edit the file, not 'crontab -e'). Add:

*/30 * * * * bash $script tick --config $MC_CONFIG >> $MC_STATE_DIR/cron.log 2>&1

2. In the same crontab file, DELETE any standalone lessons-deliver cron line —
   mission-control now dispatches lessons-deliver as Slot B's idle rung.
   Two schedulers would double-dip the same budget pools.

3. Export the push URL in the crontab environment block if you want
   notifications, e.g.:  $(cfg '.notify_env // "MC_NTFY_URL"')=https://ntfy.sh/<topic>

4. Verify before trusting it:  bash $script tick --config $MC_CONFIG --dry-run
EOF
}

cmd_status() {
  local s
  for s in A B; do
    if slot_free "$s"; then echo "slot $s: free"; else echo "slot $s: RUNNING"; fi
  done
  echo "state: $MC_STATE_DIR/state.json"
  jq '{date, pools, projects, admissions, digest}' "$MC_STATE_DIR/state.json"
  echo "recent dispatches:"
  ls -1t "$MC_STATE_DIR/dispatches/" 2>/dev/null | grep '\.json$' | head -10 | while read -r f; do
    jq -r '"  \(.started_at | todate) \(.slot) \(.project) (\(.engine)) -> \(.outcome)"' "$MC_STATE_DIR/dispatches/$f"
  done
}

cmd_wrapper() {
  echo "mission-control: wrapper not implemented yet" >&2; exit 3
}

case "$CMD" in
  tick)    cmd_tick ;;
  arm)     cmd_arm ;;
  status)  cmd_status ;;
  wrapper) cmd_wrapper ;;
  *) usage ;;
esac
```

Note the duplicated `bad=` line in `cmd_arm` above is a typo hazard — keep ONLY the second line (`bad="$(jq -r '. as $c | …')"`); delete the first `bad=` assignment when writing the file.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/core.tests.sh`
Expected: `pass=9 fail=0`. Also rerun `bash plugins/mission-control/tests/run-tests.sh` — all suites green.

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts plugins/mission-control/tests/core.tests.sh
git commit -m "mission-control: dispatcher core, governor stub, arm and status"
```

---

### Task 4: Probes and ladder candidate selection

**Files:**
- Modify: `plugins/mission-control/scripts/mission-control.sh` (replace `# LADDER-FUNCTIONS-PLACEHOLDER (Task 4)`)
- Create: `plugins/mission-control/tests/ladder.tests.sh`

**Interfaces:**
- Consumes: `run_in`, `pj`, `cfg`, `state_get`, `state_set`, `log` from Task 3.
- Produces: `probe_work <name>` (exit 0 = work exists), `probe_incident <name>`, `project_blocked <name>` (hold or active cooldown), `rotate <rung> <names...>` (prints names rotated to start after the rung's cursor), `pick_slot_a` and `pick_slot_b` (print `name` of the chosen candidate or nothing; `pick_slot_b` prints `rung name`). Admission check is a placeholder function `admission_eligible <name>` returning 1 (Task 5 implements).

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/ladder.tests.sh`:

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # fresh TD + config with file-based probes; args: extra jq mutation
  TD="$(mktemp -d)"
  mkdir -p "$TD/alpha" "$TD/beta" "$TD/gamma" "$TD/meta"
  jq -n --arg td "$TD" '{
    engines:{e:{pool:"p",cmd:"echo {prompt}"}}, pools:{p:{}},
    slots:{A:{pinned:"alpha"}},
    projects:[
      {name:"alpha", container:"local", repo_path:($td+"/alpha"), stage:"live",       engine:"e", command:"pass-a", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"beta",  container:"local", repo_path:($td+"/beta"),  stage:"live",       engine:"e", command:"pass-b", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"gamma", container:"local", repo_path:($td+"/gamma"), stage:"live",       engine:"e", command:"pass-c", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"meta1", container:"local", repo_path:($td+"/meta"),  stage:"meta",       engine:"e", command:"pass-m", hold:false, work_probe:"cat WORK 2>/dev/null"}
    ],
    admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' \
  | jq "${1:-.}" > "$TD/portfolio.json"
}
lib() { MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" source "$MC"; }

mkenv
t "no work anywhere: no candidates" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ -z "$(pick_slot_a)" ] && [ -z "$(pick_slot_b)" ]'

mkenv; echo yes > "$TD/alpha/WORK"
t "slot A picks pinned when it has work" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_slot_a)" = alpha ]'

mkenv; echo yes > "$TD/beta/WORK"; echo yes > "$TD/meta/WORK"
t "rung 1 (live incident) beats rung 4 (meta)" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_slot_b)" = "1 beta" ]'

mkenv; echo yes > "$TD/meta/WORK"
t "meta reached when higher rungs empty" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_slot_b)" = "4 meta1" ]'

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "pinned excluded from slot B rung 1" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_slot_b)" = "1 beta" ]'

mkenv; echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "round-robin cursor rotates within rung" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  state_set ".cursor[\"1\"]=\"beta\""
  [ "$(pick_slot_b)" = "1 gamma" ]'

mkenv '.projects[1].hold=true'; echo yes > "$TD/beta/WORK"; echo yes > "$TD/meta/WORK"
t "held project skipped, ladder continues" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_slot_b)" = "4 meta1" ]'

mkenv '.projects[1].work_probe="exit 1"'; echo yes > "$TD/meta/WORK"
t "probe failure = empty + streak recorded" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  [ "$(pick_slot_b)" = "4 meta1" ] && [ "$(state_get ".projects[\"beta\"].probe_failures")" = 1 ]'

mkenv
t "cooldown blocks candidate" bash -c '
  '"$(declare -f lib)"'; TD="'"$TD"'"; MC="'"$MC"'"; lib
  echo yes > "'"$TD"'/alpha/WORK"
  state_set ".projects[\"alpha\"].cooldown_until = ($n|tonumber)" --arg n "$(( $(now) + 3600 ))"
  [ -z "$(pick_slot_a)" ]'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/mission-control/tests/ladder.tests.sh`
Expected: FAIL — `pick_slot_a`/`pick_slot_b` undefined.

- [ ] **Step 3: Implement — replace `# LADDER-FUNCTIONS-PLACEHOLDER (Task 4)` with:**

```bash
# ---------- probes & ladder ----------
EXCLUDE_LABELS='"needs-human","maintain:blocked","lessons:blocked","lessons:needs-human","epic"'

probe_run() { # <name> <snippet> — run probe, maintain probe_failures streak
  local name="$1" snip="$2" c rp out rc
  c="$(pj "$name" '.container')"; rp="$(pj "$name" '.repo_path')"
  set +e; out="$(run_in "$c" "$rp" "$snip" 30)"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    [ "$DRY_RUN" = 1 ] || state_set '.projects[$n].probe_failures = ((.projects[$n].probe_failures // 0) + 1)' --arg n "$name"
    log "probe failed project=$name rc=$rc"
    return 1              # fail toward idle: treated as no work
  fi
  [ "$DRY_RUN" = 1 ] || state_set '.projects[$n].probe_failures = 0' --arg n "$name"
  [ -n "$out" ]
}

default_work_probe() { # <stage>
  if [ "$1" = "meta" ]; then
    printf '%s' "gh issue list --state open --label lesson-approved --limit 50 --json number,labels --jq 'first(.[] | select(([.labels[].name] | map(IN($EXCLUDE_LABELS)) | any | not)) | .number) // empty'"
  else
    printf '%s' "gh issue list --state open --limit 50 --json number,labels --jq 'first(.[] | select(([.labels[].name] | map(IN($EXCLUDE_LABELS)) | any | not)) | .number) // empty'"
  fi
}

probe_work() { # <name>
  local name="$1" snip stage
  stage="$(pj "$name" '.stage')"
  snip="$(pj "$name" '.work_probe // empty')"
  [ -n "$snip" ] || snip="$(default_work_probe "$stage")"
  probe_run "$name" "$snip"
}

probe_incident() { # <name> — any open issue with an incident label
  local name="$1" snip l
  snip="$(pj "$name" '.work_probe // empty')"
  if [ -n "$snip" ]; then probe_run "$name" "$snip"; return; fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if probe_run "$name" "gh issue list --state open --label $(printf %q "$l") --limit 1 --json number --jq '.[].number'"; then
      return 0
    fi
  done < <(pj "$name" '(.incident_labels // ["incident","production","critical"])[]')
  return 1
}

project_blocked() { # <name> — hold or active cooldown
  [ "$(pj "$1" '.hold')" = "true" ] && return 0
  local cd; cd="$(state_get ".projects[\"$1\"].cooldown_until // 0")"
  [ "$(now)" -lt "$cd" ]
}

# Engines refused by governor_reserve earlier THIS tick (set by cmd_tick's
# retry loop, Task 6). Lets the ladder continue past an exhausted pool.
declare -ga DENIED_ENGINES=()
engine_denied() { # <name> — is this project's engine denied this tick?
  local e d; e="$(pj "$1" '.engine')"
  for d in "${DENIED_ENGINES[@]:-}"; do [ "$d" = "$e" ] && return 0; done
  return 1
}

rotate() { # <rung> <names...> — start after this rung's cursor
  local rung="$1"; shift
  [ $# -gt 0 ] || return 0
  local cur i n=$#
  cur="$(state_get ".cursor[\"$rung\"] // \"\"")"
  local -a a=("$@")
  local start=0
  for i in "${!a[@]}"; do
    if [ "${a[$i]}" = "$cur" ]; then start=$(( (i + 1) % n )); break; fi
  done
  for ((i = 0; i < n; i++)); do echo "${a[$(( (start + i) % n ))]}"; done
}

names_by_stage() { jq -r --arg s "$1" '.projects[] | select(.stage == $s) | .name' "$MC_CONFIG"; }

# ADMISSION-ELIGIBLE-PLACEHOLDER (Task 5)
admission_eligible() { return 1; }

pick_slot_a() {
  local p; p="$(cfg '.slots.A.pinned // empty')"
  [ -n "$p" ] || return 0
  project_blocked "$p" && { log "slot A pinned $p blocked"; return 0; }
  engine_denied "$p" && return 0
  probe_work "$p" && echo "$p" || true
}

pick_slot_b() {
  local pinned n
  pinned="$(cfg '.slots.A.pinned // empty')"
  # rung 1: live incidents, excluding the pinned project
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" != "$pinned" ] || continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_incident "$n"; then state_set '.cursor["1"]=$n' --arg n "$n"; echo "1 $n"; return 0; fi
  done < <(rotate 1 $(names_by_stage live))
  # rung 2: admitted pre-launch with work
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    admission_eligible "$n" || continue
    if probe_work "$n"; then state_set '.cursor["2"]=$n' --arg n "$n"; echo "2 $n"; return 0; fi
  done < <(rotate 2 $(names_by_stage pre-launch))
  # rung 3: validation
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_work "$n"; then state_set '.cursor["3"]=$n' --arg n "$n"; echo "3 $n"; return 0; fi
  done < <(rotate 3 $(names_by_stage validation))
  # rung 4: meta
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    project_blocked "$n" && continue
    engine_denied "$n" && continue
    if probe_work "$n"; then state_set '.cursor["4"]=$n' --arg n "$n"; echo "4 $n"; return 0; fi
  done < <(rotate 4 $(names_by_stage meta))
  return 0
}
```

Note: `rotate` is called unquoted (`$(names_by_stage live)`) deliberately — project names are single tokens by construction, enforced by `cmd_arm`'s `^[A-Za-z0-9_-]+$` validation (Task 3).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/ladder.tests.sh`
Expected: `pass=10 fail=0`. Rerun the full suite (`tests/run-tests.sh`) — green.

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts/mission-control.sh plugins/mission-control/tests/ladder.tests.sh
git commit -m "mission-control: probes and slot-B priority ladder"
```

---

### Task 5: Admission gate (WIP cap, confidence bar, 72h veto)

**Files:**
- Modify: `plugins/mission-control/scripts/mission-control.sh` (replace `# ADMISSION-FUNCTIONS-PLACEHOLDER (Task 5)` and the placeholder `admission_eligible`)
- Create: `plugins/mission-control/tests/admission.tests.sh`

**Interfaces:**
- Consumes: `run_in`, `pj`, `cfg`, `state_get`, `state_set`, `now`, `alert`.
- Produces: `admission_eligible <name>` (exit 0 = admitted; evaluates/advances the gate as a side effect) and `admission_housekeeping` (clears `requested_at` on held never-admitted pre-launch projects; called by `cmd_tick` in Task 6).

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/admission.tests.sh`:

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # $1: jq mutation, default identity
  TD="$(mktemp -d)"
  mkdir -p "$TD/p1/.startup" "$TD/p2/.startup"
  jq -n --arg td "$TD" '{
    engines:{e:{pool:"p",cmd:"echo {prompt}"}}, pools:{p:{}}, slots:{A:{}},
    projects:[
      {name:"p1", container:"local", repo_path:($td+"/p1"), stage:"pre-launch", engine:"e", command:"c", hold:false},
      {name:"p2", container:"local", repo_path:($td+"/p2"), stage:"pre-launch", engine:"e", command:"c", hold:false}
    ],
    admission:{wip_cap:1, confidence_min:0.7, veto_hours:72}}' \
  | jq "${1:-.}" > "$TD/portfolio.json"
}
NOW=1700000000
run1() { MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$1" bash -c 'source "$0"; shift; "$@"' "$MC" "$@"; }
# helper: run a function in a fresh lib load at a given epoch
call() { local e="$1"; shift; MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" MC_NOW_EPOCH="$e" bash -c 'f="$1"; shift; source "$0" >/dev/null; "$f" "$@"' "$MC" "$@"; }

mkenv
t "no provenance: fail closed, nothing stamped" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"$0\"; ! admission_eligible p1 && [ \"\$(state_get \".admissions[\\\"p1\\\"].requested_at // 0\")\" = 0 ]" "'"$MC"'"'

mkenv
echo '{"validation":{"confidence":0.9}}' > "$TD/p1/.startup/provenance.json"
t "gate pass stamps requested_at, not yet eligible" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"$0\"; ! admission_eligible p1 && [ \"\$(state_get \".admissions[\\\"p1\\\"].requested_at // 0\")\" = '"$NOW"' ]" "'"$MC"'"'
LATER=$((NOW + 72*3600 + 60))
t "after veto window: admitted and eligible" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$LATER"' bash -c "source \"$0\"; admission_eligible p1 && [ \"\$(state_get \".admissions[\\\"p1\\\"].admitted_at // 0\")\" != 0 ]" "'"$MC"'"'
echo '{"validation":{"confidence":0.9}}' > "$TD/p2/.startup/provenance.json"
t "wip_cap blocks second admission" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$LATER"' bash -c "source \"$0\"; ! admission_eligible p2 && [ \"\$(state_get \".admissions[\\\"p2\\\"].requested_at // 0\")\" = 0 ]" "'"$MC"'"'

mkenv '.admission.confidence_min = 0.95'
echo '{"validation":{"confidence":0.9}}' > "$TD/p1/.startup/provenance.json"
t "below confidence bar: refused" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"$0\"; ! admission_eligible p1 && [ \"\$(state_get \".admissions[\\\"p1\\\"].requested_at // 0\")\" = 0 ]" "'"$MC"'"'

mkenv
echo '{"validation":{"confidence":0.9}}' > "$TD/p1/.startup/provenance.json"
t "hold clears requested_at via housekeeping" bash -c '
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"$0\"; admission_eligible p1 || true" "'"$MC"'"
  jq ".projects[0].hold = true" "'"$TD"'/portfolio.json" > "'"$TD"'/x" && mv "'"$TD"'/x" "'"$TD"'/portfolio.json"
  MC_LIB_ONLY=1 MC_CONFIG="'"$TD"'/portfolio.json" MC_NOW_EPOCH='"$NOW"' bash -c "source \"$0\"; admission_housekeeping; [ \"\$(state_get \".admissions[\\\"p1\\\"].requested_at // 0\")\" = 0 ]" "'"$MC"'"'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/mission-control/tests/admission.tests.sh`
Expected: FAIL — stub `admission_eligible` always refuses without stamping; `admission_housekeeping` undefined.

- [ ] **Step 3: Implement — replace `# ADMISSION-FUNCTIONS-PLACEHOLDER (Task 5)` and the stub `admission_eligible` with:**

```bash
# ---------- admission gate (absorbed from #206) ----------
admitted_unheld_count() {
  local n c=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$(state_get ".admissions[\"$n\"].admitted_at // 0")" != 0 ] || continue
    [ "$(pj "$n" '.hold')" = "true" ] && continue
    c=$((c + 1))
  done < <(names_by_stage pre-launch)
  echo "$c"
}

admission_housekeeping() { # held + never-admitted => veto clock restarts later
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$(pj "$n" '.hold')" = "true" ] || continue
    [ "$(state_get ".admissions[\"$n\"].admitted_at // 0")" = 0 ] || continue
    [ "$(state_get ".admissions[\"$n\"].requested_at // 0")" != 0 ] || continue
    state_set 'del(.admissions[$n].requested_at)' --arg n "$n"
    log "admission clock cleared (held): $n"
  done < <(names_by_stage pre-launch)
}

admission_eligible() { # <name> — exit 0 iff admitted; advances the gate
  local name="$1" req veto
  [ "$(state_get ".admissions[\"$name\"].admitted_at // 0")" != 0 ] && return 0
  veto="$(cfg '.admission.veto_hours // 72')"
  req="$(state_get ".admissions[\"$name\"].requested_at // 0")"
  if [ "$req" != 0 ]; then
    if [ "$(now)" -ge $((req + veto * 3600)) ]; then
      state_set '.admissions[$n].admitted_at = ($t|tonumber)' --arg n "$name" --arg t "$(now)"
      log "admitted: $name"
      return 0
    fi
    return 1                                    # veto window still open
  fi
  # not yet requested: evaluate the gate (fail closed at every step)
  local cap; cap="$(cfg '.admission.wip_cap // 1')"
  [ "$(admitted_unheld_count)" -lt "$cap" ] || return 1
  local c rp conf min
  c="$(pj "$name" '.container')"; rp="$(pj "$name" '.repo_path')"
  set +e
  conf="$(run_in "$c" "$rp" "jq -r '.validation.confidence // empty' .startup/provenance.json 2>/dev/null" 15)"
  set -e
  [ -n "$conf" ] || return 1
  min="$(cfg '.admission.confidence_min // 0.7')"
  awk -v c="$conf" -v m="$min" 'BEGIN { exit !(c + 0 >= m + 0) }' || return 1
  state_set '.admissions[$n].requested_at = ($t|tonumber)' --arg n "$name" --arg t "$(now)"
  alert "admission-$name" "$name enters Slot B delivery in ${veto}h — set hold:true in portfolio.json to veto"
  return 1                                      # never dispatch on request tick
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/admission.tests.sh`
Expected: `pass=6 fail=0`. Full suite green.

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts/mission-control.sh plugins/mission-control/tests/admission.tests.sh
git commit -m "mission-control: admission gate with wip cap, confidence bar, veto window"
```

---

### Task 6: Dispatch, wrapper, tick assembly

**Files:**
- Modify: `plugins/mission-control/scripts/mission-control.sh` (replace `# DISPATCH-FUNCTIONS-PLACEHOLDER (Task 6)`, `cmd_tick`, `cmd_wrapper`)
- Create: `plugins/mission-control/tests/tick.tests.sh`

**Interfaces:**
- Consumes: everything above; `governor_reserve`, `governor_envelope`, `governor_report` (stub or `MC_GOVERNOR` override).
- Produces: working `tick` and internal `wrapper` subcommands; dispatch artifacts `dispatches/<utc>-<slot>-<name>.log` + `.json` with fields `slot,project,engine,started_at,ended_at,exit_code,outcome`.

- [ ] **Step 1: Write the failing test**

`plugins/mission-control/tests/tick.tests.sh`:

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # $1: jq mutation
  TD="$(mktemp -d)"
  mkdir -p "$TD/alpha" "$TD/beta" "$TD/bin"
  cat > "$TD/bin/docker" <<'SH'
#!/bin/bash
echo "docker $*" >> "$DOCKER_CALLS"; exit 0
SH
  chmod +x "$TD/bin/docker"
  export DOCKER_CALLS="$TD/docker.calls"; : > "$DOCKER_CALLS"
  jq -n --arg td "$TD" '{
    engines:{e:{pool:"p", cmd:"echo ran-{prompt} > MARKER"}}, pools:{p:{}},
    slots:{A:{pinned:"alpha"}},
    projects:[
      {name:"alpha", container:"local", repo_path:($td+"/alpha"), stage:"live", engine:"e", command:"A", hold:false, work_probe:"cat WORK 2>/dev/null"},
      {name:"beta",  container:"local", repo_path:($td+"/beta"),  stage:"live", engine:"e", command:"B", hold:false, work_probe:"cat WORK 2>/dev/null"}
    ],
    admission:{wip_cap:1, confidence_min:0.7, veto_hours:72}}' \
  | jq "${1:-.}" > "$TD/portfolio.json"
  SD="$TD/state"
}
tick() { PATH="$TD/bin:$PATH" bash "$MC" tick --config "$TD/portfolio.json" "$@"; }
wait_outcomes() { # <count> — wait up to 5s for N outcome files
  local i=0
  while [ "$(ls "$SD/dispatches/"*.json 2>/dev/null | wc -l)" -lt "$1" ]; do
    i=$((i + 1)); [ "$i" -lt 50 ] || return 1; sleep 0.1
  done
}

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "tick dispatches both slots; outcomes ok" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && wait_outcomes 2 || exit 1
  [ -f "$TD/alpha/MARKER" ] && [ -f "$TD/beta/MARKER" ] || exit 1
  grep -q ran-A "$TD/alpha/MARKER" && grep -q ran-B "$TD/beta/MARKER" || exit 1
  for f in "$SD/dispatches/"*.json; do jq -e ".outcome == \"ok\" and .exit_code == 0" "$f" >/dev/null || exit 1; done'

mkenv '.projects[1].container="some-container"'; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "busy slots: zero dispatches, zero docker calls" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  mkdir -p "$SD"
  ( flock 9; sleep 3 ) 9>>"$SD/slot-A.lock" &
  ( flock 9; sleep 3 ) 9>>"$SD/slot-B.lock" &
  sleep 0.3
  tick || exit 1
  [ -z "$(ls "$SD/dispatches" 2>/dev/null)" ] && [ ! -s "$DOCKER_CALLS" ]'

mkenv
t "no work: no dispatches" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  tick && [ -z "$(ls "$SD/dispatches" 2>/dev/null)" ]'

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "quota-1 governor: exactly one dispatch (reserve atomicity)" bash -c '
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
  [ "$(ls "$SD/dispatches/"*.json | wc -l)" = 1 ]'

mkenv; echo yes > "$TD/alpha/WORK"
t "slot lock held when tick exits (no free window)" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  # pass sleeps: lock must be observed held right after tick returns
  jq ".engines.e.cmd = \"sleep 1 # {prompt}\"" "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
  tick || exit 1
  ! ( flock -n 9 ) 9>>"$SD/slot-A.lock"'

mkenv; echo yes > "$TD/alpha/WORK"; echo yes > "$TD/beta/WORK"
t "dry-run: prints decisions, mutates nothing" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  out="$(tick --dry-run)" || exit 1
  grep -qi "would dispatch" <<<"$out" || exit 1
  [ -z "$(ls "$SD/dispatches" 2>/dev/null)" ] && [ ! -f "$TD/alpha/MARKER" ]'

mkenv; echo yes > "$TD/alpha/WORK"
t "envelope timeout yields timeout outcome" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  cat > "$TD/gov.sh" <<'"'"'GOV'"'"'
governor_reserve() { return 0; }
governor_envelope() { echo 0.02; }   # ~1.2s via timeout(1) float support
governor_report() { if [ "$3" -eq 124 ]; then echo timeout; elif [ "$3" -eq 0 ]; then echo ok; else echo error; fi; }
governor_daily() { return 0; }
GOV
  jq ".engines.e.cmd = \"sleep 5 # {prompt}\"" "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
  MC_GOVERNOR="$TD/gov.sh" tick && wait_outcomes 1 || exit 1
  jq -e ".outcome == \"timeout\" and .exit_code == 124" "$SD"/dispatches/*.json'

mkenv; mkdir -p "$TD/gamma"
jq --arg td "$TD" '.engines.e2 = {pool:"p2", cmd:"echo ran2-{prompt} > MARKER"}
  | .projects += [{name:"gamma", container:"local", repo_path:($td+"/gamma"), stage:"meta",
                   engine:"e2", command:"M", hold:false, work_probe:"cat WORK 2>/dev/null"}]' \
  "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
echo yes > "$TD/beta/WORK"; echo yes > "$TD/gamma/WORK"
t "reserve refusal re-walks ladder to another pool" bash -c '
  '"$(declare -f tick wait_outcomes)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  cat > "$TD/gov.sh" <<'"'"'GOV'"'"'
governor_reserve() { [ "$(cfg ".engines[\"$1\"].pool")" != "p" ]; }
governor_envelope() { echo 1; }
governor_report() { if [ "$3" -eq 0 ]; then echo ok; else echo error; fi; }
governor_daily() { return 0; }
GOV
  MC_GOVERNOR="$TD/gov.sh" tick && wait_outcomes 1 || exit 1
  grep -q ran2-M "$TD/gamma/MARKER" && [ ! -f "$TD/beta/MARKER" ] &&
  jq -e ".project == \"gamma\"" "$SD"/dispatches/*.json'

mkenv; echo yes > "$TD/alpha/WORK"
t "self-resume: killed pass frees slot, next tick redispatches" bash -c '
  '"$(declare -f tick)"'; TD="'"$TD"'"; SD="'"$SD"'"; MC="'"$MC"'"
  jq ".engines.e.cmd = \"sleep 30 # RESUME-{prompt}\"" "$TD/portfolio.json" > "$TD/x" && mv "$TD/x" "$TD/portfolio.json"
  tick || exit 1
  sleep 0.5
  pid="$(pgrep -f "RESUME-A" | head -1)" || exit 1
  pgid="$(ps -o pgid= -p "$pid" | tr -d " ")" || exit 1
  kill -TERM -- "-$pgid"
  i=0; until ( flock -n 9 ) 9>>"$SD/slot-A.lock"; do i=$((i+1)); [ "$i" -lt 50 ] || exit 1; sleep 0.1; done
  tick || exit 1
  sleep 0.5
  [ "$(ls "$SD/dispatches/"*.log | wc -l)" = 2 ]'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash plugins/mission-control/tests/tick.tests.sh`
Expected: FAIL — `cmd_tick` exits 3.

- [ ] **Step 3: Implement — replace `# DISPATCH-FUNCTIONS-PLACEHOLDER (Task 6)`, `cmd_tick`, `cmd_wrapper` with:**

```bash
# ---------- dispatch ----------
dispatch() { # <slot> <name> — reserve, take slot lock on an FD, spawn wrapper
  local slot="$1" name="$2"
  local engine container rp command tmpl rendered env_min base lfd
  engine="$(pj "$name" '.engine')"
  container="$(pj "$name" '.container')"
  rp="$(pj "$name" '.repo_path')"
  command="$(pj "$name" '.command')"
  tmpl="$(cfg ".engines[\"$engine\"].cmd")"
  rendered="${tmpl//\{prompt\}/$command}"
  env_min="$(governor_envelope "$engine" "$name")"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY: would dispatch slot=$slot project=$name engine=$engine envelope=${env_min}m cmd: $rendered"
    return 0
  fi
  exec {lfd}>>"$MC_STATE_DIR/slot-$slot.lock"
  if ! flock -n "$lfd"; then exec {lfd}>&-; return 1; fi
  if ! governor_reserve "$engine"; then
    log "reserve refused slot=$slot project=$name engine=$engine"
    exec {lfd}>&-
    return 1
  fi
  base="$MC_STATE_DIR/dispatches/$(date -u +%Y%m%dT%H%M%SZ)-$slot-$name"
  : > "$base.log"
  log "dispatch slot=$slot project=$name engine=$engine envelope=${env_min}m"
  # Wrapper inherits the lock FD: held continuously until the pass ends.
  setsid bash "$0" wrapper --config "$MC_CONFIG" --slot "$slot" --project "$name" \
    --engine "$engine" --container "$container" --repo-path "$rp" \
    --envelope "$env_min" --base "$base" --cmd "$rendered" \
    >>"$base.log" 2>&1 &
  exec {lfd}>&-   # parent's copy closed; child's inherited copy keeps the lock
  return 0
}

cmd_tick() {
  exec 8>>"$MC_STATE_DIR/tick.lock"
  flock -n 8 || exit 0                       # overlapping ticks impossible
  local d; d="$(today)"
  if [ "$DRY_RUN" != 1 ] && [ "$(state_get '.date // ""')" != "$d" ]; then
    state_set '.date = $d' --arg d "$d"      # scheduler-owned; pool counters roll in governor_reserve
  fi
  [ "$DRY_RUN" = 1 ] || admission_housekeeping
  local slot cand tries
  for slot in A B; do
    if ! slot_free "$slot"; then log "slot $slot busy"; continue; fi
    if [ "$slot" = A ]; then
      cand="$(pick_slot_a)"
      if [ -n "$cand" ]; then
        dispatch A "$cand" || { DENIED_ENGINES+=("$(pj "$cand" '.engine')"); log "slot A reserve refused: $cand"; }
      else
        log "slot A idle"
      fi
    else
      tries=0
      while :; do
        cand="$(pick_slot_b)"
        [ -n "$cand" ] || { log "slot B idle"; break; }
        dispatch B "${cand#* }" && break
        DENIED_ENGINES+=("$(pj "${cand#* }" '.engine')")
        log "slot B reserve refused: $cand — re-walking ladder without that engine"
        tries=$((tries + 1))
        [ "$tries" -lt 4 ] || break
      done
    fi
  done
  [ "$DRY_RUN" = 1 ] || governor_daily
}

cmd_wrapper() {
  local slot="${WRAP[slot]}" name="${WRAP[project]}" engine="${WRAP[engine]}"
  local container="${WRAP[container]}" rp="${WRAP[repo-path]}"
  local envelope="${WRAP[envelope]}" base="${WRAP[base]}" rendered="${WRAP[cmd]}"
  local started rc outcome
  started="$(now)"
  set +e
  if [ "$container" = "local" ]; then
    bash -c "cd $(printf %q "$rp") && timeout ${envelope}m $rendered"
  else
    $DOCKER_CMD exec "$container" bash -c "cd $(printf %q "$rp") && timeout ${envelope}m $rendered"
  fi
  rc=$?
  set -e
  outcome="$(governor_report "$engine" "$name" "$rc" "$base.log")"
  jq -n --arg slot "$slot" --arg p "$name" --arg e "$engine" \
        --arg s "$started" --arg t "$(now)" --arg rc "$rc" --arg o "$outcome" \
        '{slot:$slot, project:$p, engine:$e, started_at:($s|tonumber),
          ended_at:($t|tonumber), exit_code:($rc|tonumber), outcome:$o}' \
        > "$base.json"
  log "pass done slot=$slot project=$name outcome=$outcome rc=$rc"
}
```

Subtlety: on a reserve refusal, `cmd_tick` adds the candidate's engine to `DENIED_ENGINES` and re-walks the ladder (bounded at 4 tries); `pick_slot_a`/`pick_slot_b` skip denied-engine candidates via `engine_denied` (Task 4). This is how the spec's "a backed-off Codex pool must not block a Claude-pool rung" is realized. A re-walk re-runs the higher rungs' probes — bounded and rare (only when a pool is exhausted or backed off). A refusal on Slot A also feeds `DENIED_ENGINES`, sparing Slot B a doomed attempt on the same pool.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/mission-control/tests/tick.tests.sh`
Expected: `pass=9 fail=0`. Full suite green: `bash plugins/mission-control/tests/run-tests.sh`.

- [ ] **Step 5: Commit**

```bash
git add plugins/mission-control/scripts/mission-control.sh plugins/mission-control/tests/tick.tests.sh
git commit -m "mission-control: dispatch wrapper with inherited slot lock, tick assembly"
```

---

### Task 7: /mission-status command, runbook, final wiring

**Files:**
- Create: `plugins/mission-control/commands/mission-status.md`
- Create: `plugins/mission-control/docs/runbook.md`

**Interfaces:**
- Consumes: `mission-control.sh status` from Task 3.

- [ ] **Step 1: Write the command**

`plugins/mission-control/commands/mission-status.md`:

```markdown
---
name: mission-status
description: Read-only view of mission-control state — slot occupancy, pool quotas and backoffs, cooldowns, pending admissions with veto deadlines, and recent dispatch outcomes. Usage: /mission-status [config-path]
user_invocable: true
---

# /mission-status — Portfolio Scheduler Status

Read-only. Locate the host's portfolio config: use the argument if given,
else `$MISSION_CONTROL_CONFIG`, else ask the user for the path. Then run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mission-control.sh" status --config "<path>"
```

Present the output as-is, then add one short interpretation line only when
something needs attention (a slot stuck RUNNING for hours, a pool in
backoff, a pending admission near its veto deadline). Do not paraphrase
healthy output. Never run `tick` or `arm` from this command; never modify
state. Token-frugal: this is one script call plus a short summary.
```

- [ ] **Step 2: Write the runbook**

`plugins/mission-control/docs/runbook.md`:

```markdown
# Arming mission-control (one-time, human-only)

The scheduler is deterministic bash run from cron. Agents must never install
the cron line — you do, once.

1. **Config.** Copy `examples/portfolio.example.json` to a stable host path,
   e.g. `~/.config/mission-control/portfolio.json`. Fill in your real
   projects: container names (`docker ps`), in-container repo paths, stages,
   engines. Set `docker_cmd` to `sudo docker` if your user lacks docker
   socket group membership. Keep `container: "local"` for loops that run in
   the same container as cron (e.g. the plugin repo's lessons-deliver).
2. **Prerequisites.** `jq`, `flock`, GNU `date`, `curl` on the cron host;
   `gh` authenticated inside every project container; the assistant CLIs
   (`claude`, `codex`) installed wherever their engine's passes run. Engine
   `cmd` templates run through non-login `bash -c` — if a container only
   provisions PATH in login shells, wrap the template:
   `bash -lc 'claude … {prompt}'` won't work (quoting); instead use absolute
   CLI paths in the template.
3. **Validate + print the cron line:**
   `bash plugins/mission-control/scripts/mission-control.sh arm --config <path>`
4. **Install.** Paste the printed line into your persistent crontab file
   (LinuxServer-style containers: `/config/crontabs/<user>`, then restart the
   container or run `crontab /config/crontabs/<user>`). Delete any standalone
   lessons-deliver cron line — mission-control now owns that dispatch.
5. **Set the push URL** (optional but recommended: veto announcements arrive
   here): add `MC_NTFY_URL=https://ntfy.sh/<topic>` (or your `notify_env`
   name) to the crontab environment block.
6. **Verify.** `… tick --config <path> --dry-run` prints every decision
   without dispatching. Watch `state/cron.log` and `state/mission-control.log`
   after the first real ticks; `/mission-status` shows slots and outcomes.
7. **Upgrade path.** The cron line points into this repo clone — `git pull`
   updates the scheduler; config and state are outside the repo and survive.
8. **Veto / pause.** Set `"hold": true` on any project entry. Pre-launch
   admissions announce via push + digest and wait `veto_hours` (default 72)
   before the first dispatch.
```

- [ ] **Step 3: Run the full suite + validators**

Run: `bash plugins/mission-control/tests/run-tests.sh`
Expected: all suites green.

Run: `bash -n plugins/mission-control/scripts/mission-control.sh && bash -n plugins/mission-control/scripts/governor.sh && bash -n plugins/mission-control/scripts/notify.sh`
Expected: no output (syntax clean).

- [ ] **Step 4: Commit (closes the issue)**

```bash
git add plugins/mission-control/commands plugins/mission-control/docs
git commit -m "mission-control: /mission-status command and arming runbook

Closes #198"
```

---

## Post-plan notes for the supervising session (not the implementer)

- Codex surface: run `python3 scripts/sync-codex-marketplace.py` from repo
  root in the supervised session after merge, and regenerate
  `.agents/plugins/marketplace.json` there too (outside the loop firewall).
- Version stays 0.1.0 for the whole plan (new plugin); #199 bumps to 0.2.0.
