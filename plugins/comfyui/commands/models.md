---
name: models
description: List available models by category — checkpoints, loras, vae, controlnet, upscale_models, embeddings
user_invocable: true
allowed-tools: Bash, Read
argument-hint: "[category] — e.g., checkpoints, loras, vae, controlnet"
---

# List ComfyUI Models

## Steps

1. **Read config.** Read `.claude/comfyui.local.md` for `comfyui_url` (default: `http://localhost:8188`).

2. **If `$ARGUMENTS` specifies a category** (e.g., `checkpoints`, `loras`, `vae`):

```bash
curl -s "${url}/models/${category}"
```

Parse the JSON array and list all model filenames. If the category returns an empty array or 404, report that no models were found for that category.

3. **If no arguments provided**, query all standard model folders:

   - `checkpoints`
   - `loras`
   - `vae`
   - `controlnet`
   - `upscale_models`
   - `embeddings`
   - `hypernetworks`
   - `clip_vision`

For each folder, run:

```bash
curl -s "${url}/models/${folder}"
```

4. **Format the output** as a grouped list showing each category with its model count and filenames:

```
Checkpoints (3)
  dreamshaper_8.safetensors
  sd_xl_base_1.0.safetensors
  flux1-dev-fp8.safetensors

LoRAs (1)
  detail_tweaker_xl.safetensors

VAE (0)
  (none — using model built-in)

ControlNet (2)
  control_v11p_sd15_canny.safetensors
  control_v11p_sd15_openpose.safetensors
...
```

Omit categories that return errors (likely not configured). Show `(none)` for empty categories.
