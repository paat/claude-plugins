#!/usr/bin/env bash
# Run the authoritative product check in a private sibling container.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIGEST_SCRIPT="$SCRIPT_DIR/runtime-tree-digest.py"
DOCKER_BIN=
ROOT=
IMAGE_ID=
DAEMON_ID=
CHECKOUT_ALIAS=
ACTION=run
RUNTIME_SOURCES=()
RUNTIME_TARGETS=()
RUNTIME_DIGESTS=()

usage() {
  echo "usage: supervisor-check-container.sh --metadata [--docker-bin FILE]" >&2
  echo "       supervisor-check-container.sh -C ROOT --docker-bin FILE --image-id ID --daemon-id ID --checkout-alias PATH [--runtime SOURCE TARGET DIGEST]... -- COMMAND..." >&2
  exit 2
}

need_value() { [ "$#" -ge 2 ] || usage; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --metadata) ACTION=metadata; shift ;;
    --docker-bin) need_value "$@"; DOCKER_BIN=$2; shift 2 ;;
    -C) need_value "$@"; ROOT=$2; shift 2 ;;
    --image-id) need_value "$@"; IMAGE_ID=$2; shift 2 ;;
    --daemon-id) need_value "$@"; DAEMON_ID=$2; shift 2 ;;
    --checkout-alias) need_value "$@"; CHECKOUT_ALIAS=$2; shift 2 ;;
    --runtime)
      [ "$#" -ge 4 ] || usage
      RUNTIME_SOURCES+=("$2"); RUNTIME_TARGETS+=("${3%/}"); RUNTIME_DIGESTS+=("$4")
      shift 4
      ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) echo "supervisor-check-container: unsupported argument: $1" >&2; usage ;;
  esac
done
COMMAND=("$@")

resolve_docker() {
  local path
  if [ -n "$DOCKER_BIN" ]; then path=$DOCKER_BIN
  else path=$(command -v docker 2>/dev/null) || return 1
  fi
  path=$(readlink -f -- "$path")
  [ -f "$path" ] && [ -x "$path" ] && [ ! -L "$path" ] || return 1
  printf '%s\n' "$path"
}

