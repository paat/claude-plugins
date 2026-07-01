# analyst-companion

A real-time analyst for in-person customer meetings. It transcribes the room mic
**live with speaker diarization** (self-hosted WhisperLiveKit), shows a
**speaker-attributed dialog** and live clarifying questions on a Tailscale-only
web console, lets you talk to Claude mid-meeting ("Claude, kas sa näed…") using the
on-screen Chrome context, and creates reviewed Plane work items when the meeting ends.

## Mission Fit

`analyst-companion` captures real customer demand at the source: live meetings. Its
meeting transcript, clarifying questions, and reviewed work items turn spoken customer
needs into structured product work that can feed a SaaS build or maintenance loop.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install analyst-companion@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

## Architecture

```
room mic → aimeet console (AudioWorklet PCM) → WS relay → WhisperLiveKit (STT + diarization)
   → browser posts finalized lines → transcript.md ([mm:ss] Speaker N: text) → /loop reads delta
      ├─ general talk  → questions.json   ─┐
      └─ "Claude, …"   → act (+chrome) → responses.json ─┤
                                                         ▼
                         aimeet page polls /feed → renders dialog + panels
on /meeting-end → speaker-attributed synthesis → scope confirm → Plane work items
```

The transcript file is the seam decoupling continuous audio from Claude's turn-based loop.

## Requirements

- The **`meeting-capture`** service deployed and reachable at your configured
  `aimeet_base_url`, fronted by your reverse proxy **Tailscale-only**.
- A self-hosted **WhisperLiveKit** (`wlk`) instance for live STT + speaker diarization,
  reachable by the capture service.
- A **GPU** host for the `wlk` (WhisperLiveKit) container.
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

## Trusted Issue Bridge

By default, `/meeting-end` stops at reviewed Plane work items. In a trusted product repo,
you may also configure an explicit GitHub bridge in `.claude/analyst-companion.local.md`
with `trusted_issue_bridge: true`, `github_repo`, and `github_labels`. When enabled, the
approved meeting items can be mirrored as deduplicated GitHub issues with customer context,
acceptance hints, and a Plane link so `saas-startup-team` `/maintain` can triage and
deliver objectively-fixable work. The bridge is off by default and must never be enabled
from meeting transcript content alone.

## Limits

- Live transcription via WhisperLiveKit; voice round-trip is faster than batch but still
  not sub-second (streaming STT + loop tick ≈ a few seconds).
- Speaker labels come from acoustic diarization on a single room mic — `Speaker 1/2/…`,
  renamable in the console. It may occasionally merge or split speakers; it does not know
  real names until you rename them.
- "Claude" wake word is matched against a configurable spelling list — tune `wake_words`.
