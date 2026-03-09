# Common Node Recipes

Ready-to-use node subgraph snippets in API-format JSON. These can be inserted into any workflow by adjusting node IDs and wiring connections to your existing nodes.

## Background Removal

### Using RMBG (Remove Background)

```json
{
  "20": {
    "class_type": "LoadImage",
    "inputs": {
      "image": "input_photo.png"
    },
    "_meta": { "title": "Load Image" }
  },
  "21": {
    "class_type": "RMBG",
    "inputs": {
      "image": ["20", 0]
    },
    "_meta": { "title": "Remove Background" }
  },
  "22": {
    "class_type": "SaveImage",
    "inputs": {
      "images": ["21", 0],
      "filename_prefix": "no_background"
    },
    "_meta": { "title": "Save Result" }
  }
}
```

RMBG outputs an IMAGE with the background removed (transparent/white). Some versions output a MASK as the second output (`["21", 1]`) which can be used for compositing.

### Using SAM (Segment Anything)

For more precise control, use SAM to generate a mask from a point or bounding box:

```json
{
  "20": {
    "class_type": "LoadImage",
    "inputs": { "image": "input_photo.png" },
    "_meta": { "title": "Load Image" }
  },
  "21": {
    "class_type": "SAMModelLoader",
    "inputs": { "model_name": "sam_vit_h_4b8939.pth" },
    "_meta": { "title": "Load SAM" }
  },
  "22": {
    "class_type": "SAMPredictor",
    "inputs": {
      "sam_model": ["21", 0],
      "image": ["20", 0],
      "points": [[512, 512]],
      "labels": [1]
    },
    "_meta": { "title": "SAM Predict" }
  }
}
```

Point coordinates `[x, y]` indicate the object to segment. Labels: 1 = foreground, 0 = background.

## Inpainting

Replace a region of an image while keeping the rest unchanged.

### Full Inpainting Pipeline

```json
{
  "1": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": { "ckpt_name": "sd_xl_base_1.0.safetensors" },
    "_meta": { "title": "Load Checkpoint" }
  },
  "2": {
    "class_type": "LoadImage",
    "inputs": { "image": "original_photo.png" },
    "_meta": { "title": "Load Original Image" }
  },
  "3": {
    "class_type": "LoadImage",
    "inputs": { "image": "mask.png" },
    "_meta": { "title": "Load Mask" }
  },
  "4": {
    "class_type": "ImageToMask",
    "inputs": {
      "image": ["3", 0],
      "channel": "red"
    },
    "_meta": { "title": "Convert Image to Mask" }
  },
  "5": {
    "class_type": "VAEEncode",
    "inputs": {
      "pixels": ["2", 0],
      "vae": ["1", 2]
    },
    "_meta": { "title": "VAE Encode" }
  },
  "6": {
    "class_type": "SetLatentNoiseMask",
    "inputs": {
      "samples": ["5", 0],
      "mask": ["4", 0]
    },
    "_meta": { "title": "Set Inpaint Mask" }
  },
  "7": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "a beautiful flower arrangement",
      "clip": ["1", 1]
    },
    "_meta": { "title": "Positive Prompt (inpaint region)" }
  },
  "8": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "bad quality, blurry",
      "clip": ["1", 1]
    },
    "_meta": { "title": "Negative Prompt" }
  },
  "9": {
    "class_type": "KSampler",
    "inputs": {
      "model": ["1", 0],
      "positive": ["7", 0],
      "negative": ["8", 0],
      "latent_image": ["6", 0],
      "seed": 42,
      "steps": 25,
      "cfg": 7.0,
      "sampler_name": "dpmpp_2m",
      "scheduler": "karras",
      "denoise": 0.75
    },
    "_meta": { "title": "KSampler (Inpaint)" }
  },
  "10": {
    "class_type": "VAEDecode",
    "inputs": { "samples": ["9", 0], "vae": ["1", 2] },
    "_meta": { "title": "VAE Decode" }
  },
  "11": {
    "class_type": "SaveImage",
    "inputs": { "images": ["10", 0], "filename_prefix": "inpainted" },
    "_meta": { "title": "Save Inpainted" }
  }
}
```

### Inpainting Notes
- The mask should be white (255) where you want to regenerate and black (0) where you want to preserve.
- `denoise` of 0.6-0.85 works best for inpainting. Lower values blend more with the original; higher values generate more freely.
- For dedicated inpaint models (e.g., `sd_xl_inpainting_1.0.safetensors`), use `VAEEncodeForInpaint` instead of `VAEEncode` + `SetLatentNoiseMask` — it handles mask growth and padding.

## Batch Processing

Generate multiple images with the same settings but different seeds.

### Using RepeatLatentBatch

```json
{
  "4": {
    "class_type": "EmptyLatentImage",
    "inputs": { "width": 1024, "height": 1024, "batch_size": 1 },
    "_meta": { "title": "Empty Latent" }
  },
  "5": {
    "class_type": "RepeatLatentBatch",
    "inputs": {
      "samples": ["4", 0],
      "amount": 4
    },
    "_meta": { "title": "Repeat to 4 Images" }
  }
}
```

Alternatively, set `batch_size` directly on EmptyLatentImage to achieve the same result. `RepeatLatentBatch` is useful when you want to batch an existing latent (e.g., from VAEEncode).

## SDXL Dual Prompt

SDXL supports a specialized prompt encoding node with additional parameters for resolution-aware conditioning.

### CLIPTextEncodeSDXL

```json
{
  "2": {
    "class_type": "CLIPTextEncodeSDXL",
    "inputs": {
      "clip": ["1", 1],
      "text_g": "a majestic eagle soaring over mountains, photorealistic, 8k",
      "text_l": "eagle, mountains, flying, photorealistic, detailed feathers",
      "width": 1024,
      "height": 1024,
      "crop_w": 0,
      "crop_h": 0,
      "target_width": 1024,
      "target_height": 1024
    },
    "_meta": { "title": "SDXL Positive Prompt" }
  }
}
```

