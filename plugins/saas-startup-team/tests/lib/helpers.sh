#!/usr/bin/env bash
# Shared assertion and fixture helpers for saas-startup-team tests.
# Sourced by tests/run-tests.sh (and standalone case files if invoked directly).

if [ -n "${SST_TEST_HELPERS_LOADED:-}" ]; then
  return 0
fi
SST_TEST_HELPERS_LOADED=1

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PASS_COUNT=${PASS_COUNT:-0}
FAIL_COUNT=0
TOTAL_COUNT=0
FAILURES=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

assert_exit_code() {
  local label="$1" actual="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$actual" -eq "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (expected exit $expected, got $actual)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected exit $expected, got $actual")
  fi
}

assert_output_contains() {
  local label="$1" output="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -qF -- "$expected" <<< "$output"; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (output missing: '$expected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: output missing '$expected'")
  fi
}

assert_output_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -qF -- "$unexpected" <<< "$output"; then
    echo -e "  ${RED}FAIL${NC} $label (output unexpectedly contains: '$unexpected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: output unexpectedly contains '$unexpected'")
  else
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -e "$path" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (file not found: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: file not found $path")
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ ! -e "$path" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (file unexpectedly exists: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$label: file exists $path")
  fi
}

assert_file_contains() {
  local label="$1" path="$2" pattern="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -q -- "$pattern" "$path" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label ($path missing pattern: $pattern)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: $path missing pattern '$pattern'")
  fi
}

assert_file_not_contains() {
  local label="$1" path="$2" unexpected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if grep -qF "$unexpected" "$path" 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC} $label (file unexpectedly contains: '$unexpected')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: file unexpectedly contains '$unexpected'")
  else
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (expected '$expected', got '$actual')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected '$expected', got '$actual'")
  fi
}

assert_json_valid() {
  local label="$1" path="$2"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if jq empty "$path" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (invalid JSON: $path)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: invalid JSON $path")
  fi
}

assert_json_field() {
  local label="$1" path="$2" field="$3" expected="$4"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  local actual
  actual=$(jq -r "$field" "$path" 2>/dev/null || echo "__JQ_ERROR__")
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label (expected '$expected', got '$actual')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$label: expected '$expected', got '$actual'")
  fi
}

# ---------------------------------------------------------------------------
# Helpers: exact lease fingerprints and temporary .startup/ fixtures
# ---------------------------------------------------------------------------

lease_state_fingerprint() {
  local state_file=$1 rows kind key state_dir owner_file slug artifact fingerprint rc=0
  rows=$(mktemp) || return 1
  if ! jq -er '.leases[] | [.kind,.key,.state_dir,.owner_file] | @tsv' \
    "$state_file" > "$rows"; then
    rm -f -- "$rows"
    return 1
  fi
  fingerprint=$(
    while IFS=$'\t' read -r kind key state_dir owner_file; do
      slug=$(printf '%s' "$key" | tr '/: ' '---' | tr -cd 'A-Za-z0-9._-')
      [ -n "$slug" ] || slug=lease
      for artifact in "$state_dir/$slug/heartbeat" "$state_dir/$slug/key" \
        "$state_dir/$slug/owner" "$state_dir/$slug/audit.log" \
        "$owner_file" "${owner_file}.key"; do
        [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 1
        stat -c '%n\t%i\t%s\t%y\t%z' -- "$artifact"
        sha256sum -- "$artifact"
      done
    done < "$rows" | LC_ALL=C sort | sha256sum | awk '{print $1}'
  ) || rc=$?
  rm -f -- "$rows"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$fingerprint"
}

make_workdir() {
  local tmpdir
  tmpdir=$(mktemp -d)
  git init -q "$tmpdir"
  echo "$tmpdir"
}

lint_sourced_suite_prints() {
  local target="$1" suite failed=0

  while IFS= read -r -d '' suite; do
    if grep -Eq '(echo|printf).*\$\{(GREEN|RED)\}(PASS|FAIL)' "$suite" && ! grep -qF 'TOTAL_COUNT' "$suite"; then
      echo "SOURCED SUITE PRINT LINT: $suite prints PASS/FAIL without TOTAL_COUNT" >&2
      failed=1
    fi
  done < <(
    if [ -f "$target" ]; then
      printf '%s\0' "$target"
    else
      find "$target" -type f -name '*.tests.sh' -print0
    fi | sort -z
  )

  return "$failed"
}

setup_startup_dir() {
  local workdir="$1" iteration="${2:-1}"
  mkdir -p "$workdir/docs"
  mkdir -p "$workdir/.startup/handoffs"
  mkdir -p "$workdir/.startup/docs"
  mkdir -p "$workdir/.startup/signoffs"
  mkdir -p "$workdir/.startup/reviews"
  mkdir -p "$workdir/.startup/go-live"
  cat > "$workdir/.startup/state.json" <<EOF
{
  "iteration": $iteration,
  "max_iterations": 20,
  "phase": "implementation",
  "active_role": "tech-founder",
  "status": "active",
  "started": "2026-02-23T10:00:00Z"
}
EOF
}

# Run a script in a workdir, capturing exit code and output
run_in_dir() {
  local workdir="$1" script="$2" stdin_data="${3:-}"
  local exit_code=0
  local output
  output=$(cd "$workdir" && echo "$stdin_data" | bash "$script" 2>&1) || exit_code=$?
  echo "$output"
  return $exit_code
}

# ---------------------------------------------------------------------------
# Suite P: compact-state.sh
# ---------------------------------------------------------------------------

# Helper: seed state.json with N handoff keys (ready + scope each).
seed_handoffs() {
  local state_file="$1" count="$2"
  local builder='.'
  local i padded
  for i in $(seq 1 "$count"); do
    padded=$(printf '%03d' "$i")
    builder="$builder + {\"handoff_${padded}_ready\": \"2026-02-01T10:00:00Z\", \"handoff_${padded}_scope\": \"Test scope $i\"}"
  done
  jq "$builder" "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
}
# Extract the first ```bash fenced block within a "## <heading>" section of a
# markdown command file.
extract_md_bash() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    $0 == h { inseg=1; next }
    inseg && /^## / { inseg=0 }
    inseg && /^```bash$/ && !done { cap=1; next }
    cap && /^```$/ { done=1; cap=0; next }
    cap { print }
  ' "$file"
}

