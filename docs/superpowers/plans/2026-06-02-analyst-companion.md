# analyst-companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real-time in-person meeting analyst — a Tailscale-only web console (`aimeet.r-53.com`) transcribes the room mic via the existing `stt-api`, surfaces live clarifying questions, lets you talk to Claude ("Claude, kas sa näed…"), and at meeting end creates reviewed Plane work items.

**Architecture:** A new FastAPI **`meeting-capture`** service (container on `est-datalake-net`, Caddy-fronted, Tailscale-only) records the mic in the browser with VAD chunking, forwards each chunk to `stt-api`, appends to a per-session `transcript.md`, and detects the wake word. A new **`analyst-companion`** Claude Code plugin runs a `/loop` that reads the transcript delta, handles voice commands (via claude-in-chrome), and refreshes the question/response panels the page polls. The transcript file is the seam decoupling continuous audio from Claude's turn-based loop. Output goes to self-hosted Plane via a lifted client.

**Tech Stack:** Python 3.11 / FastAPI / uvicorn, pytest, Docker Compose, Caddy, browser MediaRecorder + a VAD lib, Speaches (`stt-api`), Plane REST API (`X-API-Key`), claude-in-chrome MCP, the `loop` skill.

---

## File Structure

### New service — `/mnt/data/ai/aimeet/` (host path; NOT in the plugins repo)
- `app/main.py` — FastAPI app + routes (`/sessions`, `/r/{id}`, `/chunk`, `/feed`, `/end`)
- `app/sessions.py` — session dir lifecycle, transcript append, feed read, command queue
- `app/stt.py` — forward an audio chunk to `stt-api`
- `app/wake.py` — deterministic wake-word detection (pure function)
- `app/static/record.html` — the single-page console (recorder + 3 panels + polling)
- `tests/test_wake.py`, `tests/test_sessions.py`, `tests/test_chunk.py`
- `requirements.txt`, `Dockerfile`, `docker-compose.yml`, `Caddyfile.snippet`, `README.md`

Sessions are written under `SESSION_ROOT` (container `/data/sessions`, bind-mounted to
`/mnt/data/ai/analyst-companion/sessions`) so the webtop-side plugin reads/writes the same files.

### New plugin — `plugins/analyst-companion/` (in this repo)
- `.claude-plugin/plugin.json`
- `commands/meeting-start.md`, `commands/meeting-end.md`
- `skills/meeting-companion/SKILL.md`
- `scripts/plane_client.py`, `scripts/test_plane_client.py`
- `analyst-companion.local.md.example` — settings template
- `README.md`

### Modified
- `.claude-plugin/marketplace.json` — add the `analyst-companion` entry

### Responsibility split (deterministic vs intelligent)
- **Service** does the deterministic, testable work: chunk → STT → transcript line, and
  wake-word *detection* (append to `commands.jsonl`).
- **Plugin loop** does the intelligent work: *handle* commands (interpret intent, drive
  claude-in-chrome, answer), and synthesize clarifying questions.

---

## Phase A — `meeting-capture` service

### Task A1: Scaffold service + wake-word detection (TDD)

**Files:**
- Create: `/mnt/data/ai/aimeet/requirements.txt`
- Create: `/mnt/data/ai/aimeet/app/__init__.py` (empty)
- Create: `/mnt/data/ai/aimeet/app/wake.py`
- Test: `/mnt/data/ai/aimeet/tests/test_wake.py`

- [ ] **Step 1: Create `requirements.txt`**

```
fastapi==0.115.0
uvicorn[standard]==0.30.6
python-multipart==0.0.9
requests==2.32.3
pytest==8.3.3
httpx==0.27.2
```

- [ ] **Step 2: Create the empty package marker**

```bash
mkdir -p /mnt/data/ai/aimeet/app /mnt/data/ai/aimeet/tests
touch /mnt/data/ai/aimeet/app/__init__.py
```

- [ ] **Step 3: Write the failing test** — `tests/test_wake.py`

```python
from app.wake import find_command

WAKE = ["claude", "klaud", "kloud", "klod", "klood"]

def test_addresses_assistant_estonian():
    assert find_command("Claude, kas sa näed akent?", WAKE) == "kas sa näed akent?"

def test_alternate_spelling():
    assert find_command("Klaud kas sa näed", WAKE) == "kas sa näed"

def test_general_talk_is_not_a_command():
    assert find_command("Klient soovib uut nuppu", WAKE) is None

def test_empty_line():
    assert find_command("", WAKE) is None

def test_bare_wake_word_returns_empty_command():
    assert find_command("Claude.", WAKE) == ""
```

- [ ] **Step 4: Run it, expect failure**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_wake.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.wake'`

- [ ] **Step 5: Implement `app/wake.py`**

```python
"""Deterministic wake-word detection. Pure, no I/O — easy to unit-test."""
import re

_FIRST_TOKEN = re.compile(r"^\W*([\wõäöüÕÄÖÜ]+)\W*(.*)$", re.UNICODE)


def find_command(text: str, wake_words: list[str]) -> str | None:
    """If `text` is addressed to the assistant (first token is a wake word),
    return the remainder with the wake word + trailing punctuation stripped.
    Otherwise return None. A bare wake word returns "" (empty command)."""
    stripped = (text or "").strip()
    m = _FIRST_TOKEN.match(stripped)
    if not m:
        return None
    first, rest = m.group(1), m.group(2)
    wake = {w.casefold() for w in wake_words}
    if first.casefold() in wake:
        return rest.strip()
    return None
```

- [ ] **Step 6: Run tests, expect pass**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_wake.py -v`
Expected: PASS (5 passed)

- [ ] **Step 7: Commit**

```bash
cd /mnt/data/ai/aimeet && git init -q 2>/dev/null; git add -A && git commit -q -m "feat(aimeet): wake-word detection + scaffold"
```

---

### Task A2: Session store (TDD)

**Files:**
- Create: `/mnt/data/ai/aimeet/app/sessions.py`
- Test: `/mnt/data/ai/aimeet/tests/test_sessions.py`

- [ ] **Step 1: Write the failing test** — `tests/test_sessions.py`

```python
import json
from pathlib import Path
from app import sessions


