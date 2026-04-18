# J.A.R.V.I.S — Samlet løsningsoverblik

**Version:** v5.0.0-alpha.12
**Platform:** macOS 14+ (native menubar-app)
**Sprog:** Swift 6.3 (SwiftUI + AppKit hybrid)

---

## Hvad er J.A.R.V.I.S?

En native macOS menubar-app der omdanner stemme til handling via Google Gemini
og Anthropic Claude. Hold en hotkey, tal, og J.A.R.V.I.S transskriberer,
omskriver, svarer på spørgsmål, søger på nettet eller analyserer skærmen — og
indsætter resultatet ved markøren eller viser det i en flydende HUD.

Appen lever i menulinjen (ingen Dock-ikon), og ikonet skifter tilstand:
idle (waveform) → optager (rød) → behandler (orange).

---

## Kernefunktioner

### Voice-modes (push-to-talk; ⌥M cykler)

| Mode | Hotkey | Funktion | Output |
|------|--------|----------|--------|
| **Dictation** | ⌥Space | Tale → ren tekst | Indsættes ved markør |
| **VibeCode** | ⌥Space | Tale → struktureret AI-kodeprompt | Indsættes ved markør |
| **Professional** | ⌥Space | Tale → pro-formuleret tekst | Indsættes ved markør |
| **Q&A** | ⌥Q | Direkte svar på spørgsmål | Flydende HUD |
| **Vision** | ⌥⇧Space | Skærmbillede + spørgsmål | Flydende HUD |
| **Chat** | — | Flerturs samtale (streaming + markdown) | Chat-HUD |
| **Info** | ⌥I | Vejr, DR top-3, pendler-tid, Claude-stats | Info-panel |
| **Uptodate** | — | Dokument-summary + nyheder | Panel |

Alle hotkeys er push-to-talk (hold for at optage, slip for at behandle).
Brugerdefinerede modes kan oprettes i Settings → Modes.

### HUD-system

- Borderless, always-on-top svar-vinduer
- Tekstvalg aktiveret, auto-luk efter 15-30 sekunder
- Højttaler-knap læser svar højt (TTS via AVSpeechSynthesizer)
- Dynamic Island-agtigt notch-HUD til kompakt visning
- Chat-HUD med Claude-desktop-palet, markdown-rendering og streaming

### Web-søgning med grounding

- DuckDuckGo Instant Answer + Wikipedia fulltext som primær kilde
- Prompted `google_search` fallback via Gemini grounding
- Strict grounding med kildecitationer (rigtig **Kilder**-fodnote under svar)

### Vision-mode

- Fanger aktivt vindue via ScreenCaptureKit
- Kombinerer screenshot + stemmespørgsmål i ét Gemini-kald
- Bruges til at debugge kode, analysere UI eller læse skærmindhold

### Stemmekommandoer

- Valgfri voice-command-service ("Jarvis spørg…", "Jarvis info", osv.)
- Auto-mute under optagelse så kommandoer ikke dobbelt-udløser
- Porcupine wake-word planlagt til β-milestone

### Settings (sidebar-layout)

- **AI Keys** — Gemini + Anthropic nøgler i macOS Keychain med connection-test
- **Modes** — indbyggede modes + opret/slet brugerdefinerede
- **Hotkeys** — alle genveje redigérbare
- **Voice** — TTS-toggle, voice-command-toggle
- **Info & Location** — hjemmeadresse til vejr/pendler-info
- **Usage** — månedligt omkostningsforbrug pr. model med token-breakdown
- **General / Advanced** — øvrige indstillinger

---

## Nyeste version: v5.0.0-alpha.12

**Bugfixes fra audit efter α.11:**

1. **Footer-regex fix** — `ensureSourcesFooter` brugte `.anchored` på en
   alternation i NSRegularExpression, hvilket kun honorerede første gren.
   Resultat: duplikerede **Kilder**-sektioner. Omskrevet til at scanne efter
   literal header-markers.
2. **ChatSession defensiv trim** — Gemini's multi-turn API forventer at
   historik slutter på `model`-tur. Drain-loop tilføjet så flere trailing
   user-turns (f.eks. efter crash-recovery) ikke forvirrer modellen.
3. **Voice-command race** — `VoiceCommandService.suspend()/resume()` pauser
   genkendelsen i 4s optagelse + 500ms tail, så "Jarvis spørg…" ikke
   dobbelt-trigger på den rullende buffer.

Alle 29 unit-tests grønne.

---

## Udvikling i v5 alpha-serien

| Alpha | Højdepunkt |
|-------|-----------|
| α.1 | Dropped `google/generative-ai-swift` → ren REST + SSE streaming |
| α.2 | `AIProvider`-protokol (Gemini + Anthropic), `ErrorPresenter`, XCTest-target, GitHub Actions CI, SwiftLint |
| α.3 | UX-omlæg: sidebar-Settings, menubar-genveje, HUD-spring polish |
| α.4 | HAL 9000-overhaul, delt audio-engine, voice-commands |
| α.5 | Claude-desktop-palet, HUD-redesign, chat typing-fix, dev-script |
| α.6 | DuckDuckGo live-søgning, chat-polish |
| α.7 | Ægte web-search (DDG Instant Answer + Wikipedia), J.A.R.V.I.S-branding |
| α.8 | HUD-render + audio-race fix |
| α.9 | HUD-ScrollView collapse fix (resultat-tekst usynlig) |
| α.10 | Strict grounding + kilde-citationer |
| α.11 | Wikipedia fulltext + prompted `google_search` fallback |
| α.12 | Footer-regex, chat-historie, voice-mute |

