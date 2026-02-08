#!/usr/bin/env bash
# agent-sync: Generate AGENTS.md from Claude Code project configuration
# Dependencies: bash 4+, jq, awk, sed

set -euo pipefail

# --- Defaults ---
CHECK_MODE=false
CONFIG_PATH=""
REPO_ROOT=""

# --- CLI parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_MODE=true
      shift
      ;;
    --config)
      if [[ -z "${2:-}" ]]; then
        echo "[agent-sync] --config requires a path" >&2
        exit 1
      fi
      CONFIG_PATH="$2"
      shift 2
      ;;
    --root)
      if [[ -z "${2:-}" ]]; then
        echo "[agent-sync] --root requires a path" >&2
        exit 1
      fi
      REPO_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: generate.sh [--check] [--config <path>] [--root <path>]"
      echo ""
      echo "  --check          Verify AGENTS.md is in sync (exit 1 if drift)"
      echo "  --config <path>  Path to sources.json (default: auto-detect)"
      echo "  --root <path>    Project root directory (default: parent of config dir)"
      echo ""
      echo "Auto-detection searches for:"
      echo "  tools/agent-sync/sources.json"
      echo "  .agent-sync/sources.json"
      exit 0
      ;;
    *)
      echo "[agent-sync] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# --- Locate config ---
find_config() {
  local search_dir="${1:-.}"
  for candidate in "tools/agent-sync/sources.json" ".agent-sync/sources.json"; do
    if [[ -f "$search_dir/$candidate" ]]; then
      echo "$search_dir/$candidate"
      return 0
    fi
  done
  return 1
}

if [[ -z "$CONFIG_PATH" ]]; then
  if ! CONFIG_PATH="$(find_config "$(pwd)")"; then
    echo "[agent-sync] No sources.json found. Run /agent-sync:init to create one." >&2
    exit 1
  fi
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "[agent-sync] Config not found: $CONFIG_PATH" >&2
  exit 1
fi

CONFIG_PATH="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"

if [[ -z "$REPO_ROOT" ]]; then
  config_dir="$(dirname "$CONFIG_PATH")"
  parent_dir="$(dirname "$config_dir")"
  dir_name="$(basename "$config_dir")"
  if [[ "$dir_name" == "agent-sync" || "$dir_name" == ".agent-sync" ]]; then
    if [[ "$(basename "$parent_dir")" == "tools" ]]; then
      REPO_ROOT="$(dirname "$parent_dir")"
    else
      REPO_ROOT="$parent_dir"
    fi
  else
    REPO_ROOT="$config_dir"
  fi
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

# --- Dependency check ---
for cmd in jq awk sed; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[agent-sync] Missing dependency: $cmd" >&2
    exit 1
  fi
done

# --- Read config ---
CONFIG="$(cat "$CONFIG_PATH")"

# --- v1 → v2 compatibility ---
# If config has "outputPath" + "sections" at top level (v1), wrap into outputs array
has_outputs="$(echo "$CONFIG" | jq 'has("outputs")')"
has_output_path="$(echo "$CONFIG" | jq 'has("outputPath")')"

if [[ "$has_output_path" == "true" && "$has_outputs" == "false" ]]; then
  # v1 format: convert to v2
  CONFIG="$(echo "$CONFIG" | jq '{
    version: 2,
    variables: (.variables // {}),
    files: .files,
    outputs: [{
      path: .outputPath,
      sections: .sections
    }]
  }')"
fi