def test_create_session_makes_dir_and_token(tmp_path):
    sid = sessions.create_session(tmp_path)
    assert len(sid) >= 16
    assert (tmp_path / sid).is_dir()


def test_append_transcript_writes_timestamped_line(tmp_path):
    sid = sessions.create_session(tmp_path)
    sessions.append_transcript(tmp_path, sid, 25, "tere klient")
    body = (tmp_path / sid / "transcript.md").read_text(encoding="utf-8")
    assert "[00:25] tere klient" in body


def test_enqueue_and_read_commands(tmp_path):
    sid = sessions.create_session(tmp_path)
    sessions.enqueue_command(tmp_path, sid, 30, "kas sa näed akent")
    cmds = sessions.read_commands(tmp_path, sid, offset=0)
    assert cmds == [{"seconds": 30, "command": "kas sa näed akent"}]


def test_feed_defaults_to_empty_lists(tmp_path):
    sid = sessions.create_session(tmp_path)
    assert sessions.feed(tmp_path, sid) == {"questions": [], "responses": [], "ended": False}


def test_feed_reads_plugin_written_files(tmp_path):
    sid = sessions.create_session(tmp_path)
    (tmp_path / sid / "questions.json").write_text(json.dumps(["Mis on eesmärk?"]))
    (tmp_path / sid / "responses.json").write_text(json.dumps([{"you": "Claude?", "claude": "Jah"}]))
    f = sessions.feed(tmp_path, sid)
    assert f["questions"] == ["Mis on eesmärk?"]
    assert f["responses"] == [{"you": "Claude?", "claude": "Jah"}]


def test_end_sets_ended_flag(tmp_path):
    sid = sessions.create_session(tmp_path)
    sessions.end_session(tmp_path, sid)
    assert sessions.feed(tmp_path, sid)["ended"] is True
```

- [ ] **Step 2: Run it, expect failure**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_sessions.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.sessions'`

- [ ] **Step 3: Implement `app/sessions.py`**

```python
"""Filesystem-backed session store shared between the service and the plugin loop.

Layout under <root>/<sid>/:
  transcript.md   append-only "[mm:ss] text" lines (service writes)
  commands.jsonl  append-only wake-word hits (service writes, loop reads via offset)
  questions.json  current clarifying questions (loop writes, /feed reads)
  responses.json  You<->Claude log (loop writes, /feed reads)
  ended           marker file (service writes on /end)
"""
import json
import secrets
from pathlib import Path


def create_session(root: Path) -> str:
    sid = secrets.token_urlsafe(16)
    (Path(root) / sid).mkdir(parents=True, exist_ok=True)
    return sid


def _dir(root: Path, sid: str) -> Path:
    d = Path(root) / sid
    if not d.is_dir():
        raise FileNotFoundError(f"unknown session {sid}")
    return d


def append_transcript(root: Path, sid: str, seconds: int, text: str) -> None:
    line = f"[{seconds // 60:02d}:{seconds % 60:02d}] {text.strip()}\n"
    with (_dir(root, sid) / "transcript.md").open("a", encoding="utf-8") as fh:
        fh.write(line)


def enqueue_command(root: Path, sid: str, seconds: int, command: str) -> None:
    rec = {"seconds": seconds, "command": command}
    with (_dir(root, sid) / "commands.jsonl").open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def read_commands(root: Path, sid: str, offset: int = 0) -> list[dict]:
    path = _dir(root, sid) / "commands.jsonl"
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    return [json.loads(ln) for ln in lines[offset:] if ln.strip()]


def _read_json(path: Path, default):
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, ValueError):
        return default


def feed(root: Path, sid: str) -> dict:
    d = _dir(root, sid)
    return {
        "questions": _read_json(d / "questions.json", []),
        "responses": _read_json(d / "responses.json", []),
        "ended": (d / "ended").exists(),
    }


def end_session(root: Path, sid: str) -> None:
    (_dir(root, sid) / "ended").write_text("1", encoding="utf-8")
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_sessions.py -v`
Expected: PASS (6 passed)

- [ ] **Step 5: Commit**

```bash
cd /mnt/data/ai/aimeet && git add -A && git commit -q -m "feat(aimeet): session store (transcript, commands, feed)"
```

---

### Task A3: STT forwarding helper (TDD with injected poster)

**Files:**
- Create: `/mnt/data/ai/aimeet/app/stt.py`
- Test: append to `/mnt/data/ai/aimeet/tests/test_chunk.py`

- [ ] **Step 1: Write the failing test** — `tests/test_chunk.py`

```python
from app import stt


def test_transcribe_posts_multipart_and_returns_text():
    captured = {}

    def fake_post(url, files, data, timeout):
        captured["url"] = url
        captured["data"] = data
        captured["filename"] = files["file"][0]

        class R:
            def raise_for_status(self): pass
            def json(self): return {"text": "tere klient"}
        return R()

    text = stt.transcribe(
        audio=b"RIFF....",
        filename="chunk.webm",
        base_url="http://stt-api:8000/v1",
        model="Systran/faster-whisper-large-v3",
        language="et",
        post=fake_post,
    )
    assert text == "tere klient"
    assert captured["url"] == "http://stt-api:8000/v1/audio/transcriptions"
    assert captured["data"]["model"] == "Systran/faster-whisper-large-v3"
    assert captured["data"]["language"] == "et"
    assert captured["filename"] == "chunk.webm"
```

- [ ] **Step 2: Run it, expect failure**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_chunk.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.stt'`

- [ ] **Step 3: Implement `app/stt.py`**

```python
"""Forward one audio chunk to the Speaches `stt-api` (OpenAI transcription contract)."""
import requests


def transcribe(audio: bytes, filename: str, base_url: str, model: str,
               language: str, post=requests.post) -> str:
    """POST a multipart transcription request; return the recognized text.
    `post` is injectable for testing."""
    url = base_url.rstrip("/") + "/audio/transcriptions"
    resp = post(
        url,
        files={"file": (filename, audio, "application/octet-stream")},
        data={"model": model, "language": language},
        timeout=120,
    )
    resp.raise_for_status()
    return (resp.json().get("text") or "").strip()
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_chunk.py -v`
Expected: PASS (1 passed)

