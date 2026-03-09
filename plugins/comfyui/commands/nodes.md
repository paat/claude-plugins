---
name: nodes
description: Search available ComfyUI node types and show their input/output schemas
user_invocable: true
allowed-tools: Bash, Read
argument-hint: "[search term] — search node names/categories, or omit to list categories"
---

# Search ComfyUI Nodes

## Steps

1. **Read config.** Read `.claude/comfyui.local.md` for `comfyui_url` (default: `http://localhost:8188`).

2. **Fetch the full node registry:**

```bash
curl -s "${url}/object_info"
```

This response can be large (1MB+). Pipe through jq for processing rather than trying to read the raw output.

3. **If `$ARGUMENTS` provides a search term**, filter nodes with jq using case-insensitive matching against the node key, `display_name`, and `category` fields:

```bash
curl -s "${url}/object_info" | jq --arg q "${search_term}" '
  to_entries
  | map(select(
      (.key | ascii_downcase | contains($q | ascii_downcase))
      or (.value.display_name // "" | ascii_downcase | contains($q | ascii_downcase))
      or (.value.category // "" | ascii_downcase | contains($q | ascii_downcase))
    ))
  | .[:20]
  | from_entries
'
```

For each matching node, display:
- **class_type** — the node key (used in workflow JSON)
- **display_name** — human-readable name
- **category** — node category path
- **Required inputs** — name and type for each required input
- **Output types** — list of output type names

Limit results to 20 nodes. If more exist, note the total count and suggest a more specific search.

4. **If no arguments provided**, extract and display unique categories with node counts:

```bash
curl -s "${url}/object_info" | jq '
  [.[].category // "uncategorized"]
  | group_by(.)
  | map({category: .[0], count: length})
  | sort_by(.category)
'
```

Present as a sorted list:

```
Node Categories
---------------
conditioning (12)
image (24)
latent (18)
loaders (8)
sampling (6)
...
Total: 156 nodes in 23 categories
```
