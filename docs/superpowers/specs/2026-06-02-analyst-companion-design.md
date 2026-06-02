# analyst-companion — design

**Date:** 2026-06-02
**Status:** Approved design, pre-implementation
**Audience for the plugin:** Estonian SaaS founders running in-person customer meetings (generic; all site-specific values are config, not hardcoded).

## Problem

During an in-person customer meeting you want a real-time "analyst companion":

1. It transcribes the meeting (single room mic, Estonian).
2. It continuously surfaces **clarifying / open questions** so you capture what the
   customer *really* needs — not just what they said.
3. You can **talk to it** mid-meeting (e.g. *"Claude, kas sa näed softbuilder akent,
   mis mul kroomis lahti on?"*) and it answers, using the Chrome screen as context.
4. At the end you get a reviewed list of **Plane work items** created in
   `plan.r-53.com`.

## Existing infra this builds on (no changes required to either)

- **`stt-api`** (`/mnt/data/ai/stt-api`) — Speaches / faster-whisper, Estonian
  `Systran/faster-whisper-large-v3`, OpenAI-compatible `POST /v1/audio/transcriptions`.
  Internal-only on docker network `est-datalake-net`. **Batch, not streaming. No
  diarization** — accepted: content-only, no speaker labels.
- **Plane** (`/mnt/data/ai/plane`) — self-hosted Plane CE at `https://plan.r-53.com`,
  Caddy-fronted. This webtop container is already on the `plane_default` network, so it
  reaches Plane directly. Auth: `X-API-Key` workspace token. A reusable `Plane` client
  class already exists in `migrate_github_issues.py` (work-item create, comments, state
  + label mapping) and is lifted into the plugin.
- **claude-in-chrome MCP** — already connected; used to screenshot / read the active tab
  on demand.
- **Caddy + r-53.com** — fronts a new subdomain `aimeet.r-53.com`.
- **`loop` skill** — drives the turn-based live loop.

## Core architectural seam

Claude Code is **turn-based**, not a continuous audio consumer. The seam that makes
"live" work: a capture service continuously writes a rolling `transcript.md`; Claude
**polls the delta** on a loop. Claude never touches audio.

## Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Audio source | In-person, single room mic |
| Output target | **Plane only** (`plan.r-53.com`), with a light end-of-meeting scope confirm before writes |
| Live interaction surface | **`aimeet.r-53.com`** bidirectional page (not the raw webtop terminal) |
| Diarization | None — content is enough |
| Capture mechanism | **Browser record-page** (zero-install in the room; reuses Caddy + `est-datalake-net`) |
| Response mode | **Text on the aimeet page** (silent; won't talk over the customer). TTS is a deferred enhancement. |
| Wake word | **"Claude"**, matched against a **configurable list of Estonian STT spellings** (e.g. `claude, klaud, kloud, klod, klood`), tuned against real audio |

## Components

### 1. `meeting-capture` service (new container)

- **Stack:** FastAPI + uvicorn (matches `ocr-api`, `est-saas-datalake`).
- **Network:** `est-datalake-net` (to reach `stt-api:8000` by name). Caddy fronts
  `aimeet.r-53.com`.
- **Shared volume:** `/mnt/data/ai/analyst-companion` — bind-mounted into both the
  service and the webtop, so Claude reads/writes session files directly.
- **Endpoints:**
  - `POST /sessions` → mint a long unguessable session id; create session dir.
  - `GET  /r/{id}` → the record-page SPA (recorder + 3 live panels).
  - `POST /sessions/{id}/chunk` → receive an audio segment, forward to
    `stt-api` (`model=large-v3`, `language=et`), append `[mm:ss] text` to
    `transcript.md`.
  - `GET  /sessions/{id}/feed` → returns `questions.json` + `responses.json` for the
    page to poll.
  - `POST /sessions/{id}/end` → mark session ended.
- **Record page (`/r/{id}`):** `getUserMedia` + **VAD-based** chunking (flush a segment
  on a speech pause) for responsive commands; uploads each segment to `/chunk`. Renders
  three regions: **live transcript**, **Open questions**, **You ↔ Claude**. Polls
  `/feed` every ~2s.

### 2. `analyst-companion` plugin (this repo)

```
plugins/analyst-companion/
  .claude-plugin/plugin.json
  commands/meeting-start.md      # mint session, print aimeet URL, start the loop
  commands/meeting-end.md        # stop loop, synthesize, confirm, push to Plane
  skills/meeting-companion/SKILL.md
  scripts/plane_client.py        # lifted from migrate_github_issues.py
  README.md
```

- **`/meeting-start`** → `POST /sessions`, print `https://aimeet.r-53.com/r/<id>` to open
  on the laptop, start the live loop.
- **Live loop** (`loop` skill, ~8–10s cadence). Each tick:
  1. Read new `transcript.md` lines since last offset.
  2. **Classify each line:**
     - **Direct address** (starts with a wake-word variant) → strip wake word, interpret
       the remainder as a command, act (e.g. claude-in-chrome screenshots the active tab
       to answer *"kas sa näed…"*), append the reply to `responses.json`.
     - **General talk** → update the running needs-model.
  3. Refresh `questions.json` (open / clarifying questions).
- **`/meeting-end`** → stop the loop, run a full-transcript synthesis into proposed work
  items, show them for a **quick scope confirm**, then create the approved set in Plane
  via `plane_client.py`.

### 3. Configuration — `.claude/analyst-companion.local.md`

Per repo rule (plugins stay generic), all site-specific values live in a local settings
file with YAML frontmatter — **never hardcoded**:

```yaml
plane_base_url: https://plan.r-53.com
plane_workspace_slug: <slug>
plane_project: <name-or-uuid>
aimeet_base_url: https://aimeet.r-53.com
session_root: /mnt/data/ai/analyst-companion
stt_model: Systran/faster-whisper-large-v3
stt_language: et
loop_interval_seconds: 9
wake_words: [claude, klaud, kloud, klod, klood]
```

Plane token comes from the `PLANE_API_TOKEN` env var (not stored in the file).

## Data flow

```
room mic → aimeet record page (VAD chunks) → /chunk → capture svc → stt-api
   → transcript.md (shared volume)
        │
        └─ Claude /loop reads delta
             ├─ general talk  → questions.json   ─┐
             └─ "Claude, …"   → act (+chrome) → responses.json ─┤
                                                                ▼
                          aimeet page polls /feed → renders both panels
on /meeting-end → full-transcript synthesis → scope confirm → Plane work items
```

## Session directory layout

```
/mnt/data/ai/analyst-companion/sessions/<id>/
  transcript.md      # [mm:ss] line per transcribed chunk (append-only)
  questions.json     # current open/clarifying questions
  responses.json     # You↔Claude exchange log
  screenshots/       # chrome captures referenced by responses
  state.json         # loop offset + running needs-model
  work-items.md      # end-of-meeting proposed items (pre-confirm)
```

## Error handling

- **stt-api down / chunk fails:** record page retries the chunk; service returns the
  error; the panel shows a non-blocking "transcription lagging" notice. Audio is not lost
  (buffered client-side until acked).
- **Plane write fails:** `plane_client.py` already retries on 429; other errors abort the
  push and leave `work-items.md` intact so nothing is lost — re-run `/meeting-end`.
- **Wake word missed/false:** configurable variant list; misclassification only affects
  one line and self-corrects next tick.
- **claude-in-chrome not connected / wrong browser:** the loop reports it in the response
  panel ("ei näe brauseriakent — kontrolli ühendust") rather than failing the loop.

## Security / privacy

- `aimeet.r-53.com` is **Tailscale-only** (decided) — Caddy serves it only on the
  tailnet, never the public internet, since transcripts may contain commercially
  sensitive customer detail. Session id is additionally a long unguessable token in the
  URL.
- Meeting audio is **not** PHI (unlike AI Doctor), so no host-port prohibition — but we
  still keep `stt-api` internal and only expose the capture service.

## Key assumptions

1. Your live "second screen" is `aimeet.r-53.com` open in a browser on the meeting laptop.
2. For Claude to "see the discussed screen," the demo runs in the **Chrome instance
   claude-in-chrome is connected to**.
3. Voice-command round-trip ≈ **10–15s** (VAD flush + transcription + loop tick). Not
   sub-second; the turn-based model can't do instant.

## Explicitly out of scope (YAGNI for v1)

- TTS spoken replies (deferred; design leaves room).
- Speaker diarization.
- Remote / multi-mic meetings.
- GitHub as an output target (Plane only).
- A rigid voice-command grammar — Claude interprets intent freely.
