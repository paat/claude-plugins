---
name: update-codex-marketplace
description: Sync this repo's Claude marketplace versions and regenerate Codex and Antigravity plugin manifests from each plugin's plugin.json.
---

Use this skill when the user asks to update, refresh, sync, or verify plugin versions, `.claude-plugin/marketplace.json`, or the Codex/Antigravity manifests for this repository.

Each `plugins/<name>/.claude-plugin/plugin.json` is the single source of truth for `version` (and `author`). `scripts/sync-codex-marketplace.py` syncs those fields into `.claude-plugin/marketplace.json` (preserving marketplace fields like `category`, `homepage`, `source`, and `description`) and regenerates `.codex-plugin/plugin.json`, `.antigravity-plugin/plugin.json`, `.agents/plugins/marketplace.json`, `.agents/plugins.json`, and command workflow skills.

Steps:

1. Run the sync script from the repository root:

   ```bash
   python3 scripts/sync-codex-marketplace.py
   ```

2. Verify `.claude-plugin/marketplace.json` and all generated files are current:

   ```bash
   python3 scripts/sync-codex-marketplace.py --check
   ```

3. Validate every generated Codex plugin manifest:

   ```bash
   if [ -f /config/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py ]; then
     for plugin in plugins/*; do
       [ -d "$plugin/.codex-plugin" ] || continue
       python3 /config/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py "$plugin"
     done
   fi
   ```

4. Confirm Codex can see the marketplace:

   ```bash
   codex plugin marketplace list
   codex plugin list --marketplace paat-plugins
   ```

If the marketplace is not listed, add this repository root as a local marketplace source:

```bash
codex plugin marketplace add .
```
