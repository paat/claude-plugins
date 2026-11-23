#!/usr/bin/env bash
# Derive per-provider model allowlists from pool-tiers.tsv (extended by MMO_POOL_TIERS
# when set) plus non-pool direct-pin/compatibility rows in model-catalog.tsv
# (overridable with MMO_MODEL_CATALOG).

MMO_CATALOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Print one supported model ID per line for PROVIDER, deduplicated in canonical order.
# Pool rows are ordered highest tier first (T4..T1, then any other tier), preserving
# preference order within each tier. For provider "claude", "claude-api" pool rows count too.
# When MMO_POOL_TIERS is set, its rows extend the shipped pool-tiers.tsv so a subset
# routing override for pool.sh never revokes shipped direct-runner defaults.
mmo_catalog_models() {  # mmo_catalog_models PROVIDER
  local provider="$1"
  local shipped_tiers="$MMO_CATALOG_DIR/pool-tiers.tsv"
  local extra_tiers="${MMO_POOL_TIERS:-}"
  local catalog_file="${MMO_MODEL_CATALOG:-$MMO_CATALOG_DIR/model-catalog.tsv}"
  if [ ! -r "$shipped_tiers" ]; then
    printf 'lib-catalog: cannot read tier table %s\n' "$shipped_tiers" >&2
    return 1
  fi
  if [ -n "$extra_tiers" ] && [ ! -r "$extra_tiers" ]; then
    printf 'lib-catalog: cannot read tier table %s\n' "$extra_tiers" >&2
    return 1
  fi
  if [ ! -r "$catalog_file" ]; then
    printf 'lib-catalog: cannot read model catalog %s\n' "$catalog_file" >&2
    return 1
  fi
  local -a tier_files=("$shipped_tiers")
  if [ -n "$extra_tiers" ] && [ "$extra_tiers" != "$shipped_tiers" ]; then
    tier_files+=("$extra_tiers")
  fi
  awk -F'\t' -v provider="$provider" -v catalog_file="$catalog_file" '
    function trim_cr(s) { sub(/\r$/, "", s); return s }
    function valid_id(m) { return (m ~ /^[A-Za-z0-9][A-Za-z0-9._:\/-]*$/) }
    function emit(m) {
      if (valid_id(m) && !(m in emitted)) {
        emitted[m] = 1
        print m
      }
    }
    function emit_pool(    t_idx, t_name, i) {
      split("T4 T3 T2 T1", std_tiers, " ")
      for (t_idx = 1; t_idx <= 4; t_idx++) {
        t_name = std_tiers[t_idx]
        for (i = 1; i <= tier_count[t_name]; i++) {
          emit(tier_models[t_name, i])
        }
        seen_tier[t_name] = 1
      }
      for (t_idx = 1; t_idx <= other_tier_count; t_idx++) {
        t_name = other_tiers[t_idx]
        if (!(t_name in seen_tier)) {
          for (i = 1; i <= tier_count[t_name]; i++) {
            emit(tier_models[t_name, i])
          }
          seen_tier[t_name] = 1
        }
      }
    }
    FILENAME != catalog_file {
      line = trim_cr($0)
      if (line ~ /^[[:space:]]*(#|$)/) next
      split(line, f, "\t")
      t = f[1]; p = f[2]; m = f[3]
      if (p == provider || (provider == "claude" && p == "claude-api")) {
        if (valid_id(m)) {
          if (!(t in known_other) && t != "T1" && t != "T2" && t != "T3" && t != "T4") {
            known_other[t] = 1
            other_tiers[++other_tier_count] = t
          }
          tier_count[t]++
          tier_models[t, tier_count[t]] = m
        }
      }
      next
    }
    {
      line = trim_cr($0)
      if (line ~ /^[[:space:]]*(#|$)/) next
      split(line, f, "\t")
      p = f[1]; m = f[2]
      if (p == provider && (m == "*" || valid_id(m))) {
        cat_count++
        cat_entries[cat_count] = m
        if (m == "*") has_star = 1
      }
    }
    END {
      if (!has_star) emit_pool()
      for (i = 1; i <= cat_count; i++) {
        if (cat_entries[i] == "*") {
          emit_pool()
        } else {
          emit(cat_entries[i])
        }
      }
    }
  ' "${tier_files[@]}" "$catalog_file"
}

# Print supported model IDs for PROVIDER joined by SEP (default "|").
mmo_catalog_list() {  # mmo_catalog_list PROVIDER [SEP]
  local provider="$1" sep="${2:-|}" raw out="" model
  raw="$(mmo_catalog_models "$provider")" || return 1
  while IFS= read -r model; do
    [ -n "$model" ] || continue
    if [ -n "$out" ]; then out+="${sep}${model}"; else out="$model"; fi
  done <<< "$raw"
  printf '%s\n' "$out"
}

# Return 0 iff MODEL is an exact entry in PROVIDER catalog.
mmo_catalog_has_model() {  # mmo_catalog_has_model PROVIDER MODEL
  local provider="$1" model="${2:-}" raw entry
  [[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || return 1
  raw="$(mmo_catalog_models "$provider")" || return 1
  while IFS= read -r entry; do
    [ "$entry" = "$model" ] && return 0
  done <<< "$raw"
  return 1
}
