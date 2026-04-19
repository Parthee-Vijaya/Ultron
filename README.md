# Jarvis — AI Voice Assistant for macOS

A native macOS menu-bar app that turns your voice into action using Google Gemini + Anthropic Claude. Hold a hotkey and speak for dictation, ask questions, analyze your screen, chat with history, or open the **Cockpit** — a glanceable dashboard of weather, traffic, system stats, Tesla routes, aircraft overhead, and Claude Code usage.

![Cockpit panel](docs/screenshots/cockpit.png)

## Highlights

- **Voice modes** — dictation, Q&A, vision, VibeCode, professional rewrite. Push-to-talk with global hotkeys, local Whisper large-v3 for dictation, Gemini-audio for Q&A/Vision.
- **Chat** — full conversation history with streaming replies, agent mode with tool-call cards, drag-and-drop image attachments, semantic search, Spotlight indexing.
- **Cockpit** — a 960pt dashboard tile grid: Vejr, Sol (with solstice delta + next Danish holiday), Luft/Måne, Nyheder, Trafikinfo (live Vejdirektoratet feed), Hjem/Rute commute with zoomable MapKit + EV charger overlay, System & Netværk 2×2 quadrant, Fly over dig (live ADS-B), Himmel (planet ephemeris + ISS), Claude Code stats split across Sessioner/Tokens + Projekter/Modeller.
- **Briefing** — 6-source news (DR, Politiken, BBC, Guardian, Reddit, Hacker News) + Denne dag i historien.
- **Agent mode** — tool-using chat with file system, code execution, web search, MCP servers.

## Voice Modes

| Mode | Hotkey | What it does | Output |
|------|--------|-------------|--------|
| **Dictation** | `⌥ Space` | Transcribes speech (local WhisperKit) to clean text | Paste at cursor + clipboard + Notes.app note |
| **VibeCode** | `⌥ Space` | Converts spoken ideas into structured AI coding prompts | Paste at cursor |
| **Professional** | `⌥ Space` | Rewrites dictation for professional communication | Paste at cursor |
| **Q&A** | `⌥ Q` | Grounded question answering with Gemini + web search + citation chips | Floating HUD |
| **Vision** | `⌥ ⇧ Space` | Analyzes your screen + answers questions about it | Floating HUD |

- **⌥ M** cycles modes · **⌥ Return** toggles Chat · **⌥ ⇧ I** opens Cockpit · **⌥ ⇧ B** opens Briefing.
- All voice hotkeys are push-to-talk. Custom modes in Settings.

## Cockpit panel

A dense, glanceable dashboard laid out in a navy-glass grid (`.regularMaterial` over a dark navy gradient matching the chat visual language). Auto-refresh cadences are tuned per tile — live metrics every 5 seconds, aircraft + ISS every 30 seconds, Claude stats every 15 seconds, weather / news / commute on the 2-minute cycle.

| Tile | Content | Source |
|------|---------|--------|
| **Vejr** | Temperature, condition, feels-like, wind, humidity, today's high/low | Open-Meteo |
| **Sol** | Sunrise, sunset, daylight length, solstice delta, next Danish holiday (Easter computed, rest fixed) | Pure Swift (`SolarDateMath`, `DanishHolidays`) |
| **Luft & Måne** | AQI + UV bands · moon phase + illumination + next full moon | Open-Meteo + pure-Swift moon phase |
| **Nyheder** | DR / Politiken / BBC / Guardian headlines | RSS feeds |
| **Trafikinfo nær dig** | Live Vejdirektoratet events within 50 km, classified by DATEX II type, with per-row "for 2t 4m" chips + municipal reporter badges + a national-scope "Hele DK: 73 aktive · 23 dyr · 18 uheld · 18 hindringer" aggregate | Vejdirektoratet big-screen-events feed |
| **Hjem / Rute** | Travel time, ETA, traffic delay, Tesla kWh + kr estimate, live-traffic link, destination weather, full-width zoomable map with charger overlays, motorvejsulykker on route | Apple Maps + Open-Meteo + adsb.lol + supercharge.info + OCM |
| **System** | Battery, macOS version, hostname, uptime, chip | pmset, sw_vers, sysctl, ProcessInfo |
| **Netværk** | Local IP, DNS, WiFi SSID, signal (dBm + quality), link rate | getifaddrs, scutil, WiFi framework |
| **Ydelse** | CPU load % + bar, RAM + bar, Disk + bar, Strøm (watts), Termisk state | `host_statistics64` + `AppleSmartBattery` IORegistry |
| **Handlinger** | Speedtest, LAN scan, WiFi quality + cumulative RX/TX bytes, Bluetooth status + connected devices | `networkQuality`, `arp`, `getifaddrs`, IOBluetooth |
| **Fly over dig** | 3-4 nearest aircraft — origin → destination IATA pair, flight level, compass bearing from you, km distance | adsb.lol + adsbdb.com |
| **Himmel** | Visible planets (Merkur/Venus/Mars/Jupiter/Saturn) with altitude/compass + ISS current subpoint with distance | Pure-Swift ephemeris + wheretheiss.at |
| **Claude · Sessioner & Tokens** | I dag / I alt / Kørt / Seneste / Siden + Daily + Weekly bars (capped at >999% when over), længste session | Live sweep of `~/.claude/projects/*/*.jsonl` (all 4 token types summed per day + per model; stats-cache.json used only for session counts + firstSessionDate because it lags a day) |
| **Claude · Projekter & Modeller** | Seneste 3 projekter, top tools (wrapped in rows of 4), per-model breakdown with cache-hit ratio | Same live JSONL sweep |

