#!/usr/bin/env bash
# Daily cron job: snapshot the model catalogs of the installed provider CLIs.
# When a model ID appears whose family plugins/ already uses, a headless Claude
# session updates superseded pins and opens a PR. It never merges; a day with
# no such new ID exits before any model call.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/model-refresh"
PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
mkdir -p "$STATE"
exec 9>"$STATE/lock"
flock -n 9 || exit 0
cd "$STATE" # opencode hangs when started inside a git repo

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
section() { # name command...: append one sorted, non-empty catalog section
  local ids
  ids="$("${@:2}")" && [[ -n $ids ]] || { log "FAIL: empty $1 catalog"; exit 1; }
  printf '## %s\n%s\n' "$1" "$(sort -uV <<<"$ids")" >>"$STATE/catalog.new"
}
codex_ids() { jq -r '.models[].slug' "$HOME/.codex/models_cache.json"; }
opencode_ids() { timeout 120 opencode models </dev/null | grep -E '^(opencode|opencode-go|deepseek)/'; }
grok_ids() { timeout 120 grok models </dev/null | sed -nE 's/^ +[-*] ([^ ]+).*/\1/p'; }
agy_ids() { timeout 120 agy models </dev/null | awk -F'\t' 'NF > 1 { print $1 }'; }

: >"$STATE/catalog.new"
section "codex (~/.codex/models_cache.json)" codex_ids
section "opencode (opencode models; also lists Claude models)" opencode_ids
section "grok (grok models)" grok_ids
section "agy (agy models)" agy_ids
facts="$STATE/catalog.txt"
touch "$facts"
# Family stem of each new ID, e.g. opencode-go/glm-5.4 -> glm-
stems="$(comm -13 <(sort -u "$facts") <(sort -u "$STATE/catalog.new") |
  grep -v '^## ' | sed -E 's|.*/||; s/[0-9].*//' | awk 'length >= 3' | sort -u)" || true
if [[ -z $stems ]] || ! grep -rqF -f <(printf '%s\n' "$stems") "$REPO/plugins"; then
  mv "$STATE/catalog.new" "$facts"
  log "no new model ID in a family the plugins use"
  exit 0
fi

open_pr="$(cd "$REPO" && gh pr list --state open --limit 200 --json headRefName,url \
  -q '[.[] | select(.headRefName | startswith("chore/model-refresh-")) | .url] | first // empty')"
if [[ -n $open_pr ]]; then
  log "refresh PR still open: $open_pr"
  exit 0
fi

branch="chore/model-refresh-$(date +%Y%m%d)"
wt="$STATE/worktree"
git -C "$REPO" fetch -q origin main
git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
git -C "$REPO" worktree add -q -B "$branch" "$wt" origin/main
trap 'git -C "$REPO" worktree remove --force "$wt" || true; git -C "$REPO" branch -q -D "$branch" || true' EXIT

log "catalogs changed; running refresh on $branch"
(cd "$wt" && timeout 90m claude --model opus --effort high --dangerously-skip-permissions -p "$(cat <<PROMPT
Refresh superseded model IDs in this repository's plugins. $STATE/catalog.new
lists, per provider CLI, the model IDs available right now; a provider prefix
such as opencode/ is routing, the rest is the ID. It is the only source of
truth for which models exist; do not use memory or the web.

1. Find model IDs pinned in plugins/ (defaults, routing tables, runner scripts,
   agent and command frontmatter, README or doc lines stating a current default)
   where the catalog lists a newer version of the same family and tier, e.g.
   glm-5.3 -> glm-5.4 or gpt-6-astra -> gpt-6.1-astra. The new ID must be listed
   for the CLI and provider prefix that runs the pin: a Codex pin needs the
   codex section, opencode-go/glm-5.3 needs an opencode-go/ ID. A pin run by
   the claude CLI may take a Claude ID listed under opencode/ only after
   claude -p --model <new-id> 'Reply OK' exits 0.
2. Never change family or tier (opus -> fable, flash -> pro, sol -> astra), local
   model names, Muse (it runs on the CLI default), changelog or history text, or
   test fixtures that use an old ID on purpose. Keep a pin whose nearby comment
   justifies the older version and list it in the PR body. In a list of
   accepted or routable IDs, add the new ID and keep the old one; only
   defaults and current-model pins move.
3. If nothing qualifies, change nothing and print NO_CHANGES as the final line.
4. Otherwise edit, update tests that assert the old IDs, bump each touched
   plugin's version and sync Codex metadata per CLAUDE.md, run each touched
   plugin's tests and the README "Development Checks", commit, push this branch,
   and open a PR whose body lists each old -> new ID with the catalog line that
   proves it and how it was verified. Do not merge. Print the PR URL as the
   final line.
PROMPT
)") | tee "$STATE/last-run.log"

if [[ $(tail -n1 "$STATE/last-run.log" | tr -d '[:space:]') != NO_CHANGES ]]; then
  pr="$(cd "$wt" && gh pr list --head "$branch" --state open --json url -q '.[0].url // empty')"
  [[ -n $pr ]] || { log "FAIL: refresh ended without NO_CHANGES or a PR; see $STATE/last-run.log"; exit 1; }
  log "opened $pr"
fi
mv "$STATE/catalog.new" "$facts"
