# Arming mission-control (one-time, human-only)

The scheduler is deterministic bash run from cron. Agents must never install
the cron line — you do, once.

1. **Config.** Copy `examples/portfolio.example.json` to a stable host path,
   e.g. `~/.config/mission-control/portfolio.json`. Fill in your real
   projects: container names (`docker ps`), in-container repo paths, stages,
   engines. Set `docker_cmd` to `sudo docker` if your user lacks docker
   socket group membership. Keep `container: "local"` for loops that run in
   the same container as cron (e.g. the plugin repo's lessons-deliver).
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
