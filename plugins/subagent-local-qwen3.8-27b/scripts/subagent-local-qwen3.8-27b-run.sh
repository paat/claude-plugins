#!/usr/bin/env bash
# subagent-local-qwen3.8-27b-run.sh — drive Qwen Code CLI against local llama.cpp
# serving Qwen3.8-27B (coding profile). Role-agnostic: implement (--yolo) or
# review (--approval-mode plan).
#
# Gotchas encoded here:
#   1. Isolated HOME — never write the host ~/.qwen (tribunal DashScope creds).
#   2. Preflight refuses down / busy / wrong-model / non-coding aliases.
#   3. Prompt on stdin (never giant argv). Dual timeouts (inner timeout +
#      host Bash-tool timeout must both be generous).
#   4. Keep Qwen Code's built-in system prompt; append a short contract only.
#   5. reasoning_effort is medium only (xhigh|medium|low — never high).
#
# Usage:
#   subagent-local-qwen3.8-27b-run.sh [options] [PROMPT]
#   <build prompt> | subagent-local-qwen3.8-27b-run.sh [options]
#
# Options:
#   -C, --dir DIR              Working directory (default: $PWD).
#   -m, --model MODEL          Served llama.cpp alias
#                              (default: Qwen3.8-27B-UD-Q6_K_XL-coding).
#   -e, --effort LEVEL         xhigh|medium|low (default: medium; never high).
#   -t, --timeout SECS         Inner timeout for the qwen run (default: 900).
#       --max-session-turns N  Cap agent turns (default: 40).
#       --max-wall-time DUR    Cap wall clock, e.g. 15m (default: 15m).
#       --yolo                 Implement mode: auto-approve tools (default).
#       --approval-mode MODE   Use plan for read-only review; overrides --yolo.
#   -f, --prompt-file F        Read the prompt from file F instead of argv/stdin.
#   -d, --diff BASE            Write `git diff BASE` to a temp dir OUTSIDE the repo,
#                              share it with --include-directories, and point the
#                              prompt at it (review mode only).
#                              Required for review: approval-mode plan has NO shell,
#                              so the worker cannot run git itself. Name both ends:
#                              'HEAD~1..HEAD' for a commit, 'origin/main...HEAD' for
#                              a branch, HEAD for the uncommitted working tree.
#   -o, --out FILE             Where to keep the full captured stream (default: temp).
#       --print-base           Print the llama.cpp base URL this run would use, then
#                              exit (callers share one resolver instead of guessing).
#       --print-cmd            Print the base qwen command, then exit (no --diff
#                              patch wiring: nothing is produced for a preview).
#   -h, --help                 Show this help and exit.
#
# Env:
#   OPENAI_BASE_URL   OpenAI-compat base (default: http://127.0.0.1:8000/v1; when
#                     unset and that is unreachable, the container gateway
#                     (host.docker.internal / default route) is tried too).
#   OPENAI_API_KEY    Dummy key for local servers (default: dummy).
#   QWEN38_MODEL      Default model alias override.
#
# Exit codes: 0 ok; 2 usage; 75 transient (server down or busy — retry or route
# elsewhere); 1 wrong model or other refusal; 124/143 timeout; 127 CLI missing.
#
# Output: prints ONLY the final answer on stdout, then a short footer on stderr.
# Host Bash-tool timeout must also be generous (≥ inner --timeout in ms).
set -euo pipefail

QL_DEFAULT_TIMEOUT="900"
QL_DEFAULT_MODEL="${QWEN38_MODEL:-Qwen3.8-27B-UD-Q6_K_XL-coding}"
QL_DEFAULT_EFFORT="medium"
QL_DEFAULT_TURNS="40"
QL_DEFAULT_WALL="15m"
QL_DEFAULT_BASE="http://127.0.0.1:8000/v1"
QL_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cleanup: paths are registered as they are created and removed once, on exit.
# Nothing is interpolated into trap source, so repository paths containing quotes
# or shell syntax are harmless.
QL_CLEANUP_PATHS=()

ql_cleanup() {
  local path
  for path in ${QL_CLEANUP_PATHS+"${QL_CLEANUP_PATHS[@]}"}; do
    [ -n "$path" ] && rm -rf "$path"
  done
}

ql_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
    "${BASH_SOURCE[0]}"
}

ql_valid_effort() {
  case "$1" in
    xhigh|medium|low) return 0 ;;
    *) return 1 ;;
  esac
}

