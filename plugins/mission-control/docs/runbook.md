# Arming mission-control (one-time, human-only)

The scheduler is deterministic bash run from cron. Agents must never install
the cron line — you do, once.

1. **Config.** Copy `examples/portfolio.example.json` to a stable host path,
   e.g. `~/.config/mission-control/portfolio.json`. Fill in your real
   projects: container names (`docker ps`), in-container repo paths, stages,
   engines. Set `docker_cmd` to `sudo docker` if your user lacks docker
   socket group membership. Keep `container: "local"` for loops that run in
   the same container as cron (e.g. the plugin repo's lessons-deliver). Set
   `docker_exec_user` to the authenticated development user, leave
   `delivery_hold` absent, and run Codex with
   `--dangerously-bypass-approvals-and-sandbox` without `--ephemeral`.
2. **Prerequisites.** `jq`, `flock`, GNU `date`, `curl` on the cron host;
   `gh` authenticated inside every project container; the assistant CLIs
   (`claude`, `codex`) installed wherever their engine's passes run. Engine
   `cmd` templates run through non-login `bash -c` — if a container only
   provisions PATH in login shells, wrap the template:
   `bash -lc 'claude … {prompt}'` won't work (quoting); instead use absolute
   CLI paths in the template.
3. **Validate + print the cron line:**
   `bash plugins/mission-control/scripts/mission-control.sh arm --config <path>`
4. **Install.** Paste the printed line into your persistent crontab file
   (LinuxServer-style containers: `/config/crontabs/<user>`, then restart the
   container or run `crontab /config/crontabs/<user>`). Delete any standalone
   lessons-deliver cron line — mission-control now owns that dispatch.
5. **Set the push URL** (optional but recommended: veto announcements arrive
   here): add `MC_NTFY_URL=https://ntfy.sh/<topic>` (or your `notify_env`
   name) to the crontab environment block.
6. **Verify.** `… tick --config <path> --dry-run` prints every decision
   without dispatching. Watch `state/cron.log` and `state/mission-control.log`
   after the first real ticks; `/mission-status` shows slots and outcomes.
7. **Upgrade path.** The cron line points into this repo clone — `git pull`
   updates the scheduler; config and state are outside the repo and survive.
8. **Veto / pause.** Set `"hold": true` on any project entry. Pre-launch
   admissions announce via push + digest and wait `veto_hours` (default 72)
   before the first dispatch.
9. **Digest.** The daily digest (first tick after `digest_hour`, default 7)
   aggregates each project's own digest, then warnings and the spend
   summary. When mission-control owns a project's digest delivery, disable
   that project's own digest send wiring (monitor-nightly) — two senders
   race the mark-sent cursor and double-deliver.
10. **Kill switch.** Set top-level `"paused": true` in the portfolio config to
    stop all dispatching at the next tick — the tick exits immediately after
    taking the lock, with no dispatch and no digest. Set it back to `false`
    to resume. `arm` rejects any non-boolean value; at tick time a malformed
    value also fails closed (skips dispatch and logs a config error) rather
    than dispatching.
11. **Custom digest sections.** Set the optional top-level
    `"digest_sections_dir": "<abs dir>"` to a host directory of `*.md` files.
    Every file in it (lexicographic order) must start with a `## ` heading;
    each is appended verbatim as its own section in the daily digest, and
    the same sections lead the push notification. Useful for steering memos
    or other host-authored content that isn't tied to any one project.

# Cross-container handoff bus

`scripts/bus.sh` lets one loop hand a message to another over a shared-mount
directory — no daemon, no queue. Transport is one JSON file per message,
written tmp+mv so a poller never sees a partial. Layout under the bus dir:
`<recipient>/inbox/<msg-id>.json`; a reader acks by `mv` into
`<recipient>/done/`. Envelope: `{id, from, to, created, reply_to?, subject,
body}`, msg-id `<epoch>-<from>-<hex>`. Bodies cap at 64KB — put large payloads
on the shared mount and send the path.

**Dir resolution:** `--dir` flag > `MC_BUS_DIR` env > `bus_dir` from the config
(`MC_CONFIG`). Names (`--to`/`--from`/`--name`) must match `[A-Za-z0-9_-]`.

**Shared mount across containers.** Set the top-level `bus_dir` to the host
path of the shared directory. A container that mounts it elsewhere records the
in-container path as that project's `bus_path`; inside that container, export
`MC_BUS_DIR=<bus_path>` (or pass `--dir`) so both ends read and write the same
files. Example — host bind-mounts `/srv/mission-control/bus` into
`project-b-dev` at `/workspace/bus`:

```
# on the host (config .bus_dir = /srv/mission-control/bus)
bus.sh send --to project-b --from host --subject deploy --body "cut rc" --config <path>

# inside project-b-dev (bus_path = /workspace/bus)
MC_BUS_DIR=/workspace/bus bus.sh poll --name project-b --consume
MC_BUS_DIR=/workspace/bus bus.sh send --to host --from project-b \
  --subject ack --body done --reply-to <msg-id>

# host waits for the round trip
bus.sh wait --name host --reply-to <msg-id> --timeout 300 --config <path>
```

`gc` deletes `done/` entries older than `retention_days` (default 14); run it
from cron alongside the tick if the bus sees heavy traffic.
