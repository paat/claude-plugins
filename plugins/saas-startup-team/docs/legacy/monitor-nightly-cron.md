# Monitor-nightly host scheduling

## Daily digest

Once per day, after the monitor pass, assemble and send the batched needs-human digest
(`/digest`) so the investor gets one message instead of a ping per run. Add a second
daily cron entry invoking `/digest` (same tool scope as below, plus the notify channel:
`.startup/notify.json` or `SAAS_NOTIFY_KIND`/`SAAS_NOTIFY_URL`/`SAAS_NOTIFY_TOKEN_ENV`).
Unconfigured channel is a clean no-op.

## Cron setup

```bash
# Claude Code example:
# 0 2 * * *  cd <product-repo> && PLUGIN_ROOT=<installed-plugin-path>; export PLUGIN_ROOT; if bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" monitor-nightly; then claude -p "/monitor-nightly" \
#   --allowedTools "Bash,Read,Write,Grep,Glob" >> /var/log/monitor-nightly.log 2>&1
#   else test $? -eq 3; fi
# Codex example:
# 0 2 * * *  cd /path/to/product && <codex command for this plugin> "/monitor-nightly" \
#   >> /var/log/monitor-nightly.log 2>&1
```

Ensure `ANTHROPIC_API_KEY`, authenticated `gh`, `jq`, GNU `date`, and `flock` are available in the
cron environment.

### Hardened cron (narrow tool scope)

This monitor pulls **customer-controlled content** (feedback text, custom-checks output) into
Claude's context, so it is prompt-injection-sensitive. For that threat model, scope
`--allowedTools` to the *narrowest* Bash set instead of a blanket `Bash`. The engine
(`monitor-dedup.sh`) is invoked **directly** (it is executable with a shebang — not wrapped in
a `bash <script>` call), so you can grant just the engine path and drop the full-shell
`Bash(bash:*)` that a `bash <script>` invocation would otherwise force:

```bash
# Claude Code example:
# 0 2 * * *  cd <product-repo> && PLUGIN_ROOT=<installed-plugin-path>; export PLUGIN_ROOT; if bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" monitor-nightly; then claude -p "/monitor-nightly" --allowedTools \
#   'Bash($CLAUDE_PLUGIN_ROOT/scripts/monitor-dedup.sh:*),Bash(flock:*),Bash(mkdir:*),Bash(jq:*),Bash(grep:*),Bash(sed:*),Bash(tr:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(basename:*),Bash(dirname:*),Bash(date:*),Read,Write,Grep,Glob' \
#   >> /var/log/monitor-nightly.log 2>&1
#   else test $? -eq 3; fi
```

Add `Bash(<your custom_checks path>:*)` if a `custom_checks` script is configured. A successful
injection via customer content then cannot exec arbitrary commands — only the allowlisted
utilities — because `Bash(bash:*)` is no longer in scope.

Note the GitHub CLI is intentionally **absent** from this list: the command never calls it
directly — all GitHub I/O is encapsulated in the engine and runs as a *child process* of the
allowlisted engine, so it never reaches the Bash permission layer. The CLI only needs to be
installed and authenticated in the environment (per the prerequisites above), not granted as a
tool. Granting it here would needlessly widen the blast radius.
