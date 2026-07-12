---
name: fleet-propagate
description: Use when a configuration change (env var, shell alias, plugin marketplace, agent setting, CLAUDE.md rule) must be applied everywhere — the host, every dev/webtop container, container init scripts, and container-creator skills — idempotently and with per-target verification, so future containers inherit it and no target is missed.
---

# Fleet-wide config propagation

Manual fleet propagation re-derives the target list every time and misses one.
This skill fixes the shape: enumerate targets from a manifest, apply the same
managed block everywhere, verify each target, bake the change into creator
skills so drift stops at the source, and report a per-target matrix.

## Steps

1. **Write the change once.** Put the exact content (env exports, alias lines,
   settings fragment) in a temp file. One change = one block id
   (`kebab-case`, stable across reruns — reruns must be no-ops).
2. **Enumerate targets:**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/fleet-targets.sh" list [--manifest ~/.config/fleet-propagate/fleet.json]
   ```
   Output is `NAME\tKIND\tEXEC` — host, running containers (via the manifest's
   docker filters), and file targets (init scripts, creator skills). If docker
   is unreachable it says so and exits 1: the container list is incomplete,
   report that rather than silently covering less.
3. **Apply per target** with the idempotent block primitive:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/managed-block.sh" apply \
     --file <target-file> --id <change-id> --content-file /tmp/change.txt [--create]
   ```
   - host / file targets: run directly on the path (shell rc, init script,
     creator skill file — baking into creators IS just another file target).
   - container targets: copy the content file in (`docker cp`) or pipe it, and
     run the same primitive inside via the printed EXEC prefix; the plugin
     scripts are plain bash, so `docker cp` the script or mount it.
   - `apply` prints `created|changed|unchanged` — `unchanged` on rerun is the
     idempotency proof. Use `--comment '//'` or another prefix for files where
     `#` is not a comment.
   - Live shells: an applied rc-file block does not affect already-running
     shells; note that in the matrix (`needs manual: source or restart`).
4. **Verify per target** — never trust the apply:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/managed-block.sh" verify --file <f> --id <id> --content-file /tmp/change.txt
   ```
   For semantic changes, additionally run one behavior probe on the target
   (e.g. `docker exec <c> bash -lc 'echo $MY_VAR'`).
5. **Report the matrix** — one line per target:
   `target | applied (created/changed/unchanged) | verified (yes/no) | notes`.
   Every target from step 2 must appear; a target you could not reach is
   `needs manual attention`, never omitted.

Independent targets parallelize well — one subagent per container with the
same content file and id — but only when the target count makes the fan-out
pay for itself.

## Manifest

`~/.config/fleet-propagate/fleet.json` (per host, never committed to a repo):

```json
{
  "docker_cmd": "docker",
  "docker_exec_user": "dev",
  "container_filters": ["name=webtop", "name=devbox"],
  "exclude_containers": ["webtop-old"],
  "init_scripts": ["~/containers/init/*.sh"],
  "creator_skills": ["~/.claude/skills/container-creator/SKILL.md"]
}
```

The same manifest is reusable by other tooling (e.g. session-preflight) as the
shared target inventory.
