# analyst-companion v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **STATUS (2026-06-03):** Implemented; verified end-to-end **Steps 1–4 on RTX 5090** (cuda True,
> `large-v3` on sm_120, Sortformer loaded, relay+persistence proven). Three pre-flight
> assumptions were corrected at bring-up — all reflected below: **(1)** diarization extra is
> `diarization-sortformer` + NeMo from git `main`; **(2)** pin **CUDA-12.8 torch** (cu128) for
> Blackwell + `libcublas.so.12`; **(3)** the flag is `--lan`, not `--language`. Also: WLK frame
> timestamps are strings (`parseWlk` fixed), and the Caddy front uses a `remote_ip` gate, not
> `bind`. Authoritative code lives in the committed `aimeet` repo. **Live two-speaker mic
> rehearsal (Step 5) + Plane close (Step 6) remain** — they need a person at the laptop.

**Goal:** Upgrade the in-person meeting analyst from batch transcription to **live streaming transcription with speaker-attributed dialog**, by introducing a WhisperLiveKit (WLK) container and reworking the `aimeet` service to relay mic audio to WLK and persist finalized speaker-tagged lines — the plugin loop and Plane output are unchanged.

**Architecture:** A new internal-only **`wlk`** container runs WhisperLiveKit (`faster-whisper large-v3`, Estonian, Streaming Sortformer diarization) exposing a WebSocket `/asr`. The **`aimeet`** service gains a transparent WebSocket relay (`/sessions/{id}/stream` → `wlk:/asr`) so WLK stays off the tailnet, plus a deterministic `POST /line` endpoint where the browser posts each finalized `{seconds, speaker, text}` (persist + wake-word detect). The browser captures s16le PCM via an AudioWorklet, streams it through the relay, renders WLK's speaker dialog live, and posts finalized lines. The transcript-file seam (Claude polls `transcript.md` deltas) is unchanged; lines now carry a `Speaker N:` prefix.

**Tech Stack:** Python 3.11 / FastAPI / uvicorn / `websockets`, pytest, Docker Compose (GPU), Caddy, browser AudioWorklet + WebSocket, WhisperLiveKit (`whisperlivekit` pip pkg), Plane REST API, claude-in-chrome MCP, the `loop` skill.

**Prerequisite state:** v1 is implemented and committed in two repos:
- `/mnt/data/ai/aimeet/` (standalone git repo) — current files: `app/main.py`, `app/sessions.py`, `app/stt.py`, `app/wake.py`, `app/static/record.html`, `tests/test_wake.py`, `tests/test_sessions.py`, `tests/test_chunk.py`, `requirements.txt`, `Dockerfile`, `docker-compose.yml`, `Caddyfile.snippet`, `README.md`.
- `plugins/analyst-companion/` (in the claude-plugins repo, branch `feat/analyst-companion`).

---

## File Structure

### `wlk` container (NEW) — in the `/mnt/data/ai/aimeet/` repo
- `wlk/Dockerfile` — installs WhisperLiveKit (+ diarization extra)

### `aimeet` service — `/mnt/data/ai/aimeet/` (host path; NOT in the plugins repo)
- **Modify** `app/sessions.py` — speaker-aware `append_transcript`; `read_speakers` / `set_speaker_name`; `feed` returns `speakers`
- **Modify** `app/main.py` — remove `stt` import + `/chunk`; add `POST /line`, `POST /speaker`, `WS /sessions/{id}/stream` relay
- **Delete** `app/stt.py`
- **Rewrite** `tests/test_chunk.py` → `tests/test_routes.py` (line/speaker/feed/end flow; drop the stt test)
- **Modify** `tests/test_sessions.py` — add speaker + speakers-map cases
- **Replace** `app/static/record.html` — AudioWorklet PCM → WS relay → WLK; speaker dialog + rename; POST `/line`
- **Modify** `requirements.txt` — add `websockets`
- **Modify** `docker-compose.yml` — add `wlk` service; add `WLK_WS_URL` to aimeet; drop `STT_*` envs
- **Modify** `README.md` — v2 architecture

### plugin — `plugins/analyst-companion/` (claude-plugins repo)
- **Modify** `skills/meeting-companion/SKILL.md` — speaker-prefixed transcript lines
- **Modify** `commands/meeting-end.md` — speaker-attributed synthesis
- **Modify** `README.md` — real-time + diarization; updated Limits
- **Modify** `.claude-plugin/plugin.json` — version 0.1.0 → 0.2.0
- **Modify** `.claude-plugin/marketplace.json` — version 0.1.0 → 0.2.0 (keep in sync)

### Responsibility split (unchanged principle)
- **Browser** does the WLK-specific work: PCM capture, parsing WLK's result schema, rendering, posting finalized lines.
- **aimeet Python** does deterministic, testable work: relay bytes, persist a line, detect wake words, store speaker names, serve the feed.
- **Plugin loop** does the intelligent work: handle commands, synthesize questions/work-items.

---

## Phase E — WhisperLiveKit container

### Task E1: `wlk` container (manual verification — GPU + model download)

**Files:**
- Create: `/mnt/data/ai/aimeet/wlk/Dockerfile`

- [ ] **Step 1: Create `wlk/Dockerfile`**

```dockerfile
# WhisperLiveKit — simultaneous streaming STT + Sortformer diarization. GPU image.
# VERIFIED essentials below (RTX 5090 / Blackwell sm_120, whisperlivekit 0.2.21). The
# committed aimeet `wlk/Dockerfile` is authoritative; the pre-flight version in this plan
# was wrong on THREE points, all corrected here:
#   1. CUDA — default PyPI torch is now a CUDA-13 build, but ctranslate2 needs
#      libcublas.so.12 → pin CUDA-12.8 torch (cu128 also supports Blackwell sm_120).
#   2. Diarization extra is `diarization-sortformer` (NOT `diarization`, which doesn't exist).
#   3. Streaming Sortformer is unreleased → install nemo_toolkit[asr] from git main.
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg git \
    && rm -rf /var/lib/apt/lists/*

# CUDA-12.8 torch FIRST (Blackwell sm_120 + libcublas.so.12 for ctranslate2).
RUN pip install --no-cache-dir torch==2.8.0 --index-url https://download.pytorch.org/whl/cu128

# Streaming Sortformer from NeMo git main, then whisperlivekit with the sortformer extra.
RUN pip install --no-cache-dir "nemo_toolkit[asr] @ git+https://github.com/NVIDIA/NeMo.git@main" \
 && pip install --no-cache-dir "whisperlivekit[diarization-sortformer]"

# Build-time assertion: catch a CUDA-13 torch regression before runtime.
RUN python -c "import ctypes; ctypes.CDLL('libcublas.so.12')"

EXPOSE 8000
# Flags are provided by docker-compose `command:` so they can be tuned without rebuild.
ENTRYPOINT ["wlk"]
```

