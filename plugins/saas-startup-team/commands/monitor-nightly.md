---
name: monitor-nightly
description: Nightly automated monitor — sweeps failure markers + an optional project custom-checks script, files/dedups GitHub issues with reproduction context, persists state across runs. Usage: /monitor-nightly [--dry-run]
argument-hint: "[--dry-run]"
allowed-tools: Bash, Read, Write, Grep, Glob
user_invocable: true
---

# /monitor-nightly — Generic Nightly Monitor

Detect failure signals, file deduplicated GitHub issues with reproduction context, persist state
across runs. Project-agnostic — all specifics come from the `monitor:` block in
`.claude/saas-startup-team.local.md` (all keys optional; defaults below). The command never calls
`gh` itself — the engine (`scripts/monitor-dedup.sh`) owns all GitHub I/O.

**IMPORTANT:** This creates real GitHub issues. Pass `--dry-run` to preview without creating.

## Configuration

Parse the optional `monitor:` block from `.claude/saas-startup-team.local.md`. Each key is read by
its (unique) name regardless of indentation, matching the existing `check-regression-test.sh`
convention. List value `labels` is normalized to a comma string.

```bash
ENGINE="${CLAUDE_PLUGIN_ROOT}/scripts/monitor-dedup.sh"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$GIT_ROOT/.claude/saas-startup-team.local.md"
# Scope parsing to the `monitor:` block only (from `monitor:` to the next top-level key
# or the closing `---`), so keys never collide with the regression-gate's top-level keys.
mon_block=""; [ -f "$CONFIG" ] && mon_block="$(sed -n '/^[[:space:]]*monitor:[[:space:]]*$/,/^[^[:space:]#]/p' "$CONFIG")"
# Each value is single-line. A trailing ` # comment` (YAML-style: whitespace before the `#`)
# and trailing whitespace are stripped, surrounding quotes are removed, a bare block scalar
# (`|`/`>`) yields empty (block scalars are NOT supported), and a literal `\n` becomes a real
# newline — so a multi-line value (e.g. repro_recipe) has a safe single-line spelling. (#87)
cfg() {
  # sed1 (on the raw value, quotes intact): for UNQUOTED values only, strip a ` # comment`;
  #   always trim trailing whitespace and blank a bare block scalar (`|`/`>`).
  # sed2: remove a single pair of surrounding quotes. sed3: literal `\n` → real newline.
  printf '%s\n' "$mon_block" | grep -oP "^\s+$1:\s*\K.*" | head -1 \
    | sed -E '/["'"'"']/!s/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^[|>]$//' \
    | sed -E 's/^["'"'"']//; s/["'"'"']$//' \
    | sed -E 's/\\n/\n/g'
}

REPO=""; MARKER_DIR=".monitor"; STATE_FILE=".startup/monitor-state.json"
CUSTOM_CHECKS=".startup/monitor-checks.sh"; LABELS="monitor,customer-issue"; REPRO_RECIPE=""
if [ -f "$CONFIG" ]; then
  v="$(cfg repo)";          [ -n "$v" ] && REPO="$v"
  v="$(cfg marker_dir)";    [ -n "$v" ] && MARKER_DIR="$v"
  v="$(cfg state_file)";    [ -n "$v" ] && STATE_FILE="$v"
  v="$(cfg custom_checks)"; [ -n "$v" ] && CUSTOM_CHECKS="$v"
  v="$(cfg repro_recipe)";  [ -n "$v" ] && REPRO_RECIPE="$v"
  v="$(cfg labels)";        [ -n "$v" ] && LABELS="$(printf '%s' "$v" | sed -E 's/.*\[//; s/\].*//; s/[[:space:]]//g')"
fi
DRY_RUN_FLAG=""; case "${ARGUMENTS:-}" in *--dry-run*) DRY_RUN_FLAG="--dry-run" ;; esac
REPO_FLAG=""; [ -n "$REPO" ] && REPO_FLAG="--repo $REPO"
```

## Lock the run

Serialize the whole run with `flock` so a manual run cannot overlap the cron run:

```bash
mkdir -p "$(dirname "$STATE_FILE")"
exec 9>"${STATE_FILE}.lock"
flock -n 9 || { echo "monitor: another run holds the lock; exiting"; exit 0; }
```

## Scan window

```bash
eval "$("$ENGINE" window --state "$STATE_FILE")"
export MONITOR_SINCE MONITOR_SINCE_MINUTES
```

## Collect findings

Self-contained: reads `MARKER_DIR`, `CUSTOM_CHECKS`, and `STATE_FILE` from the environment and
writes findings JSONL (one object per line) to the file `${STATE_FILE}.findings` (the `## Commit`
step reads that file — file-based handoff survives separate shell invocations). Marker `kind` is
sanitized to a valid `pattern_key` segment.

