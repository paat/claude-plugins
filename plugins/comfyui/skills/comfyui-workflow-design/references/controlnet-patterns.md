# ControlNet Workflow Patterns

## What ControlNet Does

ControlNet provides structural guidance to the image generation process using reference images. Unlike IP-Adapter (which transfers appearance/style), ControlNet controls spatial structure: pose, edges, depth, line art, and segmentation maps. The reference image is processed by a preprocessor to extract a condition map, which then guides the diffusion process.

## Node Classes

### Core Nodes

| Node | Purpose | Key Inputs | Outputs |
|------|---------|------------|---------|
| `ControlNetLoader` | Load a ControlNet model | control_net_name | CONTROL_NET |
| `ControlNetApplyAdvanced` | Apply ControlNet to conditioning (preferred) | positive, negative, control_net, image, strength, start_percent, end_percent | CONDITIONING, CONDITIONING |
| `ControlNetApply` | Simple ControlNet apply (legacy) | conditioning, control_net, image, strength | CONDITIONING |

Always prefer `ControlNetApplyAdvanced` over `ControlNetApply` — it handles both positive and negative conditioning and supports start/end percent for temporal control.

### Preprocessor Nodes

| Node | Purpose | Output Type | Best For |
|------|---------|-------------|----------|
| `CannyEdgePreprocessor` | Edge detection | Edge map (white lines on black) | Hard edges, architecture, objects |
| `DepthAnythingPreprocessor` | Monocular depth estimation | Depth map (grayscale) | 3D structure, spatial layout |
| `OpenposePreprocessor` | Human pose estimation | Skeleton keypoints | Human poses, body positioning |
| `DWPreprocessor` | DWPose (improved OpenPose) | Skeleton keypoints + hands + face | More accurate human poses |
| `LineArtPreprocessor` | Line art extraction | Clean line drawing | Manga, illustration, coloring |
| `AnimeLineArtPreprocessor` | Anime-style line art | Stylized line drawing | Anime/cartoon art |
| `MiDaS-DepthMapPreprocessor` | MiDaS depth estimation | Depth map | General depth (legacy, use DepthAnything instead) |
| `Zoe-DepthMapPreprocessor` | ZoeDepth estimation | Depth map | Indoor scenes |
| `NormalMapPreprocessor` | Surface normal estimation | Normal map (RGB) | Surface detail, lighting |
| `SegmentAnythingPreprocessor` | Semantic segmentation | Segmentation map | Scene decomposition |
| `TilePreprocessor` | Tile/texture preservation | Processed tile | Upscaling, detail preservation |
| `ScribblePreprocessor` | Scribble/sketch detection | Simplified sketch | Loose sketch guidance |
| `SoftEdgePreprocessor` | Soft edge detection (HED/PiDi) | Soft edge map | Gentle structural guidance |

## Key Parameters

### ControlNetApplyAdvanced

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| `strength` | 0.0-2.0 | 1.0 | How strongly the ControlNet guides generation. 0.5-1.0 typical. |
| `start_percent` | 0.0-1.0 | 0.0 | When ControlNet starts influencing (0.0 = from the beginning). |
| `end_percent` | 0.0-1.0 | 1.0 | When ControlNet stops influencing (1.0 = through the end). |

**Strength tuning:**
- 0.3-0.5: Loose guidance — suggestions, not strict adherence.
- 0.5-0.8: Balanced — follows structure while allowing creative freedom.
- 0.8-1.0: Strict — closely follows the control image.
- 1.0+: Very strict — can cause artifacts if the control signal conflicts with the text prompt.

**Temporal control (start/end percent):**
- `start_percent: 0.0, end_percent: 0.8`: ControlNet guides initial structure but allows the model to refine details freely in the last 20% of steps. Good for natural-looking results.
- `start_percent: 0.2, end_percent: 1.0`: Skip ControlNet for the initial composition step, apply for detail. Rare use case.
- `start_percent: 0.0, end_percent: 0.5`: ControlNet only guides rough structure, detail is fully text-guided.

## Resolution Requirements

The preprocessor output image dimensions must match the latent image dimensions. If your latent is 1024x1024, the ControlNet input image must also be 1024x1024.

Approaches:
1. Resize the reference image before preprocessing to match the target resolution.
2. Use `ImageResize` or `ImageScale` nodes to match dimensions after preprocessing.
3. Some preprocessor nodes accept a `resolution` parameter — set it to match your target.

## Stacking Multiple ControlNets

Chain multiple `ControlNetApplyAdvanced` nodes to combine different control signals:

```
ControlNetApplyAdvanced (OpenPose) → ControlNetApplyAdvanced (Depth) → KSampler
```

Each node takes the conditioning output of the previous one. The second ControlNet applies on top of the first.