- [ ] **Step 2: Build the image**

Run: `cd /mnt/data/ai/aimeet && docker build -t wlk:local -f wlk/Dockerfile wlk`
Expected: image builds (slow — cu128 torch wheels are large and NeMo builds from git). The
extra/entrypoint were resolved during bring-up: extra `diarization-sortformer`, console
script `wlk`, flags route to `serve`. Confirm with `docker run --rm wlk:local --help`.

- [ ] **Step 3: Smoke-test the server starts on GPU and serves `/asr`** (verified fully in compose at Task F6; here just confirm the binary runs)

Run:
```bash
docker run --rm --gpus all wlk:local \
  --backend faster-whisper --model large-v3-turbo --lan et --diarization \
  --diarization-backend sortformer --pcm-input --host 0.0.0.0 --port 8000 &
sleep 30   # first run downloads weights
docker ps --filter ancestor=wlk:local
# confirm GPU (must print True), not silent CPU fallback:
docker exec "$(docker ps -q --filter ancestor=wlk:local)" python -c "import torch; print(torch.cuda.is_available())"
```
Expected: container stays up (downloads `large-v3`/Sortformer weights on first run; use a
named volume in compose to cache them — see F6). Stop it afterwards.

- [ ] **Step 4: Commit**

```bash
cd /mnt/data/ai/aimeet && git add wlk/Dockerfile && git commit -q -m "feat(wlk): WhisperLiveKit GPU container (faster-whisper + Sortformer diarization)"
```

---

## Phase F — aimeet service rework

### Task F1: Speaker-aware session store (TDD)

**Files:**
- Modify: `/mnt/data/ai/aimeet/app/sessions.py`
- Modify: `/mnt/data/ai/aimeet/tests/test_sessions.py`

- [ ] **Step 1: Add failing tests** — append to `tests/test_sessions.py`

```python
def test_append_transcript_with_speaker(tmp_path):
    sid = sessions.create_session(tmp_path)
    sessions.append_transcript(tmp_path, sid, 25, "tere klient", speaker="Speaker 1")
    body = (tmp_path / sid / "transcript.md").read_text(encoding="utf-8")
    assert "[00:25] Speaker 1: tere klient" in body


def test_append_transcript_without_speaker_is_backwards_compatible(tmp_path):
    sid = sessions.create_session(tmp_path)
    sessions.append_transcript(tmp_path, sid, 5, "tere")
    body = (tmp_path / sid / "transcript.md").read_text(encoding="utf-8")
    assert "[00:05] tere\n" in body
    assert ":" not in body.split("] ", 1)[1].split("\n", 1)[0]  # no "speaker:" prefix


def test_set_and_read_speaker_name(tmp_path):
    sid = sessions.create_session(tmp_path)
    assert sessions.read_speakers(tmp_path, sid) == {}
    sessions.set_speaker_name(tmp_path, sid, "Speaker 1", "Mari")
    sessions.set_speaker_name(tmp_path, sid, "Speaker 2", "Jüri")
    assert sessions.read_speakers(tmp_path, sid) == {"Speaker 1": "Mari", "Speaker 2": "Jüri"}


def test_feed_includes_speakers(tmp_path):
    sid = sessions.create_session(tmp_path)
    sessions.set_speaker_name(tmp_path, sid, "Speaker 1", "Mari")
    assert sessions.feed(tmp_path, sid)["speakers"] == {"Speaker 1": "Mari"}
```

- [ ] **Step 2: Run, expect failure**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_sessions.py -v`
Expected: FAIL — `append_transcript()` got an unexpected keyword `speaker` / `read_speakers` not defined / `feed` has no `speakers` key.

- [ ] **Step 3: Edit `app/sessions.py`**

Replace `append_transcript` with the speaker-aware version:

```python
def append_transcript(root: Path, sid: str, seconds: int, text: str,
                      speaker: str | None = None) -> None:
    stamp = f"[{seconds // 60:02d}:{seconds % 60:02d}]"
    body = f"{speaker}: {text.strip()}" if speaker else text.strip()
    with (_dir(root, sid) / "transcript.md").open("a", encoding="utf-8") as fh:
        fh.write(f"{stamp} {body}\n")
```

Add, after `_read_json`:

```python
def read_speakers(root: Path, sid: str) -> dict:
    """Display-name overrides for diarization labels (raw 'Speaker N' -> name)."""
    return _read_json(_dir(root, sid) / "speakers.json", {})


def set_speaker_name(root: Path, sid: str, speaker_id: str, name: str) -> None:
    d = _dir(root, sid)
    mapping = _read_json(d / "speakers.json", {})
    mapping[speaker_id] = name
    (d / "speakers.json").write_text(json.dumps(mapping, ensure_ascii=False), encoding="utf-8")
```

Add `"speakers"` to the `feed` dict:

```python
def feed(root: Path, sid: str) -> dict:
    d = _dir(root, sid)
    return {
        "questions": _read_json(d / "questions.json", []),
        "responses": _read_json(d / "responses.json", []),
        "speakers": _read_json(d / "speakers.json", {}),
        "ended": (d / "ended").exists(),
    }
```

Update the module docstring layout block to add `speakers.json   diarization display-name map (rename endpoint writes)`.

- [ ] **Step 4: Run, expect pass**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_sessions.py -v`
Expected: PASS (all existing + 4 new).

- [ ] **Step 5: Commit**

```bash
cd /mnt/data/ai/aimeet && git add app/sessions.py tests/test_sessions.py && git commit -q -m "feat(aimeet): speaker-aware transcript + speakers map in session store"
```

---

### Task F2: Routes — `/line`, `/speaker`, WS relay; drop `/chunk` + stt (TDD for the deterministic routes)

