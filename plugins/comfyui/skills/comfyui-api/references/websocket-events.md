# ComfyUI WebSocket Events Reference

## Connection

Connect to the ComfyUI WebSocket server:

```
ws://{host}:{port}/ws?clientId={uuid4}
```

- `clientId` must be a valid UUID4. Generate one per session.
- The same `clientId` should be passed in the `client_id` field when queuing prompts via `POST /prompt` to receive execution events for those prompts.
- The connection receives JSON messages for all events. Binary messages are used for image previews during execution.

**Example connection (using websocat):**

```bash
websocat "ws://{host}:{port}/ws?clientId=$(uuidgen)"
```

---

## Event Types

### status

Sent on connection and whenever the queue state changes. Indicates how many items remain in the queue.

```json
{
  "type": "status",
  "data": {
    "status": {
      "exec_info": {
        "queue_remaining": 0
      }
    },
    "sid": "client-uuid"
  }
}
```

- `queue_remaining`: Total number of queued items (running + pending). When this reaches `0`, the server is idle.
- `sid`: The client session ID (your `clientId`). Only present on the initial connection message.

---

### execution_start

Sent when a prompt begins execution.

```json
{
  "type": "execution_start",
  "data": {
    "prompt_id": "abc-def-123",
    "timestamp": 1741500000000
  }
}
```

---

### executing

Sent when the server begins executing a specific node. Also sent with `node: null` when the entire prompt has finished.

```json
{
  "type": "executing",
  "data": {
    "node": "3",
    "display_node": "3",
    "prompt_id": "abc-def-123"
  }
}
```

- `node`: The ID of the node currently being executed. `null` when execution is complete.
- `display_node`: The node to highlight in the UI (may differ from `node` for grouped nodes).
- When `node` is `null`, the prompt has finished executing all nodes.

---

### progress

Sent during iterative operations (e.g., sampling steps). Reports step-by-step progress.

```json
{
  "type": "progress",
  "data": {
    "value": 5,
    "max": 20,
    "prompt_id": "abc-def-123",
    "node": "3"
  }
}
```

- `value`: Current step (1-indexed).
- `max`: Total number of steps.
- Progress percentage: `value / max * 100`.

---

### execution_cached

Sent when nodes are skipped because their outputs are already cached.

```json
{
  "type": "execution_cached",
  "data": {
    "nodes": ["1", "2", "4", "5"],
    "prompt_id": "abc-def-123"
  }
}
```

- `nodes`: Array of node IDs whose execution was skipped due to caching.

---

### executed

Sent when a node has finished executing and produced output.

```json
{
  "type": "executed",
  "data": {
    "node": "9",
    "display_node": "9",
    "output": {
      "images": [
        {
          "filename": "ComfyUI_00001_.png",
          "subfolder": "",
          "type": "output"
        }
      ]
    },
    "prompt_id": "abc-def-123"
  }
}
```

- `output`: The node's output data. For image-producing nodes, contains an `images` array. Each image can be fetched via `GET /view`.

---

### execution_error

Sent when a node fails during execution.

```json
{
  "type": "execution_error",
  "data": {
    "prompt_id": "abc-def-123",
    "node_id": "3",
    "node_type": "KSampler",
    "exception_message": "CUDA out of memory. Tried to allocate 2.00 GiB...",
    "exception_type": "RuntimeError",
    "traceback": [
      "Traceback (most recent call last):",
      "  File \"/app/execution.py\", line 152, in execute",
      "..."
    ],
    "current_inputs": {},
    "current_outputs": {}
  }
}
```

- `exception_message`: Human-readable error description.
- `exception_type`: Python exception class name.
- `traceback`: Full Python traceback as an array of strings.
- `node_id` and `node_type`: Identify which node failed.

---

### execution_interrupted

Sent when execution is cancelled via `POST /interrupt`.

```json
{
  "type": "execution_interrupted",
  "data": {
    "prompt_id": "abc-def-123",
    "node_id": "3",
    "node_type": "KSampler",
    "executed": ["1", "2", "4", "5"]
  }
}
```

- `executed`: List of node IDs that completed before the interruption.

---

## Binary Messages (Preview Images)

During sampling, the server may send binary WebSocket frames containing preview images. The binary format is:

```
[type: 1 byte] [format: 1 byte] [image data: remaining bytes]
```

- Type `1` = preview image.
- Format `1` = JPEG, Format `2` = PNG.
- The image data can be decoded directly.

These are low-quality previews sent during each sampling step. Final outputs are delivered via the `executed` event.

---

## Typical Event Sequence: txt2img

A successful text-to-image generation with a workflow containing nodes for model loading (1), CLIP encoding (2, 3), empty latent (4), KSampler (5), VAE decode (6), and SaveImage (7):

```
1. {"type": "status",           "data": {"status": {"exec_info": {"queue_remaining": 1}}}}
2. {"type": "execution_start",  "data": {"prompt_id": "abc-123"}}
3. {"type": "execution_cached", "data": {"nodes": ["1", "2", "3"], "prompt_id": "abc-123"}}
4. {"type": "executing",        "data": {"node": "4", "prompt_id": "abc-123"}}
5. {"type": "executing",        "data": {"node": "5", "prompt_id": "abc-123"}}
6. {"type": "progress",         "data": {"value": 1,  "max": 20, "prompt_id": "abc-123", "node": "5"}}
7. {"type": "progress",         "data": {"value": 2,  "max": 20, "prompt_id": "abc-123", "node": "5"}}
   ... (progress events for each step) ...
8. {"type": "progress",         "data": {"value": 20, "max": 20, "prompt_id": "abc-123", "node": "5"}}
9. {"type": "executing",        "data": {"node": "6", "prompt_id": "abc-123"}}
10.{"type": "executing",        "data": {"node": "7", "prompt_id": "abc-123"}}
11.{"type": "executed",         "data": {"node": "7", "output": {"images": [{"filename": "ComfyUI_00001_.png", "subfolder": "", "type": "output"}]}, "prompt_id": "abc-123"}}
12.{"type": "executing",        "data": {"node": null, "prompt_id": "abc-123"}}
13.{"type": "status",           "data": {"status": {"exec_info": {"queue_remaining": 0}}}}
```

**Key observations:**

1. Cached nodes (model, CLIP) are reported once via `execution_cached` and skipped.
2. `progress` events fire for each sampling step on the KSampler node.
3. The `executed` event on the SaveImage node contains the output filenames.
4. `executing` with `node: null` signals that all nodes are done.
5. Final `status` with `queue_remaining: 0` confirms the server is idle.
