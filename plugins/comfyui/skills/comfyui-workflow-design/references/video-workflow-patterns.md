# Video Workflow Patterns

## AnimateDiff

AnimateDiff adds temporal motion to Stable Diffusion by injecting motion modules into the U-Net. It generates short video clips (typically 16-32 frames) by conditioning across a temporal dimension.

### Core Nodes (from ComfyUI-AnimateDiff-Evolved)

| Node | Purpose | Key Inputs | Outputs |
|------|---------|------------|---------|
| `ADE_AnimateDiffLoaderWithContext` | Load motion module with context config | model, model_name, context_options | MODEL |
| `ADE_AnimateDiffUniformContextOptions` | Configure context window | context_length, context_stride, context_overlap, context_schedule | CONTEXT_OPTIONS |
| `ADE_AnimateDiffModelSettings` | Fine-tune motion module behavior | motion_pe_stretch | MOTION_MODEL_SETTINGS |

### Key Parameters

| Parameter | Typical Value | Description |
|-----------|---------------|-------------|
| `context_length` | 16 | Number of frames processed together. Higher = smoother motion, more VRAM. |
| `context_stride` | 1 | Frame skip within context window. 1 = every frame. |
| `context_overlap` | 4 | Frames shared between adjacent context windows. Ensures temporal coherence. |
| `context_schedule` | "uniform" | How context windows are distributed. "uniform" is standard. |
| `frame_count` | 16-32 | Total frames to generate. Set via EmptyLatentImage batch_size or dedicated node. |

### AnimateDiff Workflow Structure

```
CheckpointLoaderSimple → ADE_AnimateDiffLoaderWithContext → KSampler → AnimateDiffCombine / VHS_VideoCombine
```

The motion module wraps around the model, so the AnimateDiff loader takes the model as input and returns a modified model. Everything else (CLIP, VAE, conditioning) works the same as image generation.

### Example: AnimateDiff txt2vid

```json
{
  "1": {
    "class_type": "CheckpointLoaderSimple",
    "inputs": {
      "ckpt_name": "sd15_base.safetensors"
    },
    "_meta": { "title": "Load Checkpoint" }
  },
  "2": {
    "class_type": "ADE_AnimateDiffUniformContextOptions",
    "inputs": {
      "context_length": 16,
      "context_stride": 1,
      "context_overlap": 4,
      "context_schedule": "uniform",
      "closed_loop": false
    },
    "_meta": { "title": "Context Options" }
  },
  "3": {
    "class_type": "ADE_AnimateDiffLoaderWithContext",
    "inputs": {
      "model": ["1", 0],
      "model_name": "mm_sd_v15_v2.ckpt",
      "beta_schedule": "sqrt_linear (AnimateDiff)",
      "context_options": ["2", 0]
    },
    "_meta": { "title": "AnimateDiff Loader" }
  },
  "4": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "a cat walking on a beach, ocean waves, sunny day",
      "clip": ["1", 1]
    },
    "_meta": { "title": "Positive Prompt" }
  },
  "5": {
    "class_type": "CLIPTextEncode",
    "inputs": {
      "text": "bad quality, static, blurry",
      "clip": ["1", 1]
    },
    "_meta": { "title": "Negative Prompt" }
  },
  "6": {
    "class_type": "EmptyLatentImage",
    "inputs": {
      "width": 512,
      "height": 512,
      "batch_size": 16
    },
    "_meta": { "title": "Empty Latent (16 frames)" }
  },
  "7": {
    "class_type": "KSampler",
    "inputs": {
      "model": ["3", 0],
      "positive": ["4", 0],
      "negative": ["5", 0],
      "latent_image": ["6", 0],
      "seed": 42,
      "steps": 20,
      "cfg": 7.5,
      "sampler_name": "euler_ancestral",
      "scheduler": "normal",
      "denoise": 1.0
    },
    "_meta": { "title": "KSampler" }
  },
  "8": {
    "class_type": "VAEDecode",
    "inputs": {
      "samples": ["7", 0],
      "vae": ["1", 2]
    },
    "_meta": { "title": "VAE Decode" }
  },
  "9": {
    "class_type": "VHS_VideoCombine",
    "inputs": {
      "images": ["8", 0],
      "frame_rate": 8,
      "loop_count": 0,
      "filename_prefix": "animatediff",
      "format": "video/h264-mp4",
      "save_output": true
    },
    "_meta": { "title": "Save Video" }
  }
}
```

**Important**: `batch_size` in EmptyLatentImage sets the frame count for AnimateDiff. 16 frames at 8 fps = 2 second clip.

## Wan2.1 / Wan2.2

