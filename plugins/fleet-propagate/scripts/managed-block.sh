#!/usr/bin/env bash
# managed-block.sh — idempotent marker-delimited block management in text files.
# The primitive behind fleet-wide config propagation: applying the same content
# twice is a no-op, changed content replaces exactly the managed block, and
# verify proves the block on disk matches the intended content.
#
# Usage:
#   managed-block.sh apply  --file F --id ID --content-file C [--create] [--comment PREFIX]
#   managed-block.sh verify --file F --id ID --content-file C [--comment PREFIX]
#   managed-block.sh remove --file F --id ID [--comment PREFIX]
#
# Markers: "<PREFIX> FLEET-BLOCK BEGIN <ID>" / "<PREFIX> FLEET-BLOCK END <ID>"
# (PREFIX default '#'). apply prints exactly one of: changed | unchanged | created.
# Exit codes: 0 ok (apply/remove; verify match); 2 usage; 4 verify mismatch or
# block missing; 1 failure (unreadable file, unterminated block).
set -uo pipefail

MODE="${1:-}"; [ "$#" -gt 0 ] && shift || { echo "managed-block: mode required (apply|verify|remove)" >&2; exit 2; }
FILE=""; ID=""; CONTENT=""; CREATE=0; PREFIX="#"
need() { [ "$#" -ge 2 ] || { echo "managed-block: $1 needs a value" >&2; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)         need "$@"; FILE="$2"; shift 2 ;;
    --id)           need "$@"; ID="$2"; shift 2 ;;
    --content-file) need "$@"; CONTENT="$2"; shift 2 ;;
    --comment)      need "$@"; PREFIX="$2"; shift 2 ;;
    --create)       CREATE=1; shift ;;
    *) echo "managed-block: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$FILE" ] && [ -n "$ID" ] || { echo "managed-block: --file and --id required" >&2; exit 2; }
case "$ID" in *[!A-Za-z0-9._-]*) echo "managed-block: id must match [A-Za-z0-9._-]+" >&2; exit 2 ;; esac
case "$MODE" in apply|verify) [ -n "$CONTENT" ] || { echo "managed-block: --content-file required" >&2; exit 2; }
  [ -f "$CONTENT" ] || { echo "managed-block: no such content file: $CONTENT" >&2; exit 2; } ;; esac

BEGIN="$PREFIX FLEET-BLOCK BEGIN $ID"
END="$PREFIX FLEET-BLOCK END $ID"

extract_block() { # current block body from $FILE (between markers), fails if unterminated
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { inb=1; found=1; next }
    $0 == e { if (!inb) { exit 3 }; inb=0; next }
    inb { print }
    END { if (inb) exit 3; if (!found) exit 4 }
  ' "$FILE"
}

case "$MODE" in
  apply)
    if [ ! -f "$FILE" ]; then
      [ "$CREATE" -eq 1 ] || { echo "managed-block: no such file: $FILE (use --create)" >&2; exit 1; }
      mkdir -p "$(dirname "$FILE")" || exit 1
      { printf '%s\n' "$BEGIN"; cat "$CONTENT"; printf '%s\n' "$END"; } > "$FILE" || exit 1
      echo "created"; exit 0
    fi
    current="$(extract_block)"; rc=$?
    if [ "$rc" -eq 3 ]; then echo "managed-block: unterminated block $ID in $FILE" >&2; exit 1; fi
    if [ "$rc" -eq 0 ] && [ "$current" = "$(cat "$CONTENT")" ]; then
      echo "unchanged"; exit 0
    fi
    tmp="$(mktemp)" || exit 1
    if [ "$rc" -eq 4 ]; then
      { cat "$FILE"; printf '%s\n' "$BEGIN"; cat "$CONTENT"; printf '%s\n' "$END"; } > "$tmp" || exit 1
    else
      awk -v b="$BEGIN" -v e="$END" -v cf="$CONTENT" '
        $0 == b { print; while ((getline line < cf) > 0) print line; close(cf); skip=1; next }
        $0 == e { skip=0; print; next }
        !skip { print }
      ' "$FILE" > "$tmp" || exit 1
    fi
    mv "$tmp" "$FILE" || exit 1
    echo "changed"; exit 0 ;;
  verify)
    [ -f "$FILE" ] || { echo "managed-block: no such file: $FILE" >&2; exit 4; }
    current="$(extract_block)"; rc=$?
    if [ "$rc" -eq 3 ]; then echo "managed-block: unterminated block $ID in $FILE" >&2; exit 1; fi
    if [ "$rc" -eq 4 ]; then echo "managed-block: block $ID missing from $FILE" >&2; exit 4; fi
    if [ "$current" != "$(cat "$CONTENT")" ]; then
      echo "managed-block: block $ID in $FILE differs from intended content" >&2; exit 4
    fi
    echo "verified"; exit 0 ;;
  remove)
    [ -f "$FILE" ] || { echo "unchanged"; exit 0; }
    extract_block >/dev/null; rc=$?
    if [ "$rc" -eq 3 ]; then echo "managed-block: unterminated block $ID in $FILE" >&2; exit 1; fi
    if [ "$rc" -eq 4 ]; then echo "unchanged"; exit 0; fi
    tmp="$(mktemp)" || exit 1
    awk -v b="$BEGIN" -v e="$END" '
      $0 == b { skip=1; next }
      $0 == e { skip=0; next }
      !skip { print }
    ' "$FILE" > "$tmp" || exit 1
    mv "$tmp" "$FILE" || exit 1
    echo "changed"; exit 0 ;;
  *) echo "managed-block: unknown mode: $MODE (apply|verify|remove)" >&2; exit 2 ;;
esac
