#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
BUS="$PLUGIN/scripts/bus.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkbus() { BUS_DIR="$(mktemp -d)/bus"; }
bus() { bash "$BUS" "$@"; }

# send -> poll round trip
mkbus
send_poll() {
  local id got
  id="$(bus send --dir "$BUS_DIR" --to alice --from bob --subject hi --body "hello world")"
  [ -n "$id" ] || return 1
  got="$(bus poll --dir "$BUS_DIR" --name alice --json)"
  [ "$(jq -r .id <<<"$got")" = "$id" ] &&
  [ "$(jq -r .from <<<"$got")" = bob ] &&
  [ "$(jq -r .to <<<"$got")" = alice ] &&
  [ "$(jq -r .subject <<<"$got")" = hi ] &&
  [ "$(jq -r .body <<<"$got")" = "hello world" ] &&
  [ "$(jq -r 'has("reply_to")' <<<"$got")" = false ]
}
t "send -> poll round trip" send_poll

# reply -> wait round trip
mkbus
reply_wait() {
  local rid got
  rid="$(bus send --dir "$BUS_DIR" --to alice --from bob --subject q --body ask)"
  bus send --dir "$BUS_DIR" --to bob --from alice --subject re --body answer --reply-to "$rid" >/dev/null
  got="$(bus wait --dir "$BUS_DIR" --name bob --reply-to "$rid" --timeout 5)"
  [ "$(jq -r .reply_to <<<"$got")" = "$rid" ] &&
  [ "$(jq -r .body <<<"$got")" = answer ]
}
t "reply -> wait round trip" reply_wait

# wait times out (exit 1) when no matching reply
mkbus
wait_timeout() {
  bus send --dir "$BUS_DIR" --to bob --from alice --subject x --body y >/dev/null
  ! bus wait --dir "$BUS_DIR" --name bob --reply-to nomatch --timeout 1
}
t "wait times out on no match" wait_timeout

# --consume moves to done/ and second poll is empty
mkbus
consume_moves() {
  local id
  id="$(bus send --dir "$BUS_DIR" --to alice --from bob --subject s --body b)"
  bus poll --dir "$BUS_DIR" --name alice --consume >/dev/null
  [ -f "$BUS_DIR/alice/done/$id.json" ] &&
  [ -z "$(bus poll --dir "$BUS_DIR" --name alice --json)" ]
}
t "--consume moves to done/, second poll empty" consume_moves

# .tmp is never visible to poll
mkbus
tmp_invisible() {
  local id
  id="$(bus send --dir "$BUS_DIR" --to alice --from bob --subject s --body b)"
  mkdir -p "$BUS_DIR/.tmp"
  echo '{"id":"stray","to":"alice"}' > "$BUS_DIR/.tmp/stray.json"
  local ids; ids="$(bus poll --dir "$BUS_DIR" --name alice --json | jq -r .id)"
  [ "$ids" = "$id" ]
}
t ".tmp never visible to poll" tmp_invisible

# body size cap refusal
mkbus
size_cap() {
  local big; big="$(head -c 66000 /dev/zero | tr '\0' x)"
  ! bus send --dir "$BUS_DIR" --to alice --from bob --subject s --body "$big"
}
t "body >64KB refused" size_cap

# empty required fields refused
mkbus
empty_fields() {
  ! bus send --dir "$BUS_DIR" --to alice --from bob --subject "" --body b
}
t "empty --subject refused" empty_fields

# no bus dir resolved -> fails closed
no_dir() {
  ( unset MC_BUS_DIR MC_CONFIG; ! bus send --to alice --from bob --subject s --body b )
}
t "missing bus dir fails closed" no_dir

# unwritable bus dir (path is a file) -> fails closed
mkbus
unwritable() {
  local f; f="$(mktemp)"
  ! bus send --dir "$f" --to alice --from bob --subject s --body b
}
t "unwritable bus dir fails closed" unwritable

# gc removes only old done/ entries
mkbus
gc_ages() {
  bus send --dir "$BUS_DIR" --to alice --from bob --subject s --body b >/dev/null
  bus poll --dir "$BUS_DIR" --name alice --consume >/dev/null
  local d="$BUS_DIR/alice/done"
  touch -d "20 days ago" "$d"/*.json
  cp "$d"/*.json "$d/fresh.json"; touch -d "now" "$d/fresh.json"
  bus gc --dir "$BUS_DIR"
  [ -f "$d/fresh.json" ] && [ "$(ls -1 "$d" | grep -vc fresh.json)" = 0 ]
}
t "gc removes only old done/ entries" gc_ages

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
