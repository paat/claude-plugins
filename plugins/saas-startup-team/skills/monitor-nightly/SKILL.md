---
name: monitor-nightly
description: "Nightly monitor job body (host-scheduled). Usage: /monitor-nightly [--dry-run]"
argument-hint: "[--dry-run]"
allowed-tools: Bash, Read, Write, Grep, Glob
user_invocable: true
transitional: true
---

# /monitor-nightly — Generic Nightly Monitor

**Scheduling lives outside prompts** (cron/host). Job body only; on-demand → operate `monitor`.

Failure markers → deduped GitHub issues via `scripts/monitor-dedup.sh` (never call `gh` here).
Config: optional `monitor:` in `.claude/saas-startup-team.local.md`. Use `--dry-run` to preview.

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

## Lock and window

```bash
mkdir -p "$(dirname "$STATE_FILE")"
exec 9>"${STATE_FILE}.lock"
flock -n 9 || { echo "monitor: another run holds the lock; exiting"; exit 0; }
eval "$("$ENGINE" window --state "$STATE_FILE")"
export MONITOR_SINCE MONITOR_SINCE_MINUTES
```

## Collect findings

Write findings JSONL to `${STATE_FILE}.findings` for the Commit step.

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

PROBE_FINDINGS="${STATE_FILE:-.startup/monitor-state.json}.probe-findings"
if [ -f "$PROBE_FINDINGS" ] && find "$PROBE_FINDINGS" -mmin -60 -print -quit | grep -q .; then
  cat "$PROBE_FINDINGS" >> "$FINDINGS"
  rm -f "$PROBE_FINDINGS"
elif [ -x "$CUSTOM_CHECKS" ]; then
  rm -f "$PROBE_FINDINGS"
  set +e
  "$CUSTOM_CHECKS" >> "$FINDINGS"; cc_ec=$?
  set -e
  if [ "$cc_ec" -ne 0 ]; then
    jq -nc --arg b "custom-checks exited $cc_ec" \
      '{pattern_key:"ops:monitor-checks:failure", severity:"high", entity:null, title:"[Monitor] custom-checks script failed", body:$b}' >> "$FINDINGS"
  fi
fi
```

> Probe may pre-fill `${STATE_FILE}.probe-findings` (consumed once); else run `CUSTOM_CHECKS` here.

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

Summarize engine JSON actions (created/commented/skipped). Prefix `[DRY RUN]` when set.

## Digest and cron

See `docs/legacy/monitor-nightly-cron.md` (includes **Hardened cron** / narrow
tool-scope). Optional daily `/digest` after monitor.
