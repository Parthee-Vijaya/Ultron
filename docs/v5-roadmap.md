# Jarvis v5.0 Roadmap

**Theme:** *Agent-era Jarvis* — a multi-provider, agentic, localised, and
production-polished assistant. From "cool demo" to "daily tool".

Scope is deliberately broad. The plan ships in **four incremental milestones**
so each one is usable on its own without waiting for the whole v5 to land.

---

## Milestones at a glance

| Milestone | Version | Theme | Approx size |
|-----------|---------|-------|-------------|
| α — Foundation  | `v5.0.0-alpha` | AI layer rewrite + quality net | ~1.5 weeks |
| β — Agent       | `v5.0.0-beta`  | Claude tool use + file ops     | ~2 weeks   |
| rc — Polish     | `v5.0.0`       | UX + accessibility + i18n      | ~1.5 weeks |
| +1 — Features   | `v5.1.0`       | Meeting / clipboard / email    | ~2 weeks   |
| +2 — Distribute | `v5.2.0`       | Shortcuts, auto-update, sign   | ~1 week    |

---

## α — Foundation (`v5.0.0-alpha`)

Goal: stop paying tax on an outdated SDK, add a safety net.

### A1. Drop `google/generative-ai-swift` 0.5.x → full REST
- The SDK is deprecated upstream; our `googleSearch` grounding already works
  around it via REST (v4.1). Let's unify on REST.
- New `Gemini/GeminiREST.swift` containing: `makeRequest`, SSE streaming
  parser, typed request/response models (messages, parts, tools, usage).
- `GeminiClient` stays as the public façade, internally delegates to
  `GeminiREST`. All existing call sites (`sendAudio`, `sendAudioWithImage`,
  `sendText`, `startChat`, `sendTextStreaming`, `sendAudioStreaming`)
  keep their shapes so `RecordingPipeline` / `ChatPipeline` don't change.
- `ChatSession.sdkChat: Chat?` removed; streaming chat instead holds a
  lightweight `[ModelContent]` history array passed with each turn.
- Expected net LOC: -200 (SDK dep removed, tool support simplified).

### A2. Multi-provider architecture
- New protocol `AIProvider` with a small surface:
  ```swift
  protocol AIProvider {
      func send(messages: [AIMessage], tools: [AITool]?) async throws -> AIResponse
      func stream(messages: [AIMessage], tools: [AITool]?) -> AsyncThrowingStream<AIChunk, Error>
  }
  ```
- Concrete implementations:
  - `GeminiProvider` — already-written REST path (A1)
  - `AnthropicProvider` — URLSession, `x-api-key` header, messages endpoint,
    tool-use support (needed for β)
  - `OllamaProvider` *(optional, defer to later)* — offline for local models
- `Mode` gains `provider: AIProviderType` (enum, default `.gemini`).
- Built-in modes keep Gemini for cost; the coming Agent mode uses Anthropic.

### A3. Central error router
- Today we have scattered `hudController.showError(...)` calls with
  inconsistent formatting. Replace with `ErrorPresenter.surface(_ error: Error, context: String)` that:
  - Logs with context to `jarvis.log`
  - Shows the right HUD variant (inline vs permission vs critical)
  - Knows about common error domains (URL, AX, Porcupine, Gemini) and shows
    a friendly Danish message for each

### A4. Test scaffolding + first batch of tests
- Add an `XCTest` target to the Xcode project (currently zero tests).
- Unit tests worth having on day one:
  - `RSSParser` — feed fixtures in `Tests/Fixtures/*.xml`
  - `WeatherCode` symbol + label mapping
  - `Mode` Codable — decoding v3-era JSON without `webSearch` field
  - `HotkeyBinding.validate()` — reserved combos, shift-alone rejection
  - `CommuteService` — Tesla kWh math
  - `ClaudeStatsService` — stats-cache.json parsing (fixture)
  - `DocumentReader` — .txt roundtrip, truncation boundary
- Target: ~40 tests, runnable via `xcodebuild test`.

### A5. CI (GitHub Actions)
- `.github/workflows/ci.yml` running on every push + PR:
  - `xcodebuild -scheme Jarvis -destination 'platform=macOS' build test`
  - Cache SPM deps
  - On `main`, additionally build the Release DMG and attach as artifact
- Badge in README.

### A6. SwiftLint
- `.swiftlint.yml` with opinionated-but-not-annoying ruleset.
- Fix existing warnings (mostly `line_length` + `force_cast`).

---

## β — Agent mode (`v5.0.0-beta`)

Goal: Jarvis can **do** things on your Mac, not just talk about them.

### B1. Tool registry
- Protocol + built-in tools (each a separate file under `Jarvis/Agent/Tools/`):
  - **Read-only (no confirm):** `read_file`, `list_directory`, `search_files` (glob), `stat_file`
  - **Destructive (confirm):** `write_file`, `edit_file` (line-range replace), `rename_file`, `delete_file`, `create_directory`
  - **Shell (confirm + whitelist):** `run_shell` — accepts a whitelist of command roots (`ls`, `cat`, `git status`, `grep`, `find`, `rg`). Anything else prompts.
