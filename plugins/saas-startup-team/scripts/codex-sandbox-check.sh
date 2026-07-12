#!/usr/bin/env bash
# Model-free Codex writer-sandbox smoke with root-cause diagnosis.
# Exit 0: writer sandbox usable. Exit 4: hard environment block (diagnosis on
# stdout, names a safe host-side remedy; never suggests danger-full-access).
# Exit 10: Codex CLI not found. Exit 2: usage.
set -euo pipefail

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
if ! codex sandbox --help >/dev/null 2>&1; then
  echo "Codex CLI lacks sandbox smoke support; update Codex before launching separate workers"
  exit 4
fi

rc=0
out="$(timeout "$TIMEOUT" codex sandbox --permission-profile :workspace \
  --sandbox-state-disable-network -C "$ROOT" /bin/pwd 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "ok: Codex writer sandbox usable with network-off workspace-write"
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