---

## Teknisk stack

| Lag | Teknologi |
|-----|-----------|
| Sprog | Swift 6.3 |
| UI | SwiftUI + AppKit (hybrid) |
| AI | Google Gemini 2.5 Flash/Pro + Anthropic Claude Sonnet 4.6 / Opus 4.7 |
| Lyd | AVAudioEngine (WAV/PCM, shared audio engine) |
| Hotkeys | [HotKey](https://github.com/soffes/HotKey) SPM |
| Tekst-indsættelse | Accessibility API (AXUIElement) + Pasteboard-fallback |
| Skærmfangst | ScreenCaptureKit |
| Nøgle-opbevaring | macOS Keychain (Security framework) |
| TTS | AVSpeechSynthesizer |
| Tests | XCTest (29 tests) |
| CI | GitHub Actions (build + test) |
| Linting | SwiftLint |
| Mål | macOS 14.0+ |

---

## Privatliv og data

- **API-nøgler** opbevares i macOS Keychain (aldrig på disk)
- **Lyd** fanges kun i hukommelsen — aldrig gemt
- **Screenshots** (Vision-mode) holdes i memory under API-kald, derefter slettet
- **Logs** skrives til `~/Library/Logs/Jarvis/jarvis.log`
- **Forbrugsdata** gemmes lokalt i `~/Library/Application Support/Jarvis/usage.json`
- Kun API-kald til Google/Anthropic forlader maskinen

---

## Priser

| Model | Input | Output |
|-------|-------|--------|
| Gemini 2.5 Flash | $0.075 / 1M tokens | $0.30 / 1M tokens |
| Gemini 2.5 Pro | $1.25 / 1M tokens | $5.00 / 1M tokens |
| Claude Sonnet 4.6 | $3 / 1M tokens | $15 / 1M tokens |
| Claude Opus 4.7 | $15 / 1M tokens | $75 / 1M tokens |

De fleste modes bruger Flash. VibeCode bruger Pro for højere kvalitet.
Agent-mode (β) bruger Claude.

---

## Roadmap fremover

### β — Agent mode (`v5.0.0-beta`)

Jarvis kan **gøre** ting på din Mac — ikke kun snakke om dem.

- Tool-registry: `read_file`, `list_directory`, `search_files`, `stat_file`
  (ingen bekræftelse) + `write_file`, `edit_file`, `rename_file`,
  `delete_file`, `create_directory`, `run_shell` (med bekræftelse)
- Inline confirmation-cards i chat-HUD ("Jarvis vil *write* `X` — [Tillad]/[Afvis]")
- Workspace-boundary: hard-guard på tilladte rødder
- Agent-chat UI med visuelt skel (cyan-lilla gradient)
- Audit-log i `~/Library/Logs/Jarvis/agent.log`
- Rate limit (max 20 tool-calls pr. tur) og time-of-use AX-check
- Porcupine wake-word som SPM

### rc — Polish (`v5.0.0`)

- Sidebar Settings (erstatter flad TabView)
- 5-trins onboarding-wizard
- Lokalisering (dansk + engelsk)
- VoiceOver-labels, keyboard-nav, Dynamic Type, high-contrast
- Log-rotation (5 MB / 10 MB caps)
- Fil-split af `HUDWindow.swift`, `AppDelegate.swift`, `SettingsView.swift`

### v5.1 — Feature pack

- **Meeting mode** (⌥⇧M) — op til 120 min, chunk-stream til Gemini,
  struktureret markdown-output (deltagere, agenda, beslutninger, actions)
- **Clipboard history** (⌥V) — sidste 20 items med "Transform…"-knap
- **Email draft mode** (⌥⇧E) — læs markeret tekst, udkast svar i din tone
- **VibeCode-templates** — API spec / bug report / feature proposal / refactor / test
- **Audio-transskription** — drag `.wav`/`.mp3`/`.m4a` på HUD'en
- **Custom mode editor v2** — max tokens, temperature, web-search-toggle, "test prompt"

### v5.2 — Distribution

- App Intents / Siri ("Hey Siri, Jarvis meeting mode")
- Sparkle 2.x auto-update + appcast på GitHub Pages
- Developer ID-signering + notarization (Gatekeeper-clean DMG)
- CHANGELOG, architecture.md, CONTRIBUTING.md

---

## Installation

### Fra DMG
1. Download `Jarvis-2.0.dmg`
2. Træk til Applications
3. Start fra Applications

### Byg fra kilde
```bash
git clone git@github.com:Parthee-Vijaya/JarvisHUD.git
cd JarvisHUD
xcodebuild -project Jarvis.xcodeproj -scheme Jarvis -configuration Release build
# eller byg DMG:
./build-dmg.sh
```

Kræver Xcode 26+ med macOS 14+ SDK.

### Opsætning
1. Hent Gemini API-nøgle fra [aistudio.google.com](https://aistudio.google.com)
2. Start Jarvis — onboarding guider dig gennem rettigheder
3. Menubar → Settings → indsæt API-nøgle → Save → Test Connection
4. Giv Mikrofon- og Accessibility-rettigheder når du bliver spurgt

---

## Licens

MIT

---

*Bygget med Claude Code.*
