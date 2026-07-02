# Generator Selection Reference

`/agent-sync:generate` and `/agent-sync:check` both need to run the generator
script. They resolve it with the same vendored-first precedence the
agent-sync hook uses, so the skill, the hook, and the vendored copy all run
the *same* generator and results never disagree with the repo's own
`--check`:

```bash
if [ -f "tools/agent-sync/generate.sh" ]; then
  GEN=tools/agent-sync/generate.sh
elif [ -f ".agent-sync/generate.sh" ]; then
  GEN=.agent-sync/generate.sh
else
  GEN="${CLAUDE_PLUGIN_ROOT}/scripts/generate.sh"
fi
bash "$GEN" --config "<path-to-sources.json>"   # append --check to verify without writing
```

> **Trust note:** the vendored `tools/agent-sync/generate.sh` is repo-controlled — it is the copy
> `/agent-sync:init` committed and the same one the hook executes, so preferring it is what keeps
> the skill, the hook, and the vendored copy byte-consistent. As with any repo build script, run
> this only on a branch you trust; on an untrusted branch the vendored copy could be modified.