- [ ] **Step 5: Commit**

```bash
cd /mnt/data/ai/aimeet && git add -A && git commit -q -m "feat(aimeet): stt-api forwarding helper"
```

---

### Task A4: FastAPI app + routes (TDD via TestClient)

**Files:**
- Create: `/mnt/data/ai/aimeet/app/main.py`
- Test: append to `/mnt/data/ai/aimeet/tests/test_chunk.py`

- [ ] **Step 1: Add the failing app-level test** — append to `tests/test_chunk.py`

```python
import json
from fastapi.testclient import TestClient


def _client(tmp_path, monkeypatch):
    monkeypatch.setenv("SESSION_ROOT", str(tmp_path))
    monkeypatch.setenv("WAKE_WORDS", "claude,klaud,kloud,klod,klood")
    monkeypatch.setenv("STT_BASE_URL", "http://stt-api:8000/v1")
    import importlib
    from app import main
    importlib.reload(main)
    # stub out the network call to stt-api
    main.stt.transcribe = lambda **kw: {"chunk1.webm": "tere klient",
                                        "chunk2.webm": "Claude, kas sa näed akent"}[kw["filename"]]
    return TestClient(main.app), main


def test_full_session_flow(tmp_path, monkeypatch):
    client, main = _client(tmp_path, monkeypatch)

    sid = client.post("/sessions").json()["id"]

    # plain talk -> transcript only, no command
    r1 = client.post(f"/sessions/{sid}/chunk",
                     files={"file": ("chunk1.webm", b"a")}, data={"seconds": "10"})
    assert r1.json()["text"] == "tere klient"

    # addressed to Claude -> transcript + command queue
    client.post(f"/sessions/{sid}/chunk",
                files={"file": ("chunk2.webm", b"b")}, data={"seconds": "20"})

    transcript = (tmp_path / sid / "transcript.md").read_text(encoding="utf-8")
    assert "[00:10] tere klient" in transcript
    assert "[00:20] Claude, kas sa näed akent" in transcript

    cmds = (tmp_path / sid / "commands.jsonl").read_text(encoding="utf-8").strip().splitlines()
    assert len(cmds) == 1
    assert json.loads(cmds[0])["command"] == "kas sa näed akent"

    # feed reflects plugin-written questions
    (tmp_path / sid / "questions.json").write_text(json.dumps(["Mis on eesmärk?"]))
    assert client.get(f"/sessions/{sid}/feed").json()["questions"] == ["Mis on eesmärk?"]

    # end
    client.post(f"/sessions/{sid}/end")
    assert client.get(f"/sessions/{sid}/feed").json()["ended"] is True
```

- [ ] **Step 2: Run it, expect failure**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/test_chunk.py::test_full_session_flow -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.main'`

- [ ] **Step 3: Implement `app/main.py`**

```python
"""meeting-capture: record-page host + chunk→STT→transcript + feed for aimeet.r-53.com."""
import os
from pathlib import Path

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse

from app import sessions, stt, wake

SESSION_ROOT = Path(os.environ.get("SESSION_ROOT", "/data/sessions"))
WAKE_WORDS = [w.strip() for w in os.environ.get("WAKE_WORDS", "claude").split(",") if w.strip()]
STT_BASE_URL = os.environ.get("STT_BASE_URL", "http://stt-api:8000/v1")
STT_MODEL = os.environ.get("STT_MODEL", "Systran/faster-whisper-large-v3")
STT_LANGUAGE = os.environ.get("STT_LANGUAGE", "et")

_RECORD_HTML = (Path(__file__).parent / "static" / "record.html").read_text(encoding="utf-8")

app = FastAPI(title="meeting-capture")
SESSION_ROOT.mkdir(parents=True, exist_ok=True)


@app.post("/sessions")
def create():
    return {"id": sessions.create_session(SESSION_ROOT)}


@app.get("/r/{sid}", response_class=HTMLResponse)
def record_page(sid: str):
    try:
        sessions._dir(SESSION_ROOT, sid)
    except FileNotFoundError:
        raise HTTPException(404, "unknown session")
    return _RECORD_HTML.replace("__SESSION_ID__", sid)


@app.post("/sessions/{sid}/chunk")
async def chunk(sid: str, seconds: int = Form(...), file: UploadFile = File(...)):
    try:
        sessions._dir(SESSION_ROOT, sid)
    except FileNotFoundError:
        raise HTTPException(404, "unknown session")
    audio = await file.read()
    text = stt.transcribe(audio=audio, filename=file.filename or "chunk.webm",
                          base_url=STT_BASE_URL, model=STT_MODEL, language=STT_LANGUAGE)
    if text:
        sessions.append_transcript(SESSION_ROOT, sid, seconds, text)
        cmd = wake.find_command(text, WAKE_WORDS)
        if cmd is not None and cmd != "":
            sessions.enqueue_command(SESSION_ROOT, sid, seconds, cmd)
    return {"text": text}


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
```

- [ ] **Step 4: Create a placeholder `static/record.html` so `main` imports** (full version in A5)

```bash
mkdir -p /mnt/data/ai/aimeet/app/static
printf '<!doctype html><title>aimeet __SESSION_ID__</title>' > /mnt/data/ai/aimeet/app/static/record.html
```

