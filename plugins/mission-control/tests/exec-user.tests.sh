#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok - $name"; else FAIL=$((FAIL+1)); echo "FAIL - $name"; fi; }

mkenv() { # [exec_user]
  TD="$(mktemp -d)"
  mkdir -p "$TD/bin"
  cat > "$TD/bin/docker" <<'SH'
#!/bin/bash
echo "docker $*" >> "$DOCKER_CALLS"; exit 0
SH
  chmod +x "$TD/bin/docker"
  export DOCKER_CALLS="$TD/docker.calls"; : > "$DOCKER_CALLS"
  jq -n --arg u "${1:-}" '{docker_cmd:"docker"}
    + (if $u == "" then {} else {docker_exec_user:$u} end)
    + {engines:{}, pools:{}, slots:{A:{}}, projects:[],
       admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/portfolio.json"
}
# run run_in against the mock docker, capture the exec line
exec_line() { # <exec_user>
  mkenv "$1"
  PATH="$TD/bin:$PATH" MC_LIB_ONLY=1 MC_CONFIG="$TD/portfolio.json" \
    bash -c 'source "$1"; run_in c1 /repo "true" 5' _ "$MC" >/dev/null 2>&1
  grep 'exec' "$DOCKER_CALLS"
}

with_user()    { exec_line dev | grep -q '^docker exec -u dev c1 '; }
without_user() { local l; l="$(exec_line '')"; echo "$l" | grep -q '^docker exec c1 ' && ! echo "$l" | grep -q ' -u '; }

t "docker_exec_user set: exec runs -u dev" with_user
t "unset: exec has no -u (image default)" without_user

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