# --- Validation ---
validate_config() {
  local files_json
  files_json="$(echo "$CONFIG" | jq -r '.files // empty')"
  if [[ -z "$files_json" ]]; then
    echo "[agent-sync] Invalid config: files is required." >&2
    exit 1
  fi

  local outputs_count
  outputs_count="$(echo "$CONFIG" | jq '.outputs | length')"
  if [[ "$outputs_count" -eq 0 ]]; then
    echo "[agent-sync] Invalid config: outputs must be a non-empty array." >&2
    exit 1
  fi

  # Validate each output's sections
  local i=0
  while [[ $i -lt $outputs_count ]]; do
    local output_path section_count
    output_path="$(echo "$CONFIG" | jq -r ".outputs[$i].path")"
    section_count="$(echo "$CONFIG" | jq ".outputs[$i].sections | length")"

    if [[ -z "$output_path" || "$output_path" == "null" ]]; then
      echo "[agent-sync] Invalid config: output[$i] requires path." >&2
      exit 1
    fi

    if [[ "$section_count" -eq 0 ]]; then
      echo "[agent-sync] Invalid config: output '$output_path' has no sections." >&2
      exit 1
    fi

    local j=0
    while [[ $j -lt $section_count ]]; do
      local sid stype ssource
      sid="$(echo "$CONFIG" | jq -r ".outputs[$i].sections[$j].id")"
      stype="$(echo "$CONFIG" | jq -r ".outputs[$i].sections[$j].type")"
      ssource="$(echo "$CONFIG" | jq -r ".outputs[$i].sections[$j].source")"

      if [[ -z "$sid" || "$sid" == "null" ]]; then
        echo "[agent-sync] Invalid config: section requires id in output '$output_path'." >&2
        exit 1
      fi

      if [[ "$stype" != "full-body" && "$stype" != "extract" && "$stype" != "settings" ]]; then
        echo "[agent-sync] Invalid config: section '$sid' has unsupported type '$stype'." >&2
        exit 1
      fi

      # Check source exists in files (settings type uses 'settings' key)
      local source_exists
      source_exists="$(echo "$CONFIG" | jq --arg s "$ssource" '.files | has($s)')"
      if [[ "$source_exists" != "true" ]]; then
        echo "[agent-sync] Invalid config: section '$sid' references unknown source '$ssource'." >&2
        exit 1
      fi

      if [[ "$stype" == "extract" ]]; then
        local headings_count
        headings_count="$(echo "$CONFIG" | jq ".outputs[$i].sections[$j].headings | length // 0")"
        if [[ "$headings_count" -eq 0 ]]; then
          echo "[agent-sync] Invalid config: extract section '$sid' requires non-empty headings." >&2
          exit 1
        fi
      fi

      j=$((j + 1))
    done

    i=$((i + 1))
  done
}

validate_config

# --- Check source files exist ---
check_source_files() {
  local keys
  keys="$(echo "$CONFIG" | jq -r '.files | keys[]')"
  while IFS= read -r key; do
    local rel_path abs_path
    rel_path="$(echo "$CONFIG" | jq -r --arg k "$key" '.files[$k]')"
    abs_path="$REPO_ROOT/$rel_path"
    if [[ ! -f "$abs_path" ]]; then
      echo "[agent-sync] Missing source file for '$key': $rel_path" >&2
      exit 1
    fi
  done <<< "$keys"
}

check_source_files

# --- Text processing functions ---

# Strip YAML frontmatter from markdown
strip_frontmatter() {
  awk '
    BEGIN { in_fm=0; found_end=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm=0; found_end=1; next }
    in_fm { next }
    { print }
  '
}

# Remove the first H1 heading and any blank lines immediately after it
remove_title_heading() {
  awk '
    BEGIN { found=0; skipping_blanks=0 }
    !found && /^[[:space:]]*$/ { next }
    !found && /^#[[:space:]]+/ { found=1; skipping_blanks=1; next }
    skipping_blanks && /^[[:space:]]*$/ { next }
    { skipping_blanks=0; print }
  '
}

# Shift heading levels by +1 (## becomes ###, etc.)
shift_headings_up() {
  sed -E 's/^(#{1,5})([[:space:]]+)/\1#\2/'
}

# Normalize heading text for comparison: lowercase, collapse whitespace
normalize_heading() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/ /g' | sed 's/^ //;s/ $//'
}

