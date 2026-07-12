#!/usr/bin/env bash
# fleet-propagate tests. Exit non-zero on any mismatch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MB="$PLUGIN/scripts/managed-block.sh"
FT="$PLUGIN/scripts/fleet-targets.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT

# --- managed-block ---
printf 'export FLEET_VAR=1\nalias ll="ls -la"\n' > "$WD/content.txt"

create_new() { [ "$(bash "$MB" apply --file "$WD/rc" --id env-v1 --content-file "$WD/content.txt" --create)" = created ]; }
t "apply --create on missing file prints created" create_new
idempotent() { [ "$(bash "$MB" apply --file "$WD/rc" --id env-v1 --content-file "$WD/content.txt")" = unchanged ]; }
t "identical re-apply prints unchanged (idempotency proof)" idempotent
block_present() { grep -q "# FLEET-BLOCK BEGIN env-v1" "$WD/rc" && grep -q "FLEET_VAR=1" "$WD/rc"; }
t "markers and content present" block_present
t "verify matches after apply" bash "$MB" verify --file "$WD/rc" --id env-v1 --content-file "$WD/content.txt"

# Update replaces exactly the block, preserving surrounding content.
printf 'echo before\n' > "$WD/rc2"; printf 'v1\n' > "$WD/c1"; printf 'v2\n' > "$WD/c2"
bash "$MB" apply --file "$WD/rc2" --id b --content-file "$WD/c1" >/dev/null
printf 'echo after\n' >> "$WD/rc2"
update_replaces() {
  [ "$(bash "$MB" apply --file "$WD/rc2" --id b --content-file "$WD/c2")" = changed ] &&
  grep -q "^v2$" "$WD/rc2" && ! grep -q "^v1$" "$WD/rc2" &&
  grep -q "echo before" "$WD/rc2" && grep -q "echo after" "$WD/rc2" &&
  [ "$(grep -c "FLEET-BLOCK BEGIN b" "$WD/rc2")" -eq 1 ]
}
t "changed content replaces exactly the block" update_replaces

# Verify failure modes.
verify_mismatch() { bash "$MB" verify --file "$WD/rc2" --id b --content-file "$WD/c1"; [ $? -eq 4 ]; }
t "verify mismatch exits 4" verify_mismatch
verify_missing_block() { bash "$MB" verify --file "$WD/rc2" --id nope --content-file "$WD/c1"; [ $? -eq 4 ]; }
t "verify missing block exits 4" verify_missing_block

# Two independent blocks coexist.
bash "$MB" apply --file "$WD/rc2" --id second --content-file "$WD/c1" >/dev/null
two_blocks() {
  bash "$MB" verify --file "$WD/rc2" --id b --content-file "$WD/c2" &&
  bash "$MB" verify --file "$WD/rc2" --id second --content-file "$WD/c1"
}
t "independent block ids coexist" two_blocks

# Custom comment prefix for non-# files.
printf '// FLEET test\n' > "$WD/c3"
js_prefix() {
  bash "$MB" apply --file "$WD/app.js" --id js --content-file "$WD/c3" --create --comment '//' >/dev/null &&
  grep -q '^// FLEET-BLOCK BEGIN js$' "$WD/app.js" &&
  bash "$MB" verify --file "$WD/app.js" --id js --content-file "$WD/c3" --comment '//'
}
t "custom comment prefix" js_prefix

# Remove deletes the block and is idempotent.
remove_block() {
  [ "$(bash "$MB" remove --file "$WD/rc2" --id second)" = changed ] &&
  ! grep -q "FLEET-BLOCK BEGIN second" "$WD/rc2" &&
  [ "$(bash "$MB" remove --file "$WD/rc2" --id second)" = unchanged ]
}
t "remove deletes block, re-remove is unchanged" remove_block

# Unterminated block fails loudly.
printf '# FLEET-BLOCK BEGIN broken\nno end\n' > "$WD/broken"
unterminated() { bash "$MB" apply --file "$WD/broken" --id broken --content-file "$WD/c1"; [ $? -eq 1 ]; }
t "unterminated block exits 1" unterminated

# Missing file without --create fails; bad id rejected.
no_create() { bash "$MB" apply --file "$WD/absent" --id x --content-file "$WD/c1"; [ $? -eq 1 ]; }
t "missing file without --create exits 1" no_create
bad_id() { bash "$MB" apply --file "$WD/rc" --id 'bad id!' --content-file "$WD/c1"; [ $? -eq 2 ]; }
t "invalid id exits 2" bad_id

# Missing final newline in file or content never corrupts markers.
printf 'no newline at end' > "$WD/nonl"
printf 'body no nl' > "$WD/cnonl"
no_final_newline() {
  [ "$(bash "$MB" apply --file "$WD/nonl" --id nl --content-file "$WD/cnonl")" = changed ] &&
  grep -qx 'no newline at end' "$WD/nonl" &&
  grep -qx '# FLEET-BLOCK BEGIN nl' "$WD/nonl" &&
  grep -qx '# FLEET-BLOCK END nl' "$WD/nonl" &&
  bash "$MB" verify --file "$WD/nonl" --id nl --content-file "$WD/cnonl" >/dev/null &&
  [ "$(bash "$MB" apply --file "$WD/nonl" --id nl --content-file "$WD/cnonl")" = unchanged ]
}
t "missing final newlines normalized, idempotency preserved" no_final_newline

