# ComfyUI Plugin for Claude Code

Manage ComfyUI workflows, models, and API from Claude Code — build workflows from natural language, queue executions, monitor progress, and download models.

## Prerequisites

- A running ComfyUI instance accessible via HTTP
- `curl` and `jq` available on the host
- ComfyUI Manager (optional, for model downloads and node installation)

## Installation

Add to your project's `.claude/settings.json`:

```json
{
  "plugins": ["paat-plugins/comfyui"]
}
```

Or test locally:

```bash
claude --plugin-dir /path/to/plugins/comfyui
```

## Configuration

Create `.claude/comfyui.local.md` in your project root:

```yaml
---
comfyui_url: "http://localhost:8188"
default_checkpoint: "sd_xl_base_1.0.safetensors"
output_dir: "./output"
poll_interval_ms: 1000
poll_timeout_ms: 300000
---
```

If this file doesn't exist, defaults to `http://localhost:8188`.

## Commands

| Command | Description |
|---------|-------------|
| `/comfyui:status` | Check server health, GPU stats, VRAM, queue depth |
| `/comfyui:run <file.json>` | Queue a workflow, monitor progress, return results |
| `/comfyui:models [category]` | List available models (checkpoints, loras, vae, etc.) |
| `/comfyui:nodes [search]` | Search node types or list categories |
| `/comfyui:download <url> <folder> [name]` | Download a model via Manager API or direct URL |

## Agents

- **workflow-designer** (Opus) — Designs workflows from natural language. Queries available nodes and models, constructs valid JSON.
- **workflow-tester** (Sonnet) — Validates workflow JSON, checks node availability, runs test executions, diagnoses errors.

## Skills

- **comfyui-api** — API reference for interacting with ComfyUI (REST + WebSocket)
- **comfyui-workflow-design** — Workflow JSON format, node patterns, IP-Adapter, ControlNet, video, upscaling

## Environment Agnostic

This plugin makes no assumptions about your ComfyUI deployment:
- No hardcoded paths, container names, or IPs
- All model paths discovered via API (`/models/{folder}`, `/internal/folder_paths`)
- Works with Docker, bare metal, remote, or cloud ComfyUI instances
- Configure once in `.claude/comfyui.local.md`
