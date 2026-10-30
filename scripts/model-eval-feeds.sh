#!/usr/bin/env bash
# Sourced by refresh-model-versions.sh. Public API shapes probed 2026-10-30.
# Fetch into scratch space; publish one complete TSV only after every feed validates.
eval_get() { curl --fail --silent --show-error --location --max-time 45 "$@"; }

eval_arena() {
  local config=$1 dest=$2 offset=0 count total expected_total='' page="$2.page"
  : >"$dest.rows" || return
  while :; do
    eval_get "https://datasets-server.huggingface.co/rows?dataset=lmarena-ai/leaderboard-dataset&config=$config&split=latest&offset=$offset&length=100" >"$page" || return
    jq -e --argjson offset "$offset" '
      .partial == false and (.num_rows_total|type == "number" and . > 0)
      and (.rows|type == "array" and length > 0 and length <= 100)
      and all(.rows | to_entries[]; .value.row_idx == ($offset + .key)
        and .value.truncated_cells == [] and (.value.row|type == "object"))
    ' "$page" >/dev/null || return 1
    total=$(jq -r '.num_rows_total' "$page") || return
    count=$(jq -r '.rows|length' "$page") || return
    [[ -z $expected_total || $total == "$expected_total" ]] || return 1
    expected_total=$total
    jq -c '.rows[].row' "$page" >>"$dest.rows" || return
    offset=$((offset + count))
    (( offset <= total )) || return 1
    (( offset < total )) || break
  done
  jq -s '.' "$dest.rows" >"$dest" || return
  # Categories publish independently (observed image_to_webdev lagged overall).
  jq -e 'group_by(.category) | all(.[]; map(.leaderboard_publish_date)|unique|length == 1)' "$dest" >/dev/null
}

eval_build() {
  local scratch=$1 catalog=$2 pool=$3 feed
  eval_get https://openrouter.ai/api/v1/models >"$scratch/openrouter.json" || return
  eval_arena webdev "$scratch/arena-webdev.json" || return
  eval_arena agent "$scratch/arena-agent.json" || return
  # Undocumented Harbor Hub read-only POST; data licence UNKNOWN.
  eval_get -H 'Content-Type: application/json' \
    --data '{"package":"terminal-bench/terminal-bench","name":"4-0-0"}' \
    https://ofhuhcpkvzjlejydnvyd.supabase.co/functions/v1/leaderboard-read >"$scratch/terminal.json" || return
  { cat "$catalog"; awk -F '\t' '!/^#/ && NF >= 3 {print $3}' "$pool"; } >"$scratch/ids" || return
  printf '%s\n' $'model\tname\tvendor\tmetric\tvalue\tci_low\tci_high\trank\teffort\tharness\tpreliminary\tcanonical_slug\tsource\tas_of\ttokens\tcost_usd' >"$scratch/evals.tsv" || return
  for feed in openrouter arena-webdev arena-agent terminal; do
    jq -er --arg feed "$feed" --arg as_of "$(date -u +%F)" \
      --rawfile aliases "$REPO/scripts/model-eval-aliases.tsv" --rawfile catalog "$scratch/ids" \
      -f "$REPO/scripts/model-eval-parse.jq" "$scratch/$feed.json" >"$scratch/$feed.tsv" || return
    cat "$scratch/$feed.tsv" >>"$scratch/evals.tsv" || return
  done
  # Arena contains duplicate model/category names; retain them as evidence.
  # The comparison suppresses rank triggers for ambiguous identities.
}

refresh_feeds() {
  local catalog=$1 pool=$2 scratch old
  scratch=$(mktemp -d "$STATE/feeds.XXXXXX") || return
  if ! eval_build "$scratch" "$catalog" "$pool"; then
    log 'FAIL: eval feed fetch/schema; keeping last good evals.tsv; catalog detection continues'
    rm -rf "$scratch"
    return 1
  fi
  old="$STATE/evals.tsv"
  if [[ ! -f $old ]]; then
    : >"$STATE/eval-pending.txt" || return
    mv "$scratch/evals.tsv" "$old" || return
    log 'eval feeds seeded; 0 pending rows'
    rm -rf "$scratch"
    return 0
  fi
  if ! jq -nr --rawfile old "$old" --rawfile new "$scratch/evals.tsv" --rawfile pool "$pool" \
    -f "$REPO/scripts/model-eval-changes.jq" >"$scratch/changes"; then
    log 'FAIL: eval comparison; keeping last good evals.tsv'
    rm -rf "$scratch"
    return 1
  fi
  # Pending evidence survives an open PR or failed headless pass; acknowledge only on success.
  touch "$STATE/eval-pending.txt"
  sort -u "$STATE/eval-pending.txt" "$scratch/changes" >"$scratch/pending" || return
  mv "$scratch/pending" "$STATE/eval-pending.txt" || return
  mv "$scratch/evals.tsv" "$STATE/evals.tsv" || return
  awk -F '\t' 'NR>1 {n[$13]++} END {for(s in n) printf "feed %s: %d rows\n",s,n[s]}' "$STATE/evals.tsv" | sort
  log "eval material evidence: $(wc -l <"$scratch/changes") new rows; $(wc -l <"$STATE/eval-pending.txt") pending rows"
  rm -rf "$scratch"
}
