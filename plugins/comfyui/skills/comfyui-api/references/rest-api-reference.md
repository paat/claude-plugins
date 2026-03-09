# ComfyUI REST API Reference

All endpoints are relative to the ComfyUI server base URL, referenced as `${COMFYUI_URL}` (e.g., `http://localhost:8188`).

---

## POST /prompt

Queue a workflow for execution.

**Request Body:**

```json
{
  "prompt": {
    "3": {
      "class_type": "KSampler",
      "inputs": {
        "seed": 42,
        "steps": 20,
        "cfg": 7.0,
        "sampler_name": "euler",
        "scheduler": "normal",
        "denoise": 1.0,
        "model": ["4", 0],
        "positive": ["6", 0],
        "negative": ["7", 0],
        "latent_image": ["5", 0]
      }
    }
  },
  "client_id": "optional-uuid4",
  "prompt_id": "optional-uuid4",
  "extra_data": {
    "extra_pnginfo": {}
  }
}
```

- `prompt` (required): Workflow graph as a dictionary of node ID to node definition. Each node has `class_type` and `inputs`. Inputs referencing other nodes use `["node_id", output_index]`.
- `client_id` (optional): UUID for WebSocket routing. If provided, execution events are sent to this client.
- `prompt_id` (optional): UUID to identify this execution. Auto-generated if omitted.
- `extra_data` (optional): Metadata embedded in output PNGs.

**Response (200):**

```json
{
  "prompt_id": "uuid-string",
  "number": 5,
  "node_errors": {}
}
```

- `prompt_id`: The execution ID.
- `number`: Queue position number.
- `node_errors`: Object mapping node IDs to validation errors. Empty if the workflow is valid.

**Response (400) — Validation Error:**

```json
{
  "error": {
    "type": "prompt_no_outputs",
    "message": "Prompt has no outputs",
    "details": "",
    "extra_info": {}
  },
  "node_errors": {
    "3": {
      "type": "invalid_input_type",
      "message": "...",
      "details": "...",
      "extra_info": {}
    }
  }
}
```

**curl Example:**

```bash
curl -s -X POST "${COMFYUI_URL}/prompt" \
  -H "Content-Type: application/json" \
  -d '{"prompt": {"3": {"class_type": "KSampler", "inputs": {...}}}}'
```

---

## GET /queue

Get current queue status showing running and pending items.

**Response (200):**

```json
{
  "queue_running": [
    [0, "prompt_id", {"prompt": {...}, "extra_data": {...}}, ["output_node_id"], {}]
  ],
  "queue_pending": [
    [1, "prompt_id", {"prompt": {...}, "extra_data": {...}}, ["output_node_id"], {}]
  ]
}
```

Each queue entry is a tuple of: `[queue_number, prompt_id, prompt_data, output_nodes, extra_info]`.

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/queue"
```

**Notes:** Use `queue_running` length and `queue_pending` length to determine queue depth.

---

## POST /queue

Delete specific queue items or clear the entire queue.

**Request Body — Delete specific items:**

```json
{
  "delete": ["prompt_id_1", "prompt_id_2"]
}
```

**Request Body — Clear all pending:**

```json
{
  "clear": true
}
```

**Response (200):** Empty body on success.

**curl Example:**

```bash
# Delete specific items
curl -s -X POST "${COMFYUI_URL}/queue" \
  -H "Content-Type: application/json" \
  -d '{"delete": ["abc-123"]}'

# Clear entire pending queue
curl -s -X POST "${COMFYUI_URL}/queue" \
  -H "Content-Type: application/json" \
  -d '{"clear": true}'
```

**Notes:** `clear` only removes pending items, not the currently running execution. Use `/interrupt` to cancel the running item.

---

## POST /interrupt

Cancel the currently executing workflow.

**Request Body:** None required (empty body or `{}`).

**Response (200):** Empty body on success.

**curl Example:**

```bash
curl -s -X POST "${COMFYUI_URL}/interrupt"
```

**Notes:** Interrupts the currently running execution. The execution appears in history with an interrupted status. Does not clear pending queue items.

---

## GET /history

Get execution history with optional pagination.

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `max_items` | int | 200 | Maximum number of history entries to return |
| `prompt_id` | string | — | Filter to a specific prompt ID |

**Response (200):**

```json
{
  "prompt_id_1": {
    "prompt": [queue_number, "prompt_id", {"prompt": {...}}, {"extra_pnginfo": {}}, ["output_nodes"]],
    "outputs": {
      "9": {
        "images": [
          {
            "filename": "ComfyUI_00001_.png",
            "subfolder": "",
            "type": "output"
          }
        ]
      }
    },
    "status": {
      "status_str": "success",
      "completed": true,
      "messages": [
        ["execution_start", {"prompt_id": "..."}],
        ["execution_cached", {"nodes": ["1", "2"]}],
        ["execution_success", {"prompt_id": "..."}]
      ]
    }
  }
}
```

**curl Example:**

```bash
# Get recent history
curl -s "${COMFYUI_URL}/history?max_items=10"
```

---

## GET /history/{prompt_id}

Get execution result for a specific prompt.

**Response (200):**

```json
{
  "prompt_id": {
    "prompt": [...],
    "outputs": {
      "node_id": {
        "images": [
          {"filename": "ComfyUI_00001_.png", "subfolder": "", "type": "output"}
        ]
      }
    },
    "status": {
      "status_str": "success",
      "completed": true,
      "messages": [...]
    }
  }
}
```

Returns an empty object `{}` if the prompt_id is not found in history (still running or never existed).

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/history/abc-def-123"
```

