---
name: comfyui-api
description: Use when interacting with the ComfyUI API, queuing workflows, checking server status, listing models, downloading models, monitoring execution progress, viewing queue, checking history, or troubleshooting ComfyUI connectivity. Activates for "comfyui api", "queue prompt", "comfyui server", "comfyui status", "execution progress", "comfyui models", "comfyui history", "comfyui queue".
---

## Configuration

Read `.claude/comfyui.local.md` YAML frontmatter for `comfyui_url`. Default to `http://localhost:8188` if the file is missing. Never hardcode URLs or paths.

## Server Health

Query `GET {url}/system_stats` for GPU info and VRAM usage. Query `GET {url}/queue` for queue depth (`running_size`, `pending_size`).

## Queuing a Workflow

POST to `{url}/prompt` with body `{"prompt": <workflow_dict>}`. Optionally include `"prompt_id"` (UUID). The response returns `prompt_id` and any `node_errors`.

## Monitoring Execution

Poll `GET {url}/history/{prompt_id}` at intervals until an entry appears with `status.status_str` of `"success"` or an error. Alternative: connect via WebSocket at `ws://{host}/ws?clientId={uuid}` for real-time events. See `references/websocket-events.md`.

## Retrieving Results

Parse `history[prompt_id].outputs` — each output node may have an `images` array with `{filename, subfolder, type}`. Fetch images via `GET {url}/view?filename={f}&subfolder={s}&type={t}`.

## Model Discovery

`GET {url}/models/{folder}` where folder is one of: `checkpoints`, `loras`, `vae`, `controlnet`, `upscale_models`, `embeddings`, `hypernetworks`, `clip_vision`. Paths are server-side — never assume filesystem layout.

## Node Discovery

`GET {url}/object_info` returns all registered node classes with full input/output schemas. `GET {url}/object_info/{class_name}` for a single node. Always query this before building workflows to verify available nodes and their expected inputs.

## Error Handling

- **Server unreachable**: Check the URL in settings, verify ComfyUI is running.
- **`node_errors` in queue response**: Invalid node class or malformed input — inspect the error details per node.
- **Execution error in history**: Parse `status.messages` for details on what failed and which node caused it.
- **VRAM OOM**: Suggest reducing resolution or batch size, or free memory via `POST {url}/free` with `{"unload_models": true, "free_memory": true}`.

## ComfyUI Manager (Optional)

If ComfyUI Manager is installed, additional endpoints are available for custom node management and model downloading. Manager endpoints return 404 if not installed — handle gracefully and inform the user. See `references/manager-api-reference.md`.

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-api/references/rest-api-reference.md` — Complete endpoint reference
- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-api/references/websocket-events.md` — Real-time event monitoring
- `${CLAUDE_PLUGIN_ROOT}/skills/comfyui-api/references/manager-api-reference.md` — ComfyUI Manager endpoints