**Files:**
- Modify: `/mnt/data/ai/aimeet/app/main.py`
- Delete: `/mnt/data/ai/aimeet/app/stt.py`
- Replace: `/mnt/data/ai/aimeet/tests/test_chunk.py` → `/mnt/data/ai/aimeet/tests/test_routes.py`
- Modify: `/mnt/data/ai/aimeet/requirements.txt`

- [ ] **Step 1: Add `websockets` to `requirements.txt`** (append)

```
websockets==12.0
```

- [ ] **Step 2: Replace the test file** — delete `tests/test_chunk.py`, create `tests/test_routes.py`

```python
import json
from fastapi.testclient import TestClient


def _client(tmp_path, monkeypatch):
    monkeypatch.setenv("SESSION_ROOT", str(tmp_path))
    monkeypatch.setenv("WAKE_WORDS", "claude,klaud,kloud,klod,klood")
    import importlib
    from app import main
    importlib.reload(main)
    return TestClient(main.app), main


def test_line_persists_and_detects_command(tmp_path, monkeypatch):
    client, _ = _client(tmp_path, monkeypatch)
    sid = client.post("/sessions").json()["id"]

    # plain talk with a speaker -> transcript only
    r1 = client.post(f"/sessions/{sid}/line",
                     json={"seconds": 10, "speaker": "Speaker 1", "text": "soovime eksporti"})
    assert r1.json()["ok"] is True

    # addressed to Claude -> transcript + command queue
    client.post(f"/sessions/{sid}/line",
                json={"seconds": 20, "speaker": "Speaker 2", "text": "Claude, kas sa näed akent"})

    transcript = (tmp_path / sid / "transcript.md").read_text(encoding="utf-8")
    assert "[00:10] Speaker 1: soovime eksporti" in transcript
    assert "[00:20] Speaker 2: Claude, kas sa näed akent" in transcript

    cmds = (tmp_path / sid / "commands.jsonl").read_text(encoding="utf-8").strip().splitlines()
    assert len(cmds) == 1
    assert json.loads(cmds[0])["command"] == "kas sa näed akent"


def test_line_without_speaker_still_works(tmp_path, monkeypatch):
    client, _ = _client(tmp_path, monkeypatch)
    sid = client.post("/sessions").json()["id"]
    client.post(f"/sessions/{sid}/line", json={"seconds": 3, "text": "tere"})
    assert "[00:03] tere\n" in (tmp_path / sid / "transcript.md").read_text(encoding="utf-8")


def test_line_unknown_session_404(tmp_path, monkeypatch):
    client, _ = _client(tmp_path, monkeypatch)
    r = client.post("/sessions/nope/line", json={"seconds": 1, "text": "x"})
    assert r.status_code == 404


def test_rename_speaker_shows_in_feed(tmp_path, monkeypatch):
    client, _ = _client(tmp_path, monkeypatch)
    sid = client.post("/sessions").json()["id"]
    client.post(f"/sessions/{sid}/speaker", json={"speaker": "Speaker 1", "name": "Mari"})
    assert client.get(f"/sessions/{sid}/feed").json()["speakers"] == {"Speaker 1": "Mari"}


def test_feed_and_end(tmp_path, monkeypatch):
    client, _ = _client(tmp_path, monkeypatch)
    sid = client.post("/sessions").json()["id"]
    (tmp_path / sid / "questions.json").write_text(json.dumps(["Mis on eesmärk?"]))
    assert client.get(f"/sessions/{sid}/feed").json()["questions"] == ["Mis on eesmärk?"]
    client.post(f"/sessions/{sid}/end")
    assert client.get(f"/sessions/{sid}/feed").json()["ended"] is True
```

- [ ] **Step 3: Run, expect failure**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_routes.py -v`
Expected: FAIL — `/line` route 404/422 (not implemented) or import error.

- [ ] **Step 4: Delete `app/stt.py`**

```bash
rm /mnt/data/ai/aimeet/app/stt.py
```

- [ ] **Step 5: Rewrite `app/main.py`**

```python
"""meeting-capture: record-page host + live relay to WhisperLiveKit + transcript feed.

The browser streams s16le PCM over WS /sessions/{id}/stream; we relay it verbatim to
WhisperLiveKit (wlk:/asr) and relay results back — we never parse WLK's JSON. The browser
posts each finalized speaker-tagged line to /line, where transcript persistence + wake-word
detection happen (deterministic + testable).
"""
import asyncio
import os
from pathlib import Path

import websockets
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel

from app import sessions, wake

SESSION_ROOT = Path(os.environ.get("SESSION_ROOT", "/data/sessions"))
WAKE_WORDS = [w.strip() for w in os.environ.get("WAKE_WORDS", "claude").split(",") if w.strip()]
WLK_WS_URL = os.environ.get("WLK_WS_URL", "ws://wlk:8000/asr")

_RECORD_HTML = (Path(__file__).parent / "static" / "record.html").read_text(encoding="utf-8")

app = FastAPI(title="meeting-capture")
SESSION_ROOT.mkdir(parents=True, exist_ok=True)


class Line(BaseModel):
    seconds: int
    text: str
    speaker: str | None = None


class SpeakerName(BaseModel):
    speaker: str
    name: str


@app.post("/sessions")
def create():
    return {"id": sessions.create_session(SESSION_ROOT)}


@app.get("/r/{sid}", response_class=HTMLResponse)
def record_page(sid: str):
    if not sessions.session_exists(SESSION_ROOT, sid):
        raise HTTPException(404, "unknown session")
    return _RECORD_HTML.replace("__SESSION_ID__", sid)


@app.post("/sessions/{sid}/line")
def add_line(sid: str, line: Line):
    if not sessions.session_exists(SESSION_ROOT, sid):
        raise HTTPException(404, "unknown session")
    text = (line.text or "").strip()
    if text:
        sessions.append_transcript(SESSION_ROOT, sid, line.seconds, text, speaker=line.speaker)
        cmd = wake.find_command(text, WAKE_WORDS)
        if cmd:
            sessions.enqueue_command(SESSION_ROOT, sid, line.seconds, cmd)
    return {"ok": True}


@app.post("/sessions/{sid}/speaker")
def rename_speaker(sid: str, body: SpeakerName):
    if not sessions.session_exists(SESSION_ROOT, sid):
        raise HTTPException(404, "unknown session")
    sessions.set_speaker_name(SESSION_ROOT, sid, body.speaker, body.name)
    return {"ok": True}


