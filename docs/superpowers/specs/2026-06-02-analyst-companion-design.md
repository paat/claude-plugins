# analyst-companion — design

**Date:** 2026-06-02 (v1) · **2026-06-03 (v2)**
**Status:** v1 implemented; **v2 implemented & verified end-to-end (Steps 1–4) on RTX 5090 (cuda True, `large-v3` on sm_120, Sortformer loaded, relay+persistence proven); live two-speaker mic rehearsal + Plane close pending**
**Audience for the plugin:** Estonian SaaS founders running in-person customer meetings (generic; all site-specific values are config, not hardcoded).

## v2 changes (what's different from v1)

v1 shipped batch transcription (browser VAD-chunks → `stt-api`) with **no speaker
labels** and a record-time-flushed live transcript. v2 reverses the two decisions that
limited it, on the back of research into 2025/2026 streaming diarization:

1. **Real-time transcription.** Replace browser VAD-chunking + `stt-api` calls with
   **WhisperLiveKit** (WLK) — a self-hosted FastAPI server doing *simultaneous* streaming
   STT (Simul-Whisper / AlignAtt) over a WebSocket. Words appear as they're spoken, not
   after a pause.
2. **Speaker-attributed dialog view.** Enable WLK's **Streaming Sortformer** diarization
   (2025 SOTA). The transcript becomes a chat-style dialog with `Speaker 1/2/…` labels you
   can rename live. (v1's "content is enough / no diarization" decision is **reversed**.)
3. **Same engine, same language.** WLK uses the `faster-whisper` backend with the same
   Estonian `large-v3` model v1 used; diarization is acoustic/language-agnostic, so
   Estonian carries over unchanged.

Everything else (Tailscale-only, Plane-only output, the transcript-file seam, the plugin
loop, scope-confirm before Plane writes) is unchanged. The plugin barely moves; the
`aimeet` service is reworked.

## Problem

During an in-person customer meeting you want a real-time "analyst companion":

1. It transcribes the meeting **live** (single room mic, Estonian) and shows it in the
   web console as a **speaker-attributed dialog** (who said what).
2. It continuously surfaces **clarifying / open questions** so you capture what the
   customer *really* needs — not just what they said.
3. You can **talk to it** mid-meeting (e.g. *"Claude, kas sa näed softbuilder akent,
   mis mul kroomis lahti on?"*) and it answers, using the Chrome screen as context.
4. At the end you get a reviewed list of **Plane work items** created in
   `plan.r-53.com`.

## Existing infra this builds on

- **`stt-api`** (`/mnt/data/ai/stt-api`) — Speaches / faster-whisper, Estonian
  `large-v3`. **No longer on this path in v2** (WLK does STT). Left untouched — other
  datalake consumers still use it. aimeet simply stops calling it.
- **WhisperLiveKit** ([QuentinFuxa/WhisperLiveKit](https://github.com/QuentinFuxa/WhisperLiveKit),
  Apache-2.0) — **NEW container** in v2. Simultaneous streaming STT + diarization over a
  WebSocket. `faster-whisper` backend (`large-v3`, `--lan et`), Streaming Sortformer
  diarization (`--diarization --diarization-backend sortformer`). Runs on the GPU box,
  internal-only on `est-datalake-net`. WebSocket endpoint `/asr`; `--pcm-input` accepts raw
  s16le PCM and bypasses ffmpeg. **Install reality (whisperlivekit 0.2.21, verified):** the
  diarization extra is `whisperlivekit[diarization-sortformer]` (pulls `nemo_toolkit[asr]`);
  streaming Sortformer isn't in any NeMo release, so install `nemo_toolkit[asr]` from git
  `main`. On Blackwell (RTX 5090, sm_120) pin **CUDA-12.8 torch** (`torch==2.8.0`,
  `--index-url …/cu128`) — default PyPI torch is now a CUDA-13 build and ctranslate2 needs
  `libcublas.so.12`.
- **Plane** (`/mnt/data/ai/plane`) — self-hosted Plane CE at `https://plan.r-53.com`,
  Caddy-fronted. The webtop is on the `plane_default` network, so it reaches Plane
  directly. Auth: `X-API-Key`. The working create endpoint on this instance is
  `/api/v1/workspaces/{ws}/projects/{project_id}/issues/` (verified against the proven
  `migrate_github_issues.py`); the client resolves a project name → id first.
- **claude-in-chrome MCP** — screenshot / read the active tab on demand.
- **Caddy + r-53.com** — fronts `aimeet.r-53.com` (Tailscale-only).
- **`loop` skill** — drives the turn-based live loop.

## Core architectural seam (unchanged)

Claude Code is **turn-based**, not a continuous audio consumer. The seam: the capture
service maintains a rolling `transcript.md`; Claude **polls the delta** on a loop. Claude
never touches audio. v2 only changes *how* lines get into `transcript.md` (live, with a
speaker prefix) — not the seam itself.

## Decisions

| Decision | v1 | v2 |
|---|---|---|
| Audio source | In-person, single room mic | unchanged |
| Transcription | Batch VAD chunks → `stt-api` | **Live streaming → WhisperLiveKit** |
| Diarization | None — content only | **Streaming Sortformer; `Speaker N`, renamable** |
| Live transcript UI | Lines appended on chunk flush | **Speaker dialog, live partial words** |
| Output target | Plane only, scope-confirm before writes | unchanged |
| Live interaction surface | `aimeet.r-53.com` bidirectional page | unchanged |
| Response mode | Text on the aimeet page | unchanged |
| Wake word | "Claude" + configurable Estonian spellings | unchanged |
| Exposure | Tailscale-only | unchanged |
| Hardware | (n/a) | **GPU box (aibox)** for WLK |

## Components

### 1. `wlk` — WhisperLiveKit (NEW container)

- **Image:** thin Dockerfile, pinned: **CUDA-12.8 torch** (`torch==2.8.0 --index-url
  …/cu128`, for Blackwell sm_120 + `libcublas.so.12`), `whisperlivekit[diarization-sortformer]`,
  and `nemo_toolkit[asr]` from git `main` (streaming Sortformer is unreleased). **GPU
  runtime** (`--gpus all`). ~7.3 GB VRAM loaded.
- **Command:** `wlk --backend faster-whisper --model large-v3 --lan et --diarization
  --diarization-backend sortformer --pcm-input --host 0.0.0.0 --port 8000`. (Verified
  against 0.2.21: the flag is `--lan`, not `--language`.) Fallback if VRAM is tight
  alongside vLLM/ComfyUI: `--model large-v3-turbo`.
- **Network:** `est-datalake-net`, **internal-only** (no Caddy front of its own; reached
  only through the aimeet relay).
- **Contract (verified against real frames):** WebSocket `/asr`. Client sends raw **s16le
  mono 16 kHz PCM** bytes; server streams JSON result messages and a
  `{"type":"ready_to_stop"}` marker. Each segment carries text, an **int `speaker`** (with
  **`-2` = silence**, skipped), and **timestamps as strings** like `"0:00:00.58"`
  (`H:MM:SS.ss`) — not numbers. The result schema is consumed **only by the browser** (see
  component 3) — the Python side never parses it.

### 2. `aimeet` — meeting-capture service (REWORKED, not rebuilt)

Same FastAPI app, container, network, shared volume, Caddy front. Changes:

- **Removed:** `app/stt.py`, the `POST /chunk` audio endpoint, the browser VAD-chunking.
  WLK subsumes all of it.
- **New `WS /sessions/{id}/stream`** — a **transparent relay**: forwards client PCM bytes
  up to `wlk:/asr` and relays WLK's messages back down, both directions, byte/text
  passthrough. Validates the session id, then pipes. This keeps WLK internal-only and the
  aimeet origin the single exposed surface. It does **not** parse WLK JSON.
- **New `POST /sessions/{id}/line`** — body `{seconds, text, speaker?}`. The browser posts
  each *finalized* speaker-tagged line here. Deterministic + testable: append
  `[mm:ss] <speaker>: text` to `transcript.md`, run wake-word detection, enqueue commands.
  This is where transcript persistence + wake detection live (was the `/chunk` body in v1).
- **New `POST /sessions/{id}/speaker`** — body `{speaker, name}`. Live rename; writes a
  `speakers.json` map (raw `Speaker N` id → display name).
- **`GET /feed`** now also returns `speakers` (the rename map) so the page renders names.
- **`sessions.append_transcript`** gains an optional `speaker` arg; `wake.py` unchanged.

### 3. Record page (`/r/{id}`) — REWORKED

One unified Estonian SPA (the v1 3-panel layout stays). Changes in the recorder + transcript panel:

- **Capture:** `getUserMedia` → `AudioContext({sampleRate:16000})` + an **AudioWorklet**
  that converts Float32 → **s16le PCM**; stream the PCM bytes over a WebSocket to
  `/sessions/{id}/stream` (which relays to WLK).
- **Render:** `parseWlk()` interprets WLK's result messages → **speaker dialog** (chat
  bubbles grouped by `Speaker N`), in-flight partial shown live, finalized text settling in
  place. This is the one place WLK's schema is interpreted. **Verified fix:** it converts
  the string timestamps via a `toSeconds()` helper (`Math.round` on a `"H:MM:SS.ss"` string
  yields `NaN` → `/line` 422 → empty transcript) and skips the `speaker === -2` silence
  sentinel. The committed `aimeet` `record.html` is the source of truth.
- **Persist:** on each *finalized* segment, `POST /line` with `{seconds, speaker, text}`.
- **Rename:** click a speaker label → inline edit → `POST /speaker`; names resolved from
  the `/feed` `speakers` map on every poll.
- **Unchanged:** Open-questions + You↔Claude panels, `/feed` polling every ~2s, mic
  release on stop/`ended`/`beforeunload`.

### 4. `analyst-companion` plugin (this repo) — minor updates

```
plugins/analyst-companion/
  .claude-plugin/plugin.json        # version bump 0.1.0 → 0.2.0
  commands/meeting-start.md          # unchanged
  commands/meeting-end.md            # synthesis attributes needs to speakers
  skills/meeting-companion/SKILL.md  # ingest speaker-prefixed lines
  scripts/plane_client.py            # unchanged (/issues/ + resolve_project)
  README.md                          # real-time + diarization; updated Limits
  analyst-companion.local.md.example # unchanged keys
```

- **SKILL.md:** transcript lines now read `[mm:ss] Speaker N: text`. Fold *who* wants what
  into the needs model; questions may target a specific speaker. Speaker display names are
  in `speakers.json` (resolve when synthesizing).
- **`/meeting-end`:** synthesis can attribute requests to named speakers; otherwise
  identical (full-transcript synthesis → scope confirm → Plane via `plane_client.py`).
- **`/meeting-start`:** unchanged (mints the session, prints the URL, starts the loop).

### 5. Configuration — `.claude/analyst-companion.local.md` (unchanged keys)

```yaml
plane_base_url: https://plan.r-53.com
plane_workspace_slug: <slug>
plane_project: <name-or-uuid>
aimeet_base_url: https://aimeet.r-53.com
session_root: /mnt/data/ai/analyst-companion/sessions
loop_interval_seconds: 9
question_refresh_seconds: 60
wake_words: [claude, klaud, kloud, klod, klood]
```

Plane token from `PLANE_API_TOKEN` env. STT model/language/diarization are **WLK service**
config (`wlk` container flags), not plugin settings — the plugin never calls WLK directly.

## Data flow (v2)

```
room mic → record page: AudioWorklet → s16le PCM
   → WS /sessions/{id}/stream  ──relay──►  wlk:/asr  (faster-whisper + Sortformer)
        ◄───────── speaker-tagged result JSON ─────────┘
   browser renders speaker dialog (live partial + final)
   browser POSTs each finalized line → /line
        → transcript.md  ([mm:ss] Speaker N: text)   (shared volume)
        → wake-word hit → commands.jsonl
             │
   Claude /loop polls transcript.md delta
        ├─ general talk  → questions.json   ─┐
        └─ "Claude, …"   → act (+chrome) → responses.json ─┤
                                                           ▼
              aimeet page polls /feed (questions+responses+speakers) → renders panels
on /meeting-end → full-transcript synthesis (speaker-attributed) → scope confirm → Plane
```

## Session directory layout

```
/mnt/data/ai/analyst-companion/sessions/<id>/
  transcript.md      # [mm:ss] <speaker>: text   (append-only; raw Speaker N ids)
  speakers.json      # { "Speaker 1": "Mari", ... }  display-name overrides (NEW)
  commands.jsonl     # wake-word hits {seconds, command}
  questions.json     # current open/clarifying questions (loop writes)
  responses.json     # You↔Claude exchange log (loop writes)
  state.json         # loop offsets + running needs-model
  screenshots/       # chrome captures referenced by responses
  work-items.md      # end-of-meeting proposed items (pre-confirm)
  ended              # marker file
```

`active` pointer (`<session_root>/active`) is written by `/meeting-start`, removed by
`/meeting-end` — the loop reads it first each tick to learn the session id.

## Error handling

- **WLK down / WS drops:** the relay closes the client socket; the page shows a
  non-blocking "transkriptsioon ühendus katkes — proovi uuesti" notice and retries the
  WebSocket. No audio is persisted server-side until a line is finalized, so a reconnect
  simply resumes; already-finalized lines are safe in `transcript.md`.
- **Diarization wobble:** single far-field mic → Sortformer may merge/split speakers or
  relabel. Generic labels until renamed; misattribution affects only display + synthesis
  hints, never the loop's stability.
- **Plane write fails:** `plane_client.py` retries on 429; other errors abort the push and
  leave `work-items.md` intact — re-run `/meeting-end`.
- **Wake word missed/false:** configurable variant list; one-line effect, self-corrects.
- **claude-in-chrome not connected:** the loop reports it in the response panel rather
  than failing.

## Security / privacy (unchanged)

- `aimeet.r-53.com` is **Tailscale-only** — the Caddy vhost is gated to the tailnet/CGNAT
  range (`remote_ip 100.64.0.0/10`), returning 403 off-tailnet (verified: tailnet 200,
  non-tailnet 403). `bind <tailnet-ip>` does **not** work in a containerized Caddy — use the
  `remote_ip` matcher. WLK has **no**
  public/tailnet front of its own — it's reachable only through the aimeet relay on
  `est-datalake-net`. Session id is a long unguessable token in the URL.
- Meeting audio is not PHI; no host-port prohibition, but WLK and the relay stay internal.

## Key assumptions

1. Your live "second screen" is `aimeet.r-53.com` open on the meeting laptop.
2. For Claude to "see the discussed screen," the demo runs in the Chrome instance
   claude-in-chrome is connected to.
3. **GPU available on aibox** — verified: RTX 5090 (Blackwell sm_120); `large-v3` +
   Sortformer load in ~7.3 GB VRAM alongside existing models (turbo model is the escape hatch).
4. Voice-command round-trip is faster than v1 (no VAD flush wait) but still **not
   sub-second** — streaming STT + loop tick ≈ a few seconds.

## Explicitly out of scope (YAGNI for v2)

- TTS spoken replies (still deferred).
- Speaker **identity** recognition (names are manual; Sortformer only separates voices).
- Remote / multi-mic meetings.
- GitHub as an output target (Plane only).
- A rigid voice-command grammar — Claude interprets intent freely.
- Server-side parsing of WLK's result schema (kept in the browser by design).