### Parameters
- `text_g`: CLIP-G prompt (global/main description). Supports longer, more descriptive text.
- `text_l`: CLIP-L prompt (local/tag-style description). Best with comma-separated tags.
- `width` / `height`: Original resolution of the intended image (tells the model what resolution it's targeting).
- `crop_w` / `crop_h`: Crop offset (0,0 = no crop, centered generation).
- `target_width` / `target_height`: Target output resolution.

For most use cases, set all resolution fields to your actual output resolution (e.g., 1024x1024). The crop fields should be 0 unless you specifically want off-center composition.

## Conditioning Combine vs Conditioning Average

### ConditioningCombine
Merges two conditioning signals with equal weight — the model tries to satisfy both simultaneously. Use for combining two distinct subjects or concepts.

```json
{
  "10": {
    "class_type": "ConditioningCombine",
    "inputs": {
      "conditioning_1": ["7", 0],
      "conditioning_2": ["8", 0]
    },
    "_meta": { "title": "Combine Conditioning" }
  }
}
```

**When to use**: "A cat AND a dog in the same image" — combine separate encodings of each subject.

### ConditioningAverage
Blends two conditioning signals with a configurable ratio. Use for interpolating between two styles or concepts.

```json
{
  "10": {
    "class_type": "ConditioningAverage",
    "inputs": {
      "conditioning_to": ["7", 0],
      "conditioning_from": ["8", 0],
      "conditioning_to_strength": 0.7
    },
    "_meta": { "title": "Average Conditioning (70/30)" }
  }
}
```

**When to use**: "Blend 70% photorealistic style with 30% watercolor style" — use `conditioning_to_strength` to control the ratio. 1.0 = 100% conditioning_to, 0.0 = 100% conditioning_from.

## Negative Prompt Patterns

Common negative prompt components for quality control:

### General Quality
```
bad quality, low quality, worst quality, jpeg artifacts, blurry, noisy, pixelated, oversaturated, underexposed, overexposed
```

### Anatomy (for human subjects)
```
deformed, disfigured, bad anatomy, wrong anatomy, extra limbs, missing limbs, floating limbs, disconnected limbs, mutated hands, extra fingers, missing fingers, too many fingers, fused fingers, long neck, bad proportions
```

### Composition
```
cropped, out of frame, watermark, text, logo, signature, username, border, frame
```

### Full Recommended Negative (general purpose)
```
bad quality, worst quality, low quality, blurry, noisy, jpeg artifacts, watermark, text, logo, signature, cropped, out of frame, deformed, disfigured, bad anatomy, extra limbs, missing limbs, mutated hands, extra fingers
```

### Model-Specific Notes
- **SD1.5 / SDXL**: Long negative prompts work well. Include anatomy terms for human subjects.
- **Flux**: Negative prompt has minimal effect due to model architecture. Keep it short or empty.
- **Wan**: Use brief negative prompts focused on quality terms.

## Scheduler / Sampler Combos

### Recommended Pairings

| Sampler | Scheduler | Strengths | Steps | Use Case |
|---------|-----------|-----------|-------|----------|
| `euler_ancestral` | `normal` | Fast, creative | 15-25 | Quick iteration, exploration |
| `euler` | `normal` | Fast, deterministic | 20-30 | Consistent results |
| `dpmpp_2m` | `karras` | High quality, balanced | 20-30 | General purpose (recommended default) |
| `dpmpp_sde` | `karras` | Rich detail, texture | 20-35 | Detailed subjects, textures |
| `dpmpp_2m_sde` | `karras` | Best detail, slower | 25-35 | Maximum quality |
| `ddim` | `normal` | Deterministic, smooth | 30-50 | Reproducibility, smooth gradients |
| `uni_pc` | `normal` | Fast convergence | 15-20 | Speed with decent quality |

### Model-Specific Recommendations
- **SD1.5**: `dpmpp_2m` + `karras` at 25 steps, cfg 7.0
- **SDXL**: `dpmpp_2m` + `karras` at 25 steps, cfg 7.0
- **Flux**: `euler` + `sgm_uniform` at 20 steps, cfg 1.0-3.5
- **Wan video**: Check model card for recommended sampler; `euler` + `normal` common

### Ancestral vs Non-Ancestral Samplers
- Ancestral samplers (`euler_ancestral`, `dpmpp_2s_ancestral`): Add noise at each step. Results vary more with step count changes. More creative/varied output.
- Non-ancestral (`euler`, `dpmpp_2m`, `ddim`): Converge to a stable result. Increasing steps past convergence point has diminishing returns. More predictable.

## Seed Management

### Fixed Seed for Reproducibility
Use the same seed across iterations to keep composition stable while tweaking other parameters:

```json
"seed": 42
```

Same seed + same settings + same model = identical output. Change one parameter (prompt, cfg, steps) to see its isolated effect.

### Different Seeds for Batch Variation
When using batch_size > 1, the seed auto-increments:
- Image 0: seed 42
- Image 1: seed 43
- Image 2: seed 44
- Image 3: seed 45

### Random Seeds for Exploration
Use any large random integer when exploring:

```json
"seed": 7294816253
```

To generate a workflow that produces different results each run, the calling code should randomize the seed before submitting to `/prompt`.

### Seed + Subseed (for advanced control)
Some workflows expose `subseed` and `subseed_strength` on KSampler for fine variation control. At subseed_strength 0, the subseed has no effect. At 1.0, the subseed fully replaces the main seed. Values in between interpolate the noise patterns.