@app.get("/sessions/{sid}/feed")
def get_feed(sid: str):
    try:
        return JSONResponse(sessions.feed(SESSION_ROOT, sid))
    except FileNotFoundError:
        raise HTTPException(404, "unknown session")


@app.post("/sessions/{sid}/end")
def end(sid: str):
    try:
        sessions.end_session(SESSION_ROOT, sid)
    except FileNotFoundError:
        raise HTTPException(404, "unknown session")
    return {"ended": True}


@app.websocket("/sessions/{sid}/stream")
async def stream(ws: WebSocket, sid: str):
    """Transparent bidirectional relay between the browser and WhisperLiveKit.
    Keeps WLK internal-only and the aimeet origin the single exposed surface."""
    if not sessions.session_exists(SESSION_ROOT, sid):
        await ws.close(code=4404)
        return
    await ws.accept()
    try:
        async with websockets.connect(WLK_WS_URL, max_size=None, ping_interval=None) as up:
            async def client_to_wlk():
                try:
                    while True:
                        await up.send(await ws.receive_bytes())
                except WebSocketDisconnect:
                    pass

            async def wlk_to_client():
                try:
                    async for msg in up:
                        if isinstance(msg, bytes):
                            await ws.send_bytes(msg)
                        else:
                            await ws.send_text(msg)
                except Exception:
                    pass

            await asyncio.gather(client_to_wlk(), wlk_to_client())
    except Exception:
        pass
    finally:
        try:
            await ws.close()
        except Exception:
            pass
```

- [ ] **Step 6: Run the deterministic route tests, expect pass**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_routes.py tests/test_sessions.py tests/test_wake.py -v`
Expected: PASS (all). The WS relay is verified manually in Step 7 (not unit-tested — it depends on a live upstream).

- [ ] **Step 7: Manually verify the WS relay against a local echo upstream**

```bash
cd /mnt/data/ai/aimeet
# 1) minimal echo "WLK": echoes text frames back
python - <<'PY' &
import asyncio, websockets
async def echo(ws):
    async for m in ws:
        await ws.send("ECHO:" + (m if isinstance(m, str) else m.decode("latin1")))
async def main():
    async with websockets.serve(echo, "127.0.0.1", 8799):
        await asyncio.Future()
asyncio.run(main())
PY
ECHO_PID=$!
# 2) aimeet pointing the relay at the echo server
SESSION_ROOT=/tmp/aimeet-ws WAKE_WORDS=claude WLK_WS_URL=ws://127.0.0.1:8799 \
  python -m uvicorn app.main:app --host 127.0.0.1 --port 4322 &
APP_PID=$!
sleep 2
SID=$(curl -s -XPOST http://127.0.0.1:4322/sessions | python -c "import sys,json;print(json.load(sys.stdin)['id'])")
# 3) connect through the relay, send bytes, expect the echo back
python - "$SID" <<'PY'
import asyncio, sys, websockets
async def main():
    sid = sys.argv[1]
    async with websockets.connect(f"ws://127.0.0.1:4322/sessions/{sid}/stream") as ws:
        await ws.send(b"hello")
        print("RELAY OK:", await asyncio.wait_for(ws.recv(), 5))
asyncio.run(main())
PY
kill $APP_PID $ECHO_PID 2>/dev/null
```
Expected: `RELAY OK: ECHO:hello`.

- [ ] **Step 8: Commit**

```bash
cd /mnt/data/ai/aimeet && git rm -q app/stt.py tests/test_chunk.py && git add -A && git commit -q -m "feat(aimeet): /line + /speaker routes and WS relay to WhisperLiveKit; drop /chunk + stt.py"
```

---

### Task F3: Record page — AudioWorklet PCM → relay → WLK; speaker dialog + rename (manual verification — browser artifact)

**Files:**
- Replace: `/mnt/data/ai/aimeet/app/static/record.html`

> **Note on WLK's result schema — VERIFIED, parser since fixed.** The HTML below is the
> **pre-flight draft**; the committed `aimeet/app/static/record.html` is authoritative and
> contains the fix. Real WLK frames (confirmed on RTX 5090, whisperlivekit 0.2.21): segments
> carry `text`, an **int `speaker`** where **`-2` = silence** (skip it), and **timestamps as
> strings** like `"0:00:00.58"` (`H:MM:SS.ss`) — NOT numbers; plus a partial/buffer field and
> a `{"type":"ready_to_stop"}` marker. The draft `parseWlk()` did `Math.round(start)` on the
> string → `NaN` → `/line` 422 → empty transcript. **Fix:** a `toSeconds()` helper parses the
> `"H:MM:SS.ss"` string, and the loop skips `speaker === -2`. The extracted parser was re-run
> against a real captured frame → PASS. `parseWlk()` remains the ONLY schema-coupled spot.

- [ ] **Step 1: Overwrite `app/static/record.html`**

