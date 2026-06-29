---
name: update-codex-marketplace
description: Regenerate this repo's Codex plugin marketplace and manifests from the Claude plugin metadata.
---

Use this skill when the user asks to update, refresh, sync, or verify the Codex marketplace for this repository.

Steps:

1. Run the sync script from the repository root:

   ```bash
   python3 scripts/sync-codex-marketplace.py
   ```

2. Verify the generated files are current:

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