Wan (from Alibaba) is a dedicated video generation model supporting text-to-video and image-to-video. It uses its own model architecture separate from Stable Diffusion.

### Core Nodes

| Node | Purpose |
|------|---------|
| `WanVideoModelLoader` | Load Wan video model (unet) |
| `WanVideoTextEncode` | Encode text prompt with Wan's text encoder |
| `WanVideoImageEncode` | Encode reference image for img2vid |
| `WanVideoSampler` | Specialized sampler for Wan models |
| `WanVideoVAEDecode` | Decode Wan latents to video frames |
| `WanVideoVAELoader` | Load Wan-specific VAE |
| `WanVideoCLIPLoader` | Load Wan text encoder |

### Text-to-Video Mode

```
WanVideoModelLoader → WanVideoTextEncode → WanVideoSampler → WanVideoVAEDecode → VHS_VideoCombine
```

### Image-to-Video Mode

```
WanVideoModelLoader + LoadImage → WanVideoImageEncode → WanVideoSampler → WanVideoVAEDecode → VHS_VideoCombine
```

The reference image provides the first frame, and the model generates subsequent frames maintaining visual consistency.

### Wan Key Parameters

| Parameter | Typical Value | Description |
|-----------|---------------|-------------|
| `num_frames` | 33-81 | Number of video frames. Wan native frame counts. |
| `width` | 832 | Video width (must match model training resolution) |
| `height` | 480 | Video height |
| `steps` | 20-30 | Sampling steps |
| `cfg` | 5.0-7.0 | Guidance scale for Wan |
| `shift` | 5.0-8.0 | Wan-specific shift parameter for noise schedule |

## Frame Interpolation

Increase apparent smoothness by interpolating between generated frames.

### FILM / RIFE Nodes

| Node | Purpose |
|------|---------|
| `RIFE VFI` | Real-time Intermediate Flow Estimation — fast frame interpolation |
| `FILM VFI` | Frame Interpolation for Large Motion — better for large motion |
| `KSampler (VFI)` | Some packs provide sampler-based interpolation |

### Interpolation Workflow Pattern

```
Generate video frames → RIFE VFI (multiplier=2) → VHS_VideoCombine (double the fps)
```

Example: Generate 16 frames at 8fps, interpolate 2x to get 32 frames, output at 16fps for the same duration but smoother motion.

```json
{
  "10": {
    "class_type": "RIFE VFI",
    "inputs": {
      "images": ["8", 0],
      "multiplier": 2,
      "fast_mode": true,
      "ensemble": true
    },
    "_meta": { "title": "RIFE Frame Interpolation" }
  }
}
```

## Video Output: VHS_VideoCombine

The standard video output node from VideoHelperSuite:

```json
{
  "class_type": "VHS_VideoCombine",
  "inputs": {
    "images": ["8", 0],
    "frame_rate": 8,
    "loop_count": 0,
    "filename_prefix": "video_output",
    "format": "video/h264-mp4",
    "save_output": true,
    "pingpong": false
  }
}
```

### Format Options

| Format | Use Case |
|--------|----------|
| `video/h264-mp4` | Standard MP4 video, broadly compatible |
| `video/h265-mp4` | Better compression, less compatible |
| `video/vp9-webm` | Web-friendly format |
| `image/gif` | Animated GIF (large files, 256 colors) |
| `image/webp` | Animated WebP (better than GIF) |

### Parameters

- `frame_rate`: Output FPS. Match to generation intent (8 for stylized, 24-30 for realistic).
- `loop_count`: 0 = no loop, 1+ = loop N times.
- `pingpong`: If true, plays forward then backward for seamless loops.
- `save_output`: If true, saves to output folder. If false, only previews.

## Memory Considerations

Video workflows are extremely VRAM-intensive:

| Technique | VRAM Estimate | Recommendation |
|-----------|---------------|----------------|
| AnimateDiff SD1.5, 512x512, 16 frames | ~6-8 GB | Feasible on most GPUs |
| AnimateDiff SDXL, 1024x1024, 16 frames | ~16-20 GB | Needs high-end GPU |
| Wan2.1 txt2vid, 832x480, 33 frames | ~12-16 GB | Medium-high VRAM |
| Wan2.1 txt2vid, 832x480, 81 frames | ~20-24 GB | High-end GPU required |

Strategies for reducing VRAM usage:
- **Reduce resolution**: Generate at lower resolution and upscale frames afterwards.
- **Reduce frame count**: Generate fewer frames, use RIFE interpolation to increase count.
- **Use context windowing**: AnimateDiff context_length controls how many frames are in memory at once.
- **CPU offloading**: Some nodes support offloading parts of the model to system RAM.
- **FP8/quantized models**: Use GGUF or FP8 variants of video models when available.