```html
<!doctype html>
<html lang="et">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>aimeet — koosolek</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font:15px/1.5 system-ui,sans-serif; background:#0e1116; color:#e6edf3; }
  header { display:flex; align-items:center; gap:12px; padding:10px 16px; background:#161b22; border-bottom:1px solid #30363d; }
  header h1 { font-size:14px; margin:0; font-weight:600; letter-spacing:.04em; color:#8b949e; }
  #rec { padding:6px 14px; border:0; border-radius:6px; font-weight:600; cursor:pointer; background:#238636; color:#fff; }
  #rec.on { background:#da3633; }
  #dot { width:10px; height:10px; border-radius:50%; background:#484f58; }
  #dot.on { background:#da3633; animation:pulse 1.2s infinite; }
  @keyframes pulse { 50% { opacity:.3 } }
  main { display:grid; grid-template-columns:1fr 1fr; grid-template-rows:1fr auto; gap:1px; height:calc(100vh - 53px); background:#30363d; }
  section { background:#0e1116; padding:12px 16px; overflow:auto; }
  section h2 { font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:#8b949e; margin:0 0 8px; }
  #chat { grid-column:1 / 3; max-height:34vh; }
  .turn { margin:8px 0; }
  .spk { font-weight:600; cursor:pointer; margin-right:6px; }
  .spk:hover { text-decoration:underline dotted; }
  .s0{color:#58a6ff} .s1{color:#3fb950} .s2{color:#d29922} .s3{color:#bc8cff} .s4{color:#f778ba} .s5{color:#56d4dd}
  .t { color:#6e7681; margin-right:6px; font-size:12px; }
  .partial { opacity:.55; font-style:italic; }
  .q { margin:4px 0; padding:6px 10px; background:#161b22; border-left:3px solid #d29922; border-radius:4px; }
  .you { color:#58a6ff; } .claude { color:#3fb950; }
  .msg { margin:6px 0; padding:6px 10px; background:#161b22; border-radius:6px; }
  .err { color:#f85149; font-size:13px; }
</style>
</head>
<body>
<header>
  <span id="dot"></span>
  <h1>aimeet · session __SESSION_ID__</h1>
  <button id="rec">● Salvesta</button>
  <span id="status" class="err"></span>
</header>
<main>
  <section id="tcol"><h2>Transkriptsioon (dialoog)</h2><div id="dialog"></div><div id="partial" class="partial"></div></section>
  <section id="qcol"><h2>❓ Avatud küsimused</h2><div id="questions"></div></section>
  <section id="chat"><h2>🗣 Sina ↔ Claude</h2><div id="responses"></div></section>
</main>
<script>
const SID = "__SESSION_ID__";
const $ = id => document.getElementById(id);
let media, audioCtx, node, ws, t0, running = false;
let speakerNames = {};               // raw "Speaker N" -> display name (from /feed)
let posted = new Set();              // finalized segment keys already POSTed

function status(m){ $("status").textContent = m || ""; }
function fmt(s){ return String(Math.floor(s/60)).padStart(2,"0")+":"+String(s%60).padStart(2,"0"); }
function esc(x){ return (x||"").replace(/[&<>]/g, c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c])); }
function spkClass(id){ const n = parseInt(String(id).replace(/\D/g,""))||0; return "s"+(n%6); }
function spkLabel(id){ return speakerNames[id] || id || "Kõneleja"; }

// ---- WLK result parsing (the ONLY WLK-schema-specific code) -------------------
// Returns { finals: [{seconds, speaker, text, key}], partial: "<live text>" }.
// Tune field names here against WLK's actual messages if they differ.
function parseWlk(data){
  let m; try { m = JSON.parse(data); } catch(e){ return {finals:[], partial:""}; }
  if(m.type === "ready_to_stop") return {finals:[], partial:"", done:true};
  const finals = [];
  const segs = m.lines || m.segments || m.transcript || [];
  for(const s of segs){
    const text = (s.text || s.transcript || "").trim();
    if(!text) continue;
    const speaker = s.speaker != null ? ("Speaker " + String(s.speaker).replace(/^Speaker\s*/i,"")) : null;
    const seconds = Math.round(s.start || s.begin || s.t0 || 0);
    finals.push({seconds, speaker, text, key: `${seconds}|${speaker}|${text}`});
  }
  const partial = (m.buffer_transcription || m.buffer || m.partial || "").trim();
  return {finals, partial};
}
// -------------------------------------------------------------------------------

function renderDialog(finals){
  for(const f of finals){
    if(posted.has(f.key)) continue;
    posted.add(f.key);
    const d = document.createElement("div"); d.className = "turn";
    const sid = f.speaker || "Speaker 0";
    d.innerHTML = `<span class="t">[${fmt(f.seconds)}]</span>`
      + `<span class="spk ${spkClass(sid)}" data-spk="${esc(sid)}">${esc(spkLabel(sid))}</span>`
      + esc(f.text);
    $("dialog").appendChild(d);
    $("tcol").scrollTop = 1e9;
    postLine(f);
  }
}

async function postLine(f){
  try{
    await fetch(`/sessions/${SID}/line`, {
      method:"POST", headers:{"Content-Type":"application/json"},
      body: JSON.stringify({seconds:f.seconds, speaker:f.speaker, text:f.text})
    });
  }catch(e){ status("Salvestus hilineb…"); }
}

// inline rename: click a speaker label
$("dialog").addEventListener("click", async e=>{
  const el = e.target.closest(".spk"); if(!el) return;
  const raw = el.getAttribute("data-spk");
  const name = prompt(`Nimeta kõneleja (${raw}):`, speakerNames[raw] || "");
  if(name == null) return;
  speakerNames[raw] = name.trim() || raw;
  await fetch(`/sessions/${SID}/speaker`, {
    method:"POST", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({speaker:raw, name:speakerNames[raw]})
  });
  document.querySelectorAll(`.spk[data-spk="${CSS.escape(raw)}"]`).forEach(n=> n.textContent = spkLabel(raw));
});

async function start(){
  try { media = await navigator.mediaDevices.getUserMedia({audio:{channelCount:1, echoCancellation:true, noiseSuppression:true}}); }
  catch(e){ status("Mikrofoni luba puudub"); return; }
  running = true; t0 = Date.now();
  $("rec").classList.add("on"); $("dot").classList.add("on"); $("rec").textContent="■ Lõpeta";

  // 16 kHz mono context so the worklet emits exactly what WLK --pcm-input wants.
  audioCtx = new AudioContext({sampleRate:16000});
  await audioCtx.audioWorklet.addModule(URL.createObjectURL(new Blob([WORKLET], {type:"application/javascript"})));
  const src = audioCtx.createMediaStreamSource(media);
  node = new AudioWorkletNode(audioCtx, "pcm16");
  node.port.onmessage = e => { if(running && ws && ws.readyState === 1) ws.send(e.data); };  // ArrayBuffer of s16le
  src.connect(node);

  openSocket();
}

function openSocket(){
  const proto = location.protocol === "https:" ? "wss" : "ws";
  ws = new WebSocket(`${proto}://${location.host}/sessions/${SID}/stream`);
  ws.binaryType = "arraybuffer";
  ws.onmessage = ev => {
    const {finals, partial} = parseWlk(typeof ev.data === "string" ? ev.data : "");
    if(finals && finals.length) renderDialog(finals);
    $("partial").textContent = partial || "";
  };
  ws.onclose = () => { if(running){ status("Ühendus katkes — taasühendan…"); setTimeout(()=>{ if(running) openSocket(); }, 1500); } };
  ws.onerror = () => status("Transkriptsiooni ühenduse viga");
  ws.onopen = () => status("");
}