metadata() {
  local docker container record container_id image_id daemon_id identity mode digest
  docker=$(resolve_docker) || {
    echo "supervisor-check-container: Docker CLI is unavailable" >&2; return 1; }
  container=${SAAS_CURRENT_CONTAINER_ID:-${HOSTNAME:-}}
  [[ "$container" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "supervisor-check-container: current container identity is unavailable" >&2; return 1; }
  record=$($docker inspect --type container --format '{{.Id}} {{.Image}}' "$container" 2>/dev/null) || {
    echo "supervisor-check-container: current dev container is not visible to Docker" >&2; return 1; }
  read -r container_id image_id extra <<<"$record"
  [ -n "$container_id" ] && [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] && [ -z "${extra:-}" ] || return 1
  [ "$($docker image inspect --format '{{.Id}}' "$image_id" 2>/dev/null)" = "$image_id" ] || return 1
  daemon_id=$($docker info --format '{{.ID}}' 2>/dev/null) || return 1
  [ -n "$daemon_id" ] || return 1
  identity=$(stat -Lc '%d:%i' -- "$docker") || return 1
  mode=$(stat -Lc '%a' -- "$docker") || return 1
  digest=$(sha256sum -- "$docker" | awk '{print $1}') || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  jq -cn --arg path "$docker" --arg identity "$identity" --arg mode "$mode" \
    --arg sha256 "$digest" --arg daemon_id "$daemon_id" --arg image_id "$image_id" \
    --arg container_id "$container_id" \
    '{docker:{path:$path,identity:$identity,mode:$mode,sha256:$sha256},daemon_id:$daemon_id,image_id:$image_id,container_id:$container_id}'
}

if [ "$ACTION" = metadata ]; then
  [ "${#COMMAND[@]}" -eq 0 ] && [ -z "$ROOT$IMAGE_ID$DAEMON_ID$CHECKOUT_ALIAS" ] \
    && [ "${#RUNTIME_SOURCES[@]}" -eq 0 ] || usage
  metadata
  exit
fi

[ "${#COMMAND[@]}" -gt 0 ] && [ -n "$ROOT" ] && [ -n "$IMAGE_ID" ] \
  && [ -n "$DAEMON_ID" ] && [ -n "$CHECKOUT_ALIAS" ] || usage
DOCKER_BIN=$(resolve_docker) || { echo "supervisor-check-container: sealed Docker CLI is unavailable" >&2; exit 1; }
ROOT=$(cd "$ROOT" && pwd -P)
[ -d "$ROOT/.git" ] && [ ! -L "$ROOT/.git" ] || {
  echo "supervisor-check-container: check root must be a disposable clone" >&2; exit 1; }
case "$CHECKOUT_ALIAS" in
  /*) ;;
  *) echo "supervisor-check-container: checkout alias must be absolute" >&2; exit 1 ;;
esac
case "$CHECKOUT_ALIAS" in
  /|/bin|/dev|/etc|/lib|/lib64|/proc|/run|/sbin|/sys|/usr|*,*|*:*|*$'\n'*|*$'\r'*|*$'\t'*)
    echo "supervisor-check-container: unsafe checkout alias" >&2; exit 1 ;;
esac
[[ "$IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "supervisor-check-container: invalid image identity" >&2; exit 1; }
[ "$($DOCKER_BIN info --format '{{.ID}}' 2>/dev/null)" = "$DAEMON_ID" ] || {
  echo "supervisor-check-container: Docker daemon identity changed" >&2; exit 1; }
[ "$($DOCKER_BIN image inspect --format '{{.Id}}' "$IMAGE_ID" 2>/dev/null)" = "$IMAGE_ID" ] || {
  echo "supervisor-check-container: sealed dev-container image is unavailable" >&2; exit 1; }
image_volumes=$($DOCKER_BIN image inspect --format '{{json .Config.Volumes}}' "$IMAGE_ID") || exit 1
[ "$image_volumes" = null ] || [ "$(jq 'length' <<<"$image_volumes")" -eq 0 ] || {
  echo "supervisor-check-container: sealed image declares implicit writable volumes" >&2; exit 1; }
IMAGE_ENV_ARGS=()
declare -A IMAGE_ENV_SEEN=()
image_env_inventory=$(mktemp) || exit 1
if ! "$DOCKER_BIN" image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
  "$IMAGE_ID" > "$image_env_inventory"; then
  rm -f -- "$image_env_inventory"
  echo "supervisor-check-container: cannot inspect dev-container environment" >&2
  exit 1
fi
while IFS= read -r key; do
  key=${key%%=*}
  [ -z "$key" ] && continue
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    rm -f -- "$image_env_inventory"
    echo "supervisor-check-container: dev-container image has an invalid environment key" >&2; exit 1; }
  [[ ${IMAGE_ENV_SEEN[$key]+present} ]] && continue
  IMAGE_ENV_SEEN["$key"]=1
  IMAGE_ENV_ARGS+=(--env "$key=")
done < "$image_env_inventory"
rm -f -- "$image_env_inventory"

valid_target() {
  case "$1" in ''|.|/*|*,*|*:*|*$'\n'*|*$'\r'*|*$'\t'*|../*|*/../*|*/..|./*|*/./*|*/.) return 1 ;; esac
}

