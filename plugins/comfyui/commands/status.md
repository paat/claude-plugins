---
name: status
description: Check ComfyUI server health — GPU stats, VRAM usage, queue depth, and connectivity
user_invocable: true
allowed-tools: Bash, Read
---

# ComfyUI Status Check

## Steps

1. Read `.claude/comfyui.local.md` for the `comfyui_url` setting. If the file is missing or the setting is absent, default to `http://localhost:8188`.

2. Test connectivity and fetch system stats:

```bash
curl -s --connect-timeout 5 "${url}/system_stats"
```

Parse the JSON with jq to extract:
- `system.os` — operating system
- `devices[].name` — GPU device name
- `devices[].type` — device type (cuda, cpu, etc.)
- `devices[].vram_total` — total VRAM in bytes
- `devices[].vram_free` — free VRAM in bytes
- Calculate VRAM used = total - free, and usage percentage

3. Fetch queue status:

```bash
curl -s --connect-timeout 5 "${url}/queue"
```

Extract:
- Length of `queue_running` array — jobs currently executing
- Length of `queue_pending` array — jobs waiting in queue

4. Present the results as a formatted status block:

```
ComfyUI Server Status
---------------------
URL:         http://...
Connection:  OK
OS:          ...
GPU:         NVIDIA RTX 5090
VRAM:        4.2 / 32.0 GB (13% used)
Queue:       0 running, 0 pending
```

Convert VRAM bytes to GB with one decimal place for readability.

5. If the server is unreachable (curl fails or times out):

```
ComfyUI Server Status
---------------------
URL:         http://...
Connection:  FAILED — server unreachable
```

Then suggest: "Check the URL in `.claude/comfyui.local.md` or verify ComfyUI is running."
