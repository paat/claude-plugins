# Upscaling Workflow Patterns

## Overview

Upscaling in ComfyUI falls into three categories:
1. **Latent upscaling**: Upscale in latent space, refine with KSampler.
2. **Model-based upscaling**: Use dedicated super-resolution models (ESRGAN, etc.) in pixel space.
3. **Combined approaches**: Model upscale for initial resolution boost, latent refinement for added detail.

## Two-Pass Latent Upscale

Generate at base resolution, upscale the latent, then refine with a second KSampler pass at lower denoise.

### Pipeline

```
KSampler (pass 1) → LatentUpscale / LatentUpscaleBy → KSampler (pass 2, denoise 0.3-0.5) → VAEDecode → SaveImage
```

### Nodes

| Node | Purpose | Key Inputs |
|------|---------|------------|
| `LatentUpscale` | Upscale latent to specific dimensions | samples, upscale_method, width, height |
| `LatentUpscaleBy` | Upscale latent by a scale factor | samples, upscale_method, scale_by |

### Upscale Methods

- `nearest-exact`: Fastest, blocky. Avoid for final output.
- `bilinear`: Fast, smooth but can be blurry.
- `bislerp`: Balanced quality/speed. Good default for latent upscale.
- `area`: Good for downscaling. Not ideal for upscaling.

### Example: Two-Pass Latent Upscale

```json
{
  "1": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": { "ckpt_name": "sd_xl_base_1.0.safetensors" },
    "_meta": { "title": "Load Checkpoint" }
  },
  "2": {
    "class_type": "CLIPTextEncode",
    "inputs": { "text": "a detailed fantasy castle on a cliff, epic landscape", "clip": ["1", 1] },
    "_meta": { "title": "Positive Prompt" }
  },
  "3": {
    "class_type": "CLIPTextEncode",
    "inputs": { "text": "blurry, low quality, artifacts", "clip": ["1", 1] },
    "_meta": { "title": "Negative Prompt" }
  },
  "4": {
    "class_type": "EmptyLatentImage",
    "inputs": { "width": 1024, "height": 1024, "batch_size": 1 },
    "_meta": { "title": "Empty Latent" }
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
      "cfg": 7.0,
      "sampler_name": "dpmpp_2m",
      "scheduler": "karras",
      "denoise": 1.0
    },
    "_meta": { "title": "KSampler Pass 1" }
  },
  "6": {
    "class_type": "LatentUpscaleBy",
    "inputs": {
      "samples": ["5", 0],
      "upscale_method": "bislerp",
      "scale_by": 1.5
    },
    "_meta": { "title": "Latent Upscale 1.5x" }
  },
  "7": {
    "class_type": "KSampler",
    "inputs": {
      "model": ["1", 0],
      "positive": ["2", 0],
      "negative": ["3", 0],
      "latent_image": ["6", 0],
      "seed": 42,
      "steps": 20,
      "cfg": 7.0,
      "sampler_name": "dpmpp_2m",
      "scheduler": "karras",
      "denoise": 0.4
    },
    "_meta": { "title": "KSampler Pass 2 (Refine)" }
  },
  "8": {
    "class_type": "VAEDecode",
    "inputs": { "samples": ["7", 0], "vae": ["1", 2] },
    "_meta": { "title": "VAE Decode" }
  },
  "9": {
    "class_type": "SaveImage",
    "inputs": { "images": ["8", 0], "filename_prefix": "upscaled" },
    "_meta": { "title": "Save Image" }
  }
}
```

### Denoise Tuning for Pass 2

| Denoise | Effect |
|---------|--------|
| 0.2-0.3 | Minimal changes — sharpens and adds subtle detail. Preserves original closely. |
| 0.35-0.5 | Moderate refinement — adds meaningful detail while keeping composition. Best balance. |
| 0.5-0.65 | Significant changes — adds detail but may alter textures and minor elements. |
| 0.65+ | Major rework — essentially re-generates at the higher resolution. Composition may shift. |

## Model-Based Upscaling (ESRGAN)

Use dedicated super-resolution models that operate in pixel space. These are fast, produce clean results, and don't require a second diffusion pass.

### Nodes

| Node | Purpose | Key Inputs | Outputs |
|------|---------|------------|---------|
| `UpscaleModelLoader` | Load an upscale model | model_name | UPSCALE_MODEL |
| `ImageUpscaleWithModel` | Apply upscale model to image | upscale_model, image | IMAGE |
| `ImageScale` | Resize image (basic interpolation) | image, upscale_method, width, height | IMAGE |
| `ImageScaleBy` | Resize image by factor | image, upscale_method, scale_by | IMAGE |

### Popular Upscale Models