# ql_extract_final_answer — prefer tribunal-style JSON result extraction;
# fall back to the raw stream tail when JSON is absent/unparseable.
ql_extract_final_answer() {
  local raw extracted
  raw="$(cat)"
  if command -v jq >/dev/null 2>&1; then
    extracted="$(printf '%s' "$raw" | jq -r '
      if type == "array" then
        (([ .[] | select(.type == "result") | .result // empty ] | last) as $r
          | if ($r != null and $r != "") then $r
            else ([ .[] | select(.type == "assistant")
                    | (.message.content // [])[]?
                    | select(.type == "text") | .text ] | join("")) end)
      elif type == "object" and has("response") then .response
      elif type == "object" and (.result? | type) == "string" then .result
      else empty end
    ' 2>/dev/null || true)"
    if [ -n "${extracted}" ]; then
      printf '%s\n' "$extracted"
      return 0
    fi
  fi
  printf '%s\n' "$raw"
}

# ql_is_coding_profile — served id must look like Qwen3.8-27B coding, not longctx.
ql_is_coding_profile() {
  local id="$1"
  case "$id" in
    *longctx*) return 1 ;;
  esac
  case "$id" in
    *Qwen3.8-27B*) ;;
    *) return 1 ;;
  esac
  case "$id" in
    *coding*) return 0 ;;
    *) return 1 ;;
  esac
}

# ql_pick_base — first reachable candidate base (llama.cpp usually runs on the
# container host, not in the container). Falls back to the default so the real
# preflight below prints the accurate error.
ql_pick_base() {
  local c gw probe code
  gw="$(ip route 2>/dev/null | awk '/^default/ { print $3; exit }' || true)"
  for c in "$QL_DEFAULT_BASE" \
    "${QL_DEFAULT_BASE/127.0.0.1/host.docker.internal}" \
    "${gw:+${QL_DEFAULT_BASE/127.0.0.1/$gw}}"; do
    [ -n "$c" ] || continue
    probe="$(curl -sS -m 3 -w '\n%{http_code}' "${c%/}/models" 2>/dev/null || true)"
    code="$(printf '%s' "$probe" | tail -n1)"
    # Accept a real models payload, and also a busy server: falling through to
    # another host would hide the fail-closed busy error from preflight.
    if { [ "$code" = "200" ] && printf '%s' "$probe" | grep -q '"id"'; } \
      || [ "$code" = "429" ] || [ "$code" = "503" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  printf '%s' "$QL_DEFAULT_BASE"
}

# ql_preflight_cli — qwen on PATH and recent enough for --yolo / --approval-mode.
ql_preflight_cli() {
  if ! command -v qwen >/dev/null 2>&1; then
    printf 'subagent-local-qwen3.8-27b-run: qwen CLI not found on PATH. install Qwen Code >= 0.23.4\n' >&2
    return 127
  fi
  local help
  help="$(qwen --help 2>&1 || true)"
  if ! printf '%s' "$help" | grep -qE -- '--yolo|--approval-mode'; then
    printf 'subagent-local-qwen3.8-27b-run: qwen --help missing --yolo/--approval-mode; install Qwen Code >= 0.23.4\n' >&2
    return 127
  fi
  return 0
}

# ql_preflight_models — GET $BASE/models; require coding-profile alias; fail busy/down.
ql_preflight_models() {
  local base="$1" want="$2"
  local url body http_code curl_rc
  url="${base%/}/models"

  if ! command -v curl >/dev/null 2>&1; then
    printf 'subagent-local-qwen3.8-27b-run: curl is required for llama.cpp preflight\n' >&2
    return 2
  fi

  set +e
  body="$(curl -sS -m 5 -w '\n%{http_code}' "$url" 2>/tmp/ql-curl-err.$$)"
  curl_rc=$?
  set -e
  if [ "$curl_rc" -ne 0 ]; then
    printf 'subagent-local-qwen3.8-27b-run: llama.cpp down or unreachable at %s (%s)\n' \
      "$url" "$(tr '\n' ' ' </tmp/ql-curl-err.$$ 2>/dev/null || true)" >&2
    rm -f /tmp/ql-curl-err.$$
    return 75
  fi
  rm -f /tmp/ql-curl-err.$$

  http_code="$(printf '%s' "$body" | tail -n1)"
  body="$(printf '%s' "$body" | sed '$d')"

  if printf '%s' "$body" | grep -qiE 'busy|overloaded|too many requests'; then
    printf 'subagent-local-qwen3.8-27b-run: llama.cpp busy (one in-flight request only); retry later\n' >&2
    return 75
  fi
  if [ "$http_code" = "503" ] || [ "$http_code" = "429" ]; then
    printf 'subagent-local-qwen3.8-27b-run: llama.cpp busy (HTTP %s); retry later\n' "$http_code" >&2
    return 75
  fi
  if [ "$http_code" != "200" ] && [ "$http_code" != "000" ]; then
    # Some servers omit a clean code in -w when body-only; still parse body.
    if ! printf '%s' "$body" | grep -q '"id"'; then
      printf 'subagent-local-qwen3.8-27b-run: llama.cpp models preflight failed (HTTP %s) at %s\n' \
        "$http_code" "$url" >&2
      # 5xx clears on a reload or restart; anything else is a misconfigured
      # endpoint that will not fix itself, so surface it instead of falling back
      # to another engine forever.
      case "$http_code" in
        5??) return 75 ;;
        *) return 1 ;;
      esac
    fi
  fi

  local ids
  if command -v jq >/dev/null 2>&1; then
    ids="$(printf '%s' "$body" | jq -r '.data[]?.id // empty' 2>/dev/null || true)"
  else
    ids="$(printf '%s' "$body" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
      | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  fi

  if [ -z "${ids}" ]; then
    printf 'subagent-local-qwen3.8-27b-run: llama.cpp returned no model ids from %s\n' "$url" >&2
    return 1
  fi

  local found="" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ "$id" = "$want" ]; then
      found="$id"
      break
    fi
  done <<< "$ids"

  if [ -z "$found" ]; then
    # Accept a served id that matches the coding profile when want is the default family.
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if ql_is_coding_profile "$id"; then
        found="$id"
        break
      fi
    done <<< "$ids"
  fi

  if [ -z "$found" ]; then
    printf 'subagent-local-qwen3.8-27b-run: wrong-model: need Qwen3.8-27B coding profile (got: %s)\n' \
      "$(printf '%s' "$ids" | tr '\n' ' ')" >&2
    return 1
  fi

  if ! ql_is_coding_profile "$found"; then
    printf 'subagent-local-qwen3.8-27b-run: wrong-model: refusing non-coding/longctx alias %s\n' "$found" >&2
    return 1
  fi

  if [ "$found" != "$want" ] && [ "$want" = "$QL_DEFAULT_MODEL" ]; then
    # Default request can follow the served coding alias.
    printf '%s' "$found"
    return 0
  fi

  if [ "$found" != "$want" ]; then
    # Explicit -m must be present exactly.
    local exact=0
    while IFS= read -r id; do
      [ "$id" = "$want" ] && exact=1 && break
    done <<< "$ids"
    if [ "$exact" -ne 1 ]; then
      printf 'subagent-local-qwen3.8-27b-run: wrong-model: requested %s not served (have: %s)\n' \
        "$want" "$(printf '%s' "$ids" | tr '\n' ' ')" >&2
      return 1
    fi
    if ! ql_is_coding_profile "$want"; then
      printf 'subagent-local-qwen3.8-27b-run: wrong-model: refusing non-coding/longctx alias %s\n' "$want" >&2
      return 1
    fi
    found="$want"
  fi

  printf '%s' "$found"
  return 0
}

