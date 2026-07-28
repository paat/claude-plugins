---
name: validate-experiment
description: "Validate measured experiment results vs invented conclusions."
---

# Validate experiment

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-experiment.sh" $ARGUMENTS
```

Separates measured demand signals from invented conclusions. Fail closed on missing
metrics or spend outside envelope.
