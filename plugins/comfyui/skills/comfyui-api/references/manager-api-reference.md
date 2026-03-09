# ComfyUI Manager API Reference

ComfyUI Manager is an optional extension that adds custom node management, model downloading, and snapshot capabilities. All endpoints below are relative to the ComfyUI server base URL (`${COMFYUI_URL}`).

**Important:** All Manager endpoints return HTTP 404 if ComfyUI Manager is not installed. Always handle 404 gracefully and inform the user that Manager is not available.

---

## GET /customnode/getlist

List all available custom nodes from the ComfyUI Manager registry.

**Response (200):**

```json
{
  "custom_nodes": [
    {
      "id": "comfyui-impact-pack",
      "title": "ComfyUI Impact Pack",
      "description": "Impact Pack provides detailers, SAM integration, and more.",
      "author": "Dr.Lt.Data",
      "reference": "https://github.com/ltdrdata/ComfyUI-Impact-Pack",
      "files": ["https://github.com/ltdrdata/ComfyUI-Impact-Pack"],
      "install_type": "git-clone",
      "installed": "True",
      "stars": 2500,
      "last_update": "2026-03-01T00:00:00Z"
    }
  ]
}
```

- `installed`: `"True"`, `"False"`, or `"Update"` (update available).
- `install_type`: Typically `"git-clone"` or `"copy"`.

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/customnode/getlist"
```

**Notes:** The response can be large (thousands of entries). Parse and filter client-side.

---

## GET /customnode/installed

List currently installed custom nodes.

**Response (200):**

```json
{
  "custom_nodes": [
    {
      "id": "comfyui-impact-pack",
      "title": "ComfyUI Impact Pack",
      "version": "4.10.2",
      "author": "Dr.Lt.Data",
      "enabled": true,
      "import_failed": false,
      "installed_path": "/app/custom_nodes/ComfyUI-Impact-Pack"
    }
  ]
}
```

- `enabled`: Whether the node pack is active.
- `import_failed`: `true` if the node pack failed to load (missing dependencies, etc.).

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/customnode/installed"
```

---

## POST /manager/queue/install

Queue a custom node for installation. The node is not installed immediately — it is added to an installation queue.

**Request Body:**

```json
{
  "id": "comfyui-impact-pack"
}
```

- `id`: The custom node ID from the registry (as returned by `/customnode/getlist`).

**Response (200):**

```json
{
  "success": true,
  "message": "Added to install queue"
}
```

**curl Example:**

```bash
curl -s -X POST "${COMFYUI_URL}/manager/queue/install" \
  -H "Content-Type: application/json" \
  -d '{"id": "comfyui-impact-pack"}'
```

**Notes:** After queuing, call `/manager/queue/start` to begin processing. A server restart is typically required after installation for new nodes to be loaded.

---

## GET /manager/queue/status

Check the current state of the installation queue.

**Response (200):**

```json
{
  "queue": [
    {
      "id": "comfyui-impact-pack",
      "status": "pending"
    }
  ],
  "running": false
}
```

- `status`: One of `"pending"`, `"installing"`, `"installed"`, `"failed"`.
- `running`: Whether the queue processor is currently active.

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/manager/queue/status"
```

---

## GET /manager/queue/start

Start processing the installation queue. Triggers the actual download and installation of queued custom nodes.

**Response (200):**

```json
{
  "success": true,
  "message": "Queue processing started"
}
```

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/manager/queue/start"
```

**Notes:** Poll `/manager/queue/status` to monitor progress. After all installations complete, a server restart is needed for new nodes to be available in `/object_info`.

---

## POST /manager/model/download

Download a model file to a specified folder on the server.

**Request Body:**

```json
{
  "url": "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors",
  "path": "checkpoints",
  "filename": "sd_xl_base_1.0.safetensors"
}
```

- `url` (required): Direct download URL for the model file.
- `path` (required): Target model folder name (e.g., `checkpoints`, `loras`, `vae`, `controlnet`).
- `filename` (required): Filename to save as within the target folder.

**Response (200):**

```json
{
  "success": true,
  "message": "Download started",
  "download_id": "uuid-string"
}
```

**curl Example:**

```bash
curl -s -X POST "${COMFYUI_URL}/manager/model/download" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors",
    "path": "checkpoints",
    "filename": "sd_xl_base_1.0.safetensors"
  }'
```

**Notes:** Downloads happen asynchronously on the server. Large models (multiple GB) may take significant time. The model becomes available in `GET /models/{folder}` once the download completes. For HuggingFace URLs, use the `/resolve/main/` URL format for direct file downloads.

---

## GET /snapshot/save

Save a snapshot of the current system state, including installed custom nodes and their versions.

**Response (200):**

```json
{
  "success": true,
  "snapshot_id": "2026-03-09_120000",
  "message": "Snapshot saved"
}
```

**curl Example:**

```bash
curl -s "${COMFYUI_URL}/snapshot/save"
```

**Notes:** Snapshots capture the current state of all installed custom nodes and their git commit hashes. Use snapshots before making changes so you can roll back if something breaks.

---

## POST /snapshot/restore

Restore the system to a previously saved snapshot.

**Request Body:**

```json
{
  "snapshot_id": "2026-03-09_120000"
}
```

**Response (200):**

```json
{
  "success": true,
  "message": "Snapshot restore queued. Restart server to apply."
}
```

**curl Example:**

```bash
curl -s -X POST "${COMFYUI_URL}/snapshot/restore" \
  -H "Content-Type: application/json" \
  -d '{"snapshot_id": "2026-03-09_120000"}'
```

**Notes:** Restoration requires a server restart to take effect. The restore operation reverts all custom nodes to the versions captured in the snapshot.

---

## Typical Workflow: Installing a Custom Node

1. Search for the node in the registry:
   ```bash
   curl -s "${COMFYUI_URL}/customnode/getlist" | jq '.custom_nodes[] | select(.title | test("Impact"))'
   ```

2. Queue the installation:
   ```bash
   curl -s -X POST "${COMFYUI_URL}/manager/queue/install" \
     -H "Content-Type: application/json" \
     -d '{"id": "comfyui-impact-pack"}'
   ```

3. Start the queue:
   ```bash
   curl -s "${COMFYUI_URL}/manager/queue/start"
   ```

4. Monitor until complete:
   ```bash
   curl -s "${COMFYUI_URL}/manager/queue/status"
   ```

5. Restart the ComfyUI server for new nodes to load.
