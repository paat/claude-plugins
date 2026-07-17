#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/bin" "$TD/repo"
cat > "$TD/bin/docker" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$DOCKER_CALLS"
exit "${MOCK_DOCKER_RC:-0}"
SH
chmod +x "$TD/bin/docker"
export DOCKER_CALLS="$TD/docker.calls"
jq -n --arg td "$TD" '{
  docker_cmd:"docker", engines:{e:{pool:"p",cmd:"unused"}}, pools:{p:{}}, slots:{A:{}},
  projects:[{name:"p1",container:"dev-container",repo_path:($td+"/repo"),stage:"live",engine:"e",command:"unused",hold:false}],
  admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/portfolio.json"

CMD="codex exec --dangerously-bypass-approvals-and-sandbox 'fix issues && verify'"
wrapper() {
  local base="$TD/$1"; shift
  : > "$base.log"; : > "$DOCKER_CALLS"
  PATH="$TD/bin:$PATH" bash "$MC" wrapper --config "$TD/portfolio.json" \
    --slot A --project p1 --engine e --container dev-container --repo-path "$TD/repo" \
    --envelope 7 --base "$base" --cmd "$CMD" "$@"
}

held_command_is_complete() {
  wrapper held --delivery-hold true || return 1
  expected="$(printf '%s\n' /paat-reconcile/with-delivery-hold.sh timeout 7m bash -c "$CMD")"
  [ "$(tail -n 6 "$DOCKER_CALLS")" = "$expected" ]
}
t "opt-in wraps the complete unrestricted command through the launcher" held_command_is_complete

absent_preserves_direct_delivery() {
  wrapper direct || return 1
  ! grep -qFx /paat-reconcile/with-delivery-hold.sh "$DOCKER_CALLS" &&
  grep -qF "timeout 7m bash -c $(printf '%q' "$CMD")" "$DOCKER_CALLS"
}
t "absent opt-in preserves direct container delivery" absent_preserves_direct_delivery

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