EV charger overlays on the commute map: Tesla Superchargers (via supercharge.info, no auth) + Clever (via Open Charge Map, optional API key in Settings).

Large token counts switch to the Danish **"mia"** (milliard) suffix above 1 billion — e.g. `1.6 mia` instead of `1600M`.

## Briefing panel

A lighter "what's in the world today" surface with six parallel news sources (DR, Politiken, BBC, Guardian, Reddit r/worldnews, Hacker News) plus a **Denne dag i historien** tile populated from Wikipedia. Same navy-glass visual language as the Cockpit.

## Chat

- Streaming replies with pulsing `▌` cursor
- Conversation history in a left sidebar with full-text + semantic search (NLEmbedding)
- Spotlight indexing — past conversations findable via ⌘Space
- Tool-call cards in agent mode (icon + name + status badge)
- Inline image preview on drag-drop
- Citation chips for web-search results (number badge + host + arrow.up.right)
- Code-block copy buttons (hover-reveal)
- Retry + quoted-reply badges on transient errors

Anthropic prompt caching (`cache_control: ephemeral`) is active on agent-mode system prompts — roughly 2× cost reduction on long tool loops.

### Empty-state greetings

Every fresh chat lands on a rotating one-liner — movie quotes, sci-fi nods, and a few Jarvis-specific jabs — so opening the app doesn't feel sterile. `GreetingProvider` picks a line at random per session; the wordmark-vs-sparkle icon choice rotates too.

<p align="center">
  <img src="docs/screenshots/chat-greeting-wordmark.png" width="380" alt="J.A.R.V.I.S wordmark + Welcome to the party, pal." />
  <img src="docs/screenshots/chat-greeting-self-destruct.png" width="380" alt="This message will self-destruct in five seconds… medmindre du sender et svar." />
  <img src="docs/screenshots/chat-greeting-gemini.png" width="380" alt="I eat Gemini for breakfast." />
</p>

