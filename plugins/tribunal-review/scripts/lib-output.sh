#!/usr/bin/env bash
# Tribunal provider result extraction, error/diagnostic formatting, envelope emission,
# diff-stat/model stamping, and pinned-tree line_check validation.
# Sourced by scripts/lib.sh.

# Grok CLI envelope stop reason (camelCase preferred; snake_case accepted).
tribunal_grok_stop_reason() {
  jq -r '(.stopReason // .stop_reason // empty) | select(type == "string")' 2>/dev/null
}

tribunal_extract_claude_result() {
  jq -r '
    if (.structured_output? | type) == "object" then (.structured_output | tojson)
    elif (.result? | type) == "object" then (.result | tojson)
    elif (.result? | type) == "string" then .result
    else empty end
  ' 2>/dev/null
}

# Grok headless --output-format json uses camelCase (structuredOutput, sessionId).
# Accept snake_case too for forward compatibility.
tribunal_extract_grok_result() {
  jq -r '
    if (.structuredOutput? | type) == "object" then (.structuredOutput | tojson)
    elif (.structured_output? | type) == "object" then (.structured_output | tojson)
    elif (.text? | type) == "string" and (.text | length) > 0 then .text
    else empty end
  ' 2>/dev/null
}

tribunal_grok_session_id() {
  jq -r '
    (.sessionId // .session_id // empty)
    | select(type == "string" and length > 0)
  ' 2>/dev/null
}

tribunal_grok_new_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# True when extracted text contains a review envelope that satisfies the
# tribunal review contract (not merely any JSON object with a verdict string).
# Progress-only announcements, partial objects, and invalid verdicts fail.
tribunal_review_payload_complete() {
  local raw json
  raw="$(cat)"
  [ -n "$raw" ] || return 1
  json="$(printf '%s' "$raw" | tribunal_extract_json_object)"
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -e '
    (.findings | type) == "array"
    and (.summary | type) == "object"
    and (((.summary.verdict // "") | tostring | gsub("^\\s+|\\s+$"; "") | ascii_upcase)
        as $v | ($v == "APPROVE" or $v == "NEEDS_WORK" or $v == "BLOCK"))
    and ((.summary.total_findings // null) | type) == "number"
    and ((.summary.critical // null) | type) == "number"
    and ((.summary.high // null) | type) == "number"
    and ((.summary.medium // null) | type) == "number"
    and ((.summary.low // null) | type) == "number"
    and ((.summary.quality_score // null) | type) == "number"
  ' >/dev/null 2>&1
}

tribunal_json_string() {
  jq -Rn --arg v "$1" '$v'
}

tribunal_disabled() {
  local provider="$1" note="$2"
  jq -nc --arg p "$provider" --arg n "$note" '{provider:$p,status:"disabled",note:$n}'
}

tribunal_error() {
  local provider="$1" message="$2"
  jq -nc --arg p "$provider" --arg e "$message" '{provider:$p,error:$e}'
}

tribunal_error_with_diagnostics() {
  local provider="$1" message="$2" phase="$3" exit_code="$4"
  local stdout_file="$5" stderr_file="$6" max_bytes=2048
  # Missing artifact -> 0. Unreadable artifact -> null (unavailable, not empty) (#504).
  local stdout_bytes=0 stderr_bytes=0
  local stdout_tail="[omitted; set TRIBUNAL_DIAGNOSTIC_TAILS=on]"
  local stderr_tail="[omitted; set TRIBUNAL_DIAGNOSTIC_TAILS=on]"
  local stdout_truncated=false stderr_truncated=false
  [[ "$exit_code" =~ ^[0-9]+$ ]] || exit_code=255
  # The collector replaces a plan-limited leg with a backup leg (TRIBUNAL_BACKUP_LEGS).
  [ "$exit_code" != 153 ] || message="file size limit (SIGXFSZ): $message"
  # DeepSeek classifies its structured error causes in its runner.
  if [ "$provider" != deepseek ] && [ "$phase" = execution ] && tribunal_plan_limited "$exit_code" "$stdout_file" "$stderr_file"; then
    message="plan limit: $message"
  fi
  if [ -f "$stdout_file" ] && [ ! -L "$stdout_file" ]; then
    # Unreadable is unavailable (null), not empty (0). Probe -r before wc so a
    # failed redirect cannot empty --argjson and erase the failure record (#504).
    if [ -r "$stdout_file" ] \
      && stdout_bytes="$(wc -c < "$stdout_file" | tr -d ' ')" \
      && [[ "$stdout_bytes" =~ ^[0-9]+$ ]]; then
      if [ "${TRIBUNAL_DIAGNOSTIC_TAILS:-off}" = on ]; then
        stdout_tail="$(tail -c "$max_bytes" -- "$stdout_file" 2>/dev/null \
          | LC_ALL=C tr -cd '\11\12\15\40-\176')"
      fi
      [ "$stdout_bytes" -le "$max_bytes" ] || stdout_truncated=true
    else
      stdout_bytes=null
    fi
  fi
  if [ -f "$stderr_file" ] && [ ! -L "$stderr_file" ]; then
    if [ -r "$stderr_file" ] \
      && stderr_bytes="$(wc -c < "$stderr_file" | tr -d ' ')" \
      && [[ "$stderr_bytes" =~ ^[0-9]+$ ]]; then
      if [ "${TRIBUNAL_DIAGNOSTIC_TAILS:-off}" = on ]; then
        stderr_tail="$(tail -c "$max_bytes" -- "$stderr_file" 2>/dev/null \
          | LC_ALL=C tr -cd '\11\12\15\40-\176')"
      fi
      [ "$stderr_bytes" -le "$max_bytes" ] || stderr_truncated=true
    else
      stderr_bytes=null
    fi
  fi
  jq -nc --arg p "$provider" --arg message "$message" --arg phase "$phase" \
    --argjson exit "$exit_code" --argjson stdout_bytes "$stdout_bytes" \
    --argjson stderr_bytes "$stderr_bytes" --argjson stdout_truncated "$stdout_truncated" \
    --argjson stderr_truncated "$stderr_truncated" --arg stdout_tail "$stdout_tail" \
    --arg stderr_tail "$stderr_tail" '
      {provider:$p,error:($message
        + "; phase=" + $phase + "; exit=" + ($exit|tostring)
        + "; stdout_bytes=" + ($stdout_bytes|tostring)
        + "; stdout_truncated=" + ($stdout_truncated|tostring)
        + "; stdout_tail=" + ($stdout_tail|@json)
        + "; stderr_bytes=" + ($stderr_bytes|tostring)
        + "; stderr_truncated=" + ($stderr_truncated|tostring)
        + "; stderr_tail=" + ($stderr_tail|@json))}'
}

tribunal_review_error() {
  local provider="$1" message="$2" phase="$3"
  local stdout_file="${4:-}" stderr_file="${5:-}" exit_code="${6:-0}"
  if [ -n "$stdout_file" ] && [ -n "$stderr_file" ]; then
    tribunal_error_with_diagnostics "$provider" "$message" "$phase" "$exit_code" \
      "$stdout_file" "$stderr_file"
  else
    tribunal_error "$provider" "$message"
  fi
}

# $4 is the range `tribunal_prepare_diff` pinned, taken by the runner. The
# emptiness re-verification and the stamp both use it, so this path cannot claim
# a range that differs from the one the diff was captured over (issue #487).
tribunal_empty() {
  local provider="$1" model="${2:-default}" base_ref="${3:-}" stat="${4:-}"
  local base_oid head_oid diff_rc
  base_oid="$(printf '%s' "$stat" | jq -r '.base_oid // empty' 2>/dev/null)"
  head_oid="$(printf '%s' "$stat" | jq -r '.head_oid // empty' 2>/dev/null)"
  if [ -z "$base_oid" ] || [ -z "$head_oid" ]; then
    tribunal_error "$provider" \
      "staged diff is empty or missing and cannot be verified: the reviewed range was not captured (base ref $base_ref)"
    return
  fi
  git diff --quiet "$base_oid...$head_oid" --no-ext-diff --no-textconv \
    && diff_rc=0 || diff_rc=$?
  if [ "$diff_rc" -eq 1 ]; then
    tribunal_error "$provider" \
      "staged diff is empty or missing for resolved base ref $base_ref: base=$base_oid head=$head_oid; a non-empty diff exists"
    return
  fi
  if [ "$diff_rc" -ne 0 ]; then
    tribunal_error "$provider" \
      "staged diff is empty or missing and verification failed for resolved base ref $base_ref: base=$base_oid head=$head_oid; git diff exited $diff_rc"
    return
  fi
  jq -nc --arg p "$provider" --arg m "$model" --arg b "$base_ref" \
    --arg base_oid "$base_oid" --arg head_oid "$head_oid" \
    '{provider:$p,model:$m,findings:[],files_examined:[],summary:{total_findings:0,critical:0,high:0,medium:0,low:0,quality_score:10.0,verdict:"APPROVE",note:("No changes detected vs " + $b)},
      diff_stat:{files_changed:0,insertions:0,deletions:0,base:$b,base_oid:$base_oid,head_oid:$head_oid,truncated:false}}'
}

# stdin: emitted review JSON. Records NOTE in summary.note; error objects pass through.
tribunal_stamp_note() {  # tribunal_stamp_note NOTE
  if [ -z "${1:-}" ]; then cat; return; fi
  jq -c --arg note "$1" 'if (.summary | type) == "object" then .summary.note = $note else . end'
}

# Validate one leg's extracted review JSON (read from stdin) and emit it, or
# emit a provider error. A blocking verdict (BLOCK/NEEDS_WORK) with zero findings
# is self-contradictory: per the arbitration contract a blocking verdict must be
# backed by a proven finding, so an empty one means the provider was blind to the
# code (sandboxed/degraded), not that the change is truly blocked. Counting it as
# a real review silently drops the provider from the panel (issue #171).
# $1 provider  $2 optional hint appended to the vacuous-verdict error message.
# $3/$4 optional captured stdout/stderr paths; $5 optional wrapper exit code.
tribunal_emit_review() {
  local provider="$1" hint="${2:-}" stdout_file="${3:-}" stderr_file="${4:-}"
  local exit_code="${5:-0}" json verdict parse_error
  json="$(cat)"
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    if [ -z "$json" ]; then
      parse_error="unparseable $provider output: no review JSON object found"
    else
      parse_error="unparseable $provider output: extracted review JSON is malformed"
    fi
    tribunal_review_error "$provider" "$parse_error" parse \
      "$stdout_file" "$stderr_file" "$exit_code"
    return
  fi
  if printf '%s' "$json" | jq -e '
      (((.findings // []) | length) == 0)
      and (((.summary.verdict // "APPROVE") | tostring | gsub("^\\s+|\\s+$"; "") | ascii_upcase) as $v
           | ($v == "BLOCK" or $v == "NEEDS_WORK"))
    ' >/dev/null 2>&1; then
    verdict="$(printf '%s' "$json" | jq -r '.summary.verdict // "?"')"
    tribunal_review_error "$provider" \
      "vacuous verdict ($verdict with 0 findings): a blocking verdict must carry a finding; provider likely blind to the repo (sandbox/degraded), excluded from quorum${hint:+ — $hint}" \
      schema "$stdout_file" "$stderr_file" "$exit_code"
    return
  fi
  if ! printf '%s' "$json" | jq -e '(.findings | type) == "array" and (.summary | type) == "object"' >/dev/null 2>&1; then
    tribunal_review_error "$provider" "provider output omitted the review findings/summary envelope" \
      schema "$stdout_file" "$stderr_file" "$exit_code"
    return
  fi
  # Provider identity belongs to the wrapper, not model-authored JSON. The
  # aggregate evidence runner relies on this assignment when it seals each leg.
  printf '%s\n' "$json" | jq -c --arg provider "$provider" '.provider = $provider | del(.status, .error, .diff_stat, .grok_execution)'
}

# Stamp a wrapper-resolved model only when it belongs to the requested provider
# family. A missing resolved model is not evidence of substitution, but the
# model-authored value remains untrusted.
# $1 provider  $2 resolved model (empty when unavailable)  $3/$4 captured
# stdout/stderr paths  $5 wrapper exit code. stdin: emitted review JSON.
tribunal_stamp_executed_model() {
  local provider="$1" model="$2" stdout_file="${3:-}" stderr_file="${4:-}"
  local exit_code="${5:-0}" json family
  json="$(cat)"
  if printf '%s' "$json" | jq -e 'has("error") or (.status? == "disabled")' >/dev/null 2>&1; then
    printf '%s\n' "$json"
    return
  fi
  if [ -z "$model" ]; then
    printf '%s' "$json" | jq -c '.model = "unverified"'
    return
  fi
  case "$provider" in
    grok) family='^grok([[:digit:]._-]|$)' ;;
    muse) family='^muse([[:digit:]._-]|$)' ;;
    qwen) family='^([[:alnum:]_.-]+/)?qwen([[:digit:]._-]|$)' ;;
    *) family='' ;;
  esac
  if [ -n "$family" ] && ! [[ "${model,,}" =~ $family ]]; then
    tribunal_review_error "$provider" \
      "executed model family mismatch: requested provider $provider, but executed model $model" \
      model_family "$stdout_file" "$stderr_file" "$exit_code"
    return
  fi
  printf '%s' "$json" | jq -c --arg model "$model" '.model = $model'
}

# Stamp the reviewed range onto a review leg, from the diff_stat that
# `tribunal_prepare_diff` pinned when it captured the diff. The provider output
# schema forbids this field and `tribunal_emit_review` strips any model-authored
# one, so only a runner script can produce it: a leg fabricated by a wrapper
# agent, or one whose runner never executed, is missing it and is rejected
# downstream instead of counting as a clean pass (issue #487).
# Also enforces files_examined (issue #518): missing/malformed lists, or an
# empty-findings APPROVE whose list intersects none of the paths changed in
# base_oid...head_oid, become provider errors excluded from quorum. A genuine
# empty range (diff_stat.files_changed==0, as from tribunal_empty) is exempt.
# Every examined path must also exist in a pinned base, head, or merge-base
# tree, with or without findings (issue #671); unavailable trees fail closed.
# $1 pinned range from `tribunal_take_diff_stat`
# stdin: one leg JSON object  stdout: same object with .diff_stat
tribunal_stamp_diff_stat() {
  local stat="$1" json provider root base_oid head_oid merge_base_oid files_changed tmpdir range absent input_dir
  json="$(cat)"
  # Error and disabled legs carry no diff_stat.
  if printf '%s' "$json" | jq -e 'has("error") or (.status? == "disabled")' >/dev/null 2>&1; then
    printf '%s\n' "$json"
    return
  fi
  provider="$(printf '%s' "$json" | jq -r '.provider // "provider"')"
  if ! printf '%s' "$stat" | jq -e . >/dev/null 2>&1; then
    tribunal_error "$provider" "the reviewed range was not captured; leg cannot be stamped"
    return
  fi
  if ! printf '%s' "$json" | jq -e '
      (.files_examined | type) == "array"
      and all(.files_examined[]; type == "string" and length > 0)
    ' >/dev/null 2>&1; then
    tribunal_error "$provider" \
      "files_examined missing or not an array of non-empty strings; excluded from quorum"
    return
  fi
  # Drop the runner's own scratch inputs before the pinned-tree existence check (issue #743).
  input_dir="${TRIBUNAL_REVIEW_INPUT_DIR:-}"
  input_dir="${input_dir%/}"
  if [ -n "$input_dir" ] && [ "$input_dir" != "/" ]; then
    json="$(printf '%s' "$json" | jq -c --arg dir "$input_dir" '
      .files_examined |= map(
        select(
          . as $p
          | ($p == $dir or (
              ($p | startswith($dir + "/"))
              and (($p[($dir | length) + 1:] | split("/") | index("..")) | not)
            ) | not)
        )
      )')" || {
      tribunal_error "$provider" \
        "cannot verify files_examined against the pinned trees; excluded from quorum"
      return
    }
  fi
  files_changed="$(printf '%s' "$stat" | jq -r '.files_changed // empty')"
  # Empty-range exemption: tribunal_empty synthesizes APPROVE with files_examined:[].
  if [ "$files_changed" != "0" ]; then
    if ! range="$(printf '%s' "$stat" | jq -er '
        [.base_oid, .head_oid] |
        select(all(.[]; type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$"))) |
        join(" ")' 2>/dev/null)" || ! root="$(tribunal_repo_root)"; then
      tribunal_error "$provider" \
        "cannot verify files_examined: pinned base/head objects unavailable; excluded from quorum"
      return
    fi
    read -r base_oid head_oid <<< "$range"
    if ! merge_base_oid="$(git -C "$root" merge-base "$base_oid" "$head_oid" 2>/dev/null)" \
      || [ -z "$merge_base_oid" ]; then
      tribunal_error "$provider" \
        "cannot verify files_examined: pinned merge-base unavailable; excluded from quorum"
      return
    fi
    # Path lists travel via temp files, not argv: large lists exceed
    # MAX_ARG_STRLEN when passed as --argjson.
    tmpdir="$(mktemp -d)" || {
      tribunal_error "$provider" \
        "cannot verify files_examined against the pinned trees; excluded from quorum"
      return
    }
    # Query exact JSON path bytes instead of decoding a tree listing (invalid
    # UTF-8 filenames would otherwise alias U+FFFD). cat-file -Z preserves
    # embedded newlines in both requests and responses. Check all three roots first.
    if ! printf '%s' "$json" | jq '[.files_examined[] | sub("^(\\./)+"; "")]' > "$tmpdir/paths" \
      || ! jq -j --arg base "$base_oid" --arg head "$head_oid" --arg mb "$merge_base_oid" '
        ($base + "^{tree}\u0000"), ($head + "^{tree}\u0000"), ($mb + "^{tree}\u0000"),
        (.[] | if contains("\u0000") then error("NUL in examined path")
          else ($base + ":" + . + "\u0000"), ($head + ":" + . + "\u0000"),
            ($mb + ":" + . + "\u0000") end)
      ' "$tmpdir/paths" > "$tmpdir/requests" 2>/dev/null \
      || ! git -C "$root" cat-file --batch-check='%(objectname)' -Z \
        < "$tmpdir/requests" > "$tmpdir/objects" 2>/dev/null; then
      rm -rf "$tmpdir"
      tribunal_error "$provider" \
        "cannot verify files_examined: pinned base/head objects unavailable; excluded from quorum"
      return
    fi
    if ! absent="$(jq -c --rawfile objects "$tmpdir/objects" '
        def oid: test("^([0-9a-f]{40}|[0-9a-f]{64})$");
        . as $paths | ($objects | split("\u0000")) as $results |
        if ($results | length) != (4 + 3 * ($paths | length))
          or $results[-1] != "" or ($results[0] | oid | not) or ($results[1] | oid | not)
          or ($results[2] | oid | not)
        then error("pinned objects unavailable or incomplete batch response") else
          [range($paths | length) | . as $i |
            select($paths[$i] == "" or
              (($results[3 + 3*$i] | oid | not) and ($results[4 + 3*$i] | oid | not)
              and ($results[5 + 3*$i] | oid | not))) |
            $paths[$i]][:3] |
          map(if length > 200 then .[:200] + "..." else . end)
        end
      ' "$tmpdir/paths" 2>/dev/null)"; then
      rm -rf "$tmpdir"
      tribunal_error "$provider" \
        "cannot verify files_examined against the pinned trees; excluded from quorum"
      return
    fi
    if [ "$absent" != "[]" ]; then
      rm -rf "$tmpdir"
      tribunal_error "$provider" \
        "files_examined paths absent from pinned base/head/merge-base trees (first 3, capped at 200 characters each): $absent; excluded from quorum"
      return
    fi
    if printf '%s' "$json" | jq -e '((.findings // []) | length) == 0' >/dev/null 2>&1; then
      if ! git -C "$root" diff --name-only --no-renames -z "$base_oid...$head_oid" \
            --no-ext-diff --no-textconv > "$tmpdir/changed" 2>/dev/null; then
        rm -rf "$tmpdir"
        tribunal_error "$provider" \
          "blind APPROVE: cannot verify files_examined against the reviewed range; excluded from quorum"
        return
      fi
      if ! printf '%s' "$json" | jq -e --rawfile changed_raw "$tmpdir/changed" '
          ($changed_raw | split("\u0000") | map(select(length > 0))) as $changed |
          (.files_examined | any((sub("^(\\./)+"; "")) as $f | $changed | index($f) != null))
        ' >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        tribunal_error "$provider" \
          "blind APPROVE: findings empty and files_examined lists no path changed in the reviewed range; excluded from quorum"
        return
      fi
    fi
    rm -rf "$tmpdir"
  fi
  printf '%s' "$json" | jq -c --argjson stat "$stat" '.diff_stat = $stat'
}

# Mark findings whose position cannot exist: a missing/mistyped file field, a
# file outside the reviewed change set, a non-positive/non-integer line, a
# line beyond the target file's length at the pinned head, or a positioned finding
# in a file missing at that head. Providers sometimes emit
# unified-diff/prompt-global positions instead of target-file line numbers
# (issue #259); marked findings still flow to the arbiter, but the evidence
# defect is explicit instead of silent. Paths travel NUL-delimited and the
# lookup tables travel via a temp file, so C-quoted/unusual filenames and
# argv size limits cannot corrupt or abort the check.
# $1 repo root  $2 pinned range from `tribunal_take_diff_stat`
# stdin: one leg JSON object  stdout: same object with line_check marks
tribunal_line_check() {
  local root="$1" stat="$2" json range base_oid head_oid aux f n
  json="$(cat)"
  if ! printf '%s' "$json" | jq -e '(.findings? | type) == "array"' >/dev/null 2>&1; then
    printf '%s\n' "$json"
    return
  fi
  # Missing provenance is handled by tribunal_stamp_diff_stat later in the pipe.
  if ! range="$(printf '%s' "$stat" | jq -er '
    [.base_oid, .head_oid] |
    select(all(.[]; type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$"))) |
    join(" ")' 2>/dev/null)"; then
    printf '%s\n' "$json"
    return
  fi
  read -r base_oid head_oid <<< "$range"
  aux="$(mktemp)"
  # Rebuild after the provider returns; no writable capture-time path list survives.
  if ! git -C "$root" diff --name-only -z "$base_oid...$head_oid" --no-ext-diff --no-textconv \
    > "$aux.changed" 2>/dev/null; then
    rm -f "$aux" "$aux.changed"
    printf '%s' "$json" | jq -c '.findings |= map(
      if type != "object" then .
      elif (.file | type) != "string" then .line_check = "malformed finding coordinates"
      elif has("file") or has("line") then .line_check = "position check unavailable"
      else . end)'
    return
  fi
  {
    jq -Rs 'split("\u0000") | map(select(length > 0))' < "$aux.changed"
    printf '%s' "$json" | jq -j '[.findings[]?.file? | strings] | unique | map(. + "\u0000") | join("")' \
      | while IFS= read -r -d '' f; do
          case "$f" in /*) continue ;; esac
          case "/$f/" in */../*) continue ;; esac
          if git -C "$root" cat-file -e "$head_oid:$f" 2>/dev/null; then
            n="$(git -C "$root" cat-file -p "$head_oid:$f" 2>/dev/null | grep -c '')" || n=0
          else
            n=-1
          fi
          jq -cn --arg f "$f" --argjson n "$n" '{($f): $n}'
        done | jq -s 'add // {}'
  } | jq -cs '{changed: .[0], counts: (.[1] // {})}' > "$aux"
  printf '%s' "$json" | jq -c --slurpfile aux "$aux" '
    $aux[0].changed as $changed | $aux[0].counts as $counts |
    .findings = [ .findings[] | . as $f |
      if (type != "object") then .
      elif (($f.file? | type) != "string") then
        .line_check = "malformed finding coordinates"
      elif (($changed | length) > 0) and (($changed | index($f.file)) == null) then
        .line_check = "file not in reviewed diff"
      elif ($f.line? == null) then .
      elif (($f.line | type) != "number") or ($f.line < 1) or ($f.line != ($f.line | floor)) then
        .line_check = "invalid line number"
      elif ($counts[$f.file] == -1) then
        .line_check = "file missing at reviewed head"
      elif ($counts[$f.file] != null) and ($f.line > $counts[$f.file]) then
        .line_check = ("line out of bounds: file has " + ($counts[$f.file] | tostring) + " lines")
      else . end ]'
  rm -f "$aux" "$aux.changed"
}

tribunal_extract_json_object() {
  sed 's/^```json//;s/^```//' | awk '
    BEGIN { seen=0 }
    /\{/ { seen=1 }
    seen { print }
  ' | sed -n 'H;${x;s/^[^{]*//;s/[^}]*$//;p;}'
}