# Mock `gh` under $1/bin. Logs argv (one line/call) to $GH_CALLS_LOG. Env knobs:
#   GH_CREATE_NUMBER  number echoed (as URL) by `gh issue create`
#   GH_VIEW_STATE     value for `gh issue view --json state` (OPEN/CLOSED)
#   GH_VIEW_BODY      value for `gh issue view --json body`   (recovery verification)
#   GH_SEARCH_JSON    JSON for `gh issue list ... --json number` (default [])
#   GH_API_JSON       paginated `gh api` JSON (default `[[]]`)
#   GH_FAIL_ON        if argv contains this substring, exit 1 (simulate gh failure)
make_mock_gh() {
  local bindir="$1/bin"
  local view_store="$1/.gh-view.json"
  mkdir -p "$bindir"
  if [ -n "${GH_VIEW_JSON:-}" ]; then
    printf '%s
' "$GH_VIEW_JSON" > "$view_store"
  else
    rm -f -- "$view_store"
  fi
  # Quoted heredoc keeps the mock body literal; only view_store path is injected.
  cat > "$bindir/gh" <<MOCK
#!/usr/bin/env bash
_args="\$*"; printf '%s
' "\${_args//\$'
'/ }" >> "\${GH_CALLS_LOG:?}"
if [ -n "\${GH_FAIL_ON:-}" ] && [[ "\$*" == *"\$GH_FAIL_ON"* ]]; then
  echo "mock gh: forced failure" >&2; exit 1
fi
_VIEW_STORE="$view_store"
_seed_view() {
  if [ ! -f "\$_VIEW_STORE" ] && [ -n "\${GH_VIEW_JSON:-}" ]; then
    printf '%s
' "\$GH_VIEW_JSON" > "\$_VIEW_STORE"
  fi
}
case "\$1 \$2" in
  "api --paginate") echo "\${GH_API_JSON:-[[]]}" ;;
  "repo view")   echo "\${GH_REPO:-o/r}" ;;
  "issue create") echo "https://github.com/o/r/issues/\${GH_CREATE_NUMBER:?GH_CREATE_NUMBER unset}" ;;
  "issue comment") echo "https://github.com/o/r/issues/commented" ;;
  "issue view")
     # Mutable store / GH_VIEW_JSON for claim re-reads; otherwise keep legacy
     # plain GH_VIEW_STATE / GH_VIEW_BODY responses used by monitor-dedup.
     if [ -f "\$_VIEW_STORE" ] || [ -n "\${GH_VIEW_JSON:-}" ]; then
       if [[ "\$*" == *"--json"* ]]; then
         _seed_view
         if [ -f "\$_VIEW_STORE" ]; then cat "\$_VIEW_STORE"; else echo "\$GH_VIEW_JSON"; fi
       elif [[ "\$*" == *"body"* ]]; then echo "\${GH_VIEW_BODY:-}"
       else echo "\${GH_VIEW_STATE:-OPEN}"; fi
     elif [[ "\$*" == *"body"* ]]; then echo "\${GH_VIEW_BODY:-}"
     else echo "\${GH_VIEW_STATE:-OPEN}"; fi ;;
  "issue list")
     if [[ "\$*" == *"--state all"* ]] && [ -n "\${GH_ALL_ISSUES_JSON:-}" ]; then
       echo "\$GH_ALL_ISSUES_JSON"
     else
       echo "\${GH_LIST_JSON:-\${GH_SEARCH_JSON:-[]}}"
     fi ;;
  "issue edit")
     _seed_view
     if [ -f "\$_VIEW_STORE" ]; then
       _cur="\$(cat "\$_VIEW_STORE")"
       _i=1
       while [ "\$_i" -le "\$#" ]; do
         _a="\${!_i}"
         if [ "\$_a" = "--add-label" ]; then
           _i=\$((_i + 1)); _lab="\${!_i}"
           _cur="\$(printf '%s' "\$_cur" | jq -c --arg l "\$_lab" '.labels = ((.labels // []) + [{name:\$l}] | group_by(.name) | map(.[0]))')"
         elif [ "\$_a" = "--remove-label" ]; then
           _i=\$((_i + 1)); _lab="\${!_i}"
           _cur="\$(printf '%s' "\$_cur" | jq -c --arg l "\$_lab" '.labels = [((.labels // [])[]) | select(.name != \$l)]')"
         fi
         _i=\$((_i + 1))
       done
       printf '%s
' "\$_cur" > "\$_VIEW_STORE"
     fi
     ;;
  "issue close") : ;;
  "label create") : ;;
  "pr create")   echo "https://github.com/o/r/pull/\${GH_PR_NUMBER:-999}" ;;
  "pr merge")    : ;;
  "pr list")     echo "\${GH_PR_LIST_JSON:-[]}" ;;
  "pr view")     echo "\${GH_PR_VIEW_JSON:-{}}" ;;
  *) : ;;
esac
MOCK
  chmod +x "$bindir/gh"
}