**Common stacking combinations:**
- OpenPose + Depth: Precise pose with spatial awareness.
- Canny + Depth: Edge structure with 3D consistency.
- LineArt + Depth: Clean outlines with proper layering.

When stacking, reduce individual strengths (e.g., 0.5-0.7 each) to prevent over-constraining.

## Common Use Cases

### Pose Control (OpenPose/DWPose)
Transfer a human pose from a reference photo to a new generation. Use DWPreprocessor for better hand/face detection.

### Edge Guidance (Canny)
Maintain the outline/silhouette of an object or scene. Good for architectural consistency.

### Depth (DepthAnything)
Preserve the spatial layout and relative distances of a scene. Best for maintaining composition.

### Line Art
Convert a sketch or drawing into a fully rendered image while preserving the drawing's structure.

### Tile
Used primarily for upscaling workflows — preserves existing detail while adding resolution.

## Example: ControlNet with OpenPose

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
    "class_type": "LoadImage",
    "inputs": {
      "image": "pose_reference.png"
    },
    "_meta": { "title": "Pose Reference Image" }
  },
  "3": {
    "class_type": "DWPreprocessor",
    "inputs": {
      "image": ["2", 0],
      "detect_hand": "enable",
      "detect_body": "enable",
      "detect_face": "enable",
      "resolution": 1024
    },
    "_meta": { "title": "DWPose Preprocessor" }
  },
  "4": {
    "class_type": "ControlNetLoader",
    "inputs": {
      "control_net_name": "controlnet-openpose-sdxl-1.0.safetensors"
    },
    "_meta": { "title": "Load ControlNet" }
  },
  "5": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "a woman in a red dress, studio photography, soft lighting",
      "clip": ["1", 1]
    },
    "_meta": { "title": "Positive Prompt" }
  },
  "6": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "bad quality, blurry, distorted, deformed",
      "clip": ["1", 1]
    },
    "_meta": { "title": "Negative Prompt" }
  },
  "7": {
    "class_type": "ControlNetApplyAdvanced",
    "inputs": {
      "positive": ["5", 0],
      "negative": ["6", 0],
      "control_net": ["4", 0],
      "image": ["3", 0],
      "strength": 0.75,
      "start_percent": 0.0,
      "end_percent": 0.85
    },
    "_meta": { "title": "Apply ControlNet" }
  },
  "8": {
    "class_type": "EmptyLatentImage",
    "inputs": {
      "width": 1024,
      "height": 1024,
      "batch_size": 1
    },
    "_meta": { "title": "Empty Latent" }
  },
  "9": {
    "class_type": "KSampler",
    "inputs": {
      "model": ["1", 0],
      "positive": ["7", 0],
      "negative": ["7", 1],
      "latent_image": ["8", 0],
      "seed": 99887766,
      "steps": 25,
      "cfg": 7.0,
      "sampler_name": "dpmpp_2m",
      "scheduler": "karras",
      "denoise": 1.0
    },
    "_meta": { "title": "KSampler" }
  },
  "10": {
    "class_type": "VAEDecode",
    "inputs": {
      "samples": ["9", 0],
      "vae": ["1", 2]
    },
    "_meta": { "title": "VAE Decode" }
  },
  "11": {
    "class_type": "SaveImage",
    "inputs": {
      "images": ["10", 0],
      "filename_prefix": "controlnet_pose"
    },
    "_meta": { "title": "Save Image" }
  }
}
```

### Key Wiring Notes
- The reference image goes through the DWPose preprocessor before being fed to ControlNet.
- `ControlNetApplyAdvanced` takes both positive and negative conditioning as inputs and returns both as outputs (indices 0 and 1).
- KSampler connects to ControlNetApplyAdvanced outputs: positive = `["7", 0]`, negative = `["7", 1]`.
- The model goes directly from the checkpoint to KSampler — ControlNet modifies conditioning, not the model.

## Example: Stacking Two ControlNets

```json
{
  "10": {
    "class_type": "ControlNetApplyAdvanced",
    "inputs": {
      "positive": ["5", 0],
      "negative": ["6", 0],
      "control_net": ["4", 0],
      "image": ["3", 0],
      "strength": 0.6,
      "start_percent": 0.0,
      "end_percent": 0.85
    },
    "_meta": { "title": "Apply ControlNet - Pose" }
  },
  "11": {
    "class_type": "ControlNetApplyAdvanced",
    "inputs": {
      "positive": ["10", 0],
      "negative": ["10", 1],
      "control_net": ["20", 0],
      "image": ["21", 0],
      "strength": 0.5,
      "start_percent": 0.0,
      "end_percent": 0.8
    },
    "_meta": { "title": "Apply ControlNet - Depth" }
  }
}
```

The second ControlNet ("11") receives its conditioning from the first ControlNet ("10"), chaining them together. Both modified conditioning outputs (positive and negative) are then fed to the KSampler.