// AudioWorklet: Float32 -> s16le PCM, posted as ArrayBuffers (~at render-quantum rate).
const WORKLET = `
class PCM16 extends AudioWorkletProcessor {
  process(inputs){
    const ch = inputs[0][0];
    if(ch){
      const buf = new ArrayBuffer(ch.length*2);
      const view = new DataView(buf);
      for(let i=0;i<ch.length;i++){
        let s = Math.max(-1, Math.min(1, ch[i]));
        view.setInt16(i*2, s < 0 ? s*0x8000 : s*0x7FFF, true);
      }
      this.port.postMessage(buf, [buf]);
    }
    return true;
  }
}
registerProcessor("pcm16", PCM16);
`;

let renderedR = 0;
async function pollFeed(){
  try{
    const f = await (await fetch(`/sessions/${SID}/feed`)).json();
    if(f.speakers){
      let changed = false;
      for(const k in f.speakers){ if(speakerNames[k] !== f.speakers[k]){ speakerNames[k] = f.speakers[k]; changed = true; } }
      if(changed) document.querySelectorAll(".spk").forEach(n=> n.textContent = spkLabel(n.getAttribute("data-spk")));
    }
    $("questions").innerHTML = (f.questions||[]).map(q=>`<div class="q">${esc(q)}</div>`).join("") || "<div class='t'>…</div>";
    const r = f.responses||[];
    for(let i=renderedR;i<r.length;i++){
      const m = document.createElement("div"); m.className="msg";
      m.innerHTML = `<div class="you">Sina: ${esc(r[i].you||"")}</div><div class="claude">Claude: ${esc(r[i].claude||"")}</div>`;
      $("responses").appendChild(m);
    }
    if(r.length>renderedR){ renderedR=r.length; $("chat").scrollTop=1e9; }
    if(f.ended && running){ stopRecording(); status("Koosolek lõpetatud"); }
  }catch(e){}
}
setInterval(pollFeed, 2000); pollFeed();

function stopRecording(){
  running = false;
  $("rec").classList.remove("on"); $("dot").classList.remove("on"); $("rec").textContent="● Salvesta";
  $("partial").textContent = "";
  try { if(ws && ws.readyState === 1) ws.close(); } catch(e){}
  try { if(node) node.disconnect(); } catch(e){}
  if(media){ media.getTracks().forEach(t => t.stop()); }
  if(audioCtx){ audioCtx.close(); audioCtx = null; }
}

$("rec").onclick = ()=>{ running ? stopRecording() : start(); };
window.addEventListener("beforeunload", ()=>{ if(running) stopRecording(); });
</script>
</body>
</html>
```

- [ ] **Step 2: Verify the page serves and renders (no WLK needed for static render)**

```bash
cd /mnt/data/ai/aimeet && SESSION_ROOT=/tmp/aimeet-dev WAKE_WORDS=claude \
  python -m uvicorn app.main:app --host 0.0.0.0 --port 4321 &