**Notes:** Poll this endpoint to check if an execution has completed. When `status.completed` is `true`, the execution is done. Check `status.status_str` for `"success"` or `"error"`.

---

## GET /object_info

Get schemas for all registered node classes including their inputs, outputs, and metadata.

**Response (200):**

```json
{
  "KSampler": {
    "input": {
      "required": {
        "model": ["MODEL"],
        "seed": ["INT", {"default": 0, "min": 0, "max": 18446744073709551615}],
        "steps": ["INT", {"default": 20, "min": 1, "max": 10000}],
        "cfg": ["FLOAT", {"default": 8.0, "min": 0.0, "max": 100.0}],
        "sampler_name": [["euler", "euler_ancestral", "heun", "dpm_2", ...]],
        "scheduler": [["normal", "karras", "exponential", "sgm_uniform", ...]],
        "positive": ["CONDITIONING"],
        "negative": ["CONDITIONING"],
        "latent_image": ["LATENT"],
        "denoise": ["FLOAT", {"default": 1.0, "min": 0.0, "max": 1.0, "step": 0.01}]
      },
      "optional": {},
      "hidden": {
        "prompt": "PROMPT",
        "extra_pnginfo": "EXTRA_PNGINFO"
      }
    },
    "input_order": {
      "required": ["model", "seed", "steps", "cfg", "sampler_name", "scheduler", "positive", "negative", "latent_image", "denoise"]
    },
    "output": ["LATENT"],
    "output_is_list": [false],
    "output_name": ["LATENT"],
    "name": "KSampler",
    "display_name": "KSampler",
    "description": "",
    "python_module": "nodes",
    "category": "sampling",
    "output_node": false
  }
}
```

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/object_info"
```

**Notes:** The response can be very large (multiple MB). Always query `/object_info/{node_class}` when looking up a specific node.

---

## GET /object_info/{node_class}

Get schema for a specific node class.

**Response (200):**

```json
{
  "KSampler": {
    "input": {...},
    "output": [...],
    "name": "KSampler",
    "display_name": "KSampler",
    "category": "sampling",
    "output_node": false
  }
}
```

**Response (404):** Returned if the node class does not exist.

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/object_info/KSampler"
```

---

## GET /system_stats

Get system statistics including GPU info, VRAM usage, and queue state.

**Response (200):**

```json
{
  "system": {
    "os": "posix",
    "comfyui_version": "0.3.10",
    "python_version": "3.12.4",
    "pytorch_version": "2.5.1+cu124",
    "embedded_python": false,
    "argv": ["/app/main.py", "--listen", "0.0.0.0"]
  },
  "devices": [
    {
      "name": "cuda:0 NVIDIA GeForce RTX 5090",
      "type": "cuda",
      "index": 0,
      "vram_total": 34089730048,
      "vram_free": 30012345678,
      "torch_vram_total": 34089730048,
      "torch_vram_free": 30012345678
    }
  ]
}
```

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/system_stats"
```

**Notes:** VRAM values are in bytes. `vram_free` vs `torch_vram_free` may differ — `torch_vram_free` reflects PyTorch's allocator view.

---

## GET /models/{folder}

List available models in a specific folder.

**Folder Names:**

| Folder | Contents |
|--------|----------|
| `checkpoints` | Stable Diffusion / SDXL / Flux checkpoint models |
| `loras` | LoRA adapter models |
| `vae` | VAE models |
| `controlnet` | ControlNet models |
| `upscale_models` | Upscaling models (ESRGAN, etc.) |
| `embeddings` | Textual inversion embeddings |
| `hypernetworks` | Hypernetwork models |
| `clip_vision` | CLIP vision models |
| `clip` | CLIP text encoder models |
| `unet` | UNet / diffusion models |
| `diffusion_models` | Diffusion model files |

**Response (200):**

```json
[
  "sd_xl_base_1.0.safetensors",
  "flux1-dev.safetensors",
  "subdirectory/model.safetensors"
]
```

Returns a flat list of relative paths within the folder.

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/models/checkpoints"
curl -s "${COMFYUI_URL}/models/loras"
```