- Tools emit a JSON schema so the provider can pass them to Claude's tool-use API.

### B2. Confirmation UI
- When the model requests a destructive tool, the chat HUD inserts an inline
  card: "Jarvis vil *write* `~/Documents/rapport.md` (2.3 KB) — [Tillad] [Afvis]".
- `Agent.Allowlist`: if user checks "husk dette" the path/command is remembered
  in `~/Library/Application Support/Jarvis/agent-allowlist.json` so next time
  the tool runs without prompting.
- First-run safety: allowlist scope defaults to `~/Desktop`, `~/Downloads`,
  `~/Documents/Jarvis/` — anything outside prompts even if allowlisted elsewhere.

### B3. Workspace boundary
- Settings → Advanced → "Agent filadgang" lets user add/remove allowed roots.
- Jarvis absolutely refuses to write/delete outside those paths (hard guard in
  each destructive tool).

### B4. Agent chat UI
- New `HotkeyAction.agent` (default `⌥A`), its own chat window variant.
- Visual distinction from regular Chat: different icon (robot), subtle
  cyan-purple gradient border to signal "this mode can touch your files".
- Tool calls render as expandable cards in the message stream with input/output.

### B5. Audit log
- Every tool execution writes to `~/Library/Logs/Jarvis/agent.log`:
  - ISO timestamp
  - Conversation UUID
  - Tool name
  - Arguments (sanitised — no file contents, just paths + sizes)
  - Result summary
  - Duration
- User can view / export via Settings → Advanced → "Agent auditlog".

### B6. Safety rails
- **No shell exec in background/hotkey callbacks** — only inside a visible
  chat where the user can see the request.
- **Time-of-use check** — re-verify `AXIsProcessTrusted()` and workspace
  allowlist just before each destructive op; state can change between chat
  turns.
- **Rate limit** — max 20 tool calls per turn (avoid runaway loops).

---

## rc — Polish (`v5.0.0`)

Goal: the release cut where Jarvis goes from "fun side project" to
"something my non-dev friend would actually use".

### P1. Settings reorganisation
- Sidebar-style nav replaces the flat TabView (current layout is overcrowded at
  7 tabs).
- Groups: **AI Keys**, **Modes**, **Hotkeys**, **Voice**, **Info & Location**,
  **Agent**, **Advanced**.
- Deep-link from menu-bar items still works (`.hotkeys`, etc.).

### P2. Onboarding v2
- Replace the current single-pane onboarding with a 5-step wizard:
  1. Welcome + what Jarvis does (3 bullets)
  2. Get/paste a Gemini API key (or "skip for now")
  3. Mic + Accessibility + Screen Recording permissions, in sequence
  4. *(Optional)* Home address for Info mode
  5. Hotkey cheat-sheet + "done" button
- Can be re-run from Settings → "Kør onboarding igen".

### P3. Localisation scaffold
- Extract every Danish string (there are ~200) into `Localizable.strings`.
- Add English translations. Language picker in Settings → General.
- Mode system prompts stay in the mode data (user-editable) — not localised.

### P4. Accessibility pass
- VoiceOver labels on every button, HUD, and list item.
- Keyboard navigation in Chat HUD (arrow keys between messages, Return to
  focus input).
- Dynamic Type support (font sizes respect system setting).
- High-contrast variant of the cyan theme for the `Increase Contrast` system
  setting.

### P5. Central log rotation
- Cap `jarvis.log` at 5 MB. On rotate, move to `.1`, `.2`, `.3`.
- `agent.log` follows the same pattern (10 MB cap since tool calls are verbose).

### P6. File split
- `HUDWindow.swift` is now ~380 lines across four presentation modes. Split:
  - `HUDWindow/HUDWindow+CornerPanel.swift`
  - `HUDWindow/HUDWindow+NotchPanel.swift`
  - `HUDWindow/HUDWindow+ChatPanel.swift`
  - `HUDWindow/HUDWindow+UptodatePanel.swift`
  - `HUDWindow/HUDWindow+InfoPanel.swift`
- `AppDelegate.swift` gets a `AppDelegate+Hotkeys.swift` extension for the
  callback wiring.
- `SettingsView.swift` splits per-tab into the new sidebar structure.

---

## +1 — Feature pack (`v5.1.0`)

Goal: push Jarvis into new workflows beyond voice Q&A.

### F1. Meeting mode
- **Hotkey:** `⌥⇧M` (rebindable).
- Recording up to **120 minutes** (vs the 60-second limit for voice modes).
- Streams audio in 2-minute chunks to Gemini so latency stays bounded.
- Output: structured markdown notes (attendees, agenda, decisions, action
  items, open questions) auto-saved to `~/Documents/Jarvis Meetings/YYYY-MM-DD HH-MM.md`.
- HUD shows elapsed + level meter + a "Pause" + "End" button.

### F2. Clipboard history
- Background listener on `NSPasteboard.general.changeCount` records the last
  20 string items.
- **Hotkey:** `⌥V` opens a searchable list HUD.
- Each item has a "Transform…" button: summarize / translate / reformat.
- Stored in memory only (privacy). User can opt into persisting to disk.