# Extract content under a specific heading (up to next heading of same or higher level)
extract_heading_content() {
  local markdown="$1"
  local heading_text="$2"
  local target
  target="$(normalize_heading "$heading_text")"

  local result
  result="$(echo "$markdown" | awk -v target="$target" '
    function normalize(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      s = tolower(s)
      gsub(/[[:space:]]+/, " ", s)
      return s
    }

    BEGIN { capturing=0; level=0; found=0 }

    /^#{1,6}[[:space:]]+/ {
      line = $0
      sub(/[[:space:]].*/, "", line)
      cur_level = length(line)
      cur_text = $0
      sub(/^#+[[:space:]]+/, "", cur_text)
      cur_text = normalize(cur_text)

      if (capturing && cur_level <= level) {
        exit
      }

      if (!found && cur_text == target) {
        found = 1
        capturing = 1
        level = cur_level
        next
      }
    }

    capturing { print }
  ')"

  # Trim leading/trailing blank lines
  result="$(echo "$result" | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

  if [[ -z "$result" ]]; then
    echo "[agent-sync] Heading not found or empty: \"$heading_text\"" >&2
    exit 1
  fi

  echo "$result"
}

# Read a source file, strip frontmatter
read_source() {
  local key="$1"
  local rel_path
  rel_path="$(echo "$CONFIG" | jq -r --arg k "$key" '.files[$k]')"
  strip_frontmatter < "$REPO_ROOT/$rel_path"
}

# Get template variable value (with fallback to empty string)
get_var() {
  echo "$CONFIG" | jq -r --arg k "$1" '.variables[$k] // ""'
}

# Apply template variable substitution
apply_variables() {
  local text="$1"
  local keys
  keys="$(echo "$CONFIG" | jq -r '.variables // {} | keys[]' 2>/dev/null || true)"
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    local val
    val="$(get_var "$key")"
    text="${text//\{\{$key\}\}/$val}"
  done <<< "$keys"
  echo "$text"
}

# Extract first 2 comment lines from a shell script (after shebang)
extract_hook_summary() {
  local content="$1"
  echo "$content" | awk '
    /^#!/ { next }
    /^#[[:space:]]/ {
      sub(/^#[[:space:]]*/, "")
      if (length($0) > 0) {
        comments[++n] = $0
        if (n >= 2) exit
      }
      next
    }
    n > 0 && !/^#/ { exit }
  END {
    sep = ""
    for (i = 1; i <= n; i++) {
      printf "%s%s", sep, comments[i]
      sep = " "
    }
  }'
}

# --- Section rendering ---

render_full_body_section() {
  local title="$1"
  local source_key="$2"

  local content
  content="$(read_source "$source_key")"
  content="$(echo "$content" | remove_title_heading)"
  content="$(echo "$content" | shift_headings_up)"

  # Trim
  content="$(echo "$content" | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

  echo "## $title"
  echo ""
  echo "$content"
}

render_extract_section() {
  local title="$1"
  local source_key="$2"
  local output_idx="$3"
  local section_idx="$4"

  local content
  content="$(read_source "$source_key")"

  local headings_count
  headings_count="$(echo "$CONFIG" | jq ".outputs[$output_idx].sections[$section_idx].headings | length")"

  # Check if single heading matches title
  local is_single_match=false
  if [[ "$headings_count" -eq 1 ]]; then
    local single_heading
    single_heading="$(echo "$CONFIG" | jq -r ".outputs[$output_idx].sections[$section_idx].headings[0]")"
    local norm_heading norm_title
    norm_heading="$(normalize_heading "$single_heading")"
    norm_title="$(normalize_heading "$title")"
    if [[ "$norm_heading" == "$norm_title" ]]; then
      is_single_match=true
    fi
  fi

  echo "## $title"
  echo ""

  local h=0
  while [[ $h -lt $headings_count ]]; do
    local heading
    heading="$(echo "$CONFIG" | jq -r ".outputs[$output_idx].sections[$section_idx].headings[$h]")"

    local extracted
    extracted="$(extract_heading_content "$content" "$heading")"

    if [[ "$is_single_match" == "true" ]]; then
      echo "$extracted"
    else
      echo "### $heading"
      echo ""
      echo "$extracted"
    fi

    h=$((h + 1))
    if [[ $h -lt $headings_count ]]; then
      echo ""
    fi
  done
}

