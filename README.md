# Ultron — The Ultimate Jarvis

> A native macOS AI assistant that combines the polished voice + HUD experience of **[JarvisHUD](https://github.com/Parthee-Vijaya/JarvisHUD)** with the skills, connectors, and local-first inference of **[OpenJarvis](https://github.com/open-jarvis/OpenJarvis)**.

Ultron is a single-user macOS menu-bar app that:
- Answers **locally** when it can (Ollama / MLX), falls back to cloud (Gemini / Claude) only when model capability requires it.
- Extends its own tool-repertoire automatically when new OpenJarvis skills are installed.
- Shows you **why** each decision was made — every LLM call is traced with provider, model, tokens, latency, and an energy estimate.

Status: **pre-alpha**, Phase 1 just started. See the [roadmap](#roadmap) below.

---

## Why this project exists

**JarvisHUD** (the author's existing project) already has a production-grade native macOS shell: menu-bar presence, always-on-top HUD, glassmorphism Cockpit with 15 live tiles, hotkey-driven voice modes, WhisperKit local STT, streaming chat with semantic search, an MCP client, agent tool-use. What it lacks: a skills ecosystem, external connectors (Gmail / Calendar / iMessage / Health), pluggable local inference, energy-aware routing.

**[OpenJarvis](https://github.com/open-jarvis/OpenJarvis)** (Stanford Scaling Intelligence Lab, Apache 2.0) has exactly what JarvisHUD lacks: **150+ skills** via the [agentskills.io](https://agentskills.io) spec, connectors for Gmail / Google Calendar / Apple Health / iMessage / Slack / GitHub, pluggable inference (Ollama / vLLM / SGLang / llama.cpp / MLX), energy-aware routing ("Intelligence Per Watt"), a Morning Digest agent, and DSPy/GEPA learning loops. What it lacks: a polished native macOS UI.

Both projects natively speak **[MCP](https://modelcontextprotocol.io)**. That's the connective tissue. Ultron keeps JarvisHUD's Swift shell and runs OpenJarvis as an embedded Python sidecar exposed over stdio MCP — the existing `MCPClient` is the bridge.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Ultron.app  (native macOS, Swift 6.3, SwiftUI + AppKit)         │
│                                                                  │
│  UI: HUD / Chat / Cockpit / Briefing / Widgets                   │
│   │                                                              │
│   ▼                                                              │
│  AgentService  ──▶  AgentToolRegistry                            │
│                        │                                         │
│                        ├─ NativeSkill   ← Ultron/Skills/         │
│                        │                                         │
│                        └─ MCPTool       ← MCPRegistry            │
│                                                                  │
│  AIProvider   ──▶  ProviderRouter  ─┬─ AnthropicProvider         │
│                      (new)          ├─ GeminiProvider            │
│                                     ├─ OllamaProvider (new)      │
│                                     └─ MLXProvider   (new)       │
│                                                                  │
│  EnergyMonitor ──▶ TraceStore (new, SQLite)                      │
│                                                                  │
│  Hotkey / Voice / WhisperKit / TTS (from JarvisHUD)              │
└──────────────────────────────────────────────────────────────────┘
          │ stdio JSON-RPC (existing MCPClient)
          ▼
┌──────────────────────────────────────────────────────────────────┐
│  ultron_sidecar  (Python 3.12, hermetic venv via uv)             │
│    ┌── OpenJarvis (git submodule, pinned to v0.1.1)              │
│    │     SkillManager / SyncEngine / InferenceRouter             │
│    │                                                             │
│    └── bridge.py:  exposes skills + connectors + digest          │
│                    as MCP tools over stdio                       │
└──────────────────────────────────────────────────────────────────┘
```

**Design choices:**
- **stdio MCP**, not XPC or embedded Python. JarvisHUD's `MCPClient` already handles this cleanly; no new IPC layer.
- **Hermetic Python venv** bundled via `uv` + pinned lockfile. No system Python dependency.
- **Hybrid native / Python:** latency-critical paths (provider routing, energy telemetry, trace store, HUD-level skills) are native Swift. Skills and connectors live in the Python sidecar.
- **Submodule, not fork.** OpenJarvis stays pinned to tagged releases; upstream bumps are submodule-pointer moves.

---

## Roadmap

Seven phases, ~7 weeks for a personal-use milestone (unsigned DMG). Public-release polish (Developer ID, notarization, Sparkle, localization, VoiceOver) is deferred.

| Phase | Goal | Branch |
|---|---|---|
| **1 — Sidecar foundation** | Python sidecar spawns, answers MCP `initialize`, logs structured | `ultron-phase-1-sidecar` (active) |
| **2 — OpenJarvis as MCP tools** | Skills, connectors, Morning Digest callable from Swift agent mode | `ultron-phase-2-mcp-bridge` |
| **3 — Native providers + router** | `OllamaProvider`, `MLXProvider`, `ProviderRouter` with battery-aware policy, `EnergyMonitor`, `TraceStore` | `ultron-phase-3-router` |
| **4 — Feature integration** | Morning Digest Cockpit tile + widget, Gmail/Calendar tiles, learning-loop UI | `ultron-phase-4-features` |
| **5 — Polish (personal)** | Smoke tests, expanded unit tests, unsigned DMG, README setup guide | `ultron-phase-5-polish` |

Future phases (post-v1):
- Public release — Developer ID signing, notarization, Sparkle auto-update
- Localization (Danish, English, German, Swedish) + VoiceOver audit
- Additional modes — Meeting recording, Clipboard history, Email drafting
- Wake word activation (Porcupine already scaffolded)

Full plan: [`docs/ultron-plan.md`](docs/ultron-plan.md) (to be added).

---

## Inherited from JarvisHUD (working today)

Ultron forks JarvisHUD's `Charlie` branch, so these features work out of the box:

**Voice modes**
| Mode | Hotkey | What it does |
|------|--------|-------------|
| Dictation | `⌥ Space` | Local WhisperKit large-v3 → text at cursor |
| VibeCode | `⌥ Space` | Spoken idea → structured AI coding prompt |
| Professional | `⌥ Space` | Dictation rewritten for professional communication |
| Q&A | `⌥ Q` | Gemini-grounded question answering with web search + citation chips |
| Vision | `⌥ ⇧ Space` | Screen analysis via Gemini vision |

**Cockpit dashboard** — 15 live tiles: Vejr, Sol, Luft/Måne, Nyheder, Trafikinfo (live Vejdirektoratet), Hjem/Rute commute with MapKit + EV chargers, System, Netværk, Ydelse, Handlinger, Fly over dig (ADS-B), Himmel (planets + ISS), Claude Code usage stats (sessions/tokens + projects/models).

**Briefing panel** — 6-source news (DR, Politiken, BBC, Guardian, Reddit, HN) + Denne dag i historien.

**Chat** — streaming replies, conversation history with semantic search (NLEmbedding), Spotlight indexing, agent mode with tool-call cards, image attachments, citation chips, Anthropic prompt caching.

**Agent mode** — tool-using Claude with file system ops, code execution, web search, MCP servers.

**Tech stack** — Swift 6.3, SwiftUI + AppKit hybrid, macOS 14+, Gemini 2.5 Flash/Pro, Claude Opus 4.7 / Sonnet 4.6 / Haiku, WhisperKit, MapKit, ScreenCaptureKit, HotKey SPM package.

---

## Coming via OpenJarvis (Phases 2-4)

- **Skills marketplace** — install community skills via `/skill install <id>`; each appears as a native tool in agent mode
- **Connectors** — Gmail unread, Google Calendar next event, Apple Health daily summary, iMessage recent threads, Slack, GitHub, Notion, Dropbox
- **Local inference** — Ollama + MLX as first-class `AIProvider`s, selected by battery state + task complexity heuristic
- **Energy-aware routing** — every LLM call records provider, reason, tokens, joules estimate; Settings pane shows distribution + local-vs-cloud savings
- **Morning Digest agent** — aggregates mail / calendar / news / weather; renders as Cockpit tile + widget with TTS narration
- **Learning loop** — thumbs-up/down on trace entries feed a DSPy/GEPA-style offline optimization run on the sidecar

---

## Installation

**Current state:** Ultron is pre-alpha. The Xcode project still uses JarvisHUD bundle IDs — a naming pass is the next Phase 1 task.

**Build from source:**

```bash
git clone --recurse-submodules https://github.com/Parthee-Vijaya/Ultron.git
cd Ultron
# Phase 1 is in progress; the sidecar scaffolding is not yet landed.
# For now, the inherited JarvisHUD experience works:
./run-dev.sh                                  # Debug build + launch
```

Requirements: Xcode 26+, macOS 14+ SDK, Swift 6.3. Ollama (for local LLM) lands in Phase 3.

After Phase 1 lands, setup will additionally require:
- `uv` (auto-bundled inside the app — no system install needed)
- First-launch onboarding runs `uv sync --frozen` to prepare the sidecar venv

---

## Repository layout

```
Ultron/
├── Jarvis/                     # Swift sources (will be renamed Ultron/ in naming pass)
│   ├── Agent/MCP/              # Existing MCP client — sidecar bridge
│   ├── AI/                     # AnthropicProvider, GeminiREST + new Ollama/MLX/Router
│   ├── Sidecar/                # NEW — SidecarSupervisor, Bootstrap, Log
│   ├── Skills/                 # NEW — native skill protocol + registry
│   ├── Telemetry/              # NEW — EnergyMonitor, TraceStore
│   └── …                       # UI, Services, Audio, Modes (from JarvisHUD)
├── Sidecar/python/             # NEW — Python sidecar package
│   └── ultron_sidecar/         # MCP server, OpenJarvis bridges
├── ThirdParty/
│   └── openjarvis/             # Git submodule, pinned to v0.1.1
├── docs/
│   └── ultron-plan.md          # Full implementation plan
└── JarvisWidgetExtension/      # macOS widgets (scaffolded, wiring in Phase 1)
```

---

## Data & privacy

- **API keys** live in macOS Keychain, never on disk
- **Audio** captured in memory only, never saved
- **Screenshots** (Vision mode) held in memory for the API round-trip, then discarded
- **Local LLM** (Phase 3) means most traffic never leaves your Mac
- **Logs** at `~/Library/Logs/Ultron/` (after naming pass: currently `~/Library/Logs/Jarvis/`)
- **Traces** at `~/Library/Application Support/Ultron/traces.db` (Phase 3+)
- **Connector credentials** (Phase 2) stored via OpenJarvis's own OAuth flow in Keychain

---

## Licenses & attribution

- **Ultron** (this repo) — MIT, inheriting JarvisHUD's license
- **[JarvisHUD](https://github.com/Parthee-Vijaya/JarvisHUD)** — MIT, by the same author
- **[OpenJarvis](https://github.com/open-jarvis/OpenJarvis)** — Apache 2.0, Stanford Scaling Intelligence Lab (included as `ThirdParty/openjarvis/` submodule, pinned to v0.1.1)

Third-party frameworks: [HotKey](https://github.com/soffes/HotKey) (MIT), [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT).

---

## Upstream cherry-picks

JarvisHUD continues to evolve in parallel on its own `Charlie` branch (widget target wiring, agent confirmation cards, etc.). Useful improvements land in Ultron via:

```bash
git fetch jarvishud
git cherry-pick <commit-sha>
```

The `jarvishud` remote is pre-configured for this purpose.

---

Built with Claude Code.
