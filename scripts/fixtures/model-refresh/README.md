# Public feed fixtures

Probed without authentication on **2026-10-30**. These are three-row extracts
from the live responses; irrelevant OpenRouter fields and Terminal-Bench schema
metadata are omitted. Counts and pagination describe the reduced samples.
No observed row was marked preliminary; tests introduce that condition explicitly.

- `openrouter.json`: GET <https://openrouter.ai/api/v1/models>.
  Catalog metadata only; no data licence is asserted here.
- `arena-webdev.json`, `arena-agent.json`: GET
  `https://datasets-server.huggingface.co/rows?dataset=lmarena-ai/leaderboard-dataset&config=webdev&split=latest&offset=0&length=100`
  (replace `webdev` with `agent` for the second sample).
  Dataset: <https://huggingface.co/datasets/lmarena-ai/leaderboard-dataset>,
  CC-BY-4.0. The row's `license` describes the model, not the dataset.
- `terminal.json`: POST
  <https://ofhuhcpkvzjlejydnvyd.supabase.co/functions/v1/leaderboard-read>,
  JSON `{"package":"terminal-bench/terminal-bench","name":"4-0-0"}`.
  Discovered from <https://www.tbench.ai/leaderboard/terminal-bench/4.0>.
  Undocumented endpoint; data licence **UNKNOWN**.