## Tech stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6.3 |
| UI | SwiftUI + AppKit hybrid |
| AI backends | Google Gemini 2.5 Flash / Pro + Anthropic Claude Opus/Sonnet/Haiku |
| Local STT | WhisperKit (openai_whisper-large-v3-v20240930_turbo_632MB) |
| Audio | AVAudioEngine (WAV/PCM) |
| Hotkeys | [HotKey](https://github.com/soffes/HotKey) package |
| Text insertion | Accessibility API (AXUIElement) + Pasteboard fallback |
| Screen capture | ScreenCaptureKit |
| Maps | MapKit (live + off-peak baseline for traffic delta) |
| Location | CoreLocation (60 s cache + reverse-geocoded city) |
| Semantic search | Apple NLEmbedding (on-device) |
| Spotlight | CoreSpotlight (`CSSearchableItem` per conversation) |
| Bluetooth | IOBluetooth (requires `NSBluetoothAlwaysUsageDescription` — added) |
| System probes | `host_statistics64`, IOKit `AppleSmartBattery`, `getifaddrs` |
| TTS | AVSpeechSynthesizer |
| Persistence | Keychain (API keys) + JSON files (conversations / modes / metrics) |
| Target | macOS 14.0+ |

## Project structure

```
Jarvis/
├── JarvisApp.swift                  # App entry point
├── AppDelegate.swift                # Menu bar + pipeline wiring
│
├── Gemini/                          # Gemini + Anthropic chat clients
│   ├── GeminiClient.swift
│   ├── ChatSession.swift
│   ├── AnthropicProvider.swift
│   └── UsageTracker.swift
│
├── Agent/                           # Tool-using agent mode
│   ├── AgentService.swift
│   ├── AgentTool.swift
│   ├── Tools/                       # SearchFilesTool, RunShellTool, …
│   └── MCP/                         # MCPClient — external tool servers
│
├── Audio/
│   ├── AudioCaptureManager.swift    # AVAudioEngine mic → WAV
│   └── WhisperKitTranscriber.swift  # Local STT
│
├── Modes/
│   ├── Mode.swift                   # Mode model + routing
│   ├── BuiltInModes.swift
│   └── ModeManager.swift
│
├── System/
│   ├── HotkeyManager.swift
│   ├── TextInsertionService.swift
│   ├── LocationService.swift
│   ├── ScreenCaptureService.swift
│   ├── DictationPersistence.swift   # Notes.app + clipboard
│   ├── FocusModeObserver.swift
│   └── JarvisAppIntents.swift       # Shortcuts.app intents
│
├── UI/
│   ├── SettingsView.swift
│   ├── ChatView.swift
│   ├── ConversationSidebar.swift
│   ├── MessageBubble.swift
│   ├── ChatCommandBar.swift
│   ├── HUDWindow.swift
│   ├── HUDContentView.swift
│   ├── InfoModeView.swift           # Cockpit panel
│   ├── UptodateView.swift           # Briefing panel
│   ├── CommuteMapView.swift         # MapKit NSViewRepresentable with chargers
│   ├── HotkeyCheatSheet.swift
│   ├── JarvisTheme.swift
│   ├── JarvisHUDBackground.swift
│   └── JarvisWordmark.swift
│
├── Services/
│   ├── InfoModeService.swift        # Cockpit orchestrator
│   ├── WeatherService.swift         # Open-Meteo
│   ├── NewsService.swift            # RSS
│   ├── CommuteService.swift         # Apple Maps routing
│   ├── SystemInfoService.swift      # OS / network / bluetooth probes
│   ├── AirQualityService.swift
│   ├── MoonService.swift
│   ├── SolarDateMath.swift          # Pure Swift solar math
│   ├── DanishHolidays.swift         # Gauss Easter + fixed dates
│   ├── PlanetEphemeris.swift        # Pure Swift planet ephemeris
│   ├── AircraftService.swift        # adsb.lol + adsbdb route resolver
│   ├── ISSService.swift             # wheretheiss.at
│   ├── TrafficEventsService.swift   # Vejdirektoratet DATEX II
│   ├── ChargerService.swift         # Tesla Supercharger + Clever
│   ├── ClaudeStatsService.swift     # Claude Code usage aggregator
│   ├── HistoryService.swift         # This-day-in-history (Wikipedia)
│   ├── InstantAnswerProvider.swift  # Pattern-match fast answers
│   ├── SemanticIndex.swift          # NLEmbedding
│   ├── SpotlightIndexer.swift
│   ├── WebSearchService.swift
│   ├── ConversationStore.swift
│   ├── MetricsService.swift
│   ├── KeychainService.swift
│   ├── TTSService.swift
│   └── LoggingService.swift
│
└── Resources/
    ├── Assets.xcassets
    ├── Info.plist                   # LSUIElement + usage descriptions
    └── Jarvis.entitlements
```

## Installation

### From DMG
1. Download `Jarvis-<version>.dmg` from Releases
2. Open the DMG and drag Jarvis to Applications
3. Launch Jarvis from Applications

### Build from source
```bash
git clone git@github.com:Parthee-Vijaya/JarvisHUD.git
cd JarvisHUD
./run-dev.sh                                  # Debug build + launch
# or
xcodebuild -scheme Jarvis -configuration Release build
./build-dmg.sh                                # Notarized DMG
```

Requirements: Xcode 26+, macOS 14+ SDK, Swift 6.3.

## Setup

1. Launch — the onboarding walks you through permissions (Mic · Accessibility · Screen capture · Speech · Location · Calendar · Bluetooth).
2. Menu bar icon → **Settings** → paste **Gemini** + **Anthropic** API keys → **Save** + **Test**.
3. Optional: add an **Open Charge Map** key in Settings to enable Clever chargers on the commute map (Tesla Superchargers work without any key).
4. Set your **home address** in Settings for the Cockpit's Hjem tile.

API keys live in Keychain, never on disk.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `⌥ Space` | Dictation / VibeCode / Professional (push-to-talk) |
| `⌥ Q` | Q&A mode (push-to-talk) |
| `⌥ ⇧ Space` | Vision mode (push-to-talk) |
| `⌥ M` | Cycle mode |
| `⌥ Return` | Toggle Chat |
| `⌥ ⇧ I` | Toggle Cockpit |
| `⌥ ⇧ B` | Toggle Briefing |
| `⌘ Space` (in chat) | Semantic search history |

## Data & privacy

- **API keys** in macOS Keychain
- **Audio** captured in memory only — never saved
- **Screenshots** (Vision) held in memory for the API round-trip, then discarded
- **Logs** at `~/Library/Logs/Jarvis/jarvis.log` (rolled at 10 MB)
- **Metrics** at `~/Library/Logs/Jarvis/metrics.jsonl`
- **Conversations** at `~/Library/Application Support/Jarvis/conversations/*.json`
- **Usage data** at `~/Library/Application Support/Jarvis/usage.json`
- **Stats-cache** is read-only from `~/.claude/stats-cache.json` (written by Claude Code)

All public data calls (weather, traffic, chargers, ADS-B, ISS, Open Charge Map) are unauthenticated and see only your approximate coordinate. LLM calls go to Google / Anthropic.

## License

MIT

---

Built with Claude Code.
