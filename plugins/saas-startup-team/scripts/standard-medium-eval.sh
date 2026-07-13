#!/usr/bin/env bash
# Local-only infrastructure for controlled Sol/medium standard-profile evaluation.
# Raw tasks, diffs, mappings, and tribunal findings remain local.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: standard-medium-eval.sh replay --base SHA --task-file FILE --sample-id ID [--repo-root DIR] [--corpus-dir DIR]" >&2
  echo "       standard-medium-eval.sh blind --sample-id ID --base-sha SHA --task-sha256 HASH --high-diff FILE --medium-diff FILE --out-dir DIR --mapping-out FILE" >&2
  echo "       standard-medium-eval.sh assess --pairs FILE --out FILE" >&2
  exit 2
}

safe_id() { [[ "$1" =~ ^sample-[0-9a-f]{16,32}$ ]]; }
safe_git_sha() { [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; }
safe_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
sha256_file() { sha256sum -- "$1" | awk '{print $1}'; }

replay_sample() {
  local base="" task_file="" sample_id="" repo_root="" corpus_dir=""
  local real_git codex_bin wt sample_dir safety_bin composite rc=1 check_rc=1 start end duration result
  local state_before state_after state_intact=true integrity_ok=true policy_verified=false policy_hash=""
  local task_hash diff_hash post_diff_hash check_hash check_mode ignore_ok=true probe_rc=1 probe_nonce probe_out probe_inside probe_outside
  local eval_private isolated_home original_codex_home disable_features="" feature
  local listener_pid="" listener_port_file listener_hit_file listener_port="" worker_tokens="null" worker_cost="null"
  local -a eval_env check_env
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ "$#" -ge 2 ] || usage; base="$2"; shift 2 ;;
      --task-file) [ "$#" -ge 2 ] || usage; task_file="$2"; shift 2 ;;
      --sample-id) [ "$#" -ge 2 ] || usage; sample_id="$2"; shift 2 ;;
      --repo-root) [ "$#" -ge 2 ] || usage; repo_root="$2"; shift 2 ;;
      --corpus-dir) [ "$#" -ge 2 ] || usage; corpus_dir="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$base" ] && [ -n "$task_file" ] && safe_id "$sample_id" || usage
  [ -n "$repo_root" ] || repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "standard-medium-eval: replay requires a git worktree" >&2; exit 2;
  }
  repo_root=$(cd "$repo_root" && pwd)
  [ -f "$task_file" ] && [ ! -L "$task_file" ] || {
    echo "standard-medium-eval: task file must be a regular local file" >&2; exit 2; }
  task_file=$(cd "$(dirname -- "$task_file")" && printf '%s/%s\n' "$PWD" "$(basename -- "$task_file")")
  real_git=$(command -v git)
  codex_bin=$(command -v codex 2>/dev/null) || {
    echo "standard-medium-eval: codex CLI is required" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
    echo "standard-medium-eval: jq and python3 are required" >&2; exit 2; }
  local exec_help sandbox_help features
  exec_help=$("$codex_bin" exec --help 2>/dev/null) || {
    echo "standard-medium-eval: could not inspect Codex exec capabilities" >&2; exit 2; }
  sandbox_help=$("$codex_bin" sandbox --help 2>/dev/null) || {
    echo "standard-medium-eval: Codex workspace sandbox support is required" >&2; exit 2; }
  grep -q -- '--strict-config' <<< "$exec_help" && grep -q -- '--disable' <<< "$exec_help" \
    && grep -q -- '--permission-profile' <<< "$sandbox_help" \
    && grep -q -- '--enable' <<< "$sandbox_help" || {
      echo "standard-medium-eval: required strict/sandbox Codex controls are unavailable" >&2; exit 2; }
  features=$("$codex_bin" features list 2>/dev/null) || {
    echo "standard-medium-eval: could not inspect Codex feature controls" >&2; exit 2; }
  for feature in apps enable_mcp_apps browser_use browser_use_external browser_use_full_cdp_access \
    in_app_browser computer_use plugins remote_plugin standalone_web_search hooks multi_agent; do
    if awk -v wanted="$feature" '$1 == wanted {found=1} END {exit !found}' <<< "$features"; then
      disable_features+="${disable_features:+,}$feature"
    fi
  done
  [ -n "$disable_features" ] || {
    echo "standard-medium-eval: no supported external-tool feature controls found" >&2; exit 2; }
  "$real_git" -C "$repo_root" rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 || {
    echo "standard-medium-eval: invalid base SHA" >&2; exit 2;
  }
  base=$("$real_git" -C "$repo_root" rev-parse "${base}^{commit}")
  [ -n "$corpus_dir" ] || corpus_dir="$repo_root/.startup/evaluation/standard-medium"
  sample_dir="$corpus_dir/samples/$sample_id"
  wt="$corpus_dir/worktrees/$sample_id"
  [ ! -e "$sample_dir" ] && [ ! -e "$wt" ] || {
    echo "standard-medium-eval: sample already exists: $sample_id" >&2; exit 2;
  }
  umask 077
  mkdir -p "$sample_dir" "$(dirname -- "$wt")"
  eval_private=$(mktemp -d "${TMPDIR:-/tmp}/saas-medium-eval.XXXXXX")
  isolated_home="$eval_private/home"
  mkdir -p "$isolated_home"
  original_codex_home=${CODEX_HOME:-${HOME:-/tmp}/.codex}

  cleanup_replay() {
    if [ -n "$listener_pid" ]; then
      kill "$listener_pid" >/dev/null 2>&1 || true
      wait "$listener_pid" 2>/dev/null || true
    fi
    if "$real_git" -C "$repo_root" worktree list --porcelain 2>/dev/null | grep -Fqx "worktree $wt"; then
      "$real_git" -C "$repo_root" worktree remove --force "$wt" >/dev/null 2>&1 || true
    fi
    [ -z "$probe_outside" ] || rm -f -- "$probe_outside"
    rm -rf -- "$eval_private"
  }
  trap cleanup_replay EXIT
  "$real_git" -C "$repo_root" worktree add --detach "$wt" "$base" >/dev/null

  repository_state() {
    local common_dir path corpus_real repo_real corpus_rel="" git_file
    repo_real=$(realpath -m -- "$repo_root")
    corpus_real=$(realpath -m -- "$corpus_dir")
    case "$corpus_real" in "$repo_real"/*) corpus_rel=${corpus_real#"$repo_real"/} ;; esac
    common_dir=$("$real_git" -C "$repo_root" rev-parse --git-common-dir)
    case "$common_dir" in /*) : ;; *) common_dir="$repo_root/$common_dir" ;; esac
    {
      "$real_git" -C "$repo_root" rev-parse HEAD
      "$real_git" -C "$repo_root" diff --binary HEAD --
      while IFS= read -r -d '' path; do
        if [ -n "$corpus_rel" ]; then
          case "$path" in "$corpus_rel"|"$corpus_rel"/*) continue ;; esac
        fi
        printf '%s\0' "$path"
        if [ -L "$repo_root/$path" ]; then
          readlink -- "$repo_root/$path"
        elif [ -f "$repo_root/$path" ]; then
          sha256sum -- "$repo_root/$path"
        fi
      done < <("$real_git" -C "$repo_root" ls-files --others --exclude-standard -z)
      "$real_git" -C "$repo_root" for-each-ref --format='%(refname) %(objectname)'
      "$real_git" -C "$repo_root" worktree list --porcelain
      for git_file in config info/exclude; do
        if [ -e "$common_dir/$git_file" ]; then sha256sum -- "$common_dir/$git_file"; else printf 'missing %s\n' "$git_file"; fi
      done
    } | sha256sum | awk '{print $1}'
  }

  ignore_files_intact() {
    local rel base_blob current_hash
    while IFS= read -r -d '' rel; do
      case "$rel" in .gitignore|*/.gitignore) : ;; *) continue ;; esac
      [ -f "$wt/$rel" ] && [ ! -L "$wt/$rel" ] || return 1
      base_blob=$("$real_git" -C "$repo_root" show "$base:$rel" | sha256sum | awk '{print $1}') || return 1
      current_hash=$(sha256_file "$wt/$rel")
      [ "$current_hash" = "$base_blob" ] || return 1
    done < <("$real_git" -C "$repo_root" ls-tree -r -z --name-only "$base")
    while IFS= read -r -d '' rel; do
      rel=${rel#"$wt"/}
      "$real_git" -C "$repo_root" cat-file -e "$base:$rel" 2>/dev/null || return 1
    done < <(find "$wt" -path "$wt/.git" -prune -o -type f -name .gitignore -print0)
  }

  check_mode=$("$real_git" -C "$repo_root" ls-tree "$base" -- check.sh | awk 'NR == 1 {print $1}')
  [ "$check_mode" = 100755 ] || {
    echo "standard-medium-eval: base check.sh must be a tracked executable regular file" >&2
    exit 2
  }
  "$real_git" -C "$repo_root" show "$base:check.sh" > "$sample_dir/base-check.sh"
  check_hash=$(sha256_file "$sample_dir/base-check.sh")
  chmod 500 "$sample_dir/base-check.sh"
  cp -- "$task_file" "$sample_dir/recorded-task.md"
  chmod 400 "$sample_dir/recorded-task.md"
  task_hash=$(sha256_file "$sample_dir/recorded-task.md")

  safety_bin="$sample_dir/safety-bin"
  mkdir -p "$safety_bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'args=("$@")' \
    'cmd=""; skip=0' \
    'for arg in "${args[@]}"; do' \
    '  if [ "$skip" -eq 1 ]; then skip=0; continue; fi' \
    '  case "$arg" in -C|-c|--git-dir|--work-tree) skip=1 ;; -*) ;; *) cmd="$arg"; break ;; esac' \
    'done' \
    'case "$cmd" in push|send-pack|commit|merge|rebase|tag) echo "evaluation safety: git $cmd blocked" >&2; exit 97 ;; esac' \
    'exec "$SAAS_EVAL_REAL_GIT" "$@"' > "$safety_bin/git"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [ "${1:-}" = exec ]; then' \
    '  shift; args=(exec --strict-config -c shell_environment_policy.inherit="core")' \
    '  IFS=, read -r -a disabled <<< "$SAAS_EVAL_DISABLE_FEATURES"' \
    '  for feature in "${disabled[@]}"; do args+=(--disable "$feature"); done' \
    '  exec "$SAAS_EVAL_REAL_CODEX" "${args[@]}" "$@"' \
    'fi' \
    'exec "$SAAS_EVAL_REAL_CODEX" "$@"' > "$safety_bin/codex"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "evaluation safety: external/remote command blocked: $(basename "$0")" >&2' \
    'exit 97' > "$safety_bin/block-remote"
  chmod +x "$safety_bin/git" "$safety_bin/codex" "$safety_bin/block-remote"
  local blocked
  for blocked in gh curl wget kubectl helm terraform flyctl vercel railway heroku aws gcloud az; do
    ln -s block-remote "$safety_bin/$blocked"
  done

  composite="$sample_dir/task.md"
  {
    printf '%s\n' 'LOCAL EVALUATION REPLAY. Work only in this detached worktree.'
    printf '%s\n' 'Do not use network tools, mutate remotes, open or edit PRs/issues, deploy, or access production.'
    printf '%s\n' 'Implement only the first attempt, run no checks, and leave changes uncommitted.'
    printf '\n================ RECORDED TASK ================\n'
    cat "$sample_dir/recorded-task.md"
  } > "$composite"
  chmod 400 "$composite"

  eval_env=(
    "PATH=$safety_bin:$PATH"
    "HOME=$isolated_home"
    "CODEX_HOME=$original_codex_home"
    "XDG_CONFIG_HOME=$eval_private/xdg-config"
    "XDG_DATA_HOME=$eval_private/xdg-data"
    "USER=${USER:-eval}"
    "TERM=${TERM:-dumb}"
    "SAAS_EVAL_REAL_GIT=$real_git"
    "SAAS_EVAL_REAL_CODEX=$codex_bin"
    "SAAS_EVAL_DISABLE_FEATURES=$disable_features"
  )
  [ -z "${FAKE_CODEX_CALLS:-}" ] || eval_env+=("FAKE_CODEX_CALLS=$FAKE_CODEX_CALLS")
  [ -z "${FAKE_CODEX_MODE:-}" ] || eval_env+=("FAKE_CODEX_MODE=$FAKE_CODEX_MODE")
  check_env=(
    "PATH=$safety_bin:$PATH"
    "HOME=$isolated_home"
    "USER=${USER:-eval}"
    "TERM=${TERM:-dumb}"
    "SAAS_EVAL_REAL_GIT=$real_git"
  )
  state_before=$(repository_state)

  # The policy is accepted only after behavioral verification: a write in the worktree
  # succeeds while an ancestor write and a connection to a live local TCP listener fail.
  probe_nonce=$(printf '%s:%s:%s' "$sample_id" "$base" "$$-$RANDOM" | sha256sum | awk '{print $1}')
  probe_inside="$wt/.saas-eval-policy-probe"
  probe_outside="$repo_root/.saas-eval-policy-$probe_nonce"
  probe_out="$sample_dir/sandbox-probe.out"
  listener_port_file="$eval_private/listener.port"
  listener_hit_file="$eval_private/listener.hit"
  python3 - "$listener_port_file" "$listener_hit_file" <<'PY' &
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", 0))
with open(sys.argv[1], "x", encoding="ascii") as out:
    out.write(str(s.getsockname()[1]))
