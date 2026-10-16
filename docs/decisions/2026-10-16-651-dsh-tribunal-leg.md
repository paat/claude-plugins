# DeepSeek Harness (dsh) as the tribunal DeepSeek leg

Research memo for #651, 2026-10-16. Probed against `dsh` 0.2.0-rc.2 in an aibox dev container (Claude Sonnet 5.5 investigation leg; load-bearing probes re-checked by the orchestrator: the overlay composes under `--dump-config`, `--json` emits one `final` event plus `status`/`turn_end` with `reason.kind`, and the fixture stayed unmodified). dsh is a developer preview; re-probe `dsh --profile headless --help` before relying on flags after an upgrade.

`dsh` can run a read-only, repo-walking, one-shot review leg. Writes are refused, `git log`/`git diff`/`git show` and file reads work, and `env -i` with just `PATH` and `HOME` works. Two caveats matter for a tribunal leg: the agent can read any file the user can, and the sandbox allows network egress.

I made 5 real model calls, plus 3 key-less and 1 fake-server run that made no model call. The fixture stayed clean (`git status` empty, no `WRITE_TEST.txt`). Run 1 used the real `~/.dsh` and left one session there (about 22 KB). `~/.dsh/.env` and the npm package were not modified.

## Recommended leg invocation

Overlay file `review.patch.yml` (verified to compose via `--dump-config`):
```yaml
- id: agent-default-model
  config: {provider: deepseek-official, model: deepseek-v4-pro, reasoningEffort: high}
- id: sandbox-policy
  config: {mode: read-only, workspaceRoot: !!js process.cwd()}
- id: approval
  config: {policy: never}
- id: permission            # else a harmless "did not activate" warning (read-only+never matches no preset)
  disabled: true
- id: session-log-deepseek  # default ON: uploads the session log to the DeepSeek API as a request field
  config: {enabled: false}
- id: session-telemetry-otel
  config: {mode: DISABLED}
- id: tool-web
  disabled: true
```
Invocation, from the disposable checkout:
```sh
H=$(mktemp -d)
tribunal_leg_env DEEPSEEK_API_KEY DSH_HOME -- timeout -k 10 720 \
  dsh --profile headless --patch /abs/review.patch.yml --json - < prompt.txt > out.jsonl
```
Set `DSH_HOME="$H"` and `DEEPSEEK_API_KEY` (read from `~/.dsh/.env`) as env extras. The `env -i` allowlist needs `DSH_*`. I tested this exact shape in run 4: no `.env` in the temp home, key passed by env, exit 0.

Extraction: take the last line with `"type":"final"` and read `.text`. Accept it only if the process exited 0 and the `turn_end` event has `reason.kind=="completed"`.

## Answers

**1. Headless one-shot (A).** `dsh --profile headless [--json] -` reads the prompt from stdin, and cwd is the workspace root. Exit 0 means the final `turn/end` was `completed`; anything else exits 1.
- Observed: `exit=0`, 5–13 s per run.
- Also from the help text: `dsh headless "task"` is shown as an alias, and `--session-id` resumes a session.

**2. Read-only (A, proven).** `sandbox-policy` `mode: read-only`, set in the overlay or via env `DSH_PERMISSION_MODE=read-only` (the base config reads it). You cannot remove `write`/`edit` individually, because `tool-fs` is one plugin and `bash` is separate. The sandbox denies the writes instead (bwrap with a read-only host root, falling back to Landlock).
- `write` tool: `Error: [sandbox: file access denied under read-only mode]`.
- bash `echo x > WRITE_TEST.txt`: `Permission denied`, exit 1.
- bash `git commit`: `Unable to create '.git/index.lock': Permission denied`, exit 128.
- bash `touch /tmp/...`: `Permission denied`.
- bash `git log -p`, `git show`, `git status`, `git diff HEAD`, `ls`, and the `read` and `glob` tools all work.
- Escalation retry: the model retried with `sandbox_permissions`. That was refused with `sandbox escalation to "workspace-write" requires approval, but no approval channel is available`. `approval: never` makes the refusal deterministic and tells the model not to try.

**3. Model and effort (A).** Choose them by replacing the whole config of the `agent-default-model` row, because patches replace config wholesale. There is no CLI flag or env var for it.
- Defaults: provider `deepseek-official`, model `deepseek-flash` ("DeepSeek-V41-Flash" per the web-app README), effort `high`.
- Accepted ids, from the live API error `The supported API model names are deepseek-flash, deepseek-v4-pro`.
- Efforts: `off | low | high | max`.
- I did not confirm `v4-pro` from the response itself, but it was accepted in runs 2–5.

**4. Output (A).**
- With `--json` the event types are `session`, `status` (`turn_start`, `step_start`, `step_end` with `usage`, `turn_end` with `reason`), `thinking`, `text`, `tool_call`, `tool_result`, `final`.
- Without `--json`, stdout is only the final message and reasoning goes to stderr under `dsh: reasoning:`. Run 5 confirmed it.
- The `final` event is lossless and uncapped, while other strings are capped at 8 KiB.
- An in-turn failure still emits `final` with empty text and exits 1, so the exit code and `turn_end` decide success.

