# IP-Adapter Workflow Patterns

## What IP-Adapter Does

IP-Adapter (Image Prompt Adapter) enables image-guided generation. Instead of describing what you want purely with text, you provide a reference image and IP-Adapter transfers its visual characteristics (style, composition, character appearance) into the generated output.

Key use cases:
- **Character consistency**: Maintain the same character across multiple images.
- **Style transfer**: Apply the visual style of a reference image to new content.
- **Face preservation**: Keep a specific person's likeness using FaceID variants.

## Node Classes

### Core Nodes (from ComfyUI_IPAdapter_plus)

| Node | Purpose | Key Inputs | Outputs |
|------|---------|------------|---------|
| `IPAdapterSimple` | Basic IP-Adapter application | model, image, weight | MODEL |
| `IPAdapterAdvanced` | Full control over IP-Adapter | model, image, weight, weight_type, start_at, end_at | MODEL |
| `IPAdapterFaceID` | Face-specific adaptation | model, image, weight, insightface | MODEL |
| `IPAdapterBatch` | Process multiple reference images | model, images, weight | MODEL |
| `PrepImageForClipVision` | Resize/crop image for CLIP vision | image, interpolation, crop_position, sharpening | IMAGE |
| `IPAdapterModelLoader` | Load IP-Adapter model file | ipadapter_file | IPADAPTER |
| `InsightFaceLoader` | Load InsightFace model for FaceID | provider | INSIGHTFACE |
| `CLIPVisionLoader` | Load CLIP vision encoder | clip_name | CLIP_VISION |
| `CLIPVisionEncode` | Encode image with CLIP vision | clip_vision, image | CLIP_VISION_OUTPUT |

### Weight Types (IPAdapterAdvanced)

- `linear`: Standard linear weighting across all layers.
- `ease in`: Weight increases through layers — subtle early influence, stronger later.
- `ease out`: Weight decreases through layers — strong early structure, subtle refinement.
- `ease in-out`: Bell curve — peaks in middle layers.
- `reverse in-out`: Inverse bell — strong at extremes, weak in middle.
- `weak input`: Reduces influence on initial composition layers.
- `weak output`: Reduces influence on final detail layers.
- `style transfer`: Optimized for transferring artistic style without content.
- `composition`: Optimized for matching layout/structure without style.

## Weight Tuning

| Weight Range | Effect |
|-------------|--------|
| 0.3-0.4 | Subtle influence, mostly text-guided |
| 0.5-0.6 | Balanced — reference visible but text still dominant |
| 0.55-0.65 | Optimal balance for character consistency |
| 0.7-0.8 | Strong reference influence, may cause pose drift |
| 0.9-1.0 | Reference dominates, text prompt has minimal effect |

**Common pitfalls:**
- Weight too high (>0.75): The generated image copies the reference pose, making it hard to create varied compositions.
- Weight too low (<0.4): Character features drift significantly from the reference.
- For FaceID specifically, weights of 0.7-0.85 work well since the face model is more targeted.

## Required Models

IP-Adapter requires models in specific folders:

| Folder | Files | Purpose |
|--------|-------|---------|
| `ipadapter/` | `ip-adapter_sd15.safetensors`, `ip-adapter-plus_sd15.safetensors`, `ip-adapter-plus-face_sd15.safetensors`, `ip-adapter_sdxl_vit-h.safetensors`, `ip-adapter-faceid-plusv2_sdxl.safetensors` | IP-Adapter model weights |
| `clip_vision/` | `CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors`, `CLIP-ViT-bigG-14-laion2B-39B-b160k.safetensors` | CLIP vision encoders |
| `insightface/` | `buffalo_l/` model files | Face detection/recognition (for FaceID) |

Check available models via `GET {url}/models/ipadapter` and `GET {url}/models/clip_vision`.

## Two-Pass Technique

For best character consistency across a series of images:

**Pass 1**: Generate a clean reference image without IP-Adapter.
- Use a detailed text prompt describing the character.
- Generate multiple candidates and pick the best one.
- This becomes the canonical reference.

**Pass 2**: Use the reference with IP-Adapter for all subsequent images.
- Feed the reference image into IP-Adapter.
- Adjust the text prompt for each new scene/pose.
- Keep IP-Adapter weight at 0.55-0.65.

## Combining IP-Adapter with ControlNet

Use IP-Adapter for appearance/style and ControlNet for pose/structure:

1. Load and apply IP-Adapter to the model (handles appearance).
2. Apply ControlNet conditioning (handles pose/composition).
3. IP-Adapter modified model feeds into KSampler; ControlNet conditioning merges with the positive prompt.