- [ ] **Step 5: Run tests, expect pass**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/ -v`
Expected: PASS (all tests across the three test files)

- [ ] **Step 6: Commit**

```bash
cd /mnt/data/ai/aimeet && git add -A && git commit -q -m "feat(aimeet): FastAPI routes (sessions, chunk, feed, end)"
```

---

### Task A5: Record-page console (manual verification — browser artifact)

**Files:**
- Modify (replace placeholder): `/mnt/data/ai/aimeet/app/static/record.html`

- [ ] **Step 1: Write the full console** — overwrite `app/static/record.html`

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
  .line { margin:2px 0; }
  .t { color:#6e7681; margin-right:6px; }
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
  <section id="tcol"><h2>Transkriptsioon</h2><div id="transcript"></div></section>
  <section id="qcol"><h2>❓ Avatud küsimused</h2><div id="questions"></div></section>
  <section id="chat"><h2>🗣 Sina ↔ Claude</h2><div id="responses"></div></section>
</main>
<script>
const SID = "__SESSION_ID__";
const SILENCE_MS = 1200, MIN_CHUNK_MS = 1500, MAX_CHUNK_MS = 15000;
const $ = id => document.getElementById(id);
let media, rec, audioCtx, analyser, t0, running = false;

function status(m){ $("status").textContent = m || ""; }

async function start(){
  try { media = await navigator.mediaDevices.getUserMedia({audio:true}); }
  catch(e){ status("Mikrofoni luba puudub"); return; }
  t0 = performance.now ? Date.now() : Date.now();
  running = true; $("rec").classList.add("on"); $("dot").classList.add("on"); $("rec").textContent="■ Lõpeta";
  audioCtx = new AudioContext();
  const src = audioCtx.createMediaStreamSource(media);
  analyser = audioCtx.createAnalyser(); analyser.fftSize = 512; src.connect(analyser);
  loopChunks();
}

// VAD-style chunking: record until a silence pause (or MAX), then flush.
async function loopChunks(){
  const buf = new Uint8Array(analyser.frequencyBinCount);
  while(running){
    rec = new MediaRecorder(media, {mimeType:"audio/webm"});
    const parts = []; rec.ondataavailable = e => parts.length && false || (e.data.size && parts.push(e.data));
    rec.start();
    const segStart = Date.now(); let lastVoice = Date.now();
    await new Promise(res => {
      const tick = setInterval(()=>{
        analyser.getByteFrequencyData(buf);
        const energy = buf.reduce((a,b)=>a+b,0)/buf.length;
        const now = Date.now();
        if(energy > 12) lastVoice = now;
        const dur = now - segStart;
        if(!running || dur >= MAX_CHUNK_MS || (dur >= MIN_CHUNK_MS && now - lastVoice >= SILENCE_MS)){
          clearInterval(tick); res();
        }
      }, 150);
    });
    await new Promise(res => { rec.onstop = res; rec.stop(); });
    if(parts.length){
      const blob = new Blob(parts, {type:"audio/webm"});
      upload(blob, Math.round((Date.now()-t0)/1000));
    }
  }
}

async function upload(blob, seconds){
  const fd = new FormData();
  fd.append("file", blob, "chunk.webm"); fd.append("seconds", seconds);
  try{
    const r = await fetch(`/sessions/${SID}/chunk`, {method:"POST", body:fd});
    const j = await r.json();
    if(j.text) addTranscript(seconds, j.text);
    status("");
  }catch(e){ status("Transkriptsioon hilineb…"); }
}

function fmt(s){ return String(Math.floor(s/60)).padStart(2,"0")+":"+String(s%60).padStart(2,"0"); }
function addTranscript(s, text){
  const d = document.createElement("div"); d.className="line";
  d.innerHTML = `<span class="t">[${fmt(s)}]</span>${esc(text)}`;
  $("transcript").appendChild(d); $("tcol").scrollTop = 1e9;
}
function esc(x){ return (x||"").replace(/[&<>]/g, c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c])); }

let renderedR = 0;
async function pollFeed(){
  try{
    const f = await (await fetch(`/sessions/${SID}/feed`)).json();
    $("questions").innerHTML = (f.questions||[]).map(q=>`<div class="q">${esc(q)}</div>`).join("") || "<div class='t'>…</div>";
    const r = f.responses||[];
    for(let i=renderedR;i<r.length;i++){
      const m = document.createElement("div"); m.className="msg";
      m.innerHTML = `<div class="you">Sina: ${esc(r[i].you||"")}</div><div class="claude">Claude: ${esc(r[i].claude||"")}</div>`;
      $("responses").appendChild(m);
    }
    if(r.length>renderedR){ renderedR=r.length; $("chat").scrollTop=1e9; }
    if(f.ended && running){ running=false; status("Koosolek lõpetatud"); }
  }catch(e){}
}
setInterval(pollFeed, 2000); pollFeed();

$("rec").onclick = ()=>{
  if(!running){ start(); }
  else { running=false; $("rec").classList.remove("on"); $("dot").classList.remove("on"); $("rec").textContent="● Salvesta"; }
};
</script>
</body>
</html>
```

- [ ] **Step 2: Manually verify the page renders (no backend STT needed)**

```bash
cd /mnt/data/ai/aimeet && SESSION_ROOT=/tmp/aimeet-dev WAKE_WORDS=claude \
  python -m uvicorn app.main:app --host 0.0.0.0 --port 4321 &
sleep 2
curl -s -XPOST http://localhost:4321/sessions
```
Open `http://aibox:4321/r/<id-from-curl>` in a browser. Expected: dark 3-panel console; clicking **● Salvesta** prompts for mic permission and the dot pulses red. Stop the dev server afterwards: `kill %1`.

- [ ] **Step 3: Commit**

```bash
cd /mnt/data/ai/aimeet && git add -A && git commit -q -m "feat(aimeet): record-page console (VAD chunking + live panels)"
```

---

### Task A6: Containerize + Caddy (Tailscale-only) (manual verification)

**Files:**
- Create: `/mnt/data/ai/aimeet/Dockerfile`
- Create: `/mnt/data/ai/aimeet/docker-compose.yml`
- Create: `/mnt/data/ai/aimeet/Caddyfile.snippet`
- Create: `/mnt/data/ai/aimeet/README.md`

- [ ] **Step 1: Create `Dockerfile`**

```dockerfile
FROM python:3.11-slim
WORKDIR /code
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 2: Create `docker-compose.yml`** (mirrors the `stt-api` network/volume pattern)

```yaml
# meeting-capture — records the room mic in the browser, forwards chunks to stt-api,
# serves the aimeet.r-53.com console. Internal to est-datalake-net (to reach stt-api);
# Caddy fronts aimeet.r-53.com, Tailscale-only (see Caddyfile.snippet).
services:
  aimeet:
    build: .
    container_name: aimeet
    restart: unless-stopped
    environment:
      - SESSION_ROOT=/data/sessions
      - STT_BASE_URL=http://stt-api:8000/v1
      - STT_MODEL=Systran/faster-whisper-large-v3
      - STT_LANGUAGE=et
      - WAKE_WORDS=claude,klaud,kloud,klod,klood
    volumes:
      - /mnt/data/ai/analyst-companion/sessions:/data/sessions
    expose:
      - "8000"
    networks:
      - est-datalake-net

