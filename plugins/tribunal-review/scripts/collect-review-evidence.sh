#!/usr/bin/env bash
# Collect and seal merge-gate tribunal evidence. Provider output is advisory;
# this runner owns provider identity, repository/PR binding, and artifact hashes.
set -euo pipefail
umask 077
export LC_ALL=C
unset BASH_ENV ENV CDPATH GLOBIGNORE
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_SSH_COMMAND

for command_name in git gh jq sha256sum awk sed wc date mktemp chmod mkdir mv rm rmdir cat dirname basename tr pwd env bash printf timeout head cp cmp codex gemini opencode qwen grok claude; do
  unset -f "$command_name" 2>/dev/null || true
done
unset command_name

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
. "$SCRIPT_DIR/lib.sh"

SCHEMA_COLLECTION="tribunal-collection/v1"
SCHEMA_PROOF="tribunal-proof/v1"
PROVIDERS="codex gemini glm deepseek qwen grok claude"
STAGING=""
REVIEW_SOURCE=""
REVIEW_WORKTREES=()
FINAL_TMP1=""
FINAL_TMP2=""

die() { printf 'tribunal evidence: %s\n' "$*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha_file() { sha256sum -- "$1" | awk '{print $1}'; }
bytes_file() { wc -c < "$1" | tr -d ' '; }

cleanup() {
  local review_worktree
  if [ -n "$REVIEW_SOURCE" ]; then
    for review_worktree in "${REVIEW_WORKTREES[@]}"; do
      [ ! -d "$review_worktree" ] || git -C "$REVIEW_SOURCE" worktree remove --force "$review_worktree" >/dev/null 2>&1 || true
    done
  fi
  [ -z "$STAGING" ] || [ ! -e "$STAGING" ] || rm -rf -- "$STAGING"
  [ -z "$FINAL_TMP1" ] || [ ! -e "$FINAL_TMP1" ] || rm -f -- "$FINAL_TMP1"
  [ -z "$FINAL_TMP2" ] || [ ! -e "$FINAL_TMP2" ] || rm -f -- "$FINAL_TMP2"
}
trap cleanup EXIT HUP INT TERM

require_tools() {
  local tool
  for tool in git gh jq sha256sum awk sed wc date mktemp chmod cmp flock; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
  done
}

real_dir() {
  [ -d "$1" ] || die "directory not found: $1"
  (cd "$1" && pwd -P)
}

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

validate_provider() {
  local provider="$1" file="$2"
  jq -e --arg p "$provider" '
    def exact($allowed; $required):
      (type == "object") and ((keys - $allowed) | length == 0)
      and (($required - keys) | length == 0);
    def text: type == "string" and length > 0;
    def uint: type == "number" and . >= 0 and . == floor;
    def confidence: type == "number" and . >= 0 and . <= 1;
    def finding:
      exact(["severity","category","file","line","title","description","suggestion","confidence","line_check"];
            ["severity","category","file","line","title","description","suggestion","confidence"])
      and (.severity | IN("critical","high","medium","low"))
      and (.category | IN("logic","security","performance","quality","edge-case","architecture","testing"))
      and (.file | text and startswith("/") | not)
      and (.file | contains("../") | not)
      and (.line | type == "number" and . >= 1 and . == floor)
      and (.title | text) and (.description | text) and (.suggestion | text)
      and (.confidence | confidence)
      and ((has("line_check") | not) or (.line_check | text));
    def summary($fs):
      exact(["total_findings","critical","high","medium","low","quality_score","verdict","note"];
            ["total_findings","critical","high","medium","low","quality_score","verdict"])
      and (.total_findings | uint) and (.critical | uint) and (.high | uint)
      and (.medium | uint) and (.low | uint)
      and (.quality_score | type == "number" and . >= 0 and . <= 10)
      and (.verdict | IN("APPROVE","NEEDS_WORK","BLOCK"))
      and ((has("note") | not) or (.note | type == "string"))
      and .total_findings == ($fs | length)
      and .critical == ([$fs[] | select(.severity == "critical")] | length)
      and .high == ([$fs[] | select(.severity == "high")] | length)
      and .medium == ([$fs[] | select(.severity == "medium")] | length)
      and .low == ([$fs[] | select(.severity == "low")] | length)
      and ((.total_findings > 0) or (.verdict == "APPROVE"));
    .provider == $p and (
      (exact(["provider","status","note"];["provider","status","note"])
       and .status == "disabled" and (.note | text))
      or
      (exact(["provider","error"];["provider","error"])
       and (.error | text))
      or
      (exact(["provider","model","findings","summary"];
             ["provider","model","findings","summary"])
       and (.model | text) and (.findings | type == "array" and all(.[]; finding))
       and (.findings as $findings | .summary | summary($findings)))
    )
  ' "$file" >/dev/null
}

provider_status() {
  jq -r 'if .status == "disabled" then "disabled" elif has("error") then "failed" else "ok" end' "$1"
}

write_failed_provider() {
  local provider="$1" message="$2" out="$3"
  jq -S -n --arg p "$provider" --arg e "$message" '{provider:$p,error:$e}' > "$out"
}

run_wrapper() {
  local name="$1" script="$2" worktree="$3" base_oid="$4" dir="$5"
  printf '%s\n' "$(now)" > "$dir/$name.started"
  set +e
  (cd "$worktree" && ulimit -f 65536 && TRIBUNAL_BASE_REF="$base_oid" bash "$script") \
    > "$dir/$name.raw" 2> "$dir/$name.stderr"
  printf '%s\n' "$?" > "$dir/$name.exit"
  set -e
  printf '%s\n' "$(now)" > "$dir/$name.finished"
}

normalize_single() {
  local provider="$1" raw="$2" rc="$3" out="$4" count
  if [ "$rc" -ne 0 ]; then
    write_failed_provider "$provider" "provider wrapper exited $rc" "$out"
    return
  fi
  count="$(jq -s 'length' "$raw" 2>/dev/null || printf 0)"
  if [ "$count" != 1 ]; then
    write_failed_provider "$provider" "provider wrapper emitted malformed JSON" "$out"
    return
  fi
  jq -S -s --arg p "$provider" '.[0] | .provider = $p' "$raw" > "$out.tmp" 2>/dev/null \
    || { rm -f "$out.tmp"; write_failed_provider "$provider" "provider wrapper emitted malformed JSON" "$out"; return; }
  if validate_provider "$provider" "$out.tmp"; then
    mv "$out.tmp" "$out"
  else
    rm -f "$out.tmp"
    write_failed_provider "$provider" "provider wrapper output failed schema validation" "$out"
  fi
}

normalize_opencode() {
  local raw="$1" rc="$2" dir="$3" provider count candidate
  for provider in glm deepseek; do
    if [ "$rc" -ne 0 ]; then
      write_failed_provider "$provider" "provider wrapper exited $rc" "$dir/providers/$provider.json"
      continue
    fi
    count="$(jq -s --arg p "$provider" '[.[] | select(.provider == $p)] | length' "$raw" 2>/dev/null || printf 0)"
    if [ "$count" != 1 ]; then
      write_failed_provider "$provider" "OpenCode wrapper omitted or duplicated provider leg" "$dir/providers/$provider.json"
      continue
    fi
    candidate="$dir/providers/$provider.tmp"
    jq -S -s --arg p "$provider" '[.[] | select(.provider == $p)][0] | .provider = $p' "$raw" > "$candidate"
    if validate_provider "$provider" "$candidate"; then
      mv "$candidate" "$dir/providers/$provider.json"
    else
      rm -f "$candidate"
      write_failed_provider "$provider" "provider wrapper output failed schema validation" "$dir/providers/$provider.json"
    fi
  done
}

wrapper_for_provider() {
  case "$1" in
    codex) printf '%s/run-codex-review.sh\n' "$SCRIPT_DIR" ;;
    gemini) printf '%s/run-gemini-review.sh\n' "$SCRIPT_DIR" ;;
    glm|deepseek) printf '%s/run-opencode-review.sh\n' "$SCRIPT_DIR" ;;
    qwen) printf '%s/run-qwen-review.sh\n' "$SCRIPT_DIR" ;;
    grok) printf '%s/run-grok-review.sh\n' "$SCRIPT_DIR" ;;
    claude) printf '%s/run-claude-review.sh\n' "$SCRIPT_DIR" ;;
    *) die "unknown provider: $1" ;;
  esac
}