| Model | Scale | Best For |
|-------|-------|----------|
| `4x-UltraSharp.pth` | 4x | General purpose, sharp results |
| `RealESRGAN_x4plus.pth` | 4x | Photorealistic content |
| `RealESRGAN_x4plus_anime_6B.pth` | 4x | Anime/illustration |
| `4x_NMKD-Siax_200k.pth` | 4x | Balanced sharpness |
| `8x_NMKD-Superscale_150000_G.pth` | 8x | Extreme upscaling |
| `2x-ESRGAN.pth` | 2x | Subtle 2x upscale |

Models are stored in the `upscale_models/` folder. Check available models via `GET {url}/models/upscale_models`.

### Example: Model Upscale

```json
{
  "10": {
    "class_type": "UpscaleModelLoader",
    "inputs": {
      "model_name": "4x-UltraSharp.pth"
    },
    "_meta": { "title": "Load Upscale Model" }
  },
  "11": {
    "class_type": "ImageUpscaleWithModel",
    "inputs": {
      "upscale_model": ["10", 0],
      "image": ["8", 0]
    },
    "_meta": { "title": "Upscale 4x" }
  },
  "12": {
    "class_type": "SaveImage",
    "inputs": {
      "images": ["11", 0],
      "filename_prefix": "upscaled_4x"
    },
    "_meta": { "title": "Save Upscaled" }
  }
}
```

## Tiled Processing for VRAM Efficiency

Large images can exceed VRAM limits. Tiled processing splits the image into overlapping tiles, processes each independently, and blends them back together.

### Nodes

| Node | Purpose |
|------|---------|
| `TiledKSampler` | KSampler variant that processes in tiles (from some custom node packs) |
| `UltimateSDUpscale` | Popular all-in-one tiled upscale node (from Ultimate SD Upscale pack) |
| `TilePreprocessor` | ControlNet Tile preprocessor for tile-based refinement |

### UltimateSDUpscale Pattern

UltimateSDUpscale combines upscaling and tiled KSampler refinement in a single node:

```json
{
  "10": {
    "class_type": "UltimateSDUpscale",
    "inputs": {
      "image": ["8", 0],
      "model": ["1", 0],
      "positive": ["2", 0],
      "negative": ["3", 0],
      "vae": ["1", 2],
      "upscale_by": 2.0,
      "seed": 42,
      "steps": 20,
      "cfg": 7.0,
      "sampler_name": "dpmpp_2m",
      "scheduler": "karras",
      "denoise": 0.35,
      "tile_width": 512,
      "tile_height": 512,
      "tile_padding": 32,
      "upscale_model": ["20", 0]
    },
    "_meta": { "title": "Ultimate SD Upscale" }
  }
}
```

### Tile Parameters

- `tile_width` / `tile_height`: Size of each tile. 512 is standard for SD1.5, 1024 for SDXL.
- `tile_padding`: Overlap between tiles in pixels. 32-64 prevents visible seams.
- Larger tiles = better coherence but more VRAM. Smaller tiles = less VRAM but risk of seams.

## Face Restoration

After upscaling, faces often need additional refinement.

### Nodes

| Node | Purpose | Source |
|------|---------|--------|
| `FaceDetailer` | Detect and re-generate faces at higher detail | Impact Pack |
| `FaceRestoreWithModel` | Apply face restoration model | ComfyUI built-in |

### FaceDetailer Pattern (from Impact Pack)

FaceDetailer detects faces, crops them, runs a separate KSampler pass on each face region, and composites back:

```json
{
  "15": {
    "class_type": "FaceDetailer",
    "inputs": {
      "image": ["11", 0],
      "model": ["1", 0],
      "clip": ["1", 1],
      "vae": ["1", 2],
      "positive": ["2", 0],
      "negative": ["3", 0],
      "bbox_detector": ["16", 0],
      "seed": 42,
      "steps": 20,
      "cfg": 7.0,
      "sampler_name": "dpmpp_2m",
      "scheduler": "karras",
      "denoise": 0.4,
      "guide_size": 384,
      "guide_size_for": true,
      "max_size": 1024,
      "feather": 5,
      "noise_mask": true
    },
    "_meta": { "title": "Face Detailer" }
  }
}
```

FaceDetailer requires a bbox_detector (typically loaded via `UltraDetectorLoader` with a YOLO face detection model).

## Resolution Strategies

### Recommended Approach

1. **Generate at native resolution**: 512x512 (SD1.5), 1024x1024 (SDXL), or model-appropriate size.
2. **Model upscale 2-4x**: Use ESRGAN for a clean, fast initial boost.
3. **Optional latent refinement**: If more detail is needed, VAEEncode the upscaled image, run a KSampler pass at low denoise (0.3-0.4).
4. **Face restoration**: Apply FaceDetailer if the image contains faces.

### Combined Pipeline

```
KSampler → VAEDecode → UpscaleModelLoader + ImageUpscaleWithModel (2x) → VAEEncode → KSampler (denoise 0.35) → VAEDecode → FaceDetailer → SaveImage
```

This three-stage approach (generate → model upscale → latent refine) gives the best quality-to-VRAM ratio.
