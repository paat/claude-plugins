#!/usr/bin/env bash
# Run one read-only Antigravity CLI (agy) prompt. Files are inlined on the host side;
# agy itself gets no file, command, URL-fetch, write, or MCP access.
set -euo pipefail

usage() {
  echo "usage: run-agy.sh [--model ID] [--timeout SECONDS] [--file PATH]... -- PROMPT" >&2
  exit 2
}

model="" seconds=180 files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) [ "$#" -ge 2 ] || usage; model="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] && [ "$2" -ge 20 ] || usage; seconds="$2"; shift 2 ;;
    --file) [ "$#" -ge 2 ] || usage; files+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ "$#" -eq 1 ] && [ -n "$1" ] || usage
prompt="$1"

command -v agy >/dev/null 2>&1 || { echo "agy unavailable: Antigravity CLI (agy) is not installed" >&2; exit 4; }
command -v jq >/dev/null 2>&1 || { echo "agy unavailable: jq is not installed" >&2; exit 4; }
for f in ${files[@]+"${files[@]}"}; do
  [ -f "$f" ] && [ -r "$f" ] || { echo "agy unavailable: cannot read file: $f" >&2; exit 2; }
done

token="${HOME:-}/.gemini/antigravity-cli/antigravity-oauth-token"
provider=""
if [ -f "$token" ] && [ ! -L "$token" ]; then
  :
elif [ -n "${GEMINI_API_KEY:-}" ]; then
  provider=',"modelProvider":"gemini"'
else
  echo "agy unavailable: not signed in; run agy once to sign in, or set GEMINI_API_KEY" >&2
  exit 4
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
agy_dir="$tmp/home/.gemini/antigravity-cli"
mkdir -p "$tmp/work/.git" "$agy_dir"
[ -n "$provider" ] || (umask 077 && cp "$token" "$agy_dir/antigravity-oauth-token")
# Sterile cwd: agy runs workspace .agents hooks and auto-allows workspace writes.
# Explicit denies return recoverable tool errors; search_web needs no permission.
printf '{"permissions":{"deny":["read_file(*)","write_file(*)","command(*)","read_url(*)","execute_url(*)","mcp(*)"]}%s}\n' \
  "$provider" > "$agy_dir/settings.json"

model_args=()
[ -z "$model" ] || model_args=(--model "$model")
env_args=(env -i "HOME=$tmp/home" "PATH=$PATH" "TMPDIR=$tmp" "LANG=C.UTF-8" "NO_COLOR=1" "TERM=dumb")
[ -z "$provider" ] || env_args+=("GEMINI_API_KEY=$GEMINI_API_KEY")

{
  printf '%s\n' "$prompt"
  for f in ${files[@]+"${files[@]}"}; do
    printf '\n=== FILE: %s ===\n' "$f"
    cat -- "$f" || { echo "agy unavailable: cannot read file: $f" >&2; exit 2; }
  done
} > "$tmp/prompt.txt"

rc=0
jq -Rsc '{event:"user",message:{content:.}}' < "$tmp/prompt.txt" \
  | (cd "$tmp/work" && "${env_args[@]}" timeout -k 5 "$seconds" agy ${model_args[@]+"${model_args[@]}"} \
      --input-format stream-json --output-format stream-json --print-timeout "$((seconds - 5))s" -p=) \
  > "$tmp/stream.jsonl" 2> "$tmp/err.txt" || rc=$?

result="$(jq -Rc '[inputs | fromjson? | select(.event=="result")] | last | .result // {}' -n < "$tmp/stream.jsonl")"
if [ "$rc" -eq 0 ] && [ "$(jq -r '.status // ""' <<<"$result")" = SUCCESS ] \
  && [ -n "$(jq -r '.response // "" | gsub("\\s"; "")' <<<"$result")" ]; then
  jq -r '.response' <<<"$result"
  exit 0
fi
reason="$(jq -r '.error // "" | split("\n")[0] // ""' <<<"$result")"
[ -n "$reason" ] || reason="$(tail -n 3 "$tmp/err.txt" | tr '\n' ' ')"
[ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] || reason="timed out after ${seconds}s"
echo "agy failed (exit $rc): ${reason:-empty response}" >&2
exit 3