collect() {
  local root="" pr="" output="" started binding head_oid base_oid parent review_tmp bundle
  local wrapper name rc provider status artifact stderr wrapper_name providers_json
  local codex_worktree gemini_worktree opencode_worktree qwen_worktree grok_worktree claude_worktree review_worktree
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo-root) [ "$#" -ge 2 ] || die "--repo-root needs a value"; root="$2"; shift 2 ;;
      --pr) [ "$#" -ge 2 ] || die "--pr needs a value"; pr="$2"; shift 2 ;;
      --output) [ "$#" -ge 2 ] || die "--output needs a value"; output="$2"; shift 2 ;;
      *) die "unknown collect argument: $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$pr" ] && [ -n "$output" ] || die "collect requires --repo-root, --pr, and --output"
  case "$pr" in ''|*[!0-9]*|0) die "invalid PR number" ;; esac
  root="$(real_dir "$root")"
  [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$root" ] || die "--repo-root is not a Git worktree root"
  case "$output" in /*) ;; *) die "--output must be absolute" ;; esac
  [ ! -e "$output" ] && [ ! -L "$output" ] || die "collection output already exists"
  parent="$(dirname "$output")"; parent="$(real_dir "$parent")"
  case "$(basename "$output")" in .|..) die "invalid collection output name" ;; esac
  output="$parent/$(basename "$output")"
  [ ! -e "$output" ] && [ ! -L "$output" ] || die "collection output already exists"
  bundle="$(bash "$SCRIPT_DIR/check-runner-bundle.sh")" || die "installed tribunal runner bundle failed integrity validation"
  started="$(now)"
  binding="$(live_binding "$root" "$pr")"
  head_oid="$(printf '%s' "$binding" | jq -r .pull_request.headRefOid)"
  base_oid="$(printf '%s' "$binding" | jq -r .pull_request.baseRefOid)"
  [ "$(git -C "$root" rev-parse HEAD)" = "$head_oid" ] || die "worktree HEAD differs from PR head"
  git -C "$root" cat-file -e "$base_oid^{commit}" 2>/dev/null || die "PR base commit is not available locally"
  git -C "$root" cat-file -e "$head_oid^{commit}" 2>/dev/null || die "PR head commit is not available locally"

  STAGING="$(mktemp -d "$parent/.tribunal-collection.XXXXXX")"
  mkdir -p "$STAGING/providers" "$STAGING/wrappers"
  printf '%s' "$binding" | jq -j .pull_request.body > "$STAGING/pr-body.txt"
  git -C "$root" diff --binary --no-ext-diff --no-textconv "$base_oid...$head_oid" > "$STAGING/review.diff"
  [ -s "$STAGING/review.diff" ] || die "PR has no diff"

  REVIEW_SOURCE="$root"; REVIEW_WORKTREES=()
  for name in codex gemini opencode qwen grok claude; do
    review_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tribunal-$name.XXXXXX")"; rmdir "$review_tmp"
    git -C "$root" worktree add --detach --quiet "$review_tmp" "$head_oid"
    REVIEW_WORKTREES+=("$review_tmp")
    case "$name" in
      codex) codex_worktree="$review_tmp" ;;
      gemini) gemini_worktree="$review_tmp" ;;
      opencode) opencode_worktree="$review_tmp" ;;
      qwen) qwen_worktree="$review_tmp" ;;
      grok) grok_worktree="$review_tmp" ;;
      claude) claude_worktree="$review_tmp" ;;
    esac
  done

  run_wrapper codex "$SCRIPT_DIR/run-codex-review.sh" "$codex_worktree" "$base_oid" "$STAGING/wrappers" &
  run_wrapper gemini "$SCRIPT_DIR/run-gemini-review.sh" "$gemini_worktree" "$base_oid" "$STAGING/wrappers" &
  run_wrapper opencode "$SCRIPT_DIR/run-opencode-review.sh" "$opencode_worktree" "$base_oid" "$STAGING/wrappers" &
  run_wrapper qwen "$SCRIPT_DIR/run-qwen-review.sh" "$qwen_worktree" "$base_oid" "$STAGING/wrappers" &
  run_wrapper grok "$SCRIPT_DIR/run-grok-review.sh" "$grok_worktree" "$base_oid" "$STAGING/wrappers" &
  run_wrapper claude "$SCRIPT_DIR/run-claude-review.sh" "$claude_worktree" "$base_oid" "$STAGING/wrappers" &
  wait

  for review_worktree in "${REVIEW_WORKTREES[@]}"; do
    [ "$(git -C "$review_worktree" rev-parse HEAD)" = "$head_oid" ] || die "provider changed review HEAD"
    [ -z "$(git -C "$review_worktree" status --porcelain --untracked-files=all)" ] \
      || die "provider changed its sealed review worktree"
  done

  for name in codex gemini qwen grok claude; do
    rc="$(cat "$STAGING/wrappers/$name.exit")"
    normalize_single "$name" "$STAGING/wrappers/$name.raw" "$rc" "$STAGING/providers/$name.json"
  done
  rc="$(cat "$STAGING/wrappers/opencode.exit")"
  normalize_opencode "$STAGING/wrappers/opencode.raw" "$rc" "$STAGING"

  providers_json="$STAGING/providers.jsonl"; : > "$providers_json"
  for provider in $PROVIDERS; do
    artifact="$STAGING/providers/$provider.json"
    validate_provider "$provider" "$artifact" || die "internal provider normalization failed: $provider"
    wrapper="$(wrapper_for_provider "$provider")"; wrapper_name="$(basename "$wrapper" .sh)"
    [ "$provider" = glm ] || [ "$provider" = deepseek ] || wrapper_name="${wrapper_name#run-}"
    case "$provider" in glm|deepseek) name=opencode ;; *) name="$provider" ;; esac
    status="$(provider_status "$artifact")"
    stderr="$STAGING/wrappers/$name.stderr"
    jq -nc --arg provider "$provider" --arg status "$status" \
      --arg wrapper_path "$wrapper" --arg wrapper_sha256 "$(sha_file "$wrapper")" \
      --arg artifact_path "providers/$provider.json" --arg artifact_sha256 "$(sha_file "$artifact")" \
      --argjson artifact_bytes "$(bytes_file "$artifact")" \
      --arg started_at "$(cat "$STAGING/wrappers/$name.started")" \
      --arg finished_at "$(cat "$STAGING/wrappers/$name.finished")" \
      --argjson exit_code "$(cat "$STAGING/wrappers/$name.exit")" \
      --arg stderr_sha256 "$(sha_file "$stderr")" --argjson stderr_bytes "$(bytes_file "$stderr")" \
      '{provider:$provider,status:$status,wrapper:{path:$wrapper_path,sha256:$wrapper_sha256},
        artifact:{path:$artifact_path,sha256:$artifact_sha256,bytes:$artifact_bytes},
        started_at:$started_at,finished_at:$finished_at,exit_code:$exit_code,
        stderr:{sha256:$stderr_sha256,bytes:$stderr_bytes}}' >> "$providers_json"
  done

  rm -rf "$STAGING/wrappers"
  for review_worktree in "${REVIEW_WORKTREES[@]}"; do
    git -C "$root" worktree remove --force "$review_worktree" >/dev/null
  done
  REVIEW_WORKTREES=(); REVIEW_SOURCE=""
  jq -S -n --arg schema "$SCHEMA_COLLECTION" --arg started_at "$started" \
    --arg completed_at "$(now)" --argjson binding "$binding" \
    --arg body_sha256 "$(sha_file "$STAGING/pr-body.txt")" \
    --argjson body_bytes "$(bytes_file "$STAGING/pr-body.txt")" \
    --arg diff_sha256 "$(sha_file "$STAGING/review.diff")" \
    --argjson diff_bytes "$(bytes_file "$STAGING/review.diff")" \
    --arg runner_path "$SCRIPT_DIR/collect-review-evidence.sh" \
    --arg runner_sha256 "$(sha_file "$SCRIPT_DIR/collect-review-evidence.sh")" \
    --arg library_path "$SCRIPT_DIR/lib.sh" --arg library_sha256 "$(sha_file "$SCRIPT_DIR/lib.sh")" \
    --arg bundle_manifest_path "$PLUGIN_ROOT/integrity/runner-bundle.json" \
    --arg bundle_manifest_sha256 "$(printf '%s' "$bundle" | jq -r .sha256)" \
    --slurpfile providers "$providers_json" \
    '{schema:$schema,started_at:$started_at,completed_at:$completed_at,
      repository:$binding.repository,
      pull_request:{number:$binding.pull_request.number,url:$binding.pull_request.url,state:$binding.pull_request.state,
        base_ref:$binding.pull_request.baseRefName,base_oid:$binding.pull_request.baseRefOid,
        head_ref:$binding.pull_request.headRefName,head_oid:$binding.pull_request.headRefOid,
        body:{path:"pr-body.txt",sha256:$body_sha256,bytes:$body_bytes}},
      diff:{path:"review.diff",sha256:$diff_sha256,bytes:$diff_bytes},
      runner:{path:$runner_path,sha256:$runner_sha256,library_path:$library_path,library_sha256:$library_sha256,
        bundle_manifest_path:$bundle_manifest_path,bundle_manifest_sha256:$bundle_manifest_sha256},
      providers:$providers}' > "$STAGING/manifest.json"
  rm -f "$providers_json"
  chmod 0444 "$STAGING/manifest.json" "$STAGING/pr-body.txt" "$STAGING/review.diff" "$STAGING/providers/"*.json
  mv -T -- "$STAGING" "$output" 2>/dev/null \
    || die "collection output appeared concurrently"
  STAGING=""
  jq -nc --arg collection "$output" --arg manifest_sha256 "$(sha_file "$output/manifest.json")" \
    --arg runner_bundle_sha256 "$(printf '%s' "$bundle" | jq -r .sha256)" \
    --arg head_oid "$head_oid" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,
      runner_bundle_sha256:$runner_bundle_sha256,head_oid:$head_oid}'
}

validate_manifest_shape() {
  local manifest="$1"
  jq -e --arg schema "$SCHEMA_COLLECTION" '
    def exact($a;$r): (type=="object") and ((keys-$a)|length==0) and (($r-keys)|length==0);
    def text: type=="string" and length>0;
    def sha: type=="string" and test("^[0-9a-f]{64}$");
    def oid: type=="string" and test("^[0-9a-f]{40}$");
    def uint: type=="number" and .>=0 and .==floor;
    def stamp: type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    exact(["schema","started_at","completed_at","repository","pull_request","diff","runner","providers"];
          ["schema","started_at","completed_at","repository","pull_request","diff","runner","providers"])
    and .schema==$schema and (.started_at|stamp) and (.completed_at|stamp) and .started_at<=.completed_at
    and (.repository | exact(["root","host","name_with_owner","url"];
                             ["root","host","name_with_owner","url"])
         and (.root|text and startswith("/")) and (.host|test("^[A-Za-z0-9.-]+$"))
         and (.name_with_owner|test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
         and (.url|test("^https://")))
    and (.pull_request | exact(["number","url","state","base_ref","base_oid","head_ref","head_oid","body"];
                               ["number","url","state","base_ref","base_oid","head_ref","head_oid","body"])
         and (.number|uint and .>0) and (.url|test("^https://")) and .state=="OPEN" and (.base_ref|text)
         and (.base_oid|oid) and (.head_ref|text) and (.head_oid|oid)
         and (.body|exact(["path","sha256","bytes"];["path","sha256","bytes"])
              and .path=="pr-body.txt" and (.sha256|sha) and (.bytes|uint)))
    and (.diff | exact(["path","sha256","bytes"];["path","sha256","bytes"])
         and .path=="review.diff" and (.sha256|sha) and (.bytes|uint and .>0))
    and (.runner | exact(["path","sha256","library_path","library_sha256","bundle_manifest_path","bundle_manifest_sha256"];
                         ["path","sha256","library_path","library_sha256","bundle_manifest_path","bundle_manifest_sha256"])
         and (.path|text and startswith("/")) and (.sha256|sha)
         and (.library_path|text and startswith("/")) and (.library_sha256|sha)
         and (.bundle_manifest_path|text and startswith("/")) and (.bundle_manifest_sha256|sha))
    and (.providers|type=="array" and length==7
         and ([.[].provider]|sort)==(["claude","codex","deepseek","gemini","glm","grok","qwen"])
         and all(.[];
           exact(["provider","status","wrapper","artifact","started_at","finished_at","exit_code","stderr"];
                 ["provider","status","wrapper","artifact","started_at","finished_at","exit_code","stderr"])
           and (.provider|IN("codex","gemini","glm","deepseek","qwen","grok","claude"))
           and (.status|IN("ok","failed","disabled"))
           and (.wrapper|exact(["path","sha256"];["path","sha256"])
                and (.path|text and startswith("/")) and (.sha256|sha))
           and (.artifact|exact(["path","sha256","bytes"];["path","sha256","bytes"])
                and (.path|test("^providers/[a-z]+\\.json$")) and (.sha256|sha) and (.bytes|uint and .>0))
           and (.started_at|stamp) and (.finished_at|stamp) and .started_at<=.finished_at and (.exit_code|uint)
           and (.stderr|exact(["sha256","bytes"];["sha256","bytes"])
                and (.sha256|sha) and (.bytes|uint))))
  ' "$manifest" >/dev/null
}

verify_live_binding() {
  local dir="$1" manifest="$2" root pr current expected body_tmp diff_tmp
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
  local dir="$1" expected_sha="$2" manifest provider path status wrapper
  [ ! -L "$dir" ] || die "collection directory must not be symbolic"
  dir="$(real_dir "$dir")"; manifest="$dir/manifest.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || die "collection manifest missing or symbolic"
  [ -d "$dir/providers" ] && [ ! -L "$dir/providers" ] || die "provider artifact directory missing or symbolic"
  [ -f "$dir/pr-body.txt" ] && [ ! -L "$dir/pr-body.txt" ] || die "retained PR body missing or symbolic"
  [ -f "$dir/review.diff" ] && [ ! -L "$dir/review.diff" ] || die "retained diff missing or symbolic"
  [ "$expected_sha" = "$(sha_file "$manifest")" ] || die "collection manifest digest mismatch"
  validate_manifest_shape "$manifest" || die "collection manifest schema invalid"
  [ "$(jq -r .runner.path "$manifest")" = "$SCRIPT_DIR/collect-review-evidence.sh" ] \
    || die "collection runner path differs from installed runner"
  [ "$(jq -r .runner.sha256 "$manifest")" = "$(sha_file "$SCRIPT_DIR/collect-review-evidence.sh")" ] \
    || die "collection runner digest differs from installed runner"
  [ "$(jq -r .runner.library_path "$manifest")" = "$SCRIPT_DIR/lib.sh" ] \
    || die "collection library path differs from installed library"
  [ "$(jq -r .runner.library_sha256 "$manifest")" = "$(sha_file "$SCRIPT_DIR/lib.sh")" ] \
    || die "collection library digest differs from installed library"
  [ "$(jq -r .runner.bundle_manifest_path "$manifest")" = "$PLUGIN_ROOT/integrity/runner-bundle.json" ] \
    || die "collection runner bundle manifest path differs from installed bundle"
  [ "$(jq -r .runner.bundle_manifest_sha256 "$manifest")" = "$(sha_file "$PLUGIN_ROOT/integrity/runner-bundle.json")" ] \
    || die "collection runner bundle manifest digest differs from installed bundle"
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
  printf '%s\n' "$dir"
}

validate_arbitration() {
  local arbitration="$1" manifest="$2" statuses dir evidence
  statuses="$(jq -c '[.providers[]|{key:.provider,value:.status}]|from_entries' "$manifest")"
  dir="$(dirname "$manifest")"
  evidence="$(jq -nc \
    --slurpfile codex "$dir/providers/codex.json" --slurpfile gemini "$dir/providers/gemini.json" \
    --slurpfile glm "$dir/providers/glm.json" --slurpfile deepseek "$dir/providers/deepseek.json" \
    --slurpfile qwen "$dir/providers/qwen.json" --slurpfile grok "$dir/providers/grok.json" \
    --slurpfile claude "$dir/providers/claude.json" \
    '{codex:$codex[0],gemini:$gemini[0],glm:$glm[0],deepseek:$deepseek[0],qwen:$qwen[0],grok:$grok[0],claude:$claude[0]}')"
  jq -e --argjson statuses "$statuses" --argjson evidence "$evidence" '
    def exact($a;$r): (type=="object") and ((keys-$a)|length==0) and (($r-keys)|length==0);
    def text: type=="string" and length>0;
    def uint: type=="number" and .>=0 and .==floor;
    def conf: type=="number" and .>=0 and .<=1;
    def finding:
      exact(["id","consensus","providers","severity","category","file","line","title","description","suggestion","confidence","blocking_proof","arbiter_notes"];
            ["id","consensus","providers","severity","category","file","line","title","description","suggestion","confidence","arbiter_notes"])
      and (.id|test("^T-[0-9]{3,}$")) and (.consensus|IN("CONSENSUS","SINGLE_PROVIDER"))
      and (. as $finding | .providers|type=="array" and length>0 and length==([.[]]|unique|length)
           and all(.[]; . as $p
             | IN("codex","gemini","glm","deepseek","qwen","grok","claude") and $statuses[$p] == "ok"
             and (($evidence[$p].findings // []) | any(.[]; .file == $finding.file))))
      and ((.providers|length)>=2) == (.consensus=="CONSENSUS")
      and (.severity|IN("critical","high","medium","low"))
      and (.category|IN("logic","security","performance","quality","edge-case","architecture","testing"))
      and (.file|text and startswith("/")|not) and (.file|contains("../")|not)
      and (.line|type=="number" and .>=1 and .==floor)
      and (.title|text) and (.description|text) and (.suggestion|text) and (.confidence|conf)
      and (.arbiter_notes|type=="string")
      and (if (.severity|IN("critical","high")) then
        (.blocking_proof|exact(["reachable_path","material_impact","caused_by_change"];
                               ["reachable_path","material_impact","caused_by_change"])
         and all(.[];text))
        else (has("blocking_proof")|not) or
          (.blocking_proof|exact(["reachable_path","material_impact","caused_by_change"];
                                 ["reachable_path","material_impact","caused_by_change"])
           and all(.[];text)) end);
    def scope:
      exact(["id","path","why_out_of_scope","disposition","conflicting_task_text","smallest_acceptable_diff"];
            ["id","path","why_out_of_scope","disposition","conflicting_task_text","smallest_acceptable_diff"])
      and (.id|test("^S-[0-9]{3,}$")) and (.path|text)
      and (.why_out_of_scope|text) and (.disposition|IN("must-remove-before-merge","follow-up-only"))
      and (.conflicting_task_text|type=="string") and (.smallest_acceptable_diff|text);
    def assessment($p;$final):
      exact(["findings_accepted","findings_rejected","false_positives","status"];
            ["findings_accepted","findings_rejected","false_positives","status"])
      and (.findings_accepted|uint) and (.findings_rejected|uint)
      and (.false_positives|type=="array" and all(.[];type=="string"))
      and .status==$statuses[$p]
      and .findings_accepted == ([$final[] | select(.providers | index($p))] | length)
      and (.findings_accepted + .findings_rejected) <= (($evidence[$p].findings // []) | length)
      and (.false_positives | length) <= .findings_rejected;
    exact(["tribunal_verdict","findings","scope_findings","provider_assessment","conflicts_resolved","summary"];
          ["tribunal_verdict","findings","scope_findings","provider_assessment","conflicts_resolved","summary"])
    and (.tribunal_verdict|exact(["decision","confidence","rationale"];
                                ["decision","confidence","rationale"])
         and (.decision|IN("APPROVE","NEEDS_WORK","BLOCK")) and (.confidence|conf) and (.rationale|text))
    and (.findings|type=="array" and all(.[];finding) and ([.[].id]|length)==([.[].id]|unique|length))
    and (.scope_findings|type=="array" and all(.[];scope) and ([.[].id]|length)==([.[].id]|unique|length))
    and (.findings as $final_findings | .provider_assessment
         | exact(["codex","gemini","glm","deepseek","qwen","grok","claude"];
                 ["codex","gemini","glm","deepseek","qwen","grok","claude"])
         and (.codex|assessment("codex";$final_findings))
         and (.gemini|assessment("gemini";$final_findings))
         and (.glm|assessment("glm";$final_findings)) and (.deepseek|assessment("deepseek";$final_findings))
         and (.qwen|assessment("qwen";$final_findings)) and (.grok|assessment("grok";$final_findings))
         and (.claude|assessment("claude";$final_findings)))
    and (.conflicts_resolved|type=="array" and all(.[];type=="string")) and (.summary|text)
    and (if .tribunal_verdict.decision=="APPROVE" then
      ([.findings[]|select(.severity=="critical" or .severity=="high")]|length)==0
      and ([.scope_findings[]|select(.disposition=="must-remove-before-merge")]|length)==0
      else true end)
    and (if ([$statuses[]|select(.=="ok")]|length)==0
      then .tribunal_verdict.decision=="NEEDS_WORK" and .tribunal_verdict.confidence==0 else true end)
    and (if ([$statuses[]|select(.=="ok")]|length)>0
            and ([$evidence[]|(.findings // [])[]]|length)==0
            and ([.scope_findings[]|select(.disposition=="must-remove-before-merge")]|length)==0
      then .tribunal_verdict.decision=="APPROVE" and .tribunal_verdict.confidence==0.95 else true end)
  ' "$arbitration" >/dev/null
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
  [ -n "$ARBITRATION" ] || die "finalize requires --arbitration"
  [ -f "$ARBITRATION" ] && [ ! -L "$ARBITRATION" ] || die "arbitration file missing or symbolic"
  local dir manifest canonical retained_tmp proof_tmp lock_fd
  dir="$(verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST")"
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
  dir="$(verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST")"
  jq -nc --arg collection "$dir" --arg manifest_sha256 "$EXPECTED_MANIFEST" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,status:"valid"}'
}

verify_proof_cmd() {
  parse_collection_args "$@"
  [ -n "$EXPECTED_PROOF" ] || die "verify-proof requires --expected-proof-sha256"
  case "$EXPECTED_PROOF" in *[!0-9a-f]*|'') die "invalid expected proof digest" ;; esac
  [ "${#EXPECTED_PROOF}" -eq 64 ] || die "invalid expected proof digest"
  local dir
  dir="$(verify_collection_internal "$COLLECTION" "$EXPECTED_MANIFEST")"
  verify_proof_internal "$dir" "$EXPECTED_MANIFEST" "$EXPECTED_PROOF"
  jq -nc --arg collection "$dir" --arg proof_sha256 "$EXPECTED_PROOF" \
    '{collection:$collection,proof_sha256:$proof_sha256,status:"valid"}'
}

usage() {
  cat >&2 <<'EOF'
Usage:
  collect-review-evidence.sh collect --repo-root ROOT --pr N --output ABS_DIR
  collect-review-evidence.sh verify-collection --collection DIR --expected-manifest-sha256 SHA
  collect-review-evidence.sh finalize --collection DIR --expected-manifest-sha256 SHA --arbitration FILE
  collect-review-evidence.sh verify-proof --collection DIR --expected-manifest-sha256 SHA --expected-proof-sha256 SHA
EOF
  exit 2
}

require_tools
command="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$command" in
  collect) collect "$@" ;;
  verify-collection) verify_collection_cmd "$@" ;;
  finalize) finalize "$@" ;;
  verify-proof) verify_proof_cmd "$@" ;;
  *) usage ;;
esac