**5. Failure modes (A).**
- **(a) Missing key:** `dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"; store DEEPSEEK_API_KEY …`, exit 1, stdout empty. An empty `DSH_HOME` self-bootstraps the profile, so there is no separate "profile missing" error.
- **(b) Invalid model:** `dsh: INVALID_REQUEST: The supported API model names are deepseek-flash, deepseek-v4-pro, but you passed deepseek-nonexistent-x. (request_id: …)`, exit 1 after 1.25 s.
- **(c) Kill:** against a hanging local server, `timeout 6` gave exit 124, empty output, and no orphan processes. The only leftover was a 0-byte `session.lock`.
- **Rate limit and quota:** the provider code maps errors to `RATE_LIMIT`, `QUOTA` (HTTP 402 or "insufficient quota/balance"), `AUTH` (401/403), `SERVER`, `TIMEOUT`, `TRANSPORT`, `EMPTY_RESPONSE`. Normal mode retries the transient ones 5 times with 0.5–10 s backoff, honouring `Retry-After`. The stream idle timeout is 300 s. I did not trigger a real 429.

**6. `env -i` (A).** `PATH`, `HOME`, `TMPDIR` is enough, with the key from `~/.dsh/.env`, from `DSH_HOME/.env`, or from `DEEPSEEK_API_KEY`. No XDG or `NODE_*` variables were needed. `node` must be on `PATH` (`/usr/bin/node` here). The agent's bash environment is scrubbed: `env | grep -c ^DEEPSEEK_` printed 0 and `$DEEPSEEK_API_KEY` had length 0.

**7. State (A).**
- **Where:** `$DSH_HOME/{sessions,storages,profiles,.anonymous-user-id}`.
- **Size:** a first run in a fresh `DSH_HOME` was about 80 KB, including the 24 KB profile. Each later run adds about 28 KB (22 KB zstd session log plus a 6 KB projection cache).
- **Per-run temp `DSH_HOME`:** works with the key from either the env var or a copied `.env` (`install -m600`). Delete the temp dir after the leg.

**8. Reads outside cwd (A).** Yes, no read confinement. `read /etc/hostname` succeeded, `cat /etc/hostname` and `ls /tmp` work in bash, and the real `~/.dsh/.env` is readable (`realenv-readable`; I tested existence only). The sandbox restricts writes only. In run 5, `curl https://example.com` returned `200`, so egress is open.

**9. Cost (A for tokens).**
- **Wall time:** 8.7 s (run 2, pro, 5 calls) to 12.9 s (run 4, pro/high, full review).
- **Run 4 tokens:** 6,003 input, 486 output, 22,656 cache-read.
- **Cost:** no dollar figure is reported.

## Unknowns

- **Credential/network exposure (UNKNOWN):** nothing in `dsh` stops a prompt-injected diff from making the agent read `~/.dsh/.env` and send it out over the network. Default: run with a throwaway `DSH_HOME` and a key passed by env. Better still, use a dedicated low-limit review key and run inside an external network or file sandbox, which I did not test.
- **Session-log upload (UNKNOWN whether other upload paths exist):** the default upload is the `dsh_session_log` request field, which includes tool output and reasoning. Telemetry otherwise only fires after explicit feedback. Default: disable both, as in the overlay. I did not capture traffic to prove nothing is uploaded.
- **Effort and model for the leg (UNKNOWN best choice):** I tried only `v4-pro`/`high` for reviews, and no `max` or `flash` runs. Default: `v4-pro`/`high`, matching the adapter default effort.
- **Dollar cost and real 429/402 text (UNKNOWN):** none observed. Default: treat exit 1 with `RATE_LIMIT`/`QUOTA` on stderr as a leg failure.
- **Stray-file risk (UNKNOWN):** I did not check how bwrap handles a checkout with symlinks that point outside it. The collector's worktree-unchanged check remains the backstop.
- **Pin (not done):** `dsh` is a global npm install at 0.2.0-rc.2. I did not check where the fleet Dockerfile pins it. A release-candidate version should be pinned, and the overlay committed in the plugin repo.

## Sources
- **Tier A, CLI output:** `dsh --help`, `dsh --profile headless --help`, `--dump-config`, `--dump-config-schema`, and my runs. Probe outputs were kept in a session scratch directory, not in the repo.
- **Tier A, vendor source:** `$(npm root -g)/@deepseek-ai/dsh/node_modules/@deepseek-ai/` READMEs and `lib/*.js` for `dsh-headless`, `dsh-sandbox-policy`, `dsh-sandbox-local`, `dsh-user-approval`, `dsh-agent-default-model`, `dsh-llm-deepseek`, `dsh-llm-deepseek-api-key`, `dsh-llm-retry`, `dsh-credentials-local`, `dsh-session-log-deepseek`, `dsh-session-telemetry-otel`, `dsh-tool-fs`.
- **Not reached:** the GitHub README (`raw.githubusercontent.com/deepseek-ai/deepseek-harness/main/README.md`) returned 404. I relied on the packaged copy and made no tier B or C claims.
