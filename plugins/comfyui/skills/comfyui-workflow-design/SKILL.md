---
name: comfyui-workflow-design
description: Use when creating, designing, building, or modifying ComfyUI workflows, generating images with specific techniques (IP-Adapter, ControlNet, LoRA, upscaling, video), constructing workflow JSON, connecting nodes, or asking about ComfyUI node types and workflow patterns. Activates for "comfyui workflow", "stable diffusion workflow", "generate image workflow", "ip adapter", "controlnet workflow", "animatediff", "wan2", "build pipeline", "design workflow", "lora workflow".
---

### Workflow JSON Structure
ComfyUI workflows are JSON objects mapping string node IDs to node definitions:
```json
{
  "1": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": { "ckpt_name": "sd_xl_base_1.0.safetensors" },
    "_meta": { "title": "Load Checkpoint" }
  },
  "2": {
    "class_type": "CLIPTextEncode",
    "inputs": { "text": "a photo of a cat", "clip": ["1", 1] },
    "_meta": { "title": "Positive Prompt" }
  }
}
```

Key rules:
- Node IDs are strings ("1", "2", "3"...)
- `class_type` must match a registered node from `/object_info`
- Inputs are either literal values or connections: `["source_node_id", output_index]`
- Output indices are 0-based integers matching the node's `RETURN_TYPES` order
- `_meta.title` is optional but useful for finding nodes programmatically

### Workflow Construction Process
1. Read `.claude/comfyui.local.md` for ComfyUI URL
2. Query `GET {url}/object_info` to discover available nodes
3. Query `GET {url}/models/{folder}` to discover available models
4. Identify required pipeline stages for the user's goal
5. Select appropriate node classes (verify they exist in /object_info)
6. Assign sequential string IDs
7. Wire connections — ensure output type matches expected input type
8. Set all required inputs (check /object_info for required vs optional)
9. Validate: every connection references an existing node, all required inputs filled

### Common Pipeline Patterns

**Text-to-Image (basic):** CheckpointLoaderSimple -> CLIPTextEncode (positive) + CLIPTextEncode (negative) -> EmptyLatentImage -> KSampler -> VAEDecode -> SaveImage

**Image-to-Image:** LoadImage -> VAEEncode -> KSampler (with denoise < 1.0) -> VAEDecode -> SaveImage

**With LoRA:** CheckpointLoaderSimple -> LoraLoader -> (rest of pipeline uses LoRA model/clip outputs)

**With ControlNet:** Load preprocessor -> Apply ControlNet -> feed into KSampler positive conditioning

**IP-Adapter:** See `references/ip-adapter-patterns.md`
**ControlNet:** See `references/controlnet-patterns.md`
**Video:** See `references/video-workflow-patterns.md`
**Upscaling:** See `references/upscaling-patterns.md`
**Common recipes:** See `references/common-node-recipes.md`

### GGUF Model Support
When using quantized GGUF models, replace the standard loader chain:
- `CheckpointLoaderSimple` -> split into `UnetLoaderGGUF` + `DualCLIPLoaderGGUF` (or `CLIPLoaderGGUF`) + `VAELoader`
- UnetLoaderGGUF outputs: MODEL
- CLIPLoaderGGUF outputs: CLIP
- Wire these separately to the rest of the pipeline

### LoRA Configuration
Insert `LoraLoader` between checkpoint loader and the rest of the pipeline:
- Input: model, clip, lora_name, strength_model, strength_clip
- Output: model, clip (modified)
- Weight guidance: 0.6-0.9 for style LoRAs, 0.4-0.6 for concept LoRAs
- Stack multiple LoRAs by chaining LoraLoader nodes

### KSampler Parameters
- `seed`: Random integer for reproducibility (use -1 or random for variation)
- `steps`: 20-30 typical (more = slower, not always better)
- `cfg`: 7.0-8.0 for SD1.5/SDXL, 1.0-4.0 for Flux/newer models
- `sampler_name`: "euler", "euler_ancestral", "dpmpp_2m", "dpmpp_sde" (common choices)
- `scheduler`: "normal", "karras", "sgm_uniform" (karras generally best)
- `denoise`: 1.0 for txt2img, 0.3-0.7 for img2img

### References
- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-workflow-design/references/workflow-json-format.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-workflow-design/references/ip-adapter-patterns.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-workflow-design/references/controlnet-patterns.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-workflow-design/references/video-workflow-patterns.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-workflow-design/references/upscaling-patterns.md`
- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-workflow-design/references/common-node-recipes.md`