s.listen(1)
s.settimeout(10)
try:
    conn, _ = s.accept()
except TimeoutError:
    pass
else:
    conn.close()
    with open(sys.argv[2], "x", encoding="ascii") as out:
        out.write("connected")
s.close()
PY
  listener_pid=$!
  local probe_wait=0
  while [ "$probe_wait" -lt 100 ]; do
    [ -s "$listener_port_file" ] && break
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.02
    probe_wait=$((probe_wait + 1))
  done
  [ -s "$listener_port_file" ] && listener_port=$(cat "$listener_port_file")
  if [[ "$listener_port" =~ ^[0-9]+$ ]] && [ ! -e "$probe_outside" ]; then
    set +e
    env -i "${eval_env[@]}" SAAS_EVAL_POLICY_CHALLENGE="$probe_nonce" \
      CODEX_BIN="$codex_bin" "$SCRIPT_DIR/codex-network-off-sandbox.sh" -C "$wt" \
      /bin/bash -c 'set -euo pipefail
        inside=$1 outside=$2 port=$3 expected=$4
        : > "$inside"
        if : > "$outside" 2>/dev/null; then exit 71; fi
        if exec 3<>"/dev/tcp/127.0.0.1/$port" 2>/dev/null; then exit 72; fi
        printf "%s\n" "$expected"' _ "$probe_inside" "$probe_outside" "$listener_port" "$probe_nonce" \
      > "$probe_out" 2> "$sample_dir/sandbox-probe.stderr"
    probe_rc=$?
    set -e
  fi
  kill "$listener_pid" >/dev/null 2>&1 || true
  wait "$listener_pid" 2>/dev/null || true
  listener_pid=""
  if [ "$probe_rc" -eq 0 ] && [ "$(cat "$probe_out" 2>/dev/null || true)" = "$probe_nonce" ] \
    && [ -f "$probe_inside" ] && [ ! -e "$probe_outside" ] && [ ! -e "$listener_hit_file" ]; then
    policy_verified=true
    policy_hash=$(printf '%s\n' 'codex-sandbox-policy-v2' 'permission-profile=saas-network-off' \
      'network=limited-proxy' 'outbound-domains=none' 'workspace-write=verified' \
      'outside-write=denied' 'local-tcp=denied' \
      | sha256sum | awk '{print $1}')
  else
    printf '%s\n' 'evaluation safety: sandbox policy probe was not verified' >> "$sample_dir/sandbox-probe.stderr"
  fi
  rm -f -- "$probe_inside"

  start=$(date +%s%3N 2>/dev/null || echo "$(( $(date +%s) * 1000 ))")
  if [ "$policy_verified" = true ]; then
    set +e
    (cd "$wt" && env -i "${eval_env[@]}" \
      SAAS_CODEX_STANDARD_MODEL=gpt-5.6-sol SAAS_CODEX_STANDARD_EFFORT=medium \
      SAAS_RUN_ID="eval-$sample_id" SAAS_COMMAND=standard-medium-eval SAAS_PHASE=replay \
      SAAS_WRITER_ID="eval-worker-$sample_id" SAAS_AGENT_EVENTS_FILE="$sample_dir/agent-events.jsonl" \
      SAAS_CODEX_LOG_DIR="$sample_dir/codex" CODEX_SANDBOX=workspace-write \
      SAAS_CODEX_NETWORK_ACCESS=off SAAS_CODEX_ISOLATED_CONFIG=1 \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_SSH_COMMAND=/bin/false \
      "$SCRIPT_DIR/codex-run-role.sh" --role tech-founder --profile standard --task-file "$composite") \
      > "$sample_dir/worker.log" 2> "$sample_dir/worker.stderr"
    rc=$?
    set -e
  else
    rc=98
    printf '%s\n' 'worker skipped: sandbox policy unverified' > "$sample_dir/worker.stderr"
    : > "$sample_dir/worker.log"
  fi

  [ "$check_mode" = 100755 ] && [ -f "$wt/check.sh" ] && [ ! -L "$wt/check.sh" ] \
    && [ "$(sha256_file "$wt/check.sh")" = "$check_hash" ] || integrity_ok=false
  ignore_files_intact || { integrity_ok=false; ignore_ok=false; }

  # Force every untracked and ignored file into the candidate before checks. This does
  # not rely on task-controlled ignore rules and makes hidden additions reviewable.
  "$real_git" -C "$wt" add -f -N --all >/dev/null 2>&1 || integrity_ok=false
  "$real_git" -C "$wt" diff --binary "$base" -- > "$sample_dir/medium.diff"
  diff_hash=$(sha256_file "$sample_dir/medium.diff")
  chmod 400 "$sample_dir/medium.diff"

  if [ "$rc" -eq 0 ] && [ "$integrity_ok" = true ]; then
    set +e
    (cd "$wt" && env -i "${check_env[@]}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND=/bin/false \
      CODEX_BIN="$codex_bin" "$SCRIPT_DIR/codex-network-off-sandbox.sh" -C "$wt" \
        "$wt/check.sh") \
      > "$sample_dir/check.log" 2>&1
    check_rc=$?
    set -e
  else
    check_rc=1
    printf '%s\n' 'check skipped: worker failed or base harness/ignore policy changed' > "$sample_dir/check.log"
  fi
  [ -f "$wt/check.sh" ] && [ ! -L "$wt/check.sh" ] \
    && [ "$(sha256_file "$wt/check.sh")" = "$check_hash" ] || { integrity_ok=false; check_rc=1; }
  ignore_files_intact || { integrity_ok=false; ignore_ok=false; check_rc=1; }
  "$real_git" -C "$wt" add -f -N --all >/dev/null 2>&1 || { integrity_ok=false; check_rc=1; }
  "$real_git" -C "$wt" diff --binary "$base" -- > "$sample_dir/post-check.diff"
  post_diff_hash=$(sha256_file "$sample_dir/post-check.diff")
  if [ "$post_diff_hash" != "$diff_hash" ]; then
    integrity_ok=false
    check_rc=1
    printf '%s\n' 'evaluation safety: deterministic checks changed the candidate tree' >> "$sample_dir/check.log"
  fi
  rm -f -- "$sample_dir/post-check.diff"
  [ "$integrity_ok" = true ] || printf '%s\n' 'evaluation safety: check harness or ignore policy changed' >> "$sample_dir/check.log"

  state_after=$(repository_state)
  if [ "$state_after" != "$state_before" ]; then
    state_intact=false
    check_rc=1
    printf '%s\n' 'evaluation safety: primary repository state changed' >> "$sample_dir/check.log"
  fi

  if [ -f "$sample_dir/agent-events.jsonl" ]; then
    worker_tokens=$(jq -s '[.[] | select(.event_type == "completed")][-1] as $e
      | if $e == null or $e.input_tokens == null or $e.output_tokens == null then null
        else ($e.input_tokens + $e.output_tokens) end' "$sample_dir/agent-events.jsonl" 2>/dev/null || echo null)
    worker_cost=$(jq -s '[.[] | select(.event_type == "completed")][-1].cost_microunits // null' \
      "$sample_dir/agent-events.jsonl" 2>/dev/null || echo null)
  fi
  end=$(date +%s%3N 2>/dev/null || echo "$(( $(date +%s) * 1000 ))")
  duration=$((end - start))
  result="$sample_dir/result.json"
  jq -cn --arg sample_id "$sample_id" --arg base_sha "$base" --arg task_sha "$task_hash" \
    --arg diff_sha "$diff_hash" --arg check_sha "$check_hash" --arg policy_sha "$policy_hash" \
    --argjson worker_exit "$rc" --argjson check_exit "$check_rc" --argjson duration_ms "$duration" \
    --argjson state_intact "$state_intact" --argjson integrity_ok "$integrity_ok" --argjson ignore_ok "$ignore_ok" \
    --argjson policy_verified "$policy_verified" --argjson tokens "$worker_tokens" --argjson cost "$worker_cost" \
    '{schema_version:2,evidence_kind:"delivery-candidate-result",sample_id:$sample_id,candidate:"medium",
      profile:"standard",model:"gpt-5.6-sol",effort:"medium",base_sha:$base_sha,task_sha256:$task_sha,
      diff_sha256:$diff_sha,check_harness_sha256:$check_sha,worker_exit:$worker_exit,check_exit:$check_exit,
      duration_ms:$duration_ms,usage:{tokens:$tokens,cost_microunits:$cost},
      safety_evidence:{sandbox_policy:(if $policy_verified then "verified" else "unknown" end),
        sandbox_policy_sha256:(if $policy_verified then $policy_sha else null end),
        network_access:(if $policy_verified then "blocked" else null end),
        filesystem_scope:(if $policy_verified then "verified" else null end),
        sanitized_environment:true,isolated_config:true,primary_state_intact:$state_intact,
        base_harness_intact:$integrity_ok,ignore_policy_intact:$ignore_ok},
      remote_mutation:(if $policy_verified then ($state_intact|not) else null end),
      production_mutation:(if $policy_verified then ($state_intact|not) else null end)}' > "$result"
  chmod 400 "$result"
  cleanup_replay
  trap - EXIT
  printf '%s\n' "$result"
  [ "$policy_verified" = true ] && [ "$rc" -eq 0 ] && [ "$check_rc" -eq 0 ] \
    && [ "$integrity_ok" = true ] && [ "$state_intact" = true ]
}

