# analyst-companion

A real-time analyst for in-person customer meetings. It transcribes the room mic
(self-hosted Whisper / Estonian), shows live clarifying questions on a Tailscale-only
web console, lets you talk to Claude mid-meeting ("Claude, kas sa näed…") using the
on-screen Chrome context, and creates reviewed Plane work items when the meeting ends.

## Architecture

```
room mic → capture console (VAD chunks) → meeting-capture svc → Whisper STT
   → transcript.md (shared volume) → /loop reads delta
      ├─ general talk  → questions.json   ─┐
      └─ "Claude, …"   → act (+chrome) → responses.json ─┤
                                                         ▼
                         console page polls /feed → renders panels
on /meeting-end → synthesis → scope confirm → Plane work items
```

The transcript file is the seam decoupling continuous audio from Claude's turn-based loop.

## Requirements

- The **`meeting-capture`** service deployed and reachable at your configured
  `aimeet_base_url`, fronted by your reverse proxy **Tailscale-only**.
- A self-hosted **Whisper STT** endpoint (OpenAI `/v1/audio/transcriptions` contract,
  e.g. Speaches) reachable by the capture service.
- A self-hosted **Plane** instance + a workspace API token in `PLANE_API_TOKEN`.
- **claude-in-chrome** MCP connected to the browser showing the discussed screen.
- External tools: `curl`, `python3`.

## Setup

1. Deploy the `meeting-capture` service (see its own repo) behind your Tailscale-only
   reverse proxy.
2. Copy `analyst-companion.local.md.example` → `.claude/analyst-companion.local.md` and
   fill in `plane_workspace_slug`, `plane_project`, `aimeet_base_url`, `plane_base_url`,
   and `session_root`.
3. `export PLANE_API_TOKEN=<workspace token>`.

## Use

- `/meeting-start` — opens a session; open the printed console URL on the meeting laptop,
  hit **Salvesta**, allow the mic.
- During the meeting: read the **Open questions** panel; say **"Claude, …"** to ask
  Claude something (it can look at your Chrome tab).
- `/meeting-end` — synthesizes proposed work items, confirms scope, creates them in Plane.

## Limits

- Voice round-trip ≈ 10–15s (VAD flush + transcription + loop tick) — not instant.
- No speaker diarization (content-only).
- "Claude" wake word is matched against a configurable spelling list — tune `wake_words`
  in settings if the STT model mishears it.