### F3. Email draft mode
- **Hotkey:** `⌥⇧E`. Jarvis reads the currently-selected text across any app
  (via AX), plus asks "what should the reply say?" in a small HUD input.
- Drafts a reply in your voice (trained on the selected text's tone).
- Paste via `⌘V` or opens Mail.app with pre-populated draft.

### F4. VibeCode templates
- `VibeCode` mode gets a set of templates you can quick-switch between:
  - "API endpoint spec"
  - "Bug report"
  - "Feature proposal"
  - "Refactor prompt"
  - "Test case"
- Each template has its own system prompt. Template picker appears as a small
  row of chips in the recording HUD.

### F5. Audio file transcription
- Drag a `.wav` / `.mp3` / `.m4a` / `.aac` file onto the HUD or menu-bar icon.
- Jarvis uploads to Gemini with a transcription prompt, returns cleaned text +
  summary. Saves to `.txt` alongside the source.

### F6. Custom mode editor v2
- Today's "new mode" dialog is thin. Expand with:
  - Model + output type (already there)
  - Max tokens slider (currently hard-coded)
  - Temperature slider
  - Web search toggle (new)
  - "Test prompt" button — runs the mode against a sample you type, shows the
    output immediately without needing to hotkey it

---

## +2 — Distribution (`v5.2.0`)

Goal: ship properly so random users aren't blocked by macOS Gatekeeper.

### D1. Shortcuts / Siri via App Intents
- Expose the fast-path actions as `AppIntent`:
  - "Jarvis, summarize this document" (takes a file param)
  - "Open Uptodate"
  - "Open Info mode"
  - "Start meeting recording"
- This also lets Siri invoke them ("Hey Siri, Jarvis meeting mode").

### D2. Sparkle auto-update
- Add Sparkle 2.x SPM package.
- Publish `appcast.xml` on GitHub Pages (or a small CDN) listing DMG versions.
- Menu bar gets "Check for Updates…" item.
- `build-dmg.sh` → `release.sh` that also signs + appcast-updates.

### D3. Code signing + notarization
- New `release.sh` that:
  1. Builds Release with a Developer ID signing identity
  2. Runs `codesign --deep --options=runtime` with timestamp
  3. Submits to notarytool, polls until done
  4. Staples the notarization ticket
  5. Produces a Gatekeeper-clean DMG
- Requires: Apple Developer Program membership + Developer ID cert.

### D4. Docs + CHANGELOG
- `CHANGELOG.md` starting from v1.0, with each version's highlights + migration
  notes.
- `docs/architecture.md` — one-page overview of the service layer, pipeline
  flows, HUD state machine.
- `CONTRIBUTING.md` — how to run tests, coding style, PR flow.
- README gets a richer screenshot gallery.

---

## Ongoing cleanup (cuts through every milestone)

Not its own phase — I do a handful in each milestone:

- **Sendable audit** — mark every class as `@MainActor`/`@unchecked Sendable`
  / `Sendable` explicitly, move us closer to Swift 6 strict concurrency
  compliance. Current default-main-actor setting papers over some issues.
- **Unused code hunt** — grep for unreachable branches from v2/v3 we haven't
  touched.
- **SwiftUI perf** — reduce body re-renders in HUDContentView (currently
  triggers on every `@Observable` change even for tiles that didn't change).
  Use `EquatableView` or `@ViewBuilder` memoization.
- **`Jarvis.xcodeproj` cleanup** — the file-system-synced group is convenient
  but some metadata (build phase config for Info.plist) still needs manual
  upkeep. Document it.

---

## Locked decisions

1. **SDK strategy** — **Full REST.** Drop `google/generative-ai-swift` 0.5.x
   in α. Write our own URLSession Gemini client, which opens for first-class
   `googleSearch`, `codeExecution`, and future Gemini-only tools without
   shopping for SDK versions.
2. **Agent LLM** — **User-selectable in Settings.** Ship both `claude-sonnet-4-6`
   and `claude-opus-4-7`; add a dropdown under Agent settings with a cost
   hint ("Sonnet: $3/$15 per M · Opus: $15/$75 per M"). Default to Sonnet.
3. **Sandbox** — **Stay un-sandboxed.** DMG distribution with Developer ID
   signing + notarization. Workspace allowlist uses plain absolute paths,
   not security-scoped bookmarks.
4. **Porcupine** — **Add SPM in β**, alongside Agent mode. Keeps α lean;
   wake-word becomes more useful once there's agent capability behind it.
5. **Localisation** — Design for i18n from rc but ship only English + Danish
   in v5.0.0. German/Swedish can come later without architectural rework.

---

## Non-goals (for v5)

Just so we're clear about what I'm *not* going to do:

- Cross-platform (iOS / Linux) port — Jarvis stays macOS-only.
- Multi-user / team sync — single-user tool.
- Full conversational memory across sessions — the existing per-conversation
  history is enough; no vector store or long-term memory graph.
- Plugin API for third-party modes — mode system stays Jarvis-internal.
- In-app Claude Code replacement — we show stats for it, we don't replicate it.