for ((i=0; i<${#RUNTIME_SOURCES[@]}; i++)); do
  source=${RUNTIME_SOURCES[$i]}; target=${RUNTIME_TARGETS[$i]}; expected=${RUNTIME_DIGESTS[$i]}
  [ -d "$source" ] && [ ! -L "$source" ] && valid_target "$target" \
    && [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    echo "supervisor-check-container: invalid sealed runtime" >&2; exit 1; }
done

uid=$(id -u); gid=$(id -g)
[ "$uid" -ne 0 ] && [ "$gid" -ne 0 ] || {
  echo "supervisor-check-container: authoritative checks require a non-root dev user" >&2; exit 1; }
nonce="$$-$RANDOM-$RANDOM"
source_volume="saas-check-source-$nonce"
git_volume="saas-check-git-$nonce"
RUNTIME_VOLUMES=()
CREATED_VOLUMES=()
CHECK_CONTAINER=

cleanup() {
  local volume
  [ -z "$CHECK_CONTAINER" ] || "$DOCKER_BIN" rm -f "$CHECK_CONTAINER" >/dev/null 2>&1 || true
  for volume in "${CREATED_VOLUMES[@]}"; do
    "$DOCKER_BIN" volume rm -f "$volume" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

create_volume() {
  "$DOCKER_BIN" volume create --label saas-startup-team.supervisor-check=1 "$1" >/dev/null
  CREATED_VOLUMES+=("$1")
}

container_base=(--rm --pull never --network none --read-only --cap-drop ALL --cap-add CHOWN --cap-add FOWNER
  --security-opt no-new-privileges --pids-limit 256 --tmpfs /tmp:rw,nosuid,nodev
  --no-healthcheck "${IMAGE_ENV_ARGS[@]}" --entrypoint /usr/bin/env)
clean_env=(-i HOME=/tmp PATH=/usr/local/sbin:/usr/local/bin:/usr/local/go/bin:/usr/local/cargo/bin:/usr/sbin:/usr/bin:/sbin:/bin
  LANG=C.UTF-8 LC_ALL=C.UTF-8 CI=1 GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1)

populate_volume() {
  local source=$1 volume=$2
  tar -C "$source" --format=posix -cpf - . | \
    "$DOCKER_BIN" run "${container_base[@]}" --user 0:0 -i \
      --mount "type=volume,src=$volume,dst=/dest" "$IMAGE_ID" \
      "${clean_env[@]}" /bin/bash -c '
        /bin/tar --no-same-owner -xpf - -C /dest
        /bin/chown -R "$1:$2" /dest
      ' _ "$uid" "$gid"
}

create_volume "$source_volume"
create_volume "$git_volume"
tar -C "$ROOT" --format=posix --exclude='./.git' -cpf - . | \
  "$DOCKER_BIN" run "${container_base[@]}" --user 0:0 -i \
    --mount "type=volume,src=$source_volume,dst=/dest" "$IMAGE_ID" \
    "${clean_env[@]}" /bin/bash -c '
      /bin/tar --no-same-owner -xpf - -C /dest
      mkdir -p /dest/.git
      chown -R "$1:$2" /dest
    ' _ "$uid" "$gid"
populate_volume "$ROOT/.git" "$git_volume"

digest_code=$(cat "$DIGEST_SCRIPT")
for ((i=0; i<${#RUNTIME_SOURCES[@]}; i++)); do
  volume="saas-check-runtime-$i-$nonce"
  create_volume "$volume"
  RUNTIME_VOLUMES+=("$volume")
  populate_volume "${RUNTIME_SOURCES[$i]}" "$volume"
  actual=$(
    "$DOCKER_BIN" run "${container_base[@]}" \
      --mount "type=volume,src=$volume,dst=/runtime,readonly" "$IMAGE_ID" \
      "${clean_env[@]}" python3 -c "$digest_code" /runtime "${RUNTIME_TARGETS[$i]}"
  ) || { echo "supervisor-check-container: copied runtime validation failed" >&2; exit 1; }
  [ "$actual" = "${RUNTIME_DIGESTS[$i]}" ] || {
    echo "supervisor-check-container: copied runtime differs from the signed tree" >&2; exit 1; }
done

volume_fingerprint() {
  "$DOCKER_BIN" run "${container_base[@]}" --user "$uid:$gid" \
    --mount "type=volume,src=$source_volume,dst=/dev/shm/saas-check,readonly" \
    --mount "type=volume,src=$git_volume,dst=/dev/shm/saas-check/.git,readonly" \
    --workdir /dev/shm/saas-check "$IMAGE_ID" "${clean_env[@]}" \
    GIT_OPTIONAL_LOCKS=0 /bin/bash -c '
      set -euo pipefail
      git -c core.fsmonitor=false diff --binary --no-ext-diff --no-textconv \
        | git hash-object --stdin
      git -c core.fsmonitor=false status --porcelain=v1 --untracked-files=all \
        | git hash-object --stdin
    '
}

PRE_CHECK_VOLUME=$(volume_fingerprint) || {
  echo "supervisor-check-container: copied candidate validation failed" >&2; exit 1; }

container_name="saas-supervisor-check-$nonce"
run_args=(create --rm --pull never --name "$container_name" --network none
  --ipc private --cgroupns private --read-only
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 4096
  --ulimit core=0 --hostname saas-check
  --no-healthcheck "${IMAGE_ENV_ARGS[@]}"
  --user "$uid:$gid" --tmpfs /tmp:rw,nosuid,nodev,mode=1777
  --tmpfs /run:rw,nosuid,nodev,mode=755 --tmpfs /home:rw,nosuid,nodev,mode=755
  --tmpfs /root:rw,nosuid,nodev,mode=700 --workdir /dev/shm/saas-check
  --entrypoint /usr/bin/env
  --mount "type=volume,src=$source_volume,dst=/dev/shm/saas-check"
  --mount "type=volume,src=$git_volume,dst=/dev/shm/saas-check/.git,readonly"
  --mount "type=volume,src=$source_volume,dst=$CHECKOUT_ALIAS"
  --mount "type=volume,src=$git_volume,dst=$CHECKOUT_ALIAS/.git,readonly")
for ((i=0; i<${#RUNTIME_VOLUMES[@]}; i++)); do
  target=${RUNTIME_TARGETS[$i]}; volume=${RUNTIME_VOLUMES[$i]}
  run_args+=(--mount "type=volume,src=$volume,dst=/dev/shm/saas-check/$target,readonly")
  run_args+=(--mount "type=volume,src=$volume,dst=$CHECKOUT_ALIAS/$target,readonly")
done

EXPECTED_MOUNTS=()
EXPECTED_MOUNTS+=("$(jq -cn --arg n "$source_volume" --arg d /dev/shm/saas-check \
  '{Name:$n,Destination:$d,RW:true,Type:"volume"}')")
EXPECTED_MOUNTS+=("$(jq -cn --arg n "$git_volume" --arg d /dev/shm/saas-check/.git \
  '{Name:$n,Destination:$d,RW:false,Type:"volume"}')")
EXPECTED_MOUNTS+=("$(jq -cn --arg n "$source_volume" --arg d "$CHECKOUT_ALIAS" \
  '{Name:$n,Destination:$d,RW:true,Type:"volume"}')")
EXPECTED_MOUNTS+=("$(jq -cn --arg n "$git_volume" --arg d "$CHECKOUT_ALIAS/.git" \
  '{Name:$n,Destination:$d,RW:false,Type:"volume"}')")
for ((i=0; i<${#RUNTIME_VOLUMES[@]}; i++)); do
  target=${RUNTIME_TARGETS[$i]}; volume=${RUNTIME_VOLUMES[$i]}
  EXPECTED_MOUNTS+=("$(jq -cn --arg n "$volume" --arg d "/dev/shm/saas-check/$target" \
    '{Name:$n,Destination:$d,RW:false,Type:"volume"}')")
  EXPECTED_MOUNTS+=("$(jq -cn --arg n "$volume" --arg d "$CHECKOUT_ALIAS/$target" \
    '{Name:$n,Destination:$d,RW:false,Type:"volume"}')")
done
expected_mounts=$(printf '%s\n' "${EXPECTED_MOUNTS[@]}" | jq -cs 'sort_by(.Destination)')

CHECK_CONTAINER=$("$DOCKER_BIN" "${run_args[@]}" "$IMAGE_ID" "${clean_env[@]}" "${COMMAND[@]}") || {
  echo "supervisor-check-container: could not create private check container" >&2; exit 1; }
container_json=$("$DOCKER_BIN" inspect "$CHECK_CONTAINER" | jq '.[0]') || exit 1
jq -e --arg image "$IMAGE_ID" --arg user "$uid:$gid" --argjson mounts "$expected_mounts" '
  .Image == $image and .Config.Image == $image and
  .Config.User == $user and .Config.Entrypoint == ["/usr/bin/env"] and
  .Config.Healthcheck.Test == ["NONE"] and
  (.Config.Env|type == "array" and all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*=$"))) and
  .HostConfig.ReadonlyRootfs == true and .HostConfig.Privileged == false and
  .HostConfig.NetworkMode == "none" and .HostConfig.PidMode == "" and
  .HostConfig.IpcMode == "private" and .HostConfig.CgroupnsMode == "private" and
  .HostConfig.CapDrop == ["ALL"] and
  (.HostConfig.SecurityOpt|index("no-new-privileges") != null) and
  ((.HostConfig.Binds // [])|length == 0) and
  ((.HostConfig.Devices // [])|length == 0) and
  ((.HostConfig.VolumesFrom // [])|length == 0) and
  ((.HostConfig.ExtraHosts // [])|length == 0) and
  ([.Mounts[] | {Name,Destination,RW,Type}] | sort_by(.Destination)) == $mounts
' <<<"$container_json" >/dev/null || {
  echo "supervisor-check-container: created container failed isolation validation" >&2; exit 1; }

set +e
"$DOCKER_BIN" start -a "$CHECK_CONTAINER"
rc=$?
set -e
CHECK_CONTAINER=
POST_CHECK_VOLUME=$(volume_fingerprint) || {
  echo "supervisor-check-container: post-check candidate validation failed" >&2; exit 1; }
[ "$POST_CHECK_VOLUME" = "$PRE_CHECK_VOLUME" ] || {
  echo "supervisor-check-container: checks modified tracked candidate files" >&2; exit 1; }
exit "$rc"