ql_write_isolated_settings() {
  local home_dir="$1" model="$2" base="$3" effort="$4"
  mkdir -p "$home_dir/.qwen"
  cat > "$home_dir/.qwen/settings.json" <<EOF
{
  "security": {
    "auth": {
      "selectedType": "openai"
    }
  },
  "model": {
    "name": "$model"
  },
  "modelProviders": {
    "openai": [
      {
        "id": "$model",
        "name": "Local Qwen3.8-27B coding",
        "baseUrl": "$base",
        "envKey": "OPENAI_API_KEY",
        "generationConfig": {
          "timeout": 600000,
          "streamIdleTimeoutMs": 600000,
          "contextWindowSize": 65536,
          "samplingParams": {
            "temperature": 1.0,
            "top_p": 0.95,
            "top_k": 20,
            "reasoning_effort": "$effort"
          },
          "extra_body": {
            "chat_template_kwargs": {
              "enable_thinking": true,
              "preserve_thinking": true
            }
          }
        }
      }
    ]
  }
}
EOF
}

# ql_build_cmd — NUL-delimited argv stream. Prompt is never included (fed on stdin).
# Multi-line contracts must stay a single argv; never emit newline-separated argv.
ql_build_cmd() {
  local model="$1" approval_mode="$2" turns="$3" wall="$4" contract_text="$5"
  local extra_dir="${6:-}"
  printf '%s\0' qwen
  printf '%s\0' -m "$model"
  printf '%s\0' -o json
  printf '%s\0' --output-style Concise
  printf '%s\0' --exclude-tools agent
  printf '%s\0' --max-session-turns "$turns"
  printf '%s\0' --max-wall-time "$wall"
  printf '%s\0' --append-system-prompt "$contract_text"
  [ -n "$extra_dir" ] && printf '%s\0' --include-directories "$extra_dir"
  if [ "$approval_mode" = "plan" ]; then
    printf '%s\0' --approval-mode plan
  else
    printf '%s\0' --yolo
  fi
  # Empty -p: full user prompt arrives on stdin (appended by qwen).
  printf '%s\0' -p
  printf '%s\0' ""
}

