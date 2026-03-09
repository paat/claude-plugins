# ComfyUI Workflow JSON Format (API Format)

## Overview

ComfyUI uses two JSON formats:
- **API format** (used by this plugin): A flat dictionary mapping string node IDs to node definitions. This is the format accepted by the `/prompt` API endpoint.
- **UI format**: Wraps the workflow in a `{"workflow": {...}, "output": {...}}` structure with additional metadata like node positions, colors, and groups. This format is used by the ComfyUI web UI for save/load. The plugin exclusively uses API format.

## Complete Annotated Example: Minimal txt2img

```json
{
  "1": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": {
      "ckpt_name": "sd_xl_base_1.0.safetensors"
    },
    "_meta": {
      "title": "Load Checkpoint"
    }
  },
  "2": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "a beautiful mountain landscape at sunset, dramatic lighting, 8k uhd",
      "clip": ["1", 1]
    },
    "_meta": {
      "title": "Positive Prompt"
    }
  },
  "3": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "bad quality, blurry, distorted",
      "clip": ["1", 1]
    },
    "_meta": {
      "title": "Negative Prompt"
    }
  },
  "4": {
    "class_type": "EmptyLatentImage",
    "inputs": {
      "width": 1024,
      "height": 1024,
      "batch_size": 1
    },
    "_meta": {
      "title": "Empty Latent"
    }
  },
  "5": {
    "class_type": "KSampler",
    "inputs": {
      "model": ["1", 0],
      "positive": ["2", 0],
      "negative": ["3", 0],
      "latent_image": ["4", 0],
      "seed": 42,
      "steps": 25,
      "cfg": 7.5,
      "sampler_name": "dpmpp_2m",
      "scheduler": "karras",
      "denoise": 1.0
    },
    "_meta": {
      "title": "KSampler"
    }
  },
  "6": {
    "class_type": "VAEDecode",
    "inputs": {
      "samples": ["5", 0],
      "vae": ["1", 2]
    },
    "_meta": {
      "title": "VAE Decode"
    }
  },
  "7": {
    "class_type": "SaveImage",
    "inputs": {
      "images": ["6", 0],
      "filename_prefix": "comfyui_output"
    },
    "_meta": {
      "title": "Save Image"
    }
  }
}
```

### Field-by-Field Explanation

**Node "1" — CheckpointLoaderSimple**
- `class_type`: The registered Python class name for the node. Must exactly match a node from `/object_info`.
- `inputs.ckpt_name`: A literal string value — the checkpoint filename. Must match a file in the `checkpoints/` model folder.
- `_meta.title`: Human-readable label. Not required by the engine but useful for programmatic lookup (e.g., finding "Positive Prompt" node to update text).
- **RETURN_TYPES**: `["MODEL", "CLIP", "VAE"]` — output index 0 = MODEL, 1 = CLIP, 2 = VAE.

**Node "2" — CLIPTextEncode (Positive)**
- `inputs.text`: Literal string — the prompt text.
- `inputs.clip`: `["1", 1]` — a **connection**. Reads output index 1 (CLIP) from node "1" (CheckpointLoaderSimple).
- **RETURN_TYPES**: `["CONDITIONING"]` — output index 0 = CONDITIONING.

**Node "3" — CLIPTextEncode (Negative)**
- Same structure as node "2" but with negative prompt text.
- Also connects to node "1" output index 1 for the CLIP model.

**Node "4" — EmptyLatentImage**
- `inputs.width`, `inputs.height`: Integer pixel dimensions. Must be multiples of 8 (ideally 64).
- `inputs.batch_size`: How many images to generate in one pass. 1 = single image, >1 = multiple images with different noise but same settings.
- **RETURN_TYPES**: `["LATENT"]` — output index 0 = LATENT.