networks:
  est-datalake-net:
    external: true
```

- [ ] **Step 3: Create `Caddyfile.snippet`** (add to the existing Caddy config; bind to the tailnet only)

```
# aimeet.r-53.com — meeting analyst console. Tailscale-only: bind the listener to the
# tailnet IP so it is never served on the public internet (transcripts are sensitive).
# Replace 100.x.y.z with this host's Tailscale IP (`tailscale ip -4`).
https://aimeet.r-53.com {
    bind 100.x.y.z
    reverse_proxy aimeet:8000
}
```

- [ ] **Step 4: Create `README.md`**

```markdown
# aimeet — meeting-capture service

Records the room mic in the browser, forwards chunks to `stt-api` (Speaches, Estonian
`large-v3`), appends a per-session `transcript.md`, and serves the `aimeet.r-53.com`
console (live transcript, open questions, You↔Claude). Wake-word hits are queued for the
`analyst-companion` plugin loop to handle.

- **Network:** `est-datalake-net` (reaches `stt-api:8000` by name)
- **Sessions:** `/mnt/data/ai/analyst-companion/sessions` (shared with the webtop plugin)
- **Exposure:** Caddy → `aimeet.r-53.com`, **Tailscale-only** (`Caddyfile.snippet`)

## Run
    cd /mnt/data/ai/aimeet && docker compose up -d --build
    docker compose logs -f

## Test
    pip install -r requirements.txt && python -m pytest tests/ -v