blind_pair() {
  local sample_id="" base_sha="" task_sha="" high_diff="" medium_diff="" out_dir="" mapping_out=""
  local byte bit out_real map_real old_umask high_hash medium_hash input_hash binding
  while [ $# -gt 0 ]; do
    case "$1" in
      --sample-id) [ "$#" -ge 2 ] || usage; sample_id="$2"; shift 2 ;;
      --base-sha) [ "$#" -ge 2 ] || usage; base_sha="$2"; shift 2 ;;
      --task-sha256) [ "$#" -ge 2 ] || usage; task_sha="$2"; shift 2 ;;
      --high-diff) [ "$#" -ge 2 ] || usage; high_diff="$2"; shift 2 ;;
      --medium-diff) [ "$#" -ge 2 ] || usage; medium_diff="$2"; shift 2 ;;
      --out-dir) [ "$#" -ge 2 ] || usage; out_dir="$2"; shift 2 ;;
      --mapping-out) [ "$#" -ge 2 ] || usage; mapping_out="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  safe_id "$sample_id" && safe_git_sha "$base_sha" && safe_sha256 "$task_sha" \
    && [ -f "$high_diff" ] && [ ! -L "$high_diff" ] \
    && [ -f "$medium_diff" ] && [ ! -L "$medium_diff" ] \
    && [ -n "$out_dir" ] && [ -n "$mapping_out" ] || usage
  contains_model_identity() {
    LC_ALL=C grep -Eiq \
      'gpt-5\.[0-9]+-(sol|terra)|claude-(fable|opus|sonnet|haiku)|(^|[^[:alnum:]_])(sol|terra)[/ _-]+(low|medium|high|xhigh|max)([^[:alnum:]_]|$)|model[_ -]*(name)?[[:space:]]*[:=][[:space:]]*[^[:space:]]+|reasoning[_ -]*effort[[:space:]]*[:=][[:space:]]*(low|medium|high|xhigh|max)' \
      "$1"
  }
  if contains_model_identity "$high_diff" || contains_model_identity "$medium_diff"; then
    echo "standard-medium-eval: candidate diff exposes model or effort identity" >&2
    exit 2
  fi
  [ ! -e "$out_dir" ] && [ ! -e "$mapping_out" ] || {
    echo "standard-medium-eval: blind output already exists" >&2; exit 2; }
  out_real=$(realpath -m -- "$out_dir"); map_real=$(realpath -m -- "$mapping_out")
  case "$map_real" in "$out_real"|"$out_real"/*)
    echo "standard-medium-eval: private mapping must be outside reviewer-visible output" >&2
    exit 2 ;;
  esac
  high_hash=$(sha256_file "$high_diff"); medium_hash=$(sha256_file "$medium_diff")
  binding=$(printf '%s\0%s\0%s\0%s\0%s' "$sample_id" "$base_sha" "$task_sha" "$high_hash" "$medium_hash" \
    | sha256sum | awk '{print $1}')
  old_umask=$(umask); umask 077
  mkdir -p "$out_dir" "$(dirname -- "$mapping_out")"
  byte=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ' || echo "${RANDOM:-0}")
  bit=$((byte % 2))
  if [ "$bit" -eq 0 ]; then
    cp -- "$high_diff" "$out_dir/candidate-a.diff"
    cp -- "$medium_diff" "$out_dir/candidate-b.diff"
    jq -n --arg id "$sample_id" --arg base "$base_sha" --arg task "$task_sha" --arg bind "$binding" \
      --arg ah "$high_hash" --arg bh "$medium_hash" \
      '{schema_version:2,evidence_kind:"private-blind-mapping",sample_id:$id,base_sha:$base,task_sha256:$task,
        binding_sha256:$bind,candidates:{"candidate-a":{diff_sha256:$ah},
        "candidate-b":{diff_sha256:$bh}}}' > "$mapping_out"
  else
    cp -- "$medium_diff" "$out_dir/candidate-a.diff"
    cp -- "$high_diff" "$out_dir/candidate-b.diff"
    jq -n --arg id "$sample_id" --arg base "$base_sha" --arg task "$task_sha" --arg bind "$binding" \
      --arg ah "$medium_hash" --arg bh "$high_hash" \
      '{schema_version:2,evidence_kind:"private-blind-mapping",sample_id:$id,base_sha:$base,task_sha256:$task,
        binding_sha256:$bind,candidates:{"candidate-a":{diff_sha256:$ah},
        "candidate-b":{diff_sha256:$bh}}}' > "$mapping_out"
  fi
  jq -n --arg id "$sample_id" --arg base "$base_sha" --arg task "$task_sha" --arg bind "$binding" \
    --arg ah "$(sha256_file "$out_dir/candidate-a.diff")" --arg bh "$(sha256_file "$out_dir/candidate-b.diff")" \
    '{schema_version:2,evidence_kind:"blinded-tribunal-input",sample_id:$id,base_sha:$base,task_sha256:$task,
      binding_sha256:$bind,candidates:[{id:"candidate-a",file:"candidate-a.diff",diff_sha256:$ah},
      {id:"candidate-b",file:"candidate-b.diff",diff_sha256:$bh}],model_identity_in_candidates:false}' \
    > "$out_dir/tribunal-input.json"
  input_hash=$(sha256_file "$out_dir/tribunal-input.json")
  jq --arg input_hash "$input_hash" '. + {tribunal_input_sha256:$input_hash}' "$mapping_out" \
    > "$mapping_out.tmp"
  mv "$mapping_out.tmp" "$mapping_out"
  chmod 400 "$mapping_out" "$out_dir/candidate-a.diff" "$out_dir/candidate-b.diff" "$out_dir/tribunal-input.json"
  umask "$old_umask"
  printf '%s\n' "$out_dir/tribunal-input.json"
}

assess_pairs() {
  local pairs="" out="" temp_root normalized used_paths used_candidates pair_dir row_count rc=20 index=0
  local row sample_id base_sha task_sha task_path high_result high_diff medium_result medium_diff
  local tribunal_input tribunal_mapping tribunal_result candidate_a candidate_b path resolved snap before after copied
  local tribunal_input_source tribunal_mapping_source tribunal_input_real tribunal_mapping_real mapping_mode
  local repo_source repo_root resolved_base base_check base_check_mode candidate_fingerprint
  local task_actual high_diff_hash medium_diff_hash input_hash mapping_medium check_hash_high check_hash_medium check_harness
  local expected_binding expected_policy_hash policy_hash_high policy_hash_medium
  local high_pass medium_pass unique_critical deep complete remote high_tokens medium_tokens high_cost medium_cost
  local high_latency medium_latency
  while [ $# -gt 0 ]; do
    case "$1" in
      --pairs) [ "$#" -ge 2 ] || usage; pairs="$2"; shift 2 ;;
      --out) [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -f "$pairs" ] && [ ! -L "$pairs" ] && [ -n "$out" ] || usage
  jq -e -s 'length > 0 and all(.[]; type == "object")' "$pairs" >/dev/null 2>&1 || {
    echo "standard-medium-eval: invalid paired evidence manifest" >&2; exit 2; }
  pair_dir=$(cd "$(dirname -- "$pairs")" && pwd)
  temp_root=$(mktemp -d)
  normalized="$temp_root/derived.jsonl"
  used_paths="$temp_root/used-paths"
  used_candidates="$temp_root/used-candidates"
  : > "$normalized"; : > "$used_paths"; : > "$used_candidates"
  cleanup_assessment() { rm -rf -- "$temp_root"; }
  trap cleanup_assessment EXIT
  expected_policy_hash=$(printf '%s\n' 'codex-sandbox-policy-v2' 'permission-profile=saas-network-off' \
    'network=limited-proxy' 'outbound-domains=none' 'workspace-write=verified' \
    'outside-write=denied' 'local-tcp=denied' \
    | sha256sum | awk '{print $1}')

  validate_patch() {
    local repo="$1" commit="$2" patch="$3" index_file="$4"
    [ -s "$patch" ] || return 1
    rm -f -- "$index_file"
    GIT_INDEX_FILE="$index_file" git -C "$repo" read-tree "$commit" >/dev/null 2>&1 || return 1
    GIT_INDEX_FILE="$index_file" git -C "$repo" apply --cached --check --binary --whitespace=nowarn \
      "$patch" >/dev/null 2>&1 || return 1
    # -C "$repo": from a repo subdirectory, bare `git apply` silently ignores
    # patch paths outside the cwd and reports an empty numstat.
    git -C "$repo" apply --numstat -- "$patch" 2>/dev/null | grep -q . || return 1
    rm -f -- "$index_file"
  }

  # Reject replaying the same delivery under a second sample identifier.
  jq -e -s '
    all(.[]; .schema_version == 2 and (.sample_id|type == "string") and
      (.base_sha|type == "string") and (.task_sha256|type == "string")) and
    ([.[].sample_id] | length == (unique|length)) and
    ([.[] | [.base_sha,.task_sha256] | join(":")] | length == (unique|length))
  ' "$pairs" >/dev/null 2>&1 || {
    echo "standard-medium-eval: duplicate or incomplete delivery identity" >&2; exit 2; }

  snapshot_artifact() {
    local supplied="$1" label="$2"
    case "$supplied" in /*) resolved="$supplied" ;; *) resolved="$pair_dir/$supplied" ;; esac
    resolved=$(realpath -e -- "$resolved" 2>/dev/null) || return 1
    [ -f "$resolved" ] && [ ! -L "$resolved" ] || return 1
    if grep -Fqx -- "$resolved" "$used_paths"; then return 1; fi
    printf '%s\n' "$resolved" >> "$used_paths"
    before=$(sha256_file "$resolved")
    snap="$temp_root/$index-$label"
    cp -- "$resolved" "$snap"
    copied=$(sha256_file "$snap")
    after=$(sha256_file "$resolved")
    [ "$before" = "$copied" ] && [ "$before" = "$after" ] || return 1
    printf '%s\n' "$snap"
  }

  while IFS= read -r row; do
    index=$((index + 1))
    sample_id=$(jq -r '.sample_id // empty' <<< "$row")
    base_sha=$(jq -r '.base_sha // empty' <<< "$row")
    task_sha=$(jq -r '.task_sha256 // empty' <<< "$row")
    safe_id "$sample_id" && safe_git_sha "$base_sha" && safe_sha256 "$task_sha" || {
      echo "standard-medium-eval: invalid delivery identity" >&2; exit 2; }
    [ "$(jq -r '.repo_root | type' <<< "$row")" = string ] || {
      echo "standard-medium-eval: missing local source repository" >&2; exit 2; }
    repo_source=$(jq -r .repo_root <<< "$row")
    case "$repo_source" in /*) : ;; *) repo_source="$pair_dir/$repo_source" ;; esac
    repo_root=$(realpath -e -- "$repo_source" 2>/dev/null) || {
      echo "standard-medium-eval: invalid source repository" >&2; exit 2; }
    [ -d "$repo_root" ] && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
      echo "standard-medium-eval: source repository is not a Git worktree" >&2; exit 2; }
    resolved_base=$(git -C "$repo_root" rev-parse --verify "${base_sha}^{commit}" 2>/dev/null) || {
      echo "standard-medium-eval: base commit is absent from source repository" >&2; exit 2; }
    [ "$resolved_base" = "$base_sha" ] || {
      echo "standard-medium-eval: base commit is not canonical" >&2; exit 2; }
    for path in task_file check_harness high_result high_diff medium_result medium_diff candidate_a candidate_b tribunal_input tribunal_mapping tribunal_result; do
      [ "$(jq -r --arg key "$path" '.[$key] | type' <<< "$row")" = string ] || {
        echo "standard-medium-eval: missing local evidence path: $path" >&2; exit 2; }
    done
    tribunal_input_source=$(jq -r .tribunal_input <<< "$row")
    tribunal_mapping_source=$(jq -r .tribunal_mapping <<< "$row")
    case "$tribunal_input_source" in /*) : ;; *) tribunal_input_source="$pair_dir/$tribunal_input_source" ;; esac
    case "$tribunal_mapping_source" in /*) : ;; *) tribunal_mapping_source="$pair_dir/$tribunal_mapping_source" ;; esac
    tribunal_input_real=$(realpath -e -- "$tribunal_input_source" 2>/dev/null) || {
      echo "standard-medium-eval: invalid tribunal input path" >&2; exit 2; }
    tribunal_mapping_real=$(realpath -e -- "$tribunal_mapping_source" 2>/dev/null) || {
      echo "standard-medium-eval: invalid tribunal mapping path" >&2; exit 2; }
    case "$tribunal_mapping_real" in "$(dirname -- "$tribunal_input_real")"/*)
      echo "standard-medium-eval: private mapping is reviewer-visible" >&2; exit 2 ;;
    esac
    mapping_mode=$(stat -c '%a' -- "$tribunal_mapping_real")
    [[ "$mapping_mode" =~ ^[0-7]00$ ]] || {
      echo "standard-medium-eval: private mapping permissions are not owner-only" >&2; exit 2; }
    task_path=$(snapshot_artifact "$(jq -r .task_file <<< "$row")" task) || {
      echo "standard-medium-eval: invalid or reused task evidence" >&2; exit 2; }
    check_harness=$(snapshot_artifact "$(jq -r .check_harness <<< "$row")" check-harness) || {
      echo "standard-medium-eval: invalid or reused check harness evidence" >&2; exit 2; }
    base_check_mode=$(git -C "$repo_root" ls-tree "$base_sha" -- check.sh | awk 'NR == 1 {print $1}')
    [ "$base_check_mode" = 100755 ] || {
      echo "standard-medium-eval: base check harness is not a tracked executable" >&2; exit 2; }
    base_check="$temp_root/$index-base-check"
    git -C "$repo_root" show "$base_sha:check.sh" > "$base_check" || {
      echo "standard-medium-eval: base check harness cannot be read" >&2; exit 2; }
    [ "$(sha256_file "$base_check")" = "$(sha256_file "$check_harness")" ] || {
      echo "standard-medium-eval: supplied check harness does not belong to base" >&2; exit 2; }
    high_result=$(snapshot_artifact "$(jq -r .high_result <<< "$row")" high-result) || {
      echo "standard-medium-eval: invalid or reused high result evidence" >&2; exit 2; }
    high_diff=$(snapshot_artifact "$(jq -r .high_diff <<< "$row")" high-diff) || {
      echo "standard-medium-eval: invalid or reused high diff evidence" >&2; exit 2; }
    medium_result=$(snapshot_artifact "$(jq -r .medium_result <<< "$row")" medium-result) || {
      echo "standard-medium-eval: invalid or reused medium result evidence" >&2; exit 2; }
    medium_diff=$(snapshot_artifact "$(jq -r .medium_diff <<< "$row")" medium-diff) || {
      echo "standard-medium-eval: invalid or reused medium diff evidence" >&2; exit 2; }
    candidate_a=$(snapshot_artifact "$(jq -r .candidate_a <<< "$row")" candidate-a) || {
      echo "standard-medium-eval: invalid or reused blinded candidate A" >&2; exit 2; }
    candidate_b=$(snapshot_artifact "$(jq -r .candidate_b <<< "$row")" candidate-b) || {
      echo "standard-medium-eval: invalid or reused blinded candidate B" >&2; exit 2; }
    tribunal_input=$(snapshot_artifact "$(jq -r .tribunal_input <<< "$row")" tribunal-input) || {
      echo "standard-medium-eval: invalid or reused tribunal input evidence" >&2; exit 2; }
    tribunal_mapping=$(snapshot_artifact "$(jq -r .tribunal_mapping <<< "$row")" tribunal-mapping) || {
      echo "standard-medium-eval: invalid or reused tribunal mapping evidence" >&2; exit 2; }
    tribunal_result=$(snapshot_artifact "$(jq -r .tribunal_result <<< "$row")" tribunal-result) || {
      echo "standard-medium-eval: invalid or reused tribunal result evidence" >&2; exit 2; }

    task_actual=$(sha256_file "$task_path")
    high_diff_hash=$(sha256_file "$high_diff")
    medium_diff_hash=$(sha256_file "$medium_diff")
    input_hash=$(sha256_file "$tribunal_input")
    validate_patch "$repo_root" "$base_sha" "$high_diff" "$temp_root/$index-high.index" \
      && validate_patch "$repo_root" "$base_sha" "$medium_diff" "$temp_root/$index-medium.index" || {
      echo "standard-medium-eval: candidate is not a non-empty patch against its base" >&2; exit 2; }
    candidate_fingerprint="$base_sha:$high_diff_hash:$medium_diff_hash"
    grep -Fqx -- "$candidate_fingerprint" "$used_candidates" && {
      echo "standard-medium-eval: duplicate candidate pair" >&2; exit 2; }
    printf '%s\n' "$candidate_fingerprint" >> "$used_candidates"
    [ "$task_actual" = "$task_sha" ] || { echo "standard-medium-eval: task binding mismatch" >&2; exit 2; }
    jq -e --arg id "$sample_id" --arg base "$base_sha" --arg task "$task_sha" --arg diff "$high_diff_hash" '
      .schema_version == 2 and .evidence_kind == "delivery-candidate-result" and .sample_id == $id and
      .candidate == "high" and .profile == "standard" and .model == "gpt-5.6-sol" and .effort == "high" and
      .base_sha == $base and .task_sha256 == $task and
      .diff_sha256 == $diff and (.check_harness_sha256|type == "string") and
      (.worker_exit|type == "number") and (.check_exit|type == "number") and
      (.duration_ms|type == "number") and .duration_ms >= 0 and
      (.usage.tokens == null or ((.usage.tokens|type) == "number" and .usage.tokens >= 0)) and
      (.usage.cost_microunits == null or ((.usage.cost_microunits|type) == "number" and .usage.cost_microunits >= 0)) and
      (.remote_mutation|type == "boolean") and (.production_mutation|type == "boolean") and
      (.safety_evidence.sandbox_policy == "verified" or .safety_evidence.sandbox_policy == "unknown") and
      (if .safety_evidence.sandbox_policy == "verified" then
        ((.safety_evidence.sandbox_policy_sha256|type) == "string" and
         (.safety_evidence.sandbox_policy_sha256|test("^[0-9a-f]{64}$"))) else
        .safety_evidence.sandbox_policy_sha256 == null end) and
      (.safety_evidence.primary_state_intact|type == "boolean") and
      (.safety_evidence.base_harness_intact|type == "boolean") and
      (.safety_evidence.ignore_policy_intact|type == "boolean")
    ' "$high_result" >/dev/null || { echo "standard-medium-eval: invalid high result provenance" >&2; exit 2; }
    jq -e --arg id "$sample_id" --arg base "$base_sha" --arg task "$task_sha" --arg diff "$medium_diff_hash" '
      .schema_version == 2 and .evidence_kind == "delivery-candidate-result" and .sample_id == $id and
      .candidate == "medium" and .profile == "standard" and .model == "gpt-5.6-sol" and .effort == "medium" and
      .base_sha == $base and .task_sha256 == $task and
      .diff_sha256 == $diff and (.check_harness_sha256|type == "string") and
      (.worker_exit|type == "number") and (.check_exit|type == "number") and
      (.duration_ms|type == "number") and .duration_ms >= 0 and
      (.usage.tokens == null or ((.usage.tokens|type) == "number" and .usage.tokens >= 0)) and
      (.usage.cost_microunits == null or ((.usage.cost_microunits|type) == "number" and .usage.cost_microunits >= 0)) and
      (.remote_mutation|type == "boolean") and (.production_mutation|type == "boolean") and
      (.safety_evidence.sandbox_policy == "verified" or .safety_evidence.sandbox_policy == "unknown") and
      (if .safety_evidence.sandbox_policy == "verified" then
        ((.safety_evidence.sandbox_policy_sha256|type) == "string" and
         (.safety_evidence.sandbox_policy_sha256|test("^[0-9a-f]{64}$"))) else
        .safety_evidence.sandbox_policy_sha256 == null end) and
      (.safety_evidence.primary_state_intact|type == "boolean") and
      (.safety_evidence.base_harness_intact|type == "boolean") and
      (.safety_evidence.ignore_policy_intact|type == "boolean")
    ' "$medium_result" >/dev/null || { echo "standard-medium-eval: invalid medium result provenance" >&2; exit 2; }
    check_hash_high=$(jq -r .check_harness_sha256 "$high_result")
    check_hash_medium=$(jq -r .check_harness_sha256 "$medium_result")
    safe_sha256 "$check_hash_high" && [ "$check_hash_high" = "$check_hash_medium" ] \
      && [ "$check_hash_high" = "$(sha256_file "$check_harness")" ] || {
      echo "standard-medium-eval: check harness binding mismatch" >&2; exit 2; }
    policy_hash_high=$(jq -r '.safety_evidence.sandbox_policy_sha256 // empty' "$high_result")
    policy_hash_medium=$(jq -r '.safety_evidence.sandbox_policy_sha256 // empty' "$medium_result")
    [ "$policy_hash_high" = "$expected_policy_hash" ] \
      && [ "$policy_hash_medium" = "$expected_policy_hash" ] || {
      echo "standard-medium-eval: sandbox policy binding mismatch" >&2; exit 2; }

    expected_binding=$(printf '%s\0%s\0%s\0%s\0%s' "$sample_id" "$base_sha" "$task_sha" \
      "$high_diff_hash" "$medium_diff_hash" | sha256sum | awk '{print $1}')

    jq -e --arg id "$sample_id" --arg base "$base_sha" --arg task "$task_sha" --arg bind "$expected_binding" \
      --arg ah "$(sha256_file "$candidate_a")" --arg bh "$(sha256_file "$candidate_b")" '
      .schema_version == 2 and .evidence_kind == "blinded-tribunal-input" and .sample_id == $id and
      .base_sha == $base and .task_sha256 == $task and .model_identity_in_candidates == false and
      .binding_sha256 == $bind and (.candidates|length == 2) and
      ([.candidates[].id] | sort == ["candidate-a","candidate-b"]) and
      (.candidates[] | select(.id == "candidate-a").file) == "candidate-a.diff" and
      (.candidates[] | select(.id == "candidate-b").file) == "candidate-b.diff" and
      (.candidates[] | select(.id == "candidate-a").diff_sha256) == $ah and
      (.candidates[] | select(.id == "candidate-b").diff_sha256) == $bh
    ' "$tribunal_input" >/dev/null || { echo "standard-medium-eval: invalid blinded input provenance" >&2; exit 2; }
    jq -e --arg id "$sample_id" --arg base "$base_sha" --arg task "$task_sha" --arg input "$input_hash" \
      --arg high "$high_diff_hash" --arg medium "$medium_diff_hash" --arg bind "$expected_binding" '
      .schema_version == 2 and .evidence_kind == "private-blind-mapping" and .sample_id == $id and
      .base_sha == $base and .task_sha256 == $task and .tribunal_input_sha256 == $input and .binding_sha256 == $bind and
      (.candidates["candidate-a"] | has("source") | not) and
      (.candidates["candidate-b"] | has("source") | not) and
      ([.candidates["candidate-a"].diff_sha256,.candidates["candidate-b"].diff_sha256] | sort == ([$high,$medium]|sort))
    ' "$tribunal_mapping" >/dev/null || { echo "standard-medium-eval: invalid private mapping provenance" >&2; exit 2; }
    jq -n -e --slurpfile input "$tribunal_input" --slurpfile mapping "$tribunal_mapping" '
      $input[0].binding_sha256 == $mapping[0].binding_sha256 and
      all($input[0].candidates[];
        $mapping[0].candidates[.id].diff_sha256 == .diff_sha256)
    ' >/dev/null || { echo "standard-medium-eval: blinded candidate binding mismatch" >&2; exit 2; }
    if [ "$(sha256_file "$candidate_a")" = "$medium_diff_hash" ]; then
      mapping_medium=candidate-a
    else
      mapping_medium=candidate-b
    fi
    jq -e --arg id "$sample_id" --arg base "$base_sha" --arg task "$task_sha" --arg input "$input_hash" '
      .schema_version == 2 and .evidence_kind == "blinded-tribunal-result" and .sample_id == $id and
      .base_sha == $base and .task_sha256 == $task and .tribunal_input_sha256 == $input and
      (.status == "complete" or .status == "incomplete") and
      (if .status == "complete" then (.decision == "accept" or .decision == "deep-escalation") else .decision == null end) and
      (.findings|type == "array") and ([.findings[].fingerprint] | length == (unique|length)) and all(.findings[];
        (.fingerprint|type == "string") and (.fingerprint|length > 0) and
        (.severity == "critical" or .severity == "high" or .severity == "medium" or .severity == "low") and
        (.candidates|type == "array") and (.candidates|length > 0) and
        (.candidates|length == (unique|length)) and all(.candidates[]; . == "candidate-a" or . == "candidate-b"))
    ' "$tribunal_result" >/dev/null || { echo "standard-medium-eval: invalid tribunal result provenance" >&2; exit 2; }

    high_pass=$(jq -r '(.worker_exit == 0 and .check_exit == 0)' "$high_result")
    medium_pass=$(jq -r '(.worker_exit == 0 and .check_exit == 0)' "$medium_result")
    complete=$(jq -r '.status == "complete"' "$tribunal_result")
    deep=$(jq -r '.status == "complete" and .decision == "deep-escalation"' "$tribunal_result")
    unique_critical=$(jq -r --arg medium "$mapping_medium" '[.findings[] |
      select((.severity == "critical" or .severity == "high") and (.candidates|length == 1) and .candidates[0] == $medium)] | length > 0' "$tribunal_result")
    remote=$(jq -s 'any(.[]; .remote_mutation != false or .production_mutation != false or
      .safety_evidence.sandbox_policy != "verified" or
      .safety_evidence.sandbox_policy_sha256 == null or .safety_evidence.network_access != "blocked" or
      .safety_evidence.filesystem_scope != "verified" or .safety_evidence.sanitized_environment != true or
      .safety_evidence.isolated_config != true or .safety_evidence.primary_state_intact != true or
      .safety_evidence.base_harness_intact != true or .safety_evidence.ignore_policy_intact != true)' \
      "$high_result" "$medium_result")
    high_tokens=$(jq -r '.usage.tokens // "null"' "$high_result")
    medium_tokens=$(jq -r '.usage.tokens // "null"' "$medium_result")
    high_cost=$(jq -r '.usage.cost_microunits // "null"' "$high_result")
    medium_cost=$(jq -r '.usage.cost_microunits // "null"' "$medium_result")
    high_latency=$(jq -r .duration_ms "$high_result")
    medium_latency=$(jq -r .duration_ms "$medium_result")
    jq -cn --argjson high_pass "$high_pass" --argjson medium_pass "$medium_pass" \
      --argjson unique_critical "$unique_critical" --argjson deep "$deep" --argjson complete "$complete" \
      --argjson remote "$remote" --argjson high_tokens "$high_tokens" --argjson medium_tokens "$medium_tokens" \
      --argjson high_cost "$high_cost" --argjson medium_cost "$medium_cost" \
      --argjson high_latency "$high_latency" --argjson medium_latency "$medium_latency" \
      '{high_check_pass:$high_pass,medium_check_pass:$medium_pass,medium_unique_critical_high:$unique_critical,
        deep_escalation_required:$deep,blinded_tribunal_complete:$complete,
        remote_or_production_mutation_or_unknown:$remote,high_tokens:$high_tokens,medium_tokens:$medium_tokens,
        high_cost_microunits:$high_cost,medium_cost_microunits:$medium_cost,
        high_latency_ms:$high_latency,medium_latency_ms:$medium_latency}' >> "$normalized"
  done < <(jq -c . "$pairs")
  row_count=$index
  [ "$row_count" -gt 0 ] || { echo "standard-medium-eval: empty evidence manifest" >&2; exit 2; }

  local tmp="$temp_root/assessment.json"
  jq -s '
    def median:
      sort as $s | ($s|length) as $n |
      if $n == 0 then null elif ($n % 2) == 1 then $s[($n/2|floor)]
      else (($s[$n/2-1] + $s[$n/2]) / 2) end;
    def rate($n;$d): if $d == 0 then null else $n/$d end;
    length as $n
    | ([.[] | select(.high_check_pass)] | length) as $high_passes
    | ([.[] | select(.medium_check_pass)] | length) as $medium_passes
    | ([.[] | select(.medium_unique_critical_high)] | length) as $unique_critical
    | ([.[] | select(.deep_escalation_required)] | length) as $deep
    | ([.[] | select(.remote_or_production_mutation_or_unknown)] | length) as $unsafe
    | ([.[] | select(.blinded_tribunal_complete | not)] | length) as $unblinded
    | ([.[].high_latency_ms] | median) as $high_latency
    | ([.[].medium_latency_ms] | median) as $medium_latency
    | (all(.[]; .high_tokens != null and .medium_tokens != null and .high_tokens > 0)) as $has_tokens
    | (all(.[]; .high_cost_microunits != null and .medium_cost_microunits != null and .high_cost_microunits > 0)) as $has_cost
    | (if $has_tokens then "tokens" elif $has_cost then "cost_microunits" else null end) as $economic_kind
    | (if $has_tokens then ([.[].high_tokens]|median) elif $has_cost then ([.[].high_cost_microunits]|median) else null end) as $high_economic
    | (if $has_tokens then ([.[].medium_tokens]|median) elif $has_cost then ([.[].medium_cost_microunits]|median) else null end) as $medium_economic
    | (if $high_economic == null or $high_economic == 0 then null else (($high_economic-$medium_economic)/$high_economic) end) as $economic_improvement
    | (rate($high_passes;$n)) as $high_rate | (rate($medium_passes;$n)) as $medium_rate | (rate($deep;$n)) as $deep_rate
    | {schema_version:2,kind:"standard-medium-assessment",sample_count:$n,
        provenance:{trusted_controller_receipts:false,
          note:"metrics_only_until_supervisor_owned_end_to_end_receipts_exist"},
        metrics:{high_pass_rate:$high_rate,medium_pass_rate:$medium_rate,deep_escalation_rate:$deep_rate,
          unique_critical_high_count:$unique_critical,unsafe_or_unknown_replay_count:$unsafe,
          incomplete_blinded_comparison_count:$unblinded,economic_metric:$economic_kind,
          median_high_economic:$high_economic,median_medium_economic:$medium_economic,
          median_economic_improvement:$economic_improvement,median_high_latency_ms:$high_latency,
          median_medium_latency_ms:$medium_latency,
          medium_latency_ratio:(if $high_latency == null or $high_latency == 0 then null else $medium_latency/$high_latency end)},
        criteria:{sample_count:($n >= 20 and $n <= 50),
          medium_pass_rate:($medium_rate != null and $medium_rate >= 0.90 and ($high_rate-$medium_rate) <= 0.05),
          no_unique_critical_high:($unique_critical == 0),deep_escalation:($deep_rate != null and $deep_rate <= 0.20),
          economic_improvement:($economic_improvement != null and $economic_improvement >= 0.20),
          latency:($high_latency != null and $high_latency > 0 and ($medium_latency/$high_latency) <= 1.25),
          blinded_comparison:($unblinded == 0),no_remote_or_production_mutation:($unsafe == 0),
          trusted_controller_receipts:false}}
    | .decision = (if ([.criteria[]] | all) then "go" else "no-go" end)
  ' "$normalized" > "$tmp"

  # shellcheck source=pii-gate.sh
  . "$SCRIPT_DIR/pii-gate.sh" || { echo "standard-medium-eval: PII gate unavailable" >&2; exit 3; }
  if pii_hit "$(cat "$tmp")"; then
    echo "standard-medium-eval: assessment blocked by secret/PII gate" >&2
    exit 3
  fi
  mkdir -p "$(dirname -- "$out")"
  mv "$tmp" "$out"
  [ "$(jq -r .decision "$out")" = go ] && rc=0
  printf '%s\n' "$out"
  rm -rf -- "$temp_root"
  trap - EXIT
  return "$rc"
}

case "${1:-}" in
  replay) shift; replay_sample "$@" ;;
  blind) shift; blind_pair "$@" ;;
  assess) shift; assess_pairs "$@" ;;
  *) usage ;;
esac
