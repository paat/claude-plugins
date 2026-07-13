#!/usr/bin/env bash
# Model-free Codex writer-sandbox smoke with root-cause diagnosis.
# Exit 0: writer sandbox usable. Exit 4: hard environment block (diagnosis on
# stdout, names a safe host-side remedy; never suggests danger-full-access).
# Exit 10: Codex CLI not found. Exit 2: usage.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_DRIVER=${SAAS_SUPERVISOR_CHECK_DRIVER:-$SCRIPT_DIR/supervisor-check-container.sh}
ROOT=""
TIMEOUT="${SAAS_CODEX_PREFLIGHT_TIMEOUT:-15}"
usage() { echo "usage: codex-sandbox-check.sh [--root DIR] [--timeout SECS]" >&2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || { usage; exit 2; }; ROOT="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage; exit 2; }; TIMEOUT="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(pwd)"
case "$TIMEOUT" in ''|0|*[!0-9]*) TIMEOUT=15 ;; esac
ROOT=$(cd -- "$ROOT" && pwd -P) || {
  echo "requested root is not an accessible directory"
  exit 4
}

is_forced_missing() {
  case " ${SAAS_PREFLIGHT_MISSING:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
have_cmd() { ! is_forced_missing "$1" && command -v "$1" >/dev/null 2>&1; }

have_cmd codex || { echo "Codex CLI not found"; exit 10; }

sandbox="${CODEX_SANDBOX:-workspace-write}"
if [ "$sandbox" != "workspace-write" ]; then
  echo "unsupported writer sandbox CODEX_SANDBOX=$sandbox; Codex implementation workers require isolated workspace-write"
  exit 4
fi
if ! have_cmd timeout; then
  echo "timeout missing; cannot bound the Codex sandbox smoke"
  exit 4
fi
CODEX_BIN=$(command -v codex)
if ! "$CODEX_BIN" sandbox --help >/dev/null 2>&1; then
  echo "Codex CLI lacks sandbox smoke support; update Codex before launching separate workers"
  exit 4
fi

rc=0
out="$(CODEX_BIN="$CODEX_BIN" timeout "$TIMEOUT" \
  "$SCRIPT_DIR/codex-network-off-sandbox.sh" -C "$ROOT" /bin/pwd 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  if [ "$out" != "$ROOT" ]; then
    echo "Codex sandbox working directory mismatch: requested root was not honored"
    exit 4
  fi
  # A bare start smoke is a false green for delivery (issues #260/#261):
  # the trusted commit path stages candidates with git outside the sandbox,
  # and validation checks need Python cross-thread wakeups inside it.
  stage_dir="$(mktemp -d)"
  stage_rc=0
  (
    cd "$stage_dir" \
      && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git init -q . \
      && echo probe > staged.txt \
      && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        git -c core.fsmonitor=false -c core.hooksPath=/dev/null add -A
  ) >/dev/null 2>&1 || stage_rc=$?
  rm -rf "$stage_dir"
  if [ "$stage_rc" -ne 0 ]; then
    echo "candidate staging probe failed (exit $stage_rc): trusted git cannot stage a disposable clone outside the sandbox"
    exit 4
  fi
  thread_note="thread-wakeup probe skipped: python3 not on PATH"
  if have_cmd python3; then
    thread_note="thread-wakeup probes"
    thread_rc=0
    CODEX_BIN="$CODEX_BIN" timeout "$TIMEOUT" \
      "$SCRIPT_DIR/codex-network-off-sandbox.sh" -C "$ROOT" python3 -c \
      'import asyncio; asyncio.run(asyncio.to_thread(lambda: None))' >/dev/null 2>&1 || thread_rc=$?
    if [ "$thread_rc" -ne 0 ]; then
      case "$thread_rc" in
        124|137) reason="timed out (likely hang)" ;;
        127) reason="python3 not available inside the sandbox" ;;
        *) reason="exit $thread_rc" ;;
      esac
      echo "Python cross-thread wakeup failed inside the Codex sandbox ($reason): threaded checks (asyncio.to_thread, HTTP test clients) will deadlock; update the Codex CLI or the container sandbox policy so ordinary thread wakeups work"
      exit 4
    fi
  fi
  supervisor_note="supervisor process probe"
  supervisor_parent=$(mktemp -d)
  supervisor_root="$supervisor_parent/root"
  outside_probe="$supervisor_parent/outside-secret"
  git init -q "$supervisor_root"
  printf 'sandbox-secret-probe\n' > "$outside_probe"
  supervisor_rc=0
  supervisor_meta=$(timeout "$TIMEOUT" "$SUPERVISOR_DRIVER" --metadata 2>/dev/null) || supervisor_rc=$?
  sleep 30 & host_probe_pid=$!
  if [ "$supervisor_rc" -eq 0 ]; then
    timeout "$TIMEOUT" "$SUPERVISOR_DRIVER" -C "$supervisor_root" \
      --docker-bin "$(jq -r .docker.path <<<"$supervisor_meta")" \
      --image-id "$(jq -r .image_id <<<"$supervisor_meta")" \
      --daemon-id "$(jq -r .daemon_id <<<"$supervisor_meta")" \
      --checkout-alias "$supervisor_root" -- /bin/bash -c \
    'set -euo pipefail