# ql_print_cmd — one argv per line for --print-cmd; encode internal newlines as \n.
ql_print_cmd() {
  local arg
  while IFS= read -r -d '' arg; do
    printf '%s\n' "${arg//$'\n'/\\n}"
  done < <(ql_build_cmd "$@")
}

ql_main() {
  trap ql_cleanup EXIT
  local dir="$PWD" model="$QL_DEFAULT_MODEL" effort="$QL_DEFAULT_EFFORT"
  local timeout_secs="$QL_DEFAULT_TIMEOUT" prompt_file="" out="" print_cmd=0 print_base=0
  local turns="$QL_DEFAULT_TURNS" wall="$QL_DEFAULT_WALL"
  local approval_mode="yolo" prompt="" diff_base="" diff_file="" diff_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -C|--dir)             dir="$2"; shift 2 ;;
      -m|--model)           model="$2"; shift 2 ;;
      -e|--effort)          effort="$2"; shift 2 ;;
      -t|--timeout)         timeout_secs="$2"; shift 2 ;;
      --max-session-turns)  turns="$2"; shift 2 ;;
      --max-wall-time)      wall="$2"; shift 2 ;;
      --yolo)               approval_mode="yolo"; shift ;;
      --approval-mode)      approval_mode="$2"; shift 2 ;;
      -f|--prompt-file)     prompt_file="$2"; shift 2 ;;
      -d|--diff)            diff_base="$2"; shift 2 ;;
      -o|--out)             out="$2"; shift 2 ;;
      --print-cmd)          print_cmd=1; shift ;;
      --print-base)         print_base=1; shift ;;
      -h|--help)            ql_usage; return 0 ;;
      --)                   shift; break ;;
      -*)                   printf 'subagent-local-qwen3.8-27b-run: unknown option: %s\n' "$1" >&2; return 2 ;;
      *)                    break ;;
    esac
  done

  if [ "$print_base" -eq 1 ]; then
    if [ -n "${OPENAI_BASE_URL:-}" ]; then
      printf '%s\n' "$OPENAI_BASE_URL"
    else
      printf '%s\n' "$(ql_pick_base)"
    fi
    return 0
  fi

  ql_valid_effort "$effort" || {
    printf 'subagent-local-qwen3.8-27b-run: unsupported effort: %s (expected xhigh|medium|low; never high)\n' "$effort" >&2
    return 2
  }

  case "$approval_mode" in
    yolo|plan|default|auto-edit|auto) ;;
    *)
      printf 'subagent-local-qwen3.8-27b-run: unsupported approval-mode: %s\n' "$approval_mode" >&2
      return 2
      ;;
  esac

  local contract_file
  if [ "$approval_mode" = "plan" ]; then
    contract_file="$QL_PLUGIN_ROOT/references/review-contract.md"
  else
    contract_file="$QL_PLUGIN_ROOT/references/implement-contract.md"
  fi
  [ -r "$contract_file" ] || {
    printf 'subagent-local-qwen3.8-27b-run: missing contract: %s\n' "$contract_file" >&2
    return 2
  }
  local contract_text
  contract_text="$(cat "$contract_file")"

  if [ "$print_cmd" -eq 1 ]; then
    ql_print_cmd "$model" "$approval_mode" "$turns" "$wall" "$contract_text" "$diff_dir"
    return 0
  fi

  if [ -n "$prompt_file" ]; then
    [ -r "$prompt_file" ] || {
      printf 'subagent-local-qwen3.8-27b-run: cannot read prompt file: %s\n' "$prompt_file" >&2
      return 2
    }
    prompt="$(cat "$prompt_file")"
  elif [ $# -gt 0 ]; then
    prompt="$*"
  elif [ ! -t 0 ]; then
    prompt="$(cat)"
  fi

  if [ -z "${prompt//[[:space:]]/}" ]; then
    printf 'subagent-local-qwen3.8-27b-run: empty prompt (pass as argument, --prompt-file, or stdin)\n' >&2
    return 2
  fi

  if [ -n "$diff_base" ] && [ "$approval_mode" != "plan" ]; then
    printf 'subagent-local-qwen3.8-27b-run: --diff requires --approval-mode plan (implement mode has a shell and can run git itself)\n' >&2
    return 2
  fi

  [ -d "$dir" ] || {
    printf 'subagent-local-qwen3.8-27b-run: directory does not exist: %s\n' "$dir" >&2
    return 2
  }

  if [ -n "$diff_base" ]; then
    # The patch lives OUTSIDE the target repo and reaches the worker through
    # --include-directories, so no artifact can be staged, committed, or left
    # behind in the repo if this process is killed.
    diff_dir="$(mktemp -d -t qwen38-review.XXXXXX)"
    QL_CLEANUP_PATHS+=("$diff_dir")
    diff_file="$diff_dir/review.patch"
    local git_err
    git_err="$(mktemp -t qwen38-git-err.XXXXXX)"
    QL_CLEANUP_PATHS+=("$git_err")
    if ! git -C "$dir" --no-pager diff "$diff_base" > "$diff_file" 2>"$git_err"; then
      printf 'subagent-local-qwen3.8-27b-run: cannot diff %s in %s: %s\n' \
        "$diff_base" "$dir" "$(tr '\n' ' ' <"$git_err")" >&2
      return 2
    fi
    if [ ! -s "$diff_file" ]; then
      printf 'subagent-local-qwen3.8-27b-run: empty diff against %s — nothing to review\n' "$diff_base" >&2
      return 2
    fi
    prompt="The diff under review is in $diff_file. Read that file first, then open the files it touches in the repo.

$prompt"
  fi

  ql_preflight_cli || return $?

  local base served rc
  if [ -n "${OPENAI_BASE_URL:-}" ]; then
    base="$OPENAI_BASE_URL"
  else
    base="$(ql_pick_base)"
  fi
  set +e
  served="$(ql_preflight_models "$base" "$model")"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    if [ -z "${OPENAI_BASE_URL:-}" ]; then
      printf 'subagent-local-qwen3.8-27b-run: set OPENAI_BASE_URL to the llama.cpp endpoint (from a container the host is usually http://host.docker.internal:8000/v1)\n' >&2
    fi
    return "$rc"
  fi
  model="$served"

  local iso_home real_home
  real_home="$HOME"
  iso_home="$(mktemp -d -t qwen38-home.XXXXXX)"
  QL_CLEANUP_PATHS+=("$iso_home")
  ql_write_isolated_settings "$iso_home" "$model" "$base" "$effort"

  local log final errlog
  log="${out:-$(mktemp -t qwen38-run-log.XXXXXX)}"
  final="$(mktemp -t qwen38-run-final.XXXXXX)"
  errlog="${log}.stderr"
  QL_CLEANUP_PATHS+=("$final")
  : > "$log"
  : > "$errlog"

  local -a cmd=()
  while IFS= read -r -d '' arg; do cmd+=("$arg"); done < <(
    ql_build_cmd "$model" "$approval_mode" "$turns" "$wall" "$contract_text" "$diff_dir"
  )

  set +e
  (
    cd "$dir" || exit 2
    export HOME="$iso_home"
    # The isolated HOME also hides the ~/.local user-site directory, which breaks
    # the project's own test runner (pytest and friends). Keep user installs visible.
    export PYTHONUSERBASE="${PYTHONUSERBASE:-$real_home/.local}"
    export OPENAI_BASE_URL="$base"
    export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
    export OPENAI_MODEL="$model"
    export QWEN_CODE_SUPPRESS_YOLO_WARNING=1
    printf '%s' "$prompt" | timeout -k 10 "$timeout_secs" "${cmd[@]}"
  ) >"$log" 2>"$errlog"
  local rc=$?
  set -e

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
    cat >&2 <<EOF
subagent-local-qwen3.8-27b-run: TIMEOUT after ${timeout_secs}s (exit $rc). qwen was killed mid-task.
  Partial, UNCOMMITTED edits may be in the working tree. To recover:
    git -C "$dir" status
    git -C "$dir" checkout -- .
    # remove any newly-created files, then retry with a larger --timeout AND a
    # larger host Bash-tool timeout (ms >= inner timeout * 1000).
  Full log: $log (stderr: $errlog)
EOF
    return "$rc"
  fi

  # Prefer JSON result extraction; write to final for symmetry with codex-run.
  if ql_extract_final_answer < "$log" > "$final" && [ -s "$final" ]; then
    cat "$final"
  else
    cat "$log"
  fi

  printf 'subagent-local-qwen3.8-27b-run: exit %d, model=%s, approval=%s, full log: %s (stderr: %s)\n' \
    "$rc" "$model" "$approval_mode" "$log" "$errlog" >&2
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ql_main "$@"
fi