# Trailing-blank-line differences are real differences.
printf 'x\n' > "$WD/ct1"; printf 'x\n\n' > "$WD/ct2"
bash "$MB" apply --file "$WD/trail" --id tr --content-file "$WD/ct1" --create >/dev/null
trailing_blank_detected() {
  bash "$MB" verify --file "$WD/trail" --id tr --content-file "$WD/ct2"; [ $? -eq 4 ] &&
  [ "$(bash "$MB" apply --file "$WD/trail" --id tr --content-file "$WD/ct2")" = changed ]
}
t "trailing blank line is a real difference" trailing_blank_detected

# Content containing the markers themselves is rejected.
printf '# FLEET-BLOCK END evil\n' > "$WD/cevil"
marker_in_content() { bash "$MB" apply --file "$WD/rc" --id evil --content-file "$WD/cevil" --create; [ $? -eq 2 ]; }
t "content containing its own markers rejected" marker_in_content

# Duplicate blocks with the same id fail instead of multi-editing.
printf '# FLEET-BLOCK BEGIN dup\na\n# FLEET-BLOCK END dup\n# FLEET-BLOCK BEGIN dup\nb\n# FLEET-BLOCK END dup\n' > "$WD/dup"
dup_blocks() { bash "$MB" apply --file "$WD/dup" --id dup --content-file "$WD/c1"; [ $? -eq 1 ]; }
t "duplicate block id fails loudly" dup_blocks

# File mode (executable init script) survives replacement.
printf '#!/bin/sh\necho hi\n' > "$WD/init.sh"; chmod 755 "$WD/init.sh"
bash "$MB" apply --file "$WD/init.sh" --id perm --content-file "$WD/c1" >/dev/null
bash "$MB" apply --file "$WD/init.sh" --id perm --content-file "$WD/c2" >/dev/null
perm_kept() { [ -x "$WD/init.sh" ]; }
t "executable mode survives block replacement" perm_kept

# fleet-targets: glob with spaces in path; wrong manifest field type.
mkdir -p "$WD/spaced dir"; printf 'x\n' > "$WD/spaced dir/a.sh"
jq -n --arg g "$WD/spaced dir/*.sh" '{init_scripts:[$g]}' > "$WD/fleet2.json"
spaced_glob() { bash "$FT" list --manifest "$WD/fleet2.json" | grep -qF "a.sh	file	$WD/spaced dir/a.sh"; }
t "glob path with spaces resolves intact" spaced_glob
printf '{"init_scripts":"not-an-array"}\n' > "$WD/badtype.json"
bad_type() { bash "$FT" list --manifest "$WD/badtype.json"; [ $? -eq 2 ]; }
t "wrong manifest field type exits 2" bad_type

# --- fleet-targets ---
mkdir -p "$WD/bin" "$WD/init"
printf 'echo init\n' > "$WD/init/setup.sh"
cat > "$WD/bin/docker" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "ps" ]; then printf 'webtop-a\nwebtop-b\n'; exit 0; fi
exit 1
SH
chmod +x "$WD/bin/docker"
jq -n --arg init "$WD/init/*.sh" '{container_filters:["name=webtop"], exclude_containers:["webtop-b"], init_scripts:[$init]}' > "$WD/fleet.json"
TGT="$(PATH="$WD/bin:$PATH" bash "$FT" list --manifest "$WD/fleet.json")"
targets_host() { printf '%s' "$TGT" | grep -q "^host	host	-$"; }
t "host target always listed" targets_host
targets_container() { printf '%s' "$TGT" | grep -q "^webtop-a	container	docker exec -i webtop-a$"; }
t "matching container listed with exec prefix" targets_container
targets_exclude() { ! printf '%s' "$TGT" | grep -q "webtop-b"; }
t "excluded container omitted" targets_exclude
targets_file() { printf '%s' "$TGT" | grep -q "^setup.sh	file	$WD/init/setup.sh$"; }
t "init-script glob resolved to file target" targets_file

# Docker down: loud incomplete-list failure.
cat > "$WD/bin/docker" <<'SH'
#!/usr/bin/env bash
exit 1
SH
docker_down() {
  out="$(PATH="$WD/bin:$PATH" bash "$FT" list --manifest "$WD/fleet.json" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "incomplete"
}
t "unreachable docker exits 1 and says incomplete" docker_down

# Manifest errors.
no_manifest() { bash "$FT" list --manifest "$WD/nope.json"; [ $? -eq 2 ]; }
t "missing manifest exits 2" no_manifest
printf '{bad' > "$WD/bad.json"
bad_manifest() { bash "$FT" list --manifest "$WD/bad.json"; [ $? -eq 2 ]; }
t "malformed manifest exits 2" bad_manifest

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