sleep 10 & child=$!
trap '\''kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true'\'' EXIT
ps -o pid= -p "$child" >/dev/null
kill "$child"
wait "$child" 2>/dev/null || true
trap - EXIT
! test -r "$1"
if touch "$1"; then rm -f "$1"; exit 70; fi
! kill -0 "$2" 2>/dev/null
if command -v curl >/dev/null 2>&1 && curl --max-time 2 -fsS http://1.1.1.1/ >/dev/null 2>&1; then exit 71; fi' \
      _ "$outside_probe" "$host_probe_pid" >/dev/null 2>&1 || supervisor_rc=$?
  fi
  kill "$host_probe_pid" 2>/dev/null || true
  wait "$host_probe_pid" 2>/dev/null || true
  rm -rf "$supervisor_parent"
  if [ "$supervisor_rc" -ne 0 ]; then
    echo "Supervisor process check failed inside the credentialless private container (exit $supervisor_rc): expose the current dev container to a working Docker CLI/socket so the sealed image can run with private process and network namespaces"
    exit 4
  fi
  echo "ok: Codex writer and supervisor sandboxes usable (start, staging, $thread_note, and $supervisor_note)"
  exit 0
fi

summary="$(printf '%s' "$out" | tr '\n' ' ' \
  | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c 1-200)"
[ -n "$summary" ] || summary="exit $rc"

if ! printf '%s\n' "$out" | grep -qiE 'bwrap|namespace|unshare|sandbox'; then
  echo "Codex sandbox smoke failed: $summary"
  exit 4
fi

# Namespace-class failure: distinguish a disabled sysctl from an outer
# runtime/LSM denial so the surfaced remedy is accurate.
sysctl_read() { sysctl -n "$1" 2>/dev/null || true; }
userns_clone="$(sysctl_read kernel.unprivileged_userns_clone)"
max_ns="$(sysctl_read user.max_user_namespaces)"
apparmor_restrict="$(sysctl_read kernel.apparmor_restrict_unprivileged_userns)"
unshare_state="unavailable"
if have_cmd unshare; then
  if unshare -Ur true 2>/dev/null; then unshare_state="allowed"; else unshare_state="denied"; fi
fi

if [ "$userns_clone" = "0" ]; then
  echo "$summary — unprivileged user namespaces disabled by sysctl: set kernel.unprivileged_userns_clone=1 on the host"
elif [ "$max_ns" = "0" ]; then
  echo "$summary — user namespace limit exhausted: raise user.max_user_namespaces on the host"
else
  detail="$summary — outer runtime/LSM denies the sandbox despite kernel.unprivileged_userns_clone=${userns_clone:-unset} and user.max_user_namespaces=${max_ns:-unset} (unshare -Ur: $unshare_state)"
  if [ "$apparmor_restrict" = "1" ]; then
    detail="$detail; kernel.apparmor_restrict_unprivileged_userns=1 with an enforcing container profile is the likely cause"
  fi
  echo "$detail: allow unprivileged user namespaces for this container in the outer runtime/AppArmor policy and keep the network-off workspace-write writer boundary"
fi
exit 4