This separation gives precise control: change the pose via ControlNet without affecting character appearance, or change the character via IP-Adapter without affecting the pose.

## Example: Basic IP-Adapter Workflow

```json
{
  "1": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": {
      "ckpt_name": "sd_xl_base_1.0.safetensors"
    },
    "_meta": { "title": "Load Checkpoint" }
  },
  "2": {
    "class_type": "CLIPVisionLoader",
    "inputs": {
      "clip_name": "CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
    },
    "_meta": { "title": "Load CLIP Vision" }
  },
  "3": {
    "class_type": "IPAdapterModelLoader",
    "inputs": {
      "ipadapter_file": "ip-adapter-plus_sdxl_vit-h.safetensors"
    },
    "_meta": { "title": "Load IP-Adapter" }
  },
  "4": {
    "class_type": "LoadImage",
    "inputs": {
      "image": "reference_character.png"
    },
    "_meta": { "title": "Reference Image" }
  },
  "5": {
    "class_type": "PrepImageForClipVision",
    "inputs": {
      "image": ["4", 0],
      "interpolation": "LANCZOS",
      "crop_position": "center",
      "sharpening": 0.0
    },
    "_meta": { "title": "Prep Image for CLIP" }
  },
  "6": {
    "class_type": "IPAdapterAdvanced",
    "inputs": {
      "model": ["1", 0],
      "ipadapter": ["3", 0],
      "clip_vision": ["2", 0],
      "image": ["5", 0],
      "weight": 0.6,
      "weight_type": "linear",
      "start_at": 0.0,
      "end_at": 1.0
    },
    "_meta": { "title": "Apply IP-Adapter" }
  },
  "7": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "a person standing in a garden, golden hour lighting, high quality",
      "clip": ["1", 1]
    },
    "_meta": { "title": "Positive Prompt" }
  },
  "8": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "bad quality, blurry, distorted",
      "clip": ["1", 1]
    },
    "_meta": { "title": "Negative Prompt" }
  },
  "9": {
    "class_type": "EmptyLatentImage",
    "inputs": {
      "width": 1024,
      "height": 1024,
      "batch_size": 1
    },
    "_meta": { "title": "Empty Latent" }
  },
  "10": {
    "class_type": "KSampler",
    "inputs": {
      "model": ["6", 0],
      "positive": ["7", 0],
      "negative": ["8", 0],
      "latent_image": ["9", 0],
      "seed": 12345,
      "steps": 25,
      "cfg": 7.0,
      "sampler_name": "dpmpp_2m",
      "scheduler": "karras",
      "denoise": 1.0
    },
    "_meta": { "title": "KSampler" }
  },
  "11": {
    "class_type": "VAEDecode",
    "inputs": {
      "samples": ["10", 0],
      "vae": ["1", 2]
    },
    "_meta": { "title": "VAE Decode" }
  },
  "12": {
    "class_type": "SaveImage",
    "inputs": {
      "images": ["11", 0],
      "filename_prefix": "ipadapter_output"
    },
    "_meta": { "title": "Save Image" }
  }
}
```

### Key Wiring Notes
- The **model** from CheckpointLoaderSimple ("1", output 0) goes into IPAdapterAdvanced, NOT directly into KSampler.
- The **modified model** from IPAdapterAdvanced ("6", output 0) goes into KSampler.
- CLIP and VAE still come directly from the checkpoint loader — IP-Adapter only modifies the model.
- The reference image is preprocessed through PrepImageForClipVision before being fed to IP-Adapter.

## Example: FaceID Workflow Addition

Replace the IPAdapterAdvanced node with IPAdapterFaceID and add InsightFace:

```json
{
  "5": {
    "class_type": "InsightFaceLoader",
    "inputs": {
      "provider": "CPU"
    },
    "_meta": { "title": "Load InsightFace" }
  },
  "6": {
    "class_type": "IPAdapterFaceID",
    "inputs": {
      "model": ["1", 0],
      "ipadapter": ["3", 0],
      "clip_vision": ["2", 0],
      "insightface": ["5", 0],
      "image": ["4", 0],
      "weight": 0.8,
      "weight_faceidv2": 0.8,
      "start_at": 0.0,
      "end_at": 1.0
    },
    "_meta": { "title": "Apply IP-Adapter FaceID" }
  }
}
```

Note: FaceID uses higher weights (0.7-0.85) because the face model is more targeted. Set InsightFace provider to "CUDA" if GPU is available, or "CPU" as fallback.