render_settings_section() {
  local source_key="$1"
  local rel_path
  rel_path="$(echo "$CONFIG" | jq -r --arg k "$source_key" '.files[$k]')"
  local raw
  raw="$(cat "$REPO_ROOT/$rel_path")"

  # Enabled plugins
  local plugins
  plugins="$(echo "$raw" | jq -r '
    .enabledPlugins // {} | to_entries[] | select(.value == true) | "- `\(.key)`"
  ' 2>/dev/null || true)"

  # PostToolUse hooks from settings
  local hook_rows
  hook_rows="$(echo "$raw" | jq -r '
    .hooks.PostToolUse // [] | .[] |
    .matcher as $m |
    (.hooks // [])[] |
    "| `\($m // "(none)")` | `\(.command // "(none)")` | \(.timeout // "(none)") |"
  ' 2>/dev/null || true)"

  # Hook script summaries from source files
  local hook_summaries=""
  local file_keys
  file_keys="$(echo "$CONFIG" | jq -r '.files | keys[]')"
  while IFS= read -r key; do
    local fpath
    fpath="$(echo "$CONFIG" | jq -r --arg k "$key" '.files[$k]')"
    if [[ "$fpath" == *.sh ]]; then
      local script_content summary
      script_content="$(cat "$REPO_ROOT/$fpath")"
      summary="$(extract_hook_summary "$script_content")"
      [[ -z "$summary" ]] && summary="No summary comment detected."
      hook_summaries="${hook_summaries}| \`$fpath\` | $summary |
"
    fi
  done <<< "$file_keys"

  cat <<SETTINGS
## Claude Settings and Hooks

### Enabled Plugins (\`.claude/settings.json\`)

${plugins:-"- None enabled"}

### PostToolUse Hooks (\`.claude/settings.json\`)

| Matcher | Command | Timeout (s) |
|---|---|---|
${hook_rows:-"| \`(none)\` | \`(none)\` | \`(none)\` |"}

### Hook Script Summaries

| Script | Purpose |
|---|---|
${hook_summaries:-"| \`(none)\` | No hook scripts configured. |"}

### Notes

- Keep \`.claude/settings.json\` as the source of truth for Claude runtime behavior.
- Edit hook scripts in \`.claude/hooks/\`; regenerate this file after changes.
SETTINGS
}

# --- Build source file list ---
build_source_list() {
  local keys
  keys="$(echo "$CONFIG" | jq -r '.files | keys[]')"
  while IFS= read -r key; do
    local fpath
    fpath="$(echo "$CONFIG" | jq -r --arg k "$key" '.files[$k]')"
    echo "- \`$fpath\`"
  done <<< "$keys" | sort
}

# --- Render a single output ---
render_output() {
  local output_idx="$1"

  local output_path parent_path
  output_path="$(echo "$CONFIG" | jq -r ".outputs[$output_idx].path")"
  parent_path="$(echo "$CONFIG" | jq -r ".outputs[$output_idx].parent // empty")"

  local section_count
  section_count="$(echo "$CONFIG" | jq ".outputs[$output_idx].sections | length")"

  local project_name stack primary_agent
  project_name="$(get_var "project_name")"
  stack="$(get_var "stack")"
  primary_agent="$(get_var "primary_agent")"

  # Build header
  local header=""
  header+="# AGENTS.md"
  [[ -n "$project_name" ]] && header+=" - $project_name"
  header+=$'\n\n'
  header+="> AUTO-GENERATED FILE. Do not edit directly."$'\n'
  header+="> Generator: \`agent-sync\`"$'\n'
  header+=$'\n'

  if [[ -n "$primary_agent" || -n "$stack" ]]; then
    local meta=""
    [[ -n "$primary_agent" ]] && meta+="**Primary Agent:** $primary_agent"
    [[ -n "$primary_agent" && -n "$stack" ]] && meta+=" | "
    [[ -n "$stack" ]] && meta+="**Stack:** $stack"
    header+="$meta"$'\n\n'
  fi

  # Parent back-reference for subdirectory outputs
  if [[ -n "$parent_path" ]]; then
    header+="> See also: [$parent_path]($parent_path)"$'\n\n'
  fi

  # Source of truth section (only for root/main output)
  if [[ -z "$parent_path" ]]; then
    header+="## Source of Truth"$'\n\n'
    header+="$(build_source_list)"$'\n'
  fi

  # Apply variables (command substitution strips trailing newlines, so re-add)
  header="$(apply_variables "$header")"$'\n'

  # Render sections
  local body=""
  local s=0
  while [[ $s -lt $section_count ]]; do
    local stitle stype ssource
    stitle="$(echo "$CONFIG" | jq -r ".outputs[$output_idx].sections[$s].title")"
    stype="$(echo "$CONFIG" | jq -r ".outputs[$output_idx].sections[$s].type")"
    ssource="$(echo "$CONFIG" | jq -r ".outputs[$output_idx].sections[$s].source")"

    local section_content=""
    case "$stype" in
      full-body)
        section_content="$(render_full_body_section "$stitle" "$ssource")"
        ;;
      extract)
        section_content="$(render_extract_section "$stitle" "$ssource" "$output_idx" "$s")"
        ;;
      settings)
        section_content="$(render_settings_section "$ssource")"
        ;;
    esac

    body+=$'\n'"$section_content"$'\n'
    s=$((s + 1))
  done

  # Apply variables (command substitution strips trailing newlines, so re-add)
  body="$(apply_variables "$body")"$'\n'

  # See Also footer (only for root/main output)
  local footer=""
  if [[ -z "$parent_path" ]]; then
    footer=$'\n'"## See Also"$'\n\n'
    footer+="- \`.claude/rules/\`"$'\n'
    footer+="- \`.claude/settings.json\`"$'\n'
    footer+="- \`CLAUDE.md\`"$'\n'
  fi

  echo "${header}${body}${footer}"
}

# --- Main ---
outputs_count="$(echo "$CONFIG" | jq '.outputs | length')"

exit_code=0
i=0
while [[ $i -lt $outputs_count ]]; do
  output_path="$(echo "$CONFIG" | jq -r ".outputs[$i].path")"
  abs_output="$REPO_ROOT/$output_path"

  # Guard against path traversal outside repo root
  abs_output_resolved="$(cd "$REPO_ROOT" && realpath -m "$output_path" 2>/dev/null || echo "$abs_output")"
  case "$abs_output_resolved" in
    "$REPO_ROOT"/*)
      ;;
    *)
      echo "[agent-sync] Output path escapes project root: $output_path" >&2
      exit 1
      ;;
  esac

  rendered="$(render_output "$i")"

  if [[ "$CHECK_MODE" == "true" ]]; then
    existing=""
    if [[ -f "$abs_output" ]]; then
      existing="$(cat "$abs_output")"
    fi

    if [[ "$existing" != "$rendered" ]]; then
      echo "[agent-sync] DRIFT: $output_path is out of sync. Run: /agent-sync:generate" >&2
      exit_code=1
    else
      echo "[agent-sync] OK: $output_path is in sync."
    fi
  else
    existing=""
    if [[ -f "$abs_output" ]]; then
      existing="$(cat "$abs_output")"
    fi

    if [[ "$existing" == "$rendered" ]]; then
      echo "[agent-sync] No changes: $output_path already up to date."
    else
      # Ensure parent directory exists
      mkdir -p "$(dirname "$abs_output")"
      echo "$rendered" > "$abs_output"
      echo "[agent-sync] Updated $output_path."
    fi
  fi

  i=$((i + 1))
done

exit $exit_code