---

## GET /embeddings

List available textual inversion embeddings.

**Response (200):**

```json
[
  "EasyNegative.safetensors",
  "bad_prompt_v2.pt"
]
```

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/embeddings"
```

---

## POST /upload/image

Upload an image to the ComfyUI input directory.

**Request:** Multipart form data.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `image` | file | yes | The image file to upload |
| `subfolder` | string | no | Subdirectory within input folder (default: root) |
| `type` | string | no | One of `input`, `temp`, `output` (default: `input`) |
| `overwrite` | string | no | `"true"` to overwrite existing file (default: `"false"`) |

**Response (200):**

```json
{
  "name": "uploaded_image.png",
  "subfolder": "",
  "type": "input"
}
```

**curl Example:**

```bash
curl -s -X POST "${COMFYUI_URL}/upload/image" \
  -F "image=@/path/to/image.png" \
  -F "subfolder=" \
  -F "type=input" \
  -F "overwrite=true"
```

**Notes:** Uploaded images can be referenced in workflows using `LoadImage` node with the returned filename. The `type` field controls which directory the image is saved to.

---

## GET /view

Retrieve a generated output file (image, video, etc.).

**Query Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `filename` | string | yes | Filename from the output |
| `subfolder` | string | no | Subfolder within the output directory |
| `type` | string | no | One of `output`, `input`, `temp` (default: `output`) |
| `preview` | string | no | Preview format, e.g. `"webp;50"` for lossy preview |
| `channel` | string | no | Color channel: `rgba`, `rgb` |

**Response (200):** Raw file bytes with appropriate Content-Type header (e.g., `image/png`).

**curl Example:**

```bash
# Download an output image
curl -s "${COMFYUI_URL}/view?filename=ComfyUI_00001_.png&subfolder=&type=output" \
  -o output.png

# Get a compressed preview
curl -s "${COMFYUI_URL}/view?filename=ComfyUI_00001_.png&type=output&preview=webp;50" \
  -o preview.webp
```

**Notes:** The `filename`, `subfolder`, and `type` values come from the `images` array in the history output. Always use the exact values returned by the API.

---

## POST /free

Free VRAM and system memory.

**Request Body:**

```json
{
  "unload_models": true,
  "free_memory": true
}
```

- `unload_models` (bool): Unload all models from GPU VRAM.
- `free_memory` (bool): Run garbage collection and clear caches.

**Response (200):** Empty body on success.

**curl Example:**

```bash
curl -s -X POST "${COMFYUI_URL}/free" \
  -H "Content-Type: application/json" \
  -d '{"unload_models": true, "free_memory": true}'
```

**Notes:** Use this when encountering VRAM OOM errors. Models are reloaded automatically on next execution, so there is a cold-start cost after freeing.

---

## GET /internal/folder_paths

Get server-side filesystem paths for each model folder.

**Response (200):**

```json
{
  "checkpoints": [
    ["/app/models/checkpoints", {"supported_extensions": [".safetensors", ".ckpt", ".pt", ".bin"]}]
  ],
  "loras": [
    ["/app/models/loras", {"supported_extensions": [".safetensors", ".ckpt", ".pt"]}]
  ],
  "vae": [
    ["/app/models/vae", {"supported_extensions": [".safetensors", ".ckpt", ".pt"]}]
  ]
}
```

Each folder maps to an array of `[path, metadata]` tuples. A folder can have multiple search paths.

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/internal/folder_paths"
```

**Notes:** These are server-side paths. Do not use them for local file operations unless the server is on the same machine. Useful for understanding where to place downloaded models.

---

## GET /internal/files/{directory_type}

List files in output, input, or temp directories.

**Path Parameters:**

| Parameter | Values |
|-----------|--------|
| `directory_type` | `output`, `input`, `temp` |

**Response (200):**

```json
[
  {
    "name": "ComfyUI_00001_.png",
    "path_index": 0,
    "subfolder": ""
  },
  {
    "name": "ComfyUI_00002_.png",
    "path_index": 0,
    "subfolder": "subfolder_name"
  }
]
```

**curl Example:**

```bash
# List output files
curl -s "${COMFYUI_URL}/internal/files/output"

# List input files
curl -s "${COMFYUI_URL}/internal/files/input"
```

---

## GET /internal/logs

Get ComfyUI server logs.

**Response (200):**

```json
{
  "entries": [
    {
      "timestamp": "2026-03-09T12:00:00.000Z",
      "message": "Prompt executed in 4.32 seconds",
      "level": "info"
    }
  ]
}
```

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/internal/logs"
```

**Notes:** Useful for debugging execution errors when history messages are insufficient. Log entries are in reverse chronological order.