sleep 2
SID=$(curl -s -XPOST http://localhost:4321/sessions | python -c "import sys,json;print(json.load(sys.stdin)['id'])")
echo "open http://aibox:4321/r/$SID"
```
Open the URL. Expected: dark layout with **Transkriptsioon (dialoog)** + question/chat
panels; clicking **● Salvesta** prompts for mic and the dot pulses (the WS will retry
until WLK is wired up in F6 — that's fine here). Stop the dev server: `kill %1`.

- [ ] **Step 3: Commit**

```bash
cd /mnt/data/ai/aimeet && git add app/static/record.html && git commit -q -m "feat(aimeet): live record page — AudioWorklet PCM stream + speaker dialog + rename"
```

---

### Task F4: Compose — add `wlk`, wire the relay, drop STT envs (manual verification)

**Files:**
- Modify: `/mnt/data/ai/aimeet/docker-compose.yml`

- [ ] **Step 1: Replace `docker-compose.yml`**

```yaml
# meeting-capture (aimeet) + WhisperLiveKit (wlk).
# Browser → aimeet (WS relay) → wlk:/asr (streaming STT + Sortformer diarization).
# Both internal to est-datalake-net; only aimeet is fronted by Caddy (Tailscale-only,
# see Caddyfile.snippet). WLK has no front of its own.
services:
  wlk:
    build:
      context: ./wlk
    container_name: wlk
    restart: unless-stopped
    command: >
      --backend faster-whisper --model large-v3 --lan et
      --diarization --diarization-backend sortformer --pcm-input --host 0.0.0.0 --port 8000
    # Verified flags (0.2.21): it's --lan (not --language); --diarization-backend sortformer
    # is explicit. If VRAM is tight alongside other GPU services, switch --model to large-v3-turbo.
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    volumes:
      - wlk-models:/root/.cache   # cache downloaded weights across restarts
    expose:
      - "8000"
    networks:
      - est-datalake-net

  aimeet:
    build: .
    container_name: aimeet
    restart: unless-stopped
    depends_on:
      - wlk
    environment:
      - SESSION_ROOT=/data/sessions
      - WLK_WS_URL=ws://wlk:8000/asr
      - WAKE_WORDS=claude,klaud,kloud,klod,klood
    volumes:
      - /mnt/data/ai/analyst-companion/sessions:/data/sessions
    expose:
      - "8000"
    networks:
      - est-datalake-net

volumes:
  wlk-models:

networks:
  est-datalake-net:
    external: true
```

- [ ] **Step 2: Build + bring up the stack**

```bash
cd /mnt/data/ai/aimeet && docker compose up -d --build
docker compose logs -f wlk   # watch first-run weight download; wait for "listening"/ready
```
Expected: both containers `Up`; `wlk` logs show the model + diarization pipeline loaded.

- [ ] **Step 3: Confirm aimeet serves and the relay reaches WLK**

```bash
SID=$(docker run --rm --network est-datalake-net curlimages/curl:latest -s -XPOST http://aimeet:8000/sessions | python -c "import sys,json;print(json.load(sys.stdin)['id'])")
docker run --rm --network est-datalake-net curlimages/curl:latest -s "http://aimeet:8000/r/$SID" | grep -q "dialoog" && echo "PAGE OK"
```
Expected: `PAGE OK`. Then add/keep the Caddy snippet, reload Caddy, open
`https://aimeet.r-53.com/r/$SID` over Tailscale, record a few Estonian sentences with two
voices, and confirm the dialog panel shows live partial text and settles into
speaker-labeled turns; rename a speaker and confirm it sticks. Use `read_console_messages`
to confirm WLK message field names match `parseWlk()`; adjust that function only if needed.

- [ ] **Step 4: Commit**

```bash
cd /mnt/data/ai/aimeet && git add docker-compose.yml && git commit -q -m "feat(aimeet): compose adds wlk GPU service + WS relay wiring; drop stt-api envs"
```

---

### Task F5: aimeet README — v2 architecture

**Files:**
- Modify: `/mnt/data/ai/aimeet/README.md`

- [ ] **Step 1: Replace `README.md`**

```markdown
# aimeet — meeting-capture service (v2)

Live, speaker-attributed meeting transcription for the `analyst-companion` plugin.

The browser captures the room mic as s16le PCM (AudioWorklet) and streams it over a
WebSocket to this service, which **relays** it to **WhisperLiveKit** (`wlk`) for
simultaneous streaming transcription + speaker diarization. The browser renders the
speaker dialog live and POSTs each finalized line back to `/line`, where it is appended to
a per-session `transcript.md` (`[mm:ss] Speaker N: text`) and scanned for the wake word.
The `analyst-companion` plugin loop polls that transcript.

## Services
- **`wlk`** — WhisperLiveKit, GPU, `faster-whisper large-v3` (Estonian) + Streaming
  Sortformer diarization. Internal-only (`est-datalake-net`); no Caddy front.
- **`aimeet`** — FastAPI: serves the console, relays audio to `wlk`, persists lines, serves
  the question/response/speaker feed. The only Caddy-fronted surface (`aimeet.r-53.com`,
  **Tailscale-only** — see `Caddyfile.snippet`).

## Endpoints (aimeet)
- `POST /sessions` — mint a session
- `GET  /r/{id}` — the console SPA
- `WS   /sessions/{id}/stream` — transparent relay to `wlk:/asr`
- `POST /sessions/{id}/line` — persist a finalized `{seconds, text, speaker?}` line + wake detect
- `POST /sessions/{id}/speaker` — rename a diarization label `{speaker, name}`
- `GET  /sessions/{id}/feed` — `{questions, responses, speakers, ended}`
- `POST /sessions/{id}/end` — mark ended

## Sessions
`/mnt/data/ai/analyst-companion/sessions/<id>/` (shared with the webtop plugin).

## Run
    cd /mnt/data/ai/aimeet && docker compose up -d --build
    docker compose logs -f wlk      # first run downloads model + diarization weights

## Test
    pip install -r requirements.txt && python -m pytest tests/ -v

## Notes
- GPU required for `wlk`. If VRAM is tight alongside other models, set `--model
  large-v3-turbo` in `docker-compose.yml`.
- WLK's result-JSON schema is interpreted only in `app/static/record.html` (`parseWlk()`).
  The Python side never parses it — it just relays bytes/text.
```

- [ ] **Step 2: Commit**

```bash
cd /mnt/data/ai/aimeet && git add README.md && git commit -q -m "docs(aimeet): v2 README (WhisperLiveKit relay + speaker dialog)"
```

---

## Phase G — plugin updates (claude-plugins repo, branch feat/analyst-companion)

### Task G1: SKILL.md — speaker-prefixed transcript lines

**Files:**
- Modify: `plugins/analyst-companion/skills/meeting-companion/SKILL.md`

- [ ] **Step 1: Update the transcript-format references**

In the "Session files under `<dir>`" list, change the `transcript.md` line to:

```
- `transcript.md` — append-only `[mm:ss] <speaker>: text` (READ deltas). `<speaker>` is a
  raw diarization label (`Speaker 1`, `Speaker 2`, …); display names live in `speakers.json`.
- `speakers.json` — diarization label → display-name map written by the page (READ for synthesis)
```

In **step 4 (Ingest transcript delta)**, replace the paragraph with:

```
4. **Ingest transcript delta.** Read `transcript.md` lines after `transcript_offset`. Each
   line is `[mm:ss] <speaker>: text` (a line may have no speaker prefix if diarization was
   off). Fold them into `needs`, tracking **which speaker** wants what (decisions,
   ambiguities, must-haves vs nice-to-haves, and any disagreement between speakers). Resolve
   `<speaker>` to a display name via `speakers.json` when available. Advance
   `transcript_offset`.
```

In **step 5 (Refresh questions)**, append to the sentence:

```
   …Where a need or gap clearly belongs to one participant, you may aim the question at
   that person (e.g. "Mari mainis eksporti — kas see on kohustuslik?").
```

- [ ] **Step 2: Verify frontmatter still parses**

Run: `cd /mnt/data/ai/claude-plugins && python -c "t=open('plugins/analyst-companion/skills/meeting-companion/SKILL.md').read(); assert t.startswith('---') and t.count('---')>=2; print('FRONTMATTER OK')"`
Expected: `FRONTMATTER OK`

- [ ] **Step 3: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add plugins/analyst-companion/skills/meeting-companion/SKILL.md && git commit -q -m "feat(analyst-companion): loop reads speaker-attributed transcript lines"
```

---

### Task G2: `/meeting-end` — speaker-attributed synthesis

**Files:**
- Modify: `plugins/analyst-companion/commands/meeting-end.md`

- [ ] **Step 1: Update step 3 (Synthesize work items)**

Replace the synthesis step's first sentence with:

```
3. **Synthesize work items.** Read the full `<session_root>/<id>/transcript.md` (lines are
   `[mm:ss] <speaker>: text`), the `<session_root>/<id>/speakers.json` name map, and the
   accumulated `needs` in `state.json`. Produce a concise list of proposed Plane work
   items, attributing each to the participant(s) who requested it where the transcript
   makes that clear (use display names from `speakers.json`).
```

- [ ] **Step 2: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add plugins/analyst-companion/commands/meeting-end.md && git commit -q -m "feat(analyst-companion): /meeting-end attributes work items to speakers"
```

---

### Task G3: README + version bump (kept in sync)

**Files:**
- Modify: `plugins/analyst-companion/README.md`
- Modify: `plugins/analyst-companion/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Update the plugin README**

In `plugins/analyst-companion/README.md`:
- Change the intro to say it transcribes the room mic **live with speaker diarization**
  (self-hosted WhisperLiveKit) and shows a **speaker-attributed dialog**.
- Replace the ASCII architecture block with the v2 flow:

```
room mic → aimeet console (AudioWorklet PCM) → WS relay → WhisperLiveKit (STT + diarization)
   → browser posts finalized lines → transcript.md ([mm:ss] Speaker N: text) → /loop reads delta
      ├─ general talk  → questions.json   ─┐
      └─ "Claude, …"   → act (+chrome) → responses.json ─┤
                                                         ▼
                         aimeet page polls /feed → renders dialog + panels
on /meeting-end → speaker-attributed synthesis → scope confirm → Plane work items
```

- In **Requirements**, add: "A **GPU** host for the `wlk` (WhisperLiveKit) container."
- In **Limits**, replace the diarization + latency bullets with:

```
- Live transcription via WhisperLiveKit; voice round-trip is faster than batch but still
  not sub-second (streaming STT + loop tick ≈ a few seconds).
- Speaker labels come from acoustic diarization on a single room mic — `Speaker 1/2/…`,
  renamable in the console. It may occasionally merge or split speakers; it does not know
  real names until you rename them.
- "Claude" wake word is matched against a configurable spelling list — tune `wake_words`.
```

- [ ] **Step 2: Bump `plugin.json` version to `0.2.0`**

In `plugins/analyst-companion/.claude-plugin/plugin.json` set `"version": "0.2.0"`.

- [ ] **Step 3: Bump the marketplace entry to `0.2.0` and refresh its description**

In `.claude-plugin/marketplace.json`, in the `analyst-companion` entry set
`"version": "0.2.0"` and update its `description` to mention **live transcription + speaker
diarization**. (Both versions MUST match — repo rule + pre-push hook.)

- [ ] **Step 4: Validate JSON + versions match**

Run:
```bash
cd /mnt/data/ai/claude-plugins && python -c "
import json
p=json.load(open('plugins/analyst-companion/.claude-plugin/plugin.json'))
m=[x for x in json.load(open('.claude-plugin/marketplace.json'))['plugins'] if x['name']=='analyst-companion'][0]
assert p['version']==m['version']=='0.2.0', (p['version'], m['version'])
print('VERSIONS OK', p['version'])"
```
Expected: `VERSIONS OK 0.2.0`

- [ ] **Step 5: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add plugins/analyst-companion/README.md plugins/analyst-companion/.claude-plugin/plugin.json .claude-plugin/marketplace.json && git commit -q -m "docs(analyst-companion): v2 README + bump 0.1.0 → 0.2.0"
```

---

## Phase H — end-to-end verification

### Task H1: Full v2 rehearsal (manual)

**Files:** none (verification only)

- [ ] **Step 1: Service tests green**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/ -v`
Expected: all pass (`test_wake.py`, `test_sessions.py`, `test_routes.py`). No `test_chunk.py`/`stt` remain.

- [ ] **Step 2: Plugin tests green**

Run: `cd /mnt/data/ai/claude-plugins/plugins/analyst-companion/scripts && python -m pytest -v`
Expected: all pass (unchanged Plane-client tests).

- [ ] **Step 3: Live rehearsal.** Stack up (`docker compose up -d --build` in aimeet),
  `.claude/analyst-companion.local.md` configured, `PLANE_API_TOKEN` exported. Run
  `/meeting-start`, open the console over Tailscale, and with **two speakers** say a few
  requirement sentences plus one *"Claude, kas sa näed seda akent?"*. Confirm: the dialog
  panel shows **live partial words** that settle into **speaker-labeled turns**; renaming a
  speaker sticks; `transcript.md` shows `[mm:ss] Speaker N: …` lines; the You↔Claude panel
  shows a Chrome-aware answer within a few seconds; Open questions populate (and may name a
  speaker).

- [ ] **Step 4: End-to-end close.** Run `/meeting-end`; confirm the proposal lists work
  items (attributed to speakers where clear), the scope-confirm prompt appears, and after
  approval the items show up in `plan.r-53.com`. Verify `work-items.md`, `transcript.md`,
  and `speakers.json` remain in the session dir.

---

## Self-Review

**Spec coverage (v2 deltas):**
- Real-time transcription → E1 (WLK streaming), F2 (WS relay), F3 (AudioWorklet PCM stream). ✓
- Transcription shown in web UI as live dialog → F3 (partial + finalized speaker turns). ✓
- Speaker-attributed "different persons" view → E1 (`--diarization`), F1 (speaker in transcript), F3 (dialog + rename), F1/F2 (`speakers.json`). ✓
- WLK internal-only, aimeet sole exposed surface → F2 (relay), F4 (compose; no WLK Caddy front). ✓
- Estonian unchanged → E1 (`--lan et`, `large-v3`). ✓ *(verified: flag is `--lan`, not `--language`)*
- Plane output + scope confirm → unchanged (G2 only adds attribution). ✓
- Tailscale-only → `Caddyfile.snippet` corrected during bring-up to a `remote_ip 100.64.0.0/10`
  gate (the `bind <tailnet-ip>` approach fails in a containerized Caddy). ✓
- Config not hardcoded → `WLK_WS_URL` is service env; plugin keys unchanged. ✓
- GPU assumption + turbo escape hatch → E1, F4 comments. ✓
- Version bump synced → G3 (plugin.json + marketplace.json both 0.2.0). ✓

**Placeholder scan:** `large-v3-turbo` and the `[diarization]` extra name are flagged as
build-time confirmations with explicit fallback instructions, not silent gaps. `parseWlk()`
is the one schema-dependent function, explicitly marked for live confirmation with a
concrete default against WLK's documented fields — consistent with treating record.html as
a manually-verified browser artifact. No code step is deferred.

**Type / name consistency:** `append_transcript(..., speaker=None)`, `read_speakers`,
`set_speaker_name`, `feed` keys `{questions, responses, speakers, ended}`, the `Line`
(`seconds,text,speaker`) and `SpeakerName` (`speaker,name`) bodies, routes `/line`,
`/speaker`, `/sessions/{id}/stream`, and env `WLK_WS_URL` are used identically across
`sessions.py`, `main.py`, `test_routes.py`, `record.html`, and `docker-compose.yml`.
`wake.find_command` is unchanged and still fed the line text. Browser `parseWlk` emits
`{seconds, speaker, text}` exactly matching the `/line` body and `Line` model.
