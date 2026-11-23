#!/usr/bin/env bash
# PR/origin binding, live collection verification, proof sealing, and finalize/verify commands.
# Sourced by scripts/collect-review-evidence.sh.

origin_identity() {
  local root="$1" origin host slug path
  origin="$(git -C "$root" remote get-url origin 2>/dev/null)" || die "origin remote is required"
  case "$origin" in
    https://*/*|http://*/*|ssh://*/*)
      host="$(printf '%s' "$origin" | sed -E 's#^[a-z]+://([^/@]+@)?([^/:]+)(:[0-9]+)?/.*#\2#')"
      path="$(printf '%s' "$origin" | sed -E 's#^[a-z]+://([^/@]+@)?[^/]+/##')"
      ;;
    *@*:*)
      host="${origin#*@}"; host="${host%%:*}"
      path="${origin#*:}"
      ;;
    *) die "unsupported origin URL: $origin" ;;
  esac
  path="${path#/}"; path="${path%.git}"; path="${path%/}"
  case "$host" in ''|*[!A-Za-z0-9.-]*) die "invalid origin host" ;; esac
  case "$path" in */*/*|/*|*'..'*|'') die "origin must identify one owner/repository" ;; esac
  case "$path" in *[!A-Za-z0-9_.\/-]*) die "invalid origin repository" ;; esac
  slug="$path"
  jq -nc --arg host "$host" --arg slug "$slug" '{host:$host,slug:$slug}'
}

gh_repo() {
  local host="$1" slug="$2"; shift 2
  env -u GH_REPO -u GITHUB_REPOSITORY GH_HOST="$host" GH_PROMPT_DISABLED=1 \
    GH_PAGER=cat PAGER=cat gh "$@" --repo "$slug"
}

live_binding() {
  local root="$1" pr="$2" identity host slug repo_json pr_json canonical repo_url
  identity="$(origin_identity "$root")"
  host="$(printf '%s' "$identity" | jq -r .host)"
  slug="$(printf '%s' "$identity" | jq -r .slug)"
  repo_json="$(env -u GH_REPO -u GITHUB_REPOSITORY GH_HOST="$host" GH_PROMPT_DISABLED=1 \
    GH_PAGER=cat PAGER=cat gh repo view "$slug" --json nameWithOwner,url)" \
    || die "cannot resolve canonical GitHub repository"
  printf '%s' "$repo_json" | jq -e '
    (type == "object") and (.nameWithOwner | type == "string" and length > 2)
    and (.url | type == "string" and length > 8)
  ' >/dev/null || die "invalid repository response"
  canonical="$(printf '%s' "$repo_json" | jq -r .nameWithOwner)"
  repo_url="$(printf '%s' "$repo_json" | jq -r .url)"
  [ "$(printf '%s' "$canonical" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ] \
    || die "origin and canonical GitHub repository differ"
  pr_json="$(gh_repo "$host" "$canonical" pr view "$pr" \
    --json number,url,state,baseRefName,baseRefOid,headRefName,headRefOid,body)" \
    || die "cannot resolve pull request #$pr"
  printf '%s' "$pr_json" | jq -e --argjson n "$pr" '
    (type == "object") and .number == $n and .state == "OPEN"
    and (.url | type == "string" and length > 8)
    and (.baseRefName | type == "string" and length > 0)
    and (.headRefName | type == "string" and length > 0)
    and (.baseRefOid | type == "string" and test("^[0-9a-f]{40}$"))
    and (.headRefOid | type == "string" and test("^[0-9a-f]{40}$"))
    and (.body | type == "string")
  ' >/dev/null || die "pull request is not an open, complete GitHub PR"
  jq -nc --argjson identity "$identity" --arg canonical "$canonical" \
    --arg repo_url "$repo_url" --arg root "$root" --argjson pr "$pr_json" \
    '{repository:{root:$root,host:$identity.host,name_with_owner:$canonical,
       url:$repo_url},pull_request:$pr}'
}

verify_live_binding() {
  local dir="$1" manifest="$2" root pr current expected body_tmp diff_tmp ignored_tmp ignored_json
  local deleted_tmp deleted_json mutation_tmp mutation_json
  root="$(jq -r .repository.root "$manifest")"; root="$(real_dir "$root")"
  pr="$(jq -r .pull_request.number "$manifest")"
  current="$(live_binding "$root" "$pr")"
  expected="$(jq -S -c '{repository,pull_request:{number:.pull_request.number,url:.pull_request.url,state:.pull_request.state,
    baseRefName:.pull_request.base_ref,baseRefOid:.pull_request.base_oid,
    headRefName:.pull_request.head_ref,headRefOid:.pull_request.head_oid}}' "$manifest")"
  [ "$(printf '%s' "$current" | jq -S -c 'del(.pull_request.body)')" = "$expected" ] \
    || die "repository or pull request drifted after collection"
  body_tmp="$(mktemp)"; diff_tmp="$(mktemp)"
  printf '%s' "$current" | jq -j .pull_request.body > "$body_tmp"
  [ "$(sha_file "$body_tmp")" = "$(jq -r .pull_request.body.sha256 "$manifest")" ] \
    || { rm -f "$body_tmp" "$diff_tmp"; die "pull request body drifted after collection"; }
  git -C "$root" diff --binary --no-ext-diff --no-textconv "$(jq -r .pull_request.base_oid "$manifest")...$(jq -r .pull_request.head_oid "$manifest")" > "$diff_tmp"
  [ "$(sha_file "$diff_tmp")" = "$(jq -r .diff.sha256 "$manifest")" ] \
    || { rm -f "$body_tmp" "$diff_tmp"; die "pull request diff drifted after collection"; }
  rm -f "$body_tmp" "$diff_tmp"
  [ "$(git -C "$root" rev-parse HEAD)" = "$(jq -r .pull_request.head_oid "$manifest")" ] \
    || die "worktree HEAD drifted after collection"
  ignored_json="$(cd "$root" && tribunal_ignored_additions "$(jq -r .pull_request.base_oid "$manifest")")"
  if jq -e 'has("ignored_paths")' "$manifest" >/dev/null; then
    ignored_tmp="$(mktemp)"; printf '%s' "$ignored_json" | jq -S . > "$ignored_tmp"
    cmp -s "$ignored_tmp" "$dir/ignored-paths.json" \
      || { rm -f "$ignored_tmp"; die "ignored-path evidence drifted after collection"; }
    rm -f "$ignored_tmp"
  else
    [ "$(printf '%s' "$ignored_json" | jq 'length')" -eq 0 ] \
      || die "ignored-path evidence appeared after collection"
  fi
  deleted_json="$(cd "$root" && tribunal_deleted_policy_paths "$(jq -r .pull_request.base_oid "$manifest")")"
  if jq -e 'has("deleted_paths")' "$manifest" >/dev/null; then
    deleted_tmp="$(mktemp)"; printf '%s' "$deleted_json" | jq -S . > "$deleted_tmp"
    cmp -s "$deleted_tmp" "$dir/deleted-paths.json" \
      || { rm -f "$deleted_tmp"; die "deleted-path evidence drifted after collection"; }
    rm -f "$deleted_tmp"
  else
    [ "$(printf '%s' "$deleted_json" | jq 'length')" -eq 0 ] \
      || die "deleted-path evidence appeared after collection"
  fi
  mutation_json="$(cd "$root" && tribunal_mutation_gate "$(jq -r .pull_request.base_oid "$manifest")" "$(jq -r .pull_request.head_oid "$manifest")")"
  if jq -e 'has("mutation_gate")' "$manifest" >/dev/null; then
    mutation_tmp="$(mktemp)"; printf '%s' "$mutation_json" | jq -S . > "$mutation_tmp"
    cmp -s "$mutation_tmp" "$dir/mutation-gate.json" \
      || { rm -f "$mutation_tmp"; die "mutation-gate evidence drifted after collection"; }
    rm -f "$mutation_tmp"
  else
    [ "$(printf '%s' "$mutation_json" | jq 'length')" -eq 0 ] \
      || die "mutation-gate evidence appeared after collection"
  fi
  [ "$(sha_file "$dir/pr-body.txt")" = "$(jq -r .pull_request.body.sha256 "$manifest")" ] \
    || die "retained PR body digest mismatch"
  [ "$(bytes_file "$dir/pr-body.txt")" = "$(jq -r .pull_request.body.bytes "$manifest")" ] \
    || die "retained PR body size mismatch"
  [ "$(sha_file "$dir/review.diff")" = "$(jq -r .diff.sha256 "$manifest")" ] \
    || die "retained diff digest mismatch"
  [ "$(bytes_file "$dir/review.diff")" = "$(jq -r .diff.bytes "$manifest")" ] \
    || die "retained diff size mismatch"
}

verify_collection_internal() {
  local dir="$1" expected_sha="$2" manifest provider path status wrapper grok_recovery roots
  [ ! -L "$dir" ] || die "collection directory must not be symbolic"
  dir="$(real_dir "$dir")"; manifest="$dir/manifest.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || die "collection manifest missing or symbolic"
  [ -d "$dir/providers" ] && [ ! -L "$dir/providers" ] || die "provider artifact directory missing or symbolic"
  [ -f "$dir/pr-body.txt" ] && [ ! -L "$dir/pr-body.txt" ] || die "retained PR body missing or symbolic"
  [ -f "$dir/review.diff" ] && [ ! -L "$dir/review.diff" ] || die "retained diff missing or symbolic"
  [ "$expected_sha" = "$(sha_file "$manifest")" ] || die "collection manifest digest mismatch"
  jq -e '.git_surface.schema == "tribunal-git-surface/v2"' "$manifest" >/dev/null \
    || die "collection manifest lacks git_surface identity; recollect with this runner (older manifests are unsupported)"
  validate_manifest_shape "$manifest" || die "collection manifest schema invalid"
  grok_recovery="$(jq -r .grok_recovery "$manifest")"
  load_git_surface "$manifest"
  load_safe_directories
  require_git_version
  reject_uncontained_config "$SURFACE_ROOT"
  if jq -e 'has("prior_rejections")' "$manifest" >/dev/null; then
    [ -f "$dir/prior-rejections.json" ] && [ ! -L "$dir/prior-rejections.json" ] \
      || die "prior-rejections artifact missing or symbolic"
    [ "$(sha_file "$dir/prior-rejections.json")" = "$(jq -r .prior_rejections.sha256 "$manifest")" ] \
      || die "prior-rejections artifact digest mismatch"
    [ "$(bytes_file "$dir/prior-rejections.json")" = "$(jq -r .prior_rejections.bytes "$manifest")" ] \
      || die "prior-rejections artifact size mismatch"
    validate_prior_rejections "$dir/prior-rejections.json" || die "prior-rejections artifact schema invalid"
  else
    [ ! -e "$dir/prior-rejections.json" ] && [ ! -L "$dir/prior-rejections.json" ] \
      || die "unbound prior-rejections artifact"
  fi
  if jq -e 'has("ignored_paths")' "$manifest" >/dev/null; then
    [ -f "$dir/ignored-paths.json" ] && [ ! -L "$dir/ignored-paths.json" ] \
      || die "ignored-path artifact missing or symbolic"
    [ "$(sha_file "$dir/ignored-paths.json")" = "$(jq -r .ignored_paths.sha256 "$manifest")" ] \
      || die "ignored-path artifact digest mismatch"
    [ "$(bytes_file "$dir/ignored-paths.json")" = "$(jq -r .ignored_paths.bytes "$manifest")" ] \
      || die "ignored-path artifact size mismatch"
    validate_ignored_paths "$dir/ignored-paths.json" || die "ignored-path artifact schema invalid"
    [ -f "$dir/sensitive-paths.json" ] && [ ! -L "$dir/sensitive-paths.json" ] \
      || die "sensitive-path artifact missing or symbolic"
    [ "$(sha_file "$dir/sensitive-paths.json")" = "$(jq -r .sensitive_paths.sha256 "$manifest")" ] \
      || die "sensitive-path artifact digest mismatch"
    [ "$(bytes_file "$dir/sensitive-paths.json")" = "$(jq -r .sensitive_paths.bytes "$manifest")" ] \
      || die "sensitive-path artifact size mismatch"
    jq -e --slurpfile ignored "$dir/ignored-paths.json" '
      type == "array" and (length == (unique | length))
      and ((. - [$ignored[0][].path]) | length == 0)
    ' "$dir/sensitive-paths.json" >/dev/null || die "sensitive-path artifact schema invalid"
  else
    [ ! -e "$dir/ignored-paths.json" ] || die "unbound ignored-path artifact"
    [ ! -e "$dir/sensitive-paths.json" ] || die "unbound sensitive-path artifact"
  fi
  if jq -e 'has("deleted_paths")' "$manifest" >/dev/null; then
    [ -f "$dir/deleted-paths.json" ] && [ ! -L "$dir/deleted-paths.json" ] \
      || die "deleted-path artifact missing or symbolic"
    [ "$(sha_file "$dir/deleted-paths.json")" = "$(jq -r .deleted_paths.sha256 "$manifest")" ] \
      || die "deleted-path artifact digest mismatch"
    [ "$(bytes_file "$dir/deleted-paths.json")" = "$(jq -r .deleted_paths.bytes "$manifest")" ] \
      || die "deleted-path artifact size mismatch"
    validate_deleted_paths "$dir/deleted-paths.json" || die "deleted-path artifact schema invalid"
  else
    [ ! -e "$dir/deleted-paths.json" ] || die "unbound deleted-path artifact"
  fi
  if jq -e 'has("mutation_gate")' "$manifest" >/dev/null; then
    [ -f "$dir/mutation-gate.json" ] && [ ! -L "$dir/mutation-gate.json" ] \
      || die "mutation-gate artifact missing or symbolic"
    [ "$(sha_file "$dir/mutation-gate.json")" = "$(jq -r .mutation_gate.sha256 "$manifest")" ] \
      || die "mutation-gate artifact digest mismatch"
    [ "$(bytes_file "$dir/mutation-gate.json")" = "$(jq -r .mutation_gate.bytes "$manifest")" ] \
      || die "mutation-gate artifact size mismatch"
    validate_mutation_gate "$dir/mutation-gate.json" || die "mutation-gate artifact schema invalid"
  else
    [ ! -e "$dir/mutation-gate.json" ] || die "unbound mutation-gate artifact"
  fi
  roots="collection root=$(dirname "$(dirname "$(jq -r .runner.path "$manifest")")"); invoked root=$PLUGIN_ROOT"
  [ "$(jq -r .runner.path "$manifest")" = "$SCRIPT_DIR/collect-review-evidence.sh" ] \
    || die "collection runner path differs from installed runner ($roots)"
  [ "$(jq -r .runner.sha256 "$manifest")" = "$(sha_file "$SCRIPT_DIR/collect-review-evidence.sh")" ] \
    || die "collection runner digest differs from installed runner ($roots)"
  [ "$(jq -r .runner.library_path "$manifest")" = "$SCRIPT_DIR/lib.sh" ] \
    || die "collection library path differs from installed library ($roots)"
  [ "$(jq -r .runner.library_sha256 "$manifest")" = "$(sha_file "$SCRIPT_DIR/lib.sh")" ] \
    || die "collection library digest differs from installed library ($roots)"
  [ "$(jq -r .runner.bundle_manifest_path "$manifest")" = "$PLUGIN_ROOT/integrity/runner-bundle.json" ] \
    || die "collection runner bundle manifest path differs from installed bundle ($roots)"
  [ "$(jq -r .runner.bundle_manifest_sha256 "$manifest")" = "$(sha_file "$PLUGIN_ROOT/integrity/runner-bundle.json")" ] \
    || die "runner bundle changed since collect at $PLUGIN_ROOT"
  bash "$SCRIPT_DIR/check-runner-bundle.sh" \
    --expected-manifest-sha256 "$(jq -r .runner.bundle_manifest_sha256 "$manifest")" >/dev/null \
    || die "installed tribunal runner bundle failed integrity validation"
  for provider in $PROVIDERS; do
    path="$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.artifact.path' "$manifest")"
    [ "$path" = "providers/$provider.json" ] || die "unexpected artifact path for $provider"
    [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ] || die "provider artifact missing or symbolic: $provider"
    [ "$(sha_file "$dir/$path")" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.artifact.sha256' "$manifest")" ] \
      || die "provider artifact digest mismatch: $provider"
    [ "$(bytes_file "$dir/$path")" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.artifact.bytes' "$manifest")" ] \
      || die "provider artifact size mismatch: $provider"
    validate_provider "$provider" "$dir/$path" || die "provider artifact schema invalid: $provider"
    grok_recovery_allowed "$grok_recovery" "$dir/$path" \
      || die "grok_recovery_rejected: artifact violates sealed recovery policy"
    status="$(provider_status "$dir/$path")"
    [ "$status" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.status' "$manifest")" ] \
      || die "provider status mismatch: $provider"
    wrapper="$(wrapper_for_provider "$provider")"
    [ "$wrapper" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.wrapper.path' "$manifest")" ] \
      || die "provider wrapper path mismatch: $provider"
    [ "$(sha_file "$wrapper")" = "$(jq -r --arg p "$provider" '.providers[]|select(.provider==$p)|.wrapper.sha256' "$manifest")" ] \
      || die "provider wrapper digest mismatch: $provider"
  done
  verify_live_binding "$dir" "$manifest"
  VERIFIED_COLLECTION="$dir"
}

parse_collection_args() {
  COLLECTION=""; EXPECTED_MANIFEST=""; ARBITRATION=""; EXPECTED_PROOF=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --collection) [ "$#" -ge 2 ] || die "--collection needs a value"; COLLECTION="$2"; shift 2 ;;
      --expected-manifest-sha256) [ "$#" -ge 2 ] || die "--expected-manifest-sha256 needs a value"; EXPECTED_MANIFEST="$2"; shift 2 ;;
      --arbitration) [ "$#" -ge 2 ] || die "--arbitration needs a value"; ARBITRATION="$2"; shift 2 ;;
      --expected-proof-sha256) [ "$#" -ge 2 ] || die "--expected-proof-sha256 needs a value"; EXPECTED_PROOF="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$COLLECTION" ] && [ -n "$EXPECTED_MANIFEST" ] || die "--collection and --expected-manifest-sha256 are required"
  case "$COLLECTION" in /*) ;; *) die "--collection must be absolute" ;; esac
  case "$EXPECTED_MANIFEST" in *[!0-9a-f]*|'') die "invalid expected manifest digest" ;; esac
  [ "${#EXPECTED_MANIFEST}" -eq 64 ] || die "invalid expected manifest digest"
}

write_proof() {
  local manifest="$1" manifest_sha="$2" arbitration="$3" output="$4"
  jq -S -n --arg schema "$SCHEMA_PROOF" --arg finalized_at "$(now)" \
    --arg manifest_sha256 "$manifest_sha" --arg arbitration_sha256 "$(sha_file "$arbitration")" \
    --argjson pr_number "$(jq -r .pull_request.number "$manifest")" \
    --arg head_oid "$(jq -r .pull_request.head_oid "$manifest")" \
    --arg body_sha256 "$(jq -r .pull_request.body.sha256 "$manifest")" \
    --arg diff_sha256 "$(jq -r .diff.sha256 "$manifest")" \
    --arg decision "$(jq -r .tribunal_verdict.decision "$arbitration")" \
    --argjson confidence "$(jq -r .tribunal_verdict.confidence "$arbitration")" \
    --argjson critical_count "$(jq '[.findings[]|select(.severity=="critical")]|length' "$arbitration")" \
    --argjson high_count "$(jq '[.findings[]|select(.severity=="high")]|length' "$arbitration")" \
    '{schema:$schema,finalized_at:$finalized_at,manifest_sha256:$manifest_sha256,
      pull_request:{number:$pr_number,head_oid:$head_oid,body_sha256:$body_sha256,diff_sha256:$diff_sha256},
      arbitration:{path:"arbitration.json",sha256:$arbitration_sha256,decision:$decision,
        confidence:$confidence,critical_count:$critical_count,high_count:$high_count}}' > "$output"
}

proof_result() {
  local dir="$1" manifest_sha="$2"
  jq -nc --arg collection "$dir" --arg manifest_sha256 "$manifest_sha" \
    --arg proof_sha256 "$(sha_file "$dir/proof.json")" \
    --arg arbitration_sha256 "$(sha_file "$dir/arbitration.json")" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,proof_sha256:$proof_sha256,
      arbitration_sha256:$arbitration_sha256}'
}

verify_proof_internal() {
  local dir="$1" manifest_sha="$2" expected_proof="$3" manifest proof arbitration
  manifest="$dir/manifest.json"; proof="$dir/proof.json"; arbitration="$dir/arbitration.json"
  [ -f "$proof" ] && [ ! -L "$proof" ] && [ -f "$arbitration" ] && [ ! -L "$arbitration" ] \
    || die "retained tribunal proof is incomplete"
  [ "$(sha_file "$proof")" = "$expected_proof" ] || die "tribunal proof digest mismatch"
  validate_arbitration "$arbitration" "$manifest" || die "retained arbitration is invalid"
  jq -e --arg schema "$SCHEMA_PROOF" --arg manifest_sha "$manifest_sha" \
    --arg arbitration_sha "$(sha_file "$arbitration")" \
    --argjson pr "$(jq -r .pull_request.number "$manifest")" \
    --arg head "$(jq -r .pull_request.head_oid "$manifest")" \
    --arg body "$(jq -r .pull_request.body.sha256 "$manifest")" \
    --arg diff "$(jq -r .diff.sha256 "$manifest")" \
    --arg decision "$(jq -r .tribunal_verdict.decision "$arbitration")" \
    --argjson confidence "$(jq -r .tribunal_verdict.confidence "$arbitration")" \
    --argjson critical "$(jq '[.findings[]|select(.severity=="critical")]|length' "$arbitration")" \
    --argjson high "$(jq '[.findings[]|select(.severity=="high")]|length' "$arbitration")" '
      (type=="object") and ((keys-["schema","finalized_at","manifest_sha256","pull_request","arbitration"]|length)==0)
      and .schema==$schema
      and (.finalized_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and .manifest_sha256==$manifest_sha
      and .pull_request=={number:$pr,head_oid:$head,body_sha256:$body,diff_sha256:$diff}
      and .arbitration=={path:"arbitration.json",sha256:$arbitration_sha,decision:$decision,
        confidence:$confidence,critical_count:$critical,high_count:$high}
    ' "$proof" >/dev/null || die "tribunal proof schema or binding is invalid"
}

idempotent_finalize_result() {
  local dir="$1" manifest_sha="$2" canonical="$3" expected_proof
  [ -f "$dir/arbitration.json" ] && [ ! -L "$dir/arbitration.json" ] \
    && [ -f "$dir/proof.json" ] && [ ! -L "$dir/proof.json" ] \
    || die "retained tribunal proof is incomplete"
  cmp -s "$canonical" "$dir/arbitration.json" || die "conflicting arbitration for finalized collection"
  expected_proof="$(sha_file "$dir/proof.json")"
  verify_proof_internal "$dir" "$manifest_sha" "$expected_proof"
  rm -f "$canonical"; FINAL_TMP1=""
  proof_result "$dir" "$manifest_sha"
}

finalize() {
  parse_collection_args "$@"
  local dir manifest canonical retained_tmp proof_tmp lock_fd
  verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST"
  dir="$VERIFIED_COLLECTION"
  [ -n "$ARBITRATION" ] || die "finalize requires --arbitration"
  [ -f "$ARBITRATION" ] && [ ! -L "$ARBITRATION" ] || die "arbitration file missing or symbolic"
  manifest="$dir/manifest.json"
  validate_arbitration "$ARBITRATION" "$manifest" || die "arbitration schema or provider status is invalid"
  canonical="$(mktemp "${TMPDIR:-/tmp}/tribunal-arbitration.XXXXXX")"; FINAL_TMP1="$canonical"
  jq -S . "$ARBITRATION" > "$canonical"
  validate_arbitration "$canonical" "$manifest" || die "canonical arbitration validation failed"

  if [ -e "$dir/proof.json" ]; then
    idempotent_finalize_result "$dir" "$EXPECTED_MANIFEST" "$canonical"
    return
  fi
  [ ! -e "$dir/arbitration.json" ] || cmp -s "$canonical" "$dir/arbitration.json" \
    || die "conflicting arbitration retained after interrupted finalization"

  exec {lock_fd}> "$dir/.finalize.lock"
  if ! flock -n "$lock_fd"; then
    if [ -f "$dir/proof.json" ] && [ -f "$dir/arbitration.json" ]; then
      idempotent_finalize_result "$dir" "$EXPECTED_MANIFEST" "$canonical"
      return
    fi
    die "collection finalization is already in progress"
  fi
  if [ -e "$dir/proof.json" ]; then
    idempotent_finalize_result "$dir" "$EXPECTED_MANIFEST" "$canonical"
    return
  fi
  if [ -e "$dir/arbitration.json" ]; then
    cmp -s "$canonical" "$dir/arbitration.json" \
      || die "conflicting arbitration retained after interrupted finalization"
  else
    retained_tmp="$dir/.arbitration.$$.tmp"; FINAL_TMP2="$retained_tmp"
    cp "$canonical" "$retained_tmp"
    chmod 0444 "$retained_tmp"
    mv "$retained_tmp" "$dir/arbitration.json"; FINAL_TMP2=""
  fi
  rm -f "$canonical"; FINAL_TMP1=""

  proof_tmp="$dir/.proof.$$.tmp"; FINAL_TMP2="$proof_tmp"
  write_proof "$manifest" "$EXPECTED_MANIFEST" "$dir/arbitration.json" "$proof_tmp"
  chmod 0444 "$proof_tmp"
  mv "$proof_tmp" "$dir/proof.json"; FINAL_TMP2=""
  verify_proof_internal "$dir" "$EXPECTED_MANIFEST" "$(sha_file "$dir/proof.json")"
  chmod 0555 "$dir/providers" "$dir"
  proof_result "$dir" "$EXPECTED_MANIFEST"
}

verify_collection_cmd() {
  parse_collection_args "$@"
  [ -z "$ARBITRATION" ] && [ -z "$EXPECTED_PROOF" ] || die "unexpected verify-collection argument"
  local dir
  verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST"
  dir="$VERIFIED_COLLECTION"
  jq -nc --arg collection "$dir" --arg manifest_sha256 "$EXPECTED_MANIFEST" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,status:"valid"}'
}

verify_proof_cmd() {
  parse_collection_args "$@"
  [ -n "$EXPECTED_PROOF" ] || die "verify-proof requires --expected-proof-sha256"
  case "$EXPECTED_PROOF" in *[!0-9a-f]*|'') die "invalid expected proof digest" ;; esac
  [ "${#EXPECTED_PROOF}" -eq 64 ] || die "invalid expected proof digest"
  local dir
  verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST"
  dir="$VERIFIED_COLLECTION"
  verify_proof_internal "$dir" "$EXPECTED_MANIFEST" "$EXPECTED_PROOF"
  jq -nc --arg collection "$dir" --arg proof_sha256 "$EXPECTED_PROOF" \
    '{collection:$collection,proof_sha256:$proof_sha256,status:"valid"}'
}
