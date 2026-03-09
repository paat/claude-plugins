---
name: run
description: Queue a ComfyUI workflow for execution, monitor progress, and return results
user_invocable: true
allowed-tools: Bash, Read, Write
argument-hint: "<workflow.json path>"
---

# Run ComfyUI Workflow

## Steps

1. **Read config.** Read `.claude/comfyui.local.md` for settings:
   - `comfyui_url` — server URL (default: `http://localhost:8188`)
   - `poll_interval_ms` — polling interval in milliseconds (default: `1000`)
   - `poll_timeout_ms` — maximum wait time in milliseconds (default: `300000`)
   - `output_dir` — local directory to download outputs to (optional)

2. **Read the workflow file** from the path provided in `$ARGUMENTS`. If no path given, ask the user for the workflow file path.

3. **Validate the workflow JSON:**
   - Parse with jq to confirm valid JSON
   - Check that each top-level key (node ID) has `class_type` and `inputs` fields
   - Report any structural issues before attempting to queue

4. **Generate a prompt_id:**

```bash
python3 -c "import uuid; print(uuid.uuid4())"
```

5. **Queue the workflow:**

```bash
curl -s -X POST "${url}/prompt" \
  -H "Content-Type: application/json" \
  -d '{"prompt": <workflow_json>, "client_id": "<prompt_id>"}'
```

Capture the response. The server returns `{"prompt_id": "..."}` on success.

6. **Check for immediate errors.** If the response contains `node_errors` with non-empty entries, report each error (node ID, class_type, exception message) and abort — do not proceed to polling.

7. **Poll for completion.** Loop with the configured interval:

```bash
curl -s "${url}/history/${prompt_id}"
```

- If the response is empty `{}`, the job is still running — wait and retry
- If the response contains the prompt_id key, check `status.status_str`:
  - `"success"` — proceed to step 8
  - `"error"` — proceed to step 9
- If total elapsed time exceeds `poll_timeout_ms`, proceed to step 10

8. **On success:**
   - List all output nodes and their filenames from the `outputs` field
   - Report image dimensions if available in the metadata
   - If `output_dir` is configured, download each output file:

```bash
curl -s "${url}/view?filename=${filename}&type=output" -o "${output_dir}/${filename}"
```

   - Report downloaded file paths

9. **On error:**
   - Parse the error from `status.messages` in the history entry
   - Identify the failing node (node ID and class_type)
   - Report the exception type and message
   - Suggest potential fixes based on common error patterns

10. **On timeout:**
    - Report that the job is still running after the timeout period
    - Provide the prompt_id so the user can check manually:
      `curl -s "${url}/history/${prompt_id}"`
    - Suggest increasing `poll_timeout_ms` in `.claude/comfyui.local.md` for long-running workflows