**Node "5" — KSampler**
- `inputs.model`: `["1", 0]` — MODEL from CheckpointLoaderSimple output index 0.
- `inputs.positive`: `["2", 0]` — CONDITIONING from positive CLIPTextEncode output index 0.
- `inputs.negative`: `["3", 0]` — CONDITIONING from negative CLIPTextEncode output index 0.
- `inputs.latent_image`: `["4", 0]` — LATENT from EmptyLatentImage output index 0.
- `inputs.seed`: Integer. Use a fixed value (e.g., 42) for reproducible results. Use a random large integer for variation.
- `inputs.steps`: Integer. Number of denoising steps.
- `inputs.cfg`: Float. Classifier-free guidance scale.
- `inputs.sampler_name`: String. Must match a registered sampler.
- `inputs.scheduler`: String. Must match a registered scheduler.
- `inputs.denoise`: Float 0.0-1.0. 1.0 for full txt2img, <1.0 for img2img refinement.
- **RETURN_TYPES**: `["LATENT"]` — output index 0 = LATENT (denoised).

**Node "6" — VAEDecode**
- `inputs.samples`: `["5", 0]` — LATENT from KSampler.
- `inputs.vae`: `["1", 2]` — VAE from CheckpointLoaderSimple output index 2.
- **RETURN_TYPES**: `["IMAGE"]` — output index 0 = IMAGE (pixel tensor).

**Node "7" — SaveImage**
- `inputs.images`: `["6", 0]` — IMAGE from VAEDecode.
- `inputs.filename_prefix`: String prefix for output filename. ComfyUI appends a counter automatically.
- **RETURN_TYPES**: `[]` — terminal node, no outputs.

## Node ID Rules

- Node IDs are **strings**, not integers: `"1"`, `"2"`, `"3"`.
- Use sequential numbering starting from `"1"` for clarity.
- IDs do not need to be contiguous but must be unique within the workflow.
- The execution order is determined by the connection graph, not by ID order.

## Connection Format

Connections link one node's output to another node's input:

```
["source_node_id", output_index]
```

- `source_node_id`: String ID of the node producing the value.
- `output_index`: 0-based integer index into the source node's `RETURN_TYPES` array.

### Determining output_index

Query `/object_info` for a node's class. The response includes `output` which lists `RETURN_TYPES`:

```json
{
  "CheckpointLoaderSimple": {
    "output": ["MODEL", "CLIP", "VAE"],
    ...
  }
}
```

- Index 0 = MODEL
- Index 1 = CLIP
- Index 2 = VAE

So to get the VAE from CheckpointLoaderSimple node "1": `["1", 2]`.

## _meta.title Usage

The `_meta` field is optional metadata. The `title` key provides a human-readable name:

```json
"_meta": { "title": "Positive Prompt" }
```

Use cases:
- Programmatically finding a specific node to update (e.g., search for title "Positive Prompt" to change the text).
- Debugging and logging — makes JSON easier to read.
- Not used by the execution engine at all.

## Batch Size Semantics

`EmptyLatentImage.batch_size` controls how many images are generated per queue item:
- `batch_size: 1` — one image per execution.
- `batch_size: 4` — four images per execution, all with the same settings but different noise patterns (seed increments automatically for each).
- SaveImage will save all images in the batch.
- Higher batch sizes consume more VRAM linearly.

## Seed Behavior

- **Fixed seed** (e.g., `42`): Produces identical results given the same workflow, model, and settings. Use for reproducibility and iterating on prompts.
- **Random seed**: Use any large random integer (e.g., `8274619352`). Each run produces different results.
- **Seed in batches**: When batch_size > 1, ComfyUI internally increments the seed for each image in the batch: seed, seed+1, seed+2, etc.
- The seed must be a non-negative integer. The maximum value is 2^53 - 1 (JavaScript safe integer limit in the UI, though the backend accepts larger).

## Validation Checklist

Before submitting a workflow to `/prompt`:
1. Every `class_type` exists in `/object_info`.
2. Every connection `["node_id", index]` references a valid node ID that exists in the workflow.
3. Every connection's output_index is within range of the source node's RETURN_TYPES.
4. Every required input (per `/object_info`) has a value — either literal or connection.
5. Type compatibility: the output type at the referenced index matches what the input expects (e.g., MODEL connects to MODEL, not CLIP).
6. No circular dependencies in the connection graph.
7. At least one terminal node (SaveImage, PreviewImage, or similar) to trigger execution.