```

- [ ] **Step 5: Build, deploy, and smoke-test end-to-end**

```bash
cd /mnt/data/ai/aimeet && docker compose up -d --build
# create a session and confirm the page serves through the container
SID=$(docker run --rm --network est-datalake-net curlimages/curl:latest -s -XPOST http://aimeet:8000/sessions | python -c "import sys,json;print(json.load(sys.stdin)['id'])")
docker run --rm --network est-datalake-net curlimages/curl:latest -s "http://aimeet:8000/r/$SID" | grep -q "aimeet" && echo "PAGE OK"
```
Expected: `PAGE OK`. Then add the Caddy snippet, reload Caddy, and confirm
`https://aimeet.r-53.com/r/$SID` loads **only** over Tailscale (and fails off-tailnet).

- [ ] **Step 6: Commit**

```bash
cd /mnt/data/ai/aimeet && git add -A && git commit -q -m "feat(aimeet): containerize + Tailscale-only Caddy front"
```

---

## Phase B — plugin: Plane client + scaffold

### Task B1: Plane client with testable payload builder (TDD)

**Files:**
- Create: `plugins/analyst-companion/scripts/plane_client.py`
- Test: `plugins/analyst-companion/scripts/test_plane_client.py`

- [ ] **Step 1: Write the failing test** — `scripts/test_plane_client.py`

```python
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent


def test_build_payload_minimal():
    from plane_client import build_payload
    p = build_payload(name="Lisa eksport-nupp", description_html="<p>klient soovib</p>",
                       priority="high")
    assert p == {"name": "Lisa eksport-nupp",
                 "description_html": "<p>klient soovib</p>",
                 "priority": "high"}


def test_build_payload_omits_empty_fields():
    from plane_client import build_payload
    p = build_payload(name="X", description_html="", priority=None)
    assert p == {"name": "X"}


def test_cli_dry_run_prints_payload(tmp_path):
    desc = tmp_path / "d.html"; desc.write_text("<p>hi</p>", encoding="utf-8")
    out = subprocess.check_output(
        [sys.executable, str(HERE / "plane_client.py"), "create",
         "--workspace", "ws", "--project", "proj-uuid",
         "--name", "Test item", "--description-html-file", str(desc),
         "--priority", "medium", "--dry-run"],
        text=True, env={"PLANE_API_TOKEN": "x", "PLANE_BASE_URL": "https://plan.r-53.com", "PATH": ""},
    )
    payload = json.loads(out)
    assert payload["name"] == "Test item"
    assert payload["description_html"] == "<p>hi</p>"
    assert payload["priority"] == "medium"
```

- [ ] **Step 2: Run it, expect failure**

Run: `cd plugins/analyst-companion/scripts && python -m pytest test_plane_client.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'plane_client'`

- [ ] **Step 3: Implement `scripts/plane_client.py`** (lifts the `Plane` class from `/mnt/data/ai/plane/migrate_github_issues.py`)

```python
#!/usr/bin/env python3
"""Minimal Plane work-item client for the analyst-companion plugin.

Auth: PLANE_API_TOKEN (workspace API token). Base URL: PLANE_BASE_URL
(default https://plan.r-53.com). Used by /meeting-end to create reviewed work items.

CLI:
    PLANE_API_TOKEN=... python plane_client.py create \
        --workspace SLUG --project NAME_OR_UUID \
        --name "Title" --description-html-file body.html [--priority high] [--dry-run]
"""
from __future__ import annotations
import argparse, json, os, sys, time
import urllib.error, urllib.request


def build_payload(name: str, description_html: str = "", priority: str | None = None,
                  state: str | None = None, labels: list[str] | None = None) -> dict:
    """Build the work-item POST body, omitting empty/None fields."""
    payload: dict = {"name": name}
    if description_html:
        payload["description_html"] = description_html
    if priority:
        payload["priority"] = priority
    if state:
        payload["state"] = state
    if labels:
        payload["labels"] = labels
    return payload


class Plane:
    def __init__(self, base_url: str, token: str, workspace_slug: str):
        self.base = base_url.rstrip("/")
        self.token = token
        self.ws = workspace_slug

    def _req(self, method: str, path: str, body: dict | None = None):
        url = f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(6):
            req = urllib.request.Request(url, method=method, data=data)
            req.add_header("X-API-Key", self.token)
            req.add_header("Accept", "application/json")
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    raw = r.read()
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < 5:
                    time.sleep(30 * (attempt + 1)); continue
                raise SystemExit(f"Plane {method} {path} failed {e.code}: {e.read().decode('utf-8','replace')}")
        raise SystemExit(f"Plane {method} {path} failed after retries")

    def create_work_item(self, project: str, payload: dict) -> dict:
        return self._req("POST", f"/api/v1/workspaces/{self.ws}/projects/{project}/work-items/", payload)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--workspace", required=True)
    c.add_argument("--project", required=True)
    c.add_argument("--name", required=True)
    c.add_argument("--description-html-file")
    c.add_argument("--priority")
    c.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    desc = ""
    if args.description_html_file:
        with open(args.description_html_file, encoding="utf-8") as fh:
            desc = fh.read()
    payload = build_payload(name=args.name, description_html=desc, priority=args.priority)

    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False))
        return 0

    token = os.environ.get("PLANE_API_TOKEN")
    if not token:
        raise SystemExit("PLANE_API_TOKEN not set")
    base = os.environ.get("PLANE_BASE_URL", "https://plan.r-53.com")
    plane = Plane(base, token, args.workspace)
    created = plane.create_work_item(args.project, payload)
    print(json.dumps({"id": created.get("id"), "name": created.get("name")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd plugins/analyst-companion/scripts && python -m pytest test_plane_client.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add plugins/analyst-companion/scripts && git commit -q -m "feat(analyst-companion): Plane work-item client"
```

---

### Task B2: Plugin manifest, settings template, marketplace entry

**Files:**
- Create: `plugins/analyst-companion/.claude-plugin/plugin.json`
- Create: `plugins/analyst-companion/analyst-companion.local.md.example`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Create `plugin.json`**

```json
{
  "name": "analyst-companion",
  "version": "0.1.0",
  "description": "Real-time in-person meeting analyst — transcribes the room mic via self-hosted Whisper, surfaces live clarifying questions on a Tailscale-only console, answers voice commands using the on-screen Chrome context, and creates reviewed Plane work items at meeting end",
  "author": {
    "name": "Andre Paat"
  },
  "repository": "https://github.com/paat/claude-plugins",
  "license": "MIT",
  "keywords": ["meetings", "transcription", "whisper", "plane", "requirements", "analyst", "chrome", "estonian"]
}
```

- [ ] **Step 2: Create the settings template `analyst-companion.local.md.example`**

```markdown
---
plane_base_url: https://plan.r-53.com
plane_workspace_slug: <your-workspace-slug>
plane_project: <project-name-or-uuid>
aimeet_base_url: https://aimeet.r-53.com
session_root: /mnt/data/ai/analyst-companion/sessions
loop_interval_seconds: 9
question_refresh_seconds: 60
wake_words: [claude, klaud, kloud, klod, klood]
---

# analyst-companion settings

Copy this file to `.claude/analyst-companion.local.md` in your project and fill in the
placeholders. The Plane API token is read from the `PLANE_API_TOKEN` environment
variable (workspace API token from Plane → Workspace settings → API Tokens), never
stored here.
```

- [ ] **Step 3: Add the marketplace entry** — in `.claude-plugin/marketplace.json`, append to the `plugins` array (after the `google-ads-strategist` entry)

```json
    ,{
      "name": "analyst-companion",
      "description": "Real-time in-person meeting analyst — live transcription, clarifying questions, voice commands with Chrome screen context, and Plane work items at meeting end",
      "version": "0.1.0",
      "author": {
        "name": "Andre Paat"
      },
      "source": "./plugins/analyst-companion",
      "category": "productivity",
      "homepage": "https://github.com/paat/claude-plugins"
    }
```

- [ ] **Step 4: Validate JSON**

Run: `cd /mnt/data/ai/claude-plugins && python -c "import json; json.load(open('.claude-plugin/marketplace.json')); json.load(open('plugins/analyst-companion/.claude-plugin/plugin.json')); print('JSON OK')"`
Expected: `JSON OK`

- [ ] **Step 5: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add -A && git commit -q -m "feat(analyst-companion): plugin manifest, settings template, marketplace entry"
```

---

## Phase C — plugin: skill + commands

### Task C1: The meeting-companion skill (loop logic)

**Files:**
- Create: `plugins/analyst-companion/skills/meeting-companion/SKILL.md`

- [ ] **Step 1: Write `SKILL.md`**

````markdown
---
name: meeting-companion
description: Use during a live customer meeting started with /meeting-start — drives the per-tick loop that reads new transcript lines, handles "Claude, …" voice commands using claude-in-chrome, refreshes the open-questions panel, and writes the feeds the aimeet.r-53.com page polls.
---

# Meeting Companion Loop

You are the live analyst during an in-person customer meeting. A browser console at
`aimeet.r-53.com/r/<session>` records the room mic; the `meeting-capture` service writes
files into the session dir (`<session_root>/<session>/`). You run on a `/loop` and react
to those files. **You never touch audio** — only the files.

## Session files (read/write)
- `transcript.md` — append-only `[mm:ss] text` (READ deltas)
- `commands.jsonl` — wake-word hits, one JSON per line (READ via offset)
- `state.json` — YOUR cursor + running needs-model (READ/WRITE)
- `questions.json` — clarifying questions for the page (WRITE)
- `responses.json` — You↔Claude log for the page (WRITE; append)
- `ended` — present when the meeting is over (READ; stop the loop)

## Config
Read from `.claude/analyst-companion.local.md` frontmatter: `session_root`,
`loop_interval_seconds`, `question_refresh_seconds`. The active session id is in
`state.json` (written by `/meeting-start`).

## Each tick (do in order)

1. **Stop check.** If `<dir>/ended` exists, stop looping and tell the user the meeting
   ended (do NOT auto-create Plane items — that is `/meeting-end`).

2. **Load state.** Read `state.json` → `{ "session": id, "transcript_offset": N,
   "commands_offset": M, "needs": {...}, "last_question_refresh": secs }`. If missing,
   initialize offsets to 0.

3. **Handle commands first (responsive).** Read `commands.jsonl` lines after
   `commands_offset`. For each command (the text after the wake word):
   - Interpret intent freely (no rigid grammar). Common cases:
     - *"kas sa näed … akent / ekraani"* → use **claude-in-chrome** (`tabs_context_mcp`
       to find the active tab, then `read_page`/screenshot) to look, then answer in
       Estonian what you see.
     - *"tee sellest tööülesanne / lisa märkus"* → note it into `needs` for the final
       synthesis and confirm briefly.
     - Otherwise → answer the question directly from meeting context.
   - Append `{ "you": "<command>", "claude": "<your reply>" }` to `responses.json`.
   - Advance `commands_offset`.

3a. **claude-in-chrome unavailable.** If the chrome tools error or no tab is connected,
    append a reply like `"ei näe brauseriakent — kontrolli claude-in-chrome ühendust"`
    and continue. Never let one command abort the loop.

4. **Ingest transcript delta.** Read `transcript.md` lines after `transcript_offset`.
   Fold them into `needs` (what the customer wants, decisions, ambiguities, must-haves
   vs nice-to-haves). Advance `transcript_offset`.

5. **Refresh questions (throttled).** Only if `current_secs - last_question_refresh >=
   question_refresh_seconds` OR there are ≥6 new transcript lines: regenerate the list of
   the most useful **open/clarifying questions** (Estonian, customer-facing wording, max
   ~6) and write them to `questions.json` as a JSON array of strings. Update
   `last_question_refresh`.

6. **Persist** `state.json` and reschedule the next tick `loop_interval_seconds` later.

## Style for questions
Estonian, specific, and aimed at uncovering true need — gaps, unstated assumptions,
scope edges. Prefer "Mis juhtub kui…", "Kas X on kohustuslik või soovituslik?",
"Kuidas te seda täna teete?". Drop questions already answered in the transcript.
````

- [ ] **Step 2: Verify frontmatter parses**

Run: `cd /mnt/data/ai/claude-plugins && python -c "import re,sys; t=open('plugins/analyst-companion/skills/meeting-companion/SKILL.md').read(); assert t.startswith('---') and t.count('---')>=2; print('FRONTMATTER OK')"`
Expected: `FRONTMATTER OK`

- [ ] **Step 3: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add plugins/analyst-companion/skills && git commit -q -m "feat(analyst-companion): meeting-companion loop skill"
```

---

### Task C2: `/meeting-start` command

**Files:**
- Create: `plugins/analyst-companion/commands/meeting-start.md`

- [ ] **Step 1: Write `commands/meeting-start.md`**

````markdown
---
description: Start a live meeting analyst session — mints an aimeet session, prints the console URL to open on the laptop, and starts the companion loop.
---

# /meeting-start

Start an in-person customer meeting analyst session.

## Steps

1. **Read settings** from `.claude/analyst-companion.local.md` frontmatter:
   `aimeet_base_url`, `session_root`, `loop_interval_seconds`. If the file is missing,
   tell the user to copy `analyst-companion.local.md.example` and stop.

2. **Mint a session** — POST to the capture service:

   ```bash
   curl -s -XPOST "${aimeet_base_url}/sessions"
   ```

   Parse `{"id": "..."}`. (The service writes the session dir under `session_root`.)

3. **Initialize `state.json`** in `<session_root>/<id>/`:

   ```json
   { "session": "<id>", "transcript_offset": 0, "commands_offset": 0,
     "needs": {}, "last_question_refresh": 0 }
   ```

4. **Tell the user to open the console** on the meeting laptop (Tailscale required):

   > 🎙 Ava koosoleku konsool: `<aimeet_base_url>/r/<id>`
   > Vajuta **● Salvesta** ja luba mikrofon. Ütle "Claude, …" et minuga rääkida.

5. **Start the loop.** Invoke the `loop` skill to run the `meeting-companion` skill every
   `loop_interval_seconds`. The loop reacts to transcript/command files and writes the
   question/response feeds until the `ended` marker appears or the user runs
   `/meeting-end`.
````

- [ ] **Step 2: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add plugins/analyst-companion/commands/meeting-start.md && git commit -q -m "feat(analyst-companion): /meeting-start command"
```

---

### Task C3: `/meeting-end` command (synthesis → confirm → Plane)

**Files:**
- Create: `plugins/analyst-companion/commands/meeting-end.md`

- [ ] **Step 1: Write `commands/meeting-end.md`**

````markdown
---
description: End the meeting — stop the loop, mark the session ended, synthesize proposed Plane work items from the full transcript, confirm scope, then create them in Plane.
---

# /meeting-end

Close the active meeting and turn it into reviewed Plane work items.

## Steps

1. **Read settings** (`.claude/analyst-companion.local.md`): `aimeet_base_url`,
   `session_root`, `plane_base_url`, `plane_workspace_slug`, `plane_project`. Read the
   active session id from the most recent `state.json` under `session_root` (or ask the
   user if ambiguous).

2. **Mark ended** so the console shows "Koosolek lõpetatud" and the loop stops:

   ```bash
   curl -s -XPOST "${aimeet_base_url}/sessions/<id>/end"
   ```

3. **Synthesize work items.** Read the full `<session_root>/<id>/transcript.md` plus the
   accumulated `needs` in `state.json`. Produce a concise list of proposed Plane work
   items. For each: a short Estonian **title**, an HTML **description** (context + what
   the customer asked + acceptance hint), and a **priority** (urgent/high/medium/low/none).
   Write the proposal to `<session_root>/<id>/work-items.md` for the record.

4. **Confirm scope with the user.** Show the proposed titles + priorities and ask for
   approval/edits BEFORE writing anything to Plane. Honor edits, drops, and merges.

5. **Create approved items in Plane.** For each approved item, write its HTML body to a
   temp file and call the client:

   ```bash
   PLANE_API_TOKEN="$PLANE_API_TOKEN" PLANE_BASE_URL="${plane_base_url}" \
   python "${CLAUDE_PLUGIN_ROOT}/scripts/plane_client.py" create \
     --workspace "${plane_workspace_slug}" --project "${plane_project}" \
     --name "<title>" --description-html-file /tmp/wi-<n>.html --priority "<priority>"
   ```

   If `PLANE_API_TOKEN` is unset, stop and ask the user to export it. Collect the returned
   ids.

6. **Report.** List the created work items with their Plane ids/names. Note that the
   transcript and `work-items.md` remain in the session dir for reference.
````

- [ ] **Step 2: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add plugins/analyst-companion/commands/meeting-end.md && git commit -q -m "feat(analyst-companion): /meeting-end command"
```

---

### Task C4: Plugin README

**Files:**
- Create: `plugins/analyst-companion/README.md`

- [ ] **Step 1: Write `README.md`**

````markdown
# analyst-companion

A real-time analyst for in-person customer meetings. It transcribes the room mic
(self-hosted Whisper / Estonian), shows live clarifying questions on a Tailscale-only
web console, lets you talk to Claude mid-meeting ("Claude, kas sa näed…") using the
on-screen Chrome context, and creates reviewed Plane work items when the meeting ends.

## Architecture

```
room mic → aimeet console (VAD chunks) → meeting-capture svc → stt-api
   → transcript.md (shared volume) → /loop reads delta
      ├─ general talk  → questions.json   ─┐
      └─ "Claude, …"   → act (+chrome) → responses.json ─┤
                                                         ▼
                         aimeet page polls /feed → renders panels
on /meeting-end → synthesis → scope confirm → Plane work items
```

The transcript file is the seam decoupling continuous audio from Claude's turn-based loop.

## Requirements

- The **`meeting-capture`** service deployed (see `/mnt/data/ai/aimeet`), fronted by Caddy
  at `aimeet.r-53.com`, **Tailscale-only**.
- The existing **`stt-api`** (Speaches) on `est-datalake-net`.
- A self-hosted **Plane** instance + a workspace API token in `PLANE_API_TOKEN`.
- **claude-in-chrome** MCP connected to the browser showing the discussed screen.
- External tools: `curl`, `python3`.

## Setup

1. Deploy the capture service (`/mnt/data/ai/aimeet`: `docker compose up -d --build`).
2. Copy `analyst-companion.local.md.example` → `.claude/analyst-companion.local.md` and
   fill in `plane_workspace_slug` + `plane_project`.
3. `export PLANE_API_TOKEN=<workspace token>`.

## Use

- `/meeting-start` — opens a session; open the printed `aimeet.r-53.com/r/<id>` URL on the
  meeting laptop, hit **Salvesta**, allow the mic.
- During the meeting: read the **Open questions** panel; say **"Claude, …"** to ask
  Claude something (it can look at your Chrome tab).
- `/meeting-end` — synthesizes proposed work items, confirms scope, creates them in Plane.

## Limits

- Voice round-trip ≈ 10–15s (VAD flush + transcription + loop tick) — not instant.
- No speaker diarization (content-only).
- "Claude" wake word is matched against a configurable spelling list — tune `wake_words`
  in settings if `large-v3` mishears it.
````

- [ ] **Step 2: Commit**

```bash
cd /mnt/data/ai/claude-plugins && git add plugins/analyst-companion/README.md && git commit -q -m "docs(analyst-companion): plugin README"
```

---

## Phase D — end-to-end verification

### Task D1: Full dry-run rehearsal (manual)

**Files:** none (verification only)

- [ ] **Step 1: Service tests green**

Run: `cd /mnt/data/ai/aimeet && python -m pytest tests/ -v`
Expected: all pass.

- [ ] **Step 2: Plugin tests green**

Run: `cd /mnt/data/ai/claude-plugins/plugins/analyst-companion/scripts && python -m pytest -v`
Expected: all pass.

- [ ] **Step 3: Live rehearsal.** With the service deployed and `.claude/analyst-companion.local.md` configured, run `/meeting-start`, open the console over Tailscale, record yourself saying a few requirement sentences and one *"Claude, kas sa näed seda akent?"*. Confirm: transcript lines appear; the You↔Claude panel shows a Chrome-aware answer within ~15s; the Open questions panel populates.

- [ ] **Step 4: End-to-end close.** Run `/meeting-end`; confirm the proposal lists work items, the scope-confirm prompt appears, and after approval the items show up in `plan.r-53.com`. Verify `work-items.md` and `transcript.md` remain in the session dir.

- [ ] **Step 5: Bump + sync versions if any fix commits were needed** (repo rule: plugin.json and marketplace.json must match). No version bump needed for the initial `0.1.0`.

---

## Self-Review

**Spec coverage:**
- In-person room mic → A5 record page (`getUserMedia`). ✓
- stt-api unchanged, Estonian `large-v3` → A3/A4 (`STT_MODEL`/`STT_LANGUAGE`), A6 compose env. ✓
- Live clarifying questions → C1 step 5, A5 questions panel. ✓
- Voice commands ("Claude, …") + Chrome context → A1/A4 wake detection, C1 step 3 (claude-in-chrome). ✓
- aimeet.r-53.com bidirectional page → A5, feed polling. ✓
- Plane-only output + scope confirm → B1 client, C3 (confirm before writes). ✓
- Tailscale-only → A6 `Caddyfile.snippet` (`bind` tailnet IP). ✓
- Content-only / no diarization → not implemented (correct). ✓
- Config not hardcoded → B2 settings template, `PLANE_API_TOKEN` from env. ✓
- Latency ~10–15s expectation → README "Limits". ✓
- Session layout (transcript/questions/responses/state/work-items) → A2 + C1. ✓

**Placeholder scan:** Config placeholders (`<your-workspace-slug>`, `100.x.y.z`) are
intentional user-supplied values in templates, not plan gaps. No code steps are deferred.

**Type consistency:** `find_command`, `create_session`, `append_transcript`,
`enqueue_command`, `read_commands`, `feed`, `end_session`, `transcribe`, `build_payload`,
`Plane.create_work_item` names match across service code, tests, and the FastAPI routes.
Feed shape `{questions, responses, ended}` is consistent between `sessions.feed`,
`record.html` polling, and the C1 skill. Session-file names match between A2, C1, C2, C3.