```bash
MARKER_DIR="${MARKER_DIR:-.monitor}"
CUSTOM_CHECKS="${CUSTOM_CHECKS:-.startup/monitor-checks.sh}"
FINDINGS="${STATE_FILE:-.startup/monitor-state.json}.findings"
mkdir -p "$(dirname "$FINDINGS")"; : > "$FINDINGS"

shopt -s nullglob
for marker in "$MARKER_DIR"/*-last-failure.txt; do
  [ -f "$marker" ] || continue
  # lowercase, replace every non [a-z0-9_-] char with '-', collapse/trim dashes → valid key segment
  kind="$(basename "$marker" -last-failure.txt | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  [ -n "$kind" ] || continue
  first_line="$(head -1 "$marker" 2>/dev/null || true)"
  body="$(cat "$marker" 2>/dev/null || true)"
  for cand in "logs/${kind}.log" "logs/nightly-${kind}.log" "$MARKER_DIR/${kind}.log"; do
    [ -f "$cand" ] && { body="$body"$'\n\n--- recent log ---\n'"$(tail -40 "$cand")"; break; }
  done
  body="$body"$'\n\n(The marker auto-clears on the producer'"'"'s next successful run.)'
  jq -nc --arg pk "ops:${kind}:failure" --arg t "[Monitor] ${kind} failed — ${first_line}" --arg b "$body" \
    '{pattern_key:$pk, severity:"high", entity:null, title:$t, body:$b}' >> "$FINDINGS"
done
shopt -u nullglob

if [ -x "$CUSTOM_CHECKS" ]; then
  set +e
  "$CUSTOM_CHECKS" >> "$FINDINGS"; cc_ec=$?
  set -e
  if [ "$cc_ec" -ne 0 ]; then
    jq -nc --arg b "custom-checks exited $cc_ec" \
      '{pattern_key:"ops:monitor-checks:failure", severity:"high", entity:null, title:"[Monitor] custom-checks script failed", body:$b}' >> "$FINDINGS"
  fi
fi
```

> The custom-checks script writes its **own** findings JSONL to stdout (appended straight into
> `$FINDINGS`) and may write diagnostics to stderr. A non-zero exit still keeps the findings it
> already emitted and adds one `ops:monitor-checks:failure` tracking finding.

## Commit

Pipe the collected findings file to the engine (the engine owns all `gh` I/O):

```bash
FINDINGS="${STATE_FILE:-.startup/monitor-state.json}.findings"
# `grep` exits 1 when there are zero findings (the common "all clear" night). The `|| true`
# keeps that from tripping the pipeline under `set -o pipefail`; the engine handles empty stdin
# (advances last_run_at, writes initialized state) and exits 0.
{ grep -v '^[[:space:]]*$' "$FINDINGS" || true; } \
  | "$ENGINE" commit --state "$STATE_FILE" $REPO_FLAG \
      --labels "$LABELS" --repro-recipe "$REPRO_RECIPE" $DRY_RUN_FLAG
```

## Summary

The engine prints one JSON action per finding. Summarize for the human:

```
Nightly Monitor — <date>
Created: <n>  Commented: <m>  Skipped: <k>
<created/commented issue numbers>
```

If `--dry-run`, prefix every line with `[DRY RUN]`.

## Cron setup

```bash
# 0 2 * * *  cd /path/to/product && claude -p "/monitor-nightly" \
#   --allowedTools "Bash,Read,Write,Grep,Glob" >> /var/log/monitor-nightly.log 2>&1
```

Ensure `ANTHROPIC_API_KEY`, authenticated `gh`, `jq`, GNU `date`, and `flock` are available in the
cron environment.

### Hardened cron (narrow tool scope)

This monitor pulls **customer-controlled content** (feedback text, custom-checks output) into
Claude's context, so it is prompt-injection-sensitive. For that threat model, scope
`--allowedTools` to the *narrowest* Bash set instead of a blanket `Bash`. The engine
(`monitor-dedup.sh`) is invoked **directly** (it is executable with a shebang — not wrapped in
a `bash <script>` call), so you can grant just the engine path and drop the full-shell
`Bash(bash:*)` that a `bash <script>` invocation would otherwise force:

```bash
# 0 2 * * *  cd /path/to/product && claude -p "/monitor-nightly" --allowedTools \
#   'Bash($CLAUDE_PLUGIN_ROOT/scripts/monitor-dedup.sh:*),Bash(flock:*),Bash(mkdir:*),Bash(jq:*),Bash(grep:*),Bash(sed:*),Bash(tr:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(basename:*),Bash(dirname:*),Bash(date:*),Read,Write,Grep,Glob' \
#   >> /var/log/monitor-nightly.log 2>&1
```

Add `Bash(<your custom_checks path>:*)` if a `custom_checks` script is configured. A successful
injection via customer content then cannot exec arbitrary commands — only the allowlisted
utilities — because `Bash(bash:*)` is no longer in scope.

Note the GitHub CLI is intentionally **absent** from this list: the command never calls it
directly — all GitHub I/O is encapsulated in the engine and runs as a *child process* of the
allowlisted engine, so it never reaches the Bash permission layer. The CLI only needs to be
installed and authenticated in the environment (per the prerequisites above), not granted as a
tool. Granting it here would needlessly widen the blast radius.
