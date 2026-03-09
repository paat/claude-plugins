---
name: download
description: Download a model to ComfyUI via Manager API or direct URL
user_invocable: true
allowed-tools: Bash, Read
argument-hint: "<url> <folder> [filename] — HuggingFace/CivitAI URL, target folder, optional filename"
---

# Download Model to ComfyUI

## Steps

1. **Read config.** Read `.claude/comfyui.local.md` for `comfyui_url` (default: `http://localhost:8188`).

2. **Parse `$ARGUMENTS`:**
   - First argument: the download URL (HuggingFace, CivitAI, or direct link)
   - Second argument: the target folder name (`checkpoints`, `loras`, `vae`, `controlnet`, `upscale_models`, `embeddings`, `hypernetworks`, `clip_vision`)
   - Third argument (optional): desired filename

   If fewer than 2 arguments are provided, report the required usage:
   `comfyui download <url> <folder> [filename]`

3. **Determine filename.** If no filename was provided, extract it from the URL:
   - For HuggingFace URLs: extract the filename from the path (last segment after `/resolve/`)
   - For CivitAI URLs: extract from the `?modelVersionId=` response or use the URL path
   - For direct URLs: use the last path segment
   - URL-decode the filename if needed

4. **Try ComfyUI Manager API first:**

```bash
curl -s -X POST "${url}/manager/model/download" \
  -H "Content-Type: application/json" \
  -d '{"url":"<download_url>","path":"<folder>","filename":"<filename>"}'
```

Check the HTTP status code and response body:
- **200/Success**: Report that the download has been queued. Note that large models may take time.
- **404 or connection refused on /manager/**: Manager API is not available (step 5)
- **Other error**: Report the error message from the response

5. **If Manager API is not available:**
   - Query `curl -s "${url}/internal/folder_paths"` to discover the server-side filesystem path for the target folder
   - Report that ComfyUI Manager is not installed
   - Provide the resolved filesystem path so the user can download manually:

```
ComfyUI Manager is not installed. To download manually:
  Target directory: /path/to/ComfyUI/models/<folder>/
  wget -O "/path/to/ComfyUI/models/<folder>/<filename>" "<download_url>"

To install ComfyUI Manager: https://github.com/ltdrdata/ComfyUI-Manager
```

6. **Report result:**
   - On success: "Queued download of `<filename>` to `<folder>/`"
   - On failure: clear error message with the specific issue and suggested resolution
