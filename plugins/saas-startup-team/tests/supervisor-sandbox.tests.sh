# Private supervisor-check container regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "supervisor-sandbox.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_supervisor_sandbox() {
  echo -e "\n${CYAN}Suite SS: private supervisor check container${NC}"
  local script="$PLUGIN_ROOT/scripts/supervisor-check-container.sh"
  local digest_script="$PLUGIN_ROOT/scripts/runtime-tree-digest.py"
  local commit_script="$PLUGIN_ROOT/scripts/supervisor-commit.sh"
  local workdir root runtime fake log ec out meta digest
  local image="sha256:1111111111111111111111111111111111111111111111111111111111111111"

  assert_file_exists "SS1: supervisor container driver exists" "$script"
  assert_file_exists "SS2: runtime digest helper exists" "$digest_script"
  assert_file_contains "SS2a: trust snapshot bounds Docker metadata discovery" "$commit_script" \
    'timeout -k 5 30 "$path" --metadata'
  assert_equals "SS2b: every trusted Docker metadata read is bounded" \
    "$(grep -Fc 'timeout -k 5 30 ' "$commit_script")" 2
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ] && [ -x "$digest_script" ]; then
    echo -e "  ${GREEN}PASS${NC} SS3: supervisor container helpers are executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} SS3: supervisor container helpers are executable"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("SS3: supervisor container helpers are not executable")
  fi

  workdir=$(mktemp -d)
  root="$workdir/root"; runtime="$workdir/runtime"; fake="$workdir/docker"; log="$workdir/docker.log"
  mkdir -p "$root/.git" "$runtime/.bin"
  printf 'candidate\n' > "$root/value.txt"
  printf 'runtime\n' > "$runtime/value.txt"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
  printf '<call>\n'
  printf '%s\n' "$@"
} >> "$FAKE_DOCKER_LOG"
case "${1:-}" in
  inspect)
    if [ "${2:-}" = --type ]; then
      printf '%s %s\n' \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        sha256:1111111111111111111111111111111111111111111111111111111111111111
    else
      state=${FAKE_DOCKER_STATE:-$FAKE_DOCKER_LOG.state}
      mapfile -d '' -t saved < "$state"
      user= image=
      env_json=(); mount_json=()
      for ((i=0; i<${#saved[@]}; i++)); do
        case "${saved[$i]}" in
          --user) user=${saved[$((i+1))]} ;;
          --env) env_json+=("$(jq -Rn --arg v "${saved[$((i+1))]}" '$v')") ;;
          --mount)
            spec=${saved[$((i+1))]}
            name=${spec#*src=}; name=${name%%,*}
            dest=${spec#*dst=}; dest=${dest%%,*}
            rw=true; case ",$spec," in *,readonly,*) rw=false ;; esac
            mount_json+=("$(jq -cn --arg n "$name" --arg d "$dest" --argjson rw "$rw" \
              '{Name:$n,Destination:$d,RW:$rw,Type:"volume"}')")
            ;;
          sha256:*) image=${saved[$i]} ;;
        esac
      done
      envs=$(printf '%s\n' "${env_json[@]}" | jq -s .)
      mounts=$(printf '%s\n' "${mount_json[@]}" | jq -s .)
      jq -cn --arg image "$image" --arg user "$user" --argjson envs "$envs" \
        --argjson mounts "$mounts" '[{
          Image:$image,Config:{Image:$image,User:$user,Entrypoint:["/usr/bin/env"],
            Healthcheck:{Test:["NONE"]},Env:$envs},
          HostConfig:{ReadonlyRootfs:true,Privileged:false,NetworkMode:"none",PidMode:"",
            IpcMode:"private",CgroupnsMode:"private",CapDrop:["ALL"],
            SecurityOpt:["no-new-privileges"],Binds:[],Devices:[],VolumesFrom:[],ExtraHosts:[]},
          Mounts:$mounts
        }]'
    fi
    ;;
  image)
    case "$*" in
      *Config.Env*)
        printf '%s\n' 'SECRET_KEY=must-not-survive' 'PATH=/image/path'
        [ "${FAKE_ENV_INSPECT_FAIL:-0}" -eq 0 ] || exit 73
        ;;
      *Config.Volumes*) printf '%s\n' null ;;
      *) printf '%s\n' sha256:1111111111111111111111111111111111111111111111111111111111111111 ;;
    esac
    ;;
  info) printf '%s\n' test-daemon ;;
  volume)
    [ "${2:-}" != create ] || printf '%s\n' "${*: -1}"
    ;;
  run)
    case "$*" in
      *'dst=/dest'*)
        case " $* " in *' --user 0:0 '*) : ;; *) exit 77 ;; esac
        case "$*" in *'chown -R'*) : ;; *) exit 78 ;; esac
        cat >/dev/null
        ;;
    esac
    case "$*" in
      *GIT_OPTIONAL_LOCKS=0*)
        fingerprint_state="${FAKE_DOCKER_LOG}.fingerprints"
        count=0; [ ! -f "$fingerprint_state" ] || count=$(cat "$fingerprint_state")
        count=$((count + 1)); printf '%s\n' "$count" > "$fingerprint_state"
        if [ "${FAKE_POST_FINGERPRINT_CHANGE:-0}" = 1 ] && [ "$count" -gt 1 ]; then
          printf '%040d\n%040d\n' 3 4
        else
          printf '%040d\n%040d\n' 1 2
        fi
        exit 0
        ;;
    esac
    case "$*" in *'dst=/runtime,readonly'*) printf '%s\n' "$FAKE_RUNTIME_DIGEST" ;; esac
    ;;
  create)
    state=${FAKE_DOCKER_STATE:-$FAKE_DOCKER_LOG.state}
    printf '%s\0' "$@" > "$state"
    printf '%s\n' fake-container
    ;;
  start) exit "${FAKE_FINAL_RC:-0}" ;;
  rm) ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fake"
  : > "$log"
  ec=0; meta=$(FAKE_DOCKER_LOG="$log" SAAS_CURRENT_CONTAINER_ID=test \
    bash "$script" --metadata --docker-bin "$fake" 2>&1) || ec=$?
  assert_exit_code "SS4: sealed Docker metadata resolves" "$ec" 0
  assert_equals "SS5: metadata pins the image ID" "$(jq -r .image_id <<<"$meta")" "$image"
  assert_equals "SS6: metadata pins the daemon" "$(jq -r .daemon_id <<<"$meta")" test-daemon

  : > "$log"
  ec=0; FAKE_DOCKER_LOG="$log" FAKE_RUNTIME_DIGEST=unused \
    bash "$script" -C "$root" --docker-bin "$fake" --image-id "$image" \
      --daemon-id test-daemon --checkout-alias /workspace/project -- /bin/true || ec=$?
  assert_exit_code "SS7: private container invocation succeeds" "$ec" 0
  assert_file_contains "SS8: final check has no network" "$log" '^none$'
  assert_file_contains "SS9: final root filesystem is read-only" "$log" '^--read-only$'
  assert_file_contains "SS10: final check drops all capabilities" "$log" '^ALL$'
  assert_file_contains "SS11: final check forbids privilege gain" "$log" '^no-new-privileges$'
  assert_file_contains "SS12: final check uses a private cgroup namespace" "$log" '^private$'
  assert_file_contains "SS13: candidate is mounted at the neutral root" "$log" \
    'dst=/dev/shm/saas-check'
  assert_file_contains "SS14: candidate overlays the original checkout" "$log" \
    'dst=/workspace/project'
  assert_file_contains "SS15: Git metadata is mounted read-only" "$log" \
    'dst=/dev/shm/saas-check/.git,readonly'
  assert_file_contains "SS16: image credential variables are blanked" "$log" '^SECRET_KEY=$'
  assert_file_contains "SS17: candidate starts under a clean environment" "$log" '^-i$'
  assert_file_contains "SS17a: volume population uses an explicit root helper" "$log" '^0:0$'
  assert_file_contains "SS17b: populated volumes are assigned to the check user" "$log" 'chown -R'
  assert_file_contains "SS17c: check fingerprint includes non-ignored generated files" "$script" \
    '--untracked-files=all'
  assert_file_not_contains "SS17d: check fingerprint never omits untracked state" "$script" \
    '--untracked-files=no'
  assert_file_contains "SS17e: clean check PATH retains baked-in Go tools" "$log" \
    '/usr/local/go/bin'
  assert_file_contains "SS17f: clean check PATH retains baked-in Rust tools" "$log" \
    '/usr/local/cargo/bin'

  : > "$log"
  ec=0; out=$(FAKE_DOCKER_LOG="$log" FAKE_RUNTIME_DIGEST=unused FAKE_ENV_INSPECT_FAIL=1 \
    bash "$script" -C "$root" --docker-bin "$fake" --image-id "$image" \
      --daemon-id test-daemon --checkout-alias /workspace/project -- /bin/true 2>&1) || ec=$?
  assert_exit_code "SS17g: failed image-environment inspection fails closed" "$ec" 1
  assert_output_contains "SS17h: image-environment failure is explicit" "$out" \
    'cannot inspect dev-container environment'
  assert_file_not_contains "SS17i: failed environment inspection creates no volume" "$log" '^create$'

  digest=$(python3 "$digest_script" "$runtime" deps)
  : > "$log"
  ec=0; FAKE_DOCKER_LOG="$log" FAKE_RUNTIME_DIGEST="$digest" \
    bash "$script" -C "$root" --docker-bin "$fake" --image-id "$image" \
      --daemon-id test-daemon --checkout-alias /workspace/project \
      --runtime "$runtime" deps "$digest" -- /bin/true || ec=$?
  assert_exit_code "SS18: copied sealed runtime is accepted" "$ec" 0
  assert_file_contains "SS19: runtime is read-only at neutral path" "$log" \
    'dst=/dev/shm/saas-check/deps,readonly'
  assert_file_contains "SS20: runtime is read-only at editable-install alias" "$log" \
    'dst=/workspace/project/deps,readonly'

  : > "$log"
  ec=0; out=$(FAKE_DOCKER_LOG="$log" FAKE_RUNTIME_DIGEST=0000000000000000000000000000000000000000000000000000000000000000 \
    bash "$script" -C "$root" --docker-bin "$fake" --image-id "$image" \
      --daemon-id test-daemon --checkout-alias /workspace/project \
      --runtime "$runtime" deps "$digest" -- /bin/true 2>&1) || ec=$?
  assert_exit_code "SS21: changed copied runtime fails closed" "$ec" 1
  assert_output_contains "SS22: copied-runtime failure is explicit" "$out" \
    'copied runtime differs from the signed tree'

  : > "$log"
  ec=0; out=$(FAKE_DOCKER_LOG="$log" FAKE_RUNTIME_DIGEST=unused \
    bash "$script" -C "$root" --docker-bin "$fake" --image-id "$image" \
      --daemon-id test-daemon --checkout-alias /usr -- /bin/true 2>&1) || ec=$?
  assert_exit_code "SS23: system checkout alias is rejected" "$ec" 1
  assert_file_not_contains "SS24: rejected alias creates no volume" "$log" '^create$'

  : > "$log"
  ec=0; FAKE_DOCKER_LOG="$log" FAKE_RUNTIME_DIGEST=unused FAKE_FINAL_RC=37 \
    bash "$script" -C "$root" --docker-bin "$fake" --image-id "$image" \
      --daemon-id test-daemon --checkout-alias /workspace/project -- /bin/false || ec=$?
  assert_exit_code "SS25: check failure status is preserved" "$ec" 37
  assert_file_contains "SS26: failed check still removes volumes" "$log" '^rm$'

  : > "$log"; rm -f "${log}.fingerprints"
  ec=0; out=$(FAKE_DOCKER_LOG="$log" FAKE_RUNTIME_DIGEST=unused \
    FAKE_POST_FINGERPRINT_CHANGE=1 \
    bash "$script" -C "$root" --docker-bin "$fake" --image-id "$image" \
      --daemon-id test-daemon --checkout-alias /workspace/project -- /bin/true 2>&1) || ec=$?
  assert_exit_code "SS27: tracked mutation during checks fails closed" "$ec" 1
  assert_output_contains "SS28: tracked-mutation failure is explicit" "$out" \
    'checks modified tracked candidate files'

  rm -rf "$workdir"
}

test_supervisor_sandbox
