import SwiftUI

/// Sidebar items for the Settings window. Exposed so `AppDelegate` can deep-link
/// into a specific pane via menu-bar items.
enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case apiKey, hud, modes, hotkeys, location, voice, claude, agent, mcp, traces, history, usage, about

    var id: Self { self }

    var title: String {
        switch self {
        case .apiKey:   return "API-nøgler"
        case .hud:      return "HUD"
        case .modes:    return "Modes"
        case .hotkeys:  return "Hotkeys"
        case .location: return "Lokation"
        case .voice:    return "Stemme"
        case .claude:   return "Claude Code"
        case .agent:    return "Agent"
        case .mcp:      return "MCP-servere"
        case .traces:   return "Læringsspor"
        case .history:  return "Samtaler"
        case .usage:    return "Forbrug"
        case .about:    return "Om"
        }
    }

    var systemImage: String {
        switch self {
        case .apiKey:   return "key.horizontal.fill"
        case .hud:      return "rectangle.on.rectangle"
        case .modes:    return "list.bullet.rectangle"
        case .hotkeys:  return "command.square"
        case .location: return "location.fill"
        case .voice:    return "mic.and.signal.meter.fill"
        case .claude:   return "sparkles"
        case .agent:    return "wand.and.stars"
        case .mcp:      return "server.rack"
        case .traces:   return "waveform.path.ecg"
        case .history:  return "clock.arrow.circlepath"
        case .usage:    return "chart.bar.fill"
        case .about:    return "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(ModeManager.self) private var modeManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(HotkeyBindings.self) private var hotkeys

    @Binding var selectedTab: SettingsTab

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(
                get: { selectedTab },
                set: { if let newValue = $0 { selectedTab = newValue } }
            )) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: Constants.SettingsWindow.sidebarWidth, max: 240)
        } detail: {
            detailPane
        }
        .navigationTitle("Ultron Settings")
        .frame(
            minWidth: Constants.SettingsWindow.minWidth,
            idealWidth: Constants.SettingsWindow.defaultWidth,
            minHeight: Constants.SettingsWindow.minHeight,
            idealHeight: Constants.SettingsWindow.defaultHeight
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedTab {
        case .apiKey:
            SettingsAPIKeysPane(goToTab: goToTab)
        case .hud:
            SettingsHUDPane()
        case .modes:
            SettingsModesPane()
        case .hotkeys:
            SettingsHotkeysPane()
        case .location:
            SettingsLocationPane()
        case .voice:
            SettingsVoicePane()
        case .claude:
            SettingsClaudePane()
        case .agent:
            SettingsAgentPane()
        case .mcp:
            SettingsMCPPane()
        case .traces:
            SettingsTracesPane()
        case .history:
            SettingsHistoryPane()
        case .usage:
            SettingsUsagePane()
        case .about:
            SettingsAboutPane()
        }
    }

    private func goToTab(_ tab: SettingsTab) {
        selectedTab = tab
    }
}

// MARK: - Shared scrolling scaffold used by every pane

/// Every settings pane wraps its content in this scaffold so scroll behaviour,
/// padding, and typography are consistent.
struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Constants.Spacing.lg) {
                VStack(alignment: .leading, spacing: Constants.Spacing.xxs) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, Constants.Spacing.sm)

                content()

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Constants.Spacing.xxl)
            .padding(.vertical, Constants.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Card-style grouping for a settings subsection. Mimics the SwiftUI-on-iOS
/// grouped-form look, adapted for macOS windows.
struct SettingsCard<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, Constants.Spacing.xs)
            }
            VStack(alignment: .leading, spacing: Constants.Spacing.md) {
                content()
            }
            .padding(Constants.Spacing.lg)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
            }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Constants.Spacing.xs)
                    .padding(.top, Constants.Spacing.xxs)
            }
        }
    }
}

// MARK: - API Keys pane

struct SettingsAPIKeysPane: View {
    let goToTab: (SettingsTab) -> Void
    @Environment(UsageTracker.self) private var usageTracker

    @State private var apiKey = ""
    @State private var anthropicKey = ""
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var anthropicStatus: String?
    @State private var isTesting = false
    private let keychainService = KeychainService()

    enum ConnectionStatus {
        case unknown, connected, failed(String)

        var label: String {
            switch self {
            case .unknown: return ""
            case .connected: return "Forbundet"
            case .failed(let msg): return "Fejl: \(msg)"
            }
        }

        var color: Color {
            switch self {
            case .unknown: return .secondary
            case .connected: return .green
            case .failed: return .red
            }
        }
    }

    var body: some View {
        SettingsPane(
            title: "API-nøgler",
            subtitle: "Ultron bruger Google Gemini til voice og Uptodate, og Anthropic Claude til Agent-mode (kommer i β)."
        ) {
            SettingsCard(
                title: "Google Gemini",
                footer: "Hent din nøgle på aistudio.google.com"
            ) {
                LabeledContent("API-nøgle") {
                    SecureField("AIza…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: Constants.Spacing.sm) {
                    Button("Gem") {
                        keychainService.clearCache()
                        if keychainService.saveAPIKey(apiKey) {
                            LoggingService.shared.log("Gemini API key saved")
                            connectionStatus = .unknown
                            (NSApp.delegate as? AppDelegate)?.resetChatPipelineForKeyRotation()
                        }
                    }
                    .disabled(apiKey.isEmpty)
                    .buttonStyle(.borderedProminent)

                    Button("Test forbindelse") { testConnection() }
                        .disabled(apiKey.isEmpty || isTesting)

                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Text(connectionStatus.label)
                        .foregroundStyle(connectionStatus.color)
                        .font(.caption)
                    Spacer()
                }
            }

            SettingsCard(
                title: "Anthropic Claude",
                footer: "Hent din nøgle på console.anthropic.com — bruges af Agent-mode i β"
            ) {
                LabeledContent("API-nøgle") {
                    SecureField("sk-ant-…", text: $anthropicKey)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: Constants.Spacing.sm) {
                    Button("Gem") {
                        keychainService.clearCache()
                        if keychainService.saveAnthropicKey(anthropicKey) {
                            LoggingService.shared.log("Anthropic API key saved")
                            anthropicStatus = "Gemt"
                        } else {
                            anthropicStatus = "Kunne ikke gemme nøglen"
                        }
                    }
                    .disabled(anthropicKey.isEmpty)
                    .buttonStyle(.borderedProminent)

                    if let status = anthropicStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            if let existing = keychainService.getAPIKey() { apiKey = existing }
            if let existing = keychainService.getAnthropicKey() { anthropicKey = existing }
        }
    }

    private func testConnection() {
        isTesting = true
        connectionStatus = .unknown
        let client = GeminiClient(keychainService: keychainService, usageTracker: usageTracker)
        Task {
            let result = await client.testConnection()
            isTesting = false
            switch result {
            case .success: connectionStatus = .connected
            case .failure(let error): connectionStatus = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - HUD pane

struct SettingsHUDPane: View {
    @AppStorage("ttsEnabled") private var ttsEnabled = false
    @AppStorage(Constants.Defaults.respectFocusMode) private var respectFocusMode: Bool = true

    var body: some View {
        SettingsPane(
            title: "HUD",
            subtitle: "Udseendet på Ultron' svar- og optagelsespanel."
        ) {
            SettingsCard(title: "Tale") {
                Toggle("Læs HUD-svar op (Text-to-Speech)", isOn: $ttsEnabled)
                Text("Når aktiveret læser Ultron Q&A- og Vision-svar op med systemets stemmesyntese.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsCard(title: "Fokus") {
                Toggle("Respekter Focus Mode / skærm-lås", isOn: $respectFocusMode)
                Text("Auto-pop HUD er stille mens skærmen er låst eller sovende.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Modes pane

struct SettingsModesPane: View {
    @Environment(ModeManager.self) private var modeManager
    @State private var showingNewMode = false

    var body: some View {
        SettingsPane(title: "Modes", subtitle: "De tilstande Ultron kan køre i.") {
            SettingsCard(title: "Indbyggede") {
                VStack(spacing: 0) {
                    ForEach(Array(BuiltInModes.all.enumerated()), id: \.element.id) { index, mode in
                        if index > 0 { Divider() }
                        modeRow(mode: mode, deletable: false)
                    }
                }
            }

            SettingsCard(
                title: "Brugerdefinerede",
                footer: modeManager.customModes.isEmpty
                    ? "Tryk \"Ny mode\" for at lave din egen med custom prompt og model."
                    : nil
            ) {
                if modeManager.customModes.isEmpty {
                    HStack {
                        Image(systemName: "plus.rectangle.on.rectangle").foregroundStyle(.tertiary)
                        Text("Ingen brugerdefinerede modes endnu")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, Constants.Spacing.sm)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(modeManager.customModes.enumerated()), id: \.element.id) { index, mode in
                            if index > 0 { Divider() }
                            modeRow(mode: mode, deletable: true)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        showingNewMode = true
                    } label: {
                        Label("Ny mode", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewMode) {
            NewModeView(modeManager: modeManager, isPresented: $showingNewMode)
        }
    }

    private func modeRow(mode: Mode, deletable: Bool) -> some View {
        HStack(spacing: Constants.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.name).fontWeight(.medium)
                Text(mode.model.displayName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(mode.outputType.displayName)
                .font(.caption.weight(.medium))
                .padding(.horizontal, Constants.Spacing.sm)
                .padding(.vertical, Constants.Spacing.xxs)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)

            if deletable {
                Button(role: .destructive) {
                    modeManager.deleteCustomMode(id: mode.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, Constants.Spacing.sm)
    }
}

// MARK: - Hotkeys pane

struct SettingsHotkeysPane: View {
    @Environment(HotkeyBindings.self) private var hotkeys
    @State private var hotkeyErrorMessage: String?
    @State private var hotkeyErrorAction: HotkeyAction?

    var body: some View {
        SettingsPane(
            title: "Hotkeys",
            subtitle: "Klik på en tastaturkombination og tryk en ny kombination. Tryk ⎋ for at annullere."
        ) {
            SettingsCard {
                VStack(spacing: 0) {
                    ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { index, action in
                        if index > 0 { Divider() }
                        hotkeyRow(action)
                    }
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    hotkeys.resetAll()
                } label: {
                    Label("Nulstil til standard", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func hotkeyRow(_ action: HotkeyAction) -> some View {
        let binding = hotkeys.binding(for: action)
        return HStack(spacing: Constants.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName).fontWeight(.medium)
                Text(action.isPushToTalk ? "Hold nede for at optage" : "Tryk én gang")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if hotkeyErrorAction == action, let msg = hotkeyErrorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 180, alignment: .trailing)
                    .lineLimit(2)
            }
            HotkeyRecorderView(currentBinding: binding) { keyCode, modifiers in
                let result = hotkeys.update(action, keyCode: keyCode, modifiers: modifiers)
                switch result {
                case .valid:
                    hotkeyErrorAction = nil
                    hotkeyErrorMessage = nil
                case .invalid(let msg):
                    hotkeyErrorAction = action
                    hotkeyErrorMessage = msg
                }
            }
            .frame(width: 140, height: 28)
        }
        .padding(.vertical, Constants.Spacing.sm)
    }
}

// MARK: - Location pane

struct SettingsLocationPane: View {
    @State private var homeAddress = ""
    @State private var manualCity = ""

    var body: some View {
        SettingsPane(
            title: "Lokation",
            subtitle: "Bruges af Uptodate-panelet til vejr, og Info-mode til beregning af køretid hjem."
        ) {
            SettingsCard(
                title: "By",
                footer: "Hvis denne er tom bruger Ultron lokationstjenester. Indsæt en by hvis du vil omgå GPS."
            ) {
                LabeledContent("Manuel by") {
                    HStack {
                        TextField("fx København, Aarhus, …", text: $manualCity)
                            .textFieldStyle(.roundedBorder)
                        Button("Gem") {
                            (NSApp.delegate as? AppDelegate)?.locationService.manualCity =
                                manualCity.isEmpty ? nil : manualCity
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            SettingsCard(
                title: "Hjemadresse",
                footer: "Bruges af Info-mode (⌥I) til at beregne køretid og Tesla-forbrug."
            ) {
                LabeledContent("Hjemadresse") {
                    HStack {
                        TextField("fx Nørregade 12, 1165 København", text: $homeAddress)
                            .textFieldStyle(.roundedBorder)
                        Button("Gem") {
                            (NSApp.delegate as? AppDelegate)?.locationService.homeAddress =
                                homeAddress.isEmpty ? nil : homeAddress
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onAppear {
            if let locationService = (NSApp.delegate as? AppDelegate)?.locationService {
                homeAddress = locationService.homeAddress ?? ""
                manualCity = locationService.manualCity ?? ""
            }
        }
    }
}

// MARK: - Voice pane (wake word)

struct SettingsVoicePane: View {
    @AppStorage(Constants.Defaults.wakeWordEnabled) private var wakeWordEnabled = false
    @AppStorage(Constants.Defaults.voiceCommandsEnabled) private var voiceCommandsEnabled = false
    @State private var porcupineKey = ""
    @State private var wakeWordStatus: String?
    private let keychainService = KeychainService()

    var body: some View {
        SettingsPane(
            title: "Stemme",
            subtitle: "Ultron kan lytte kontinuerligt efter kommandoer uden at du skal trykke en hotkey."
        ) {
            SettingsCard(
                title: "Voice commands",
                footer: "Kør on-device via Apples speech-recognizer. Sig fx \"Ultron info\", \"Ultron update\", \"Ultron chat\", \"Ultron oversæt\" for at starte den respektive mode."
            ) {
                Toggle("Lyt efter \"Ultron …\" kommandoer", isOn: $voiceCommandsEnabled)
                    .onChange(of: voiceCommandsEnabled) { _, _ in
                        NotificationCenter.default.post(name: .ultronVoiceCommandSettingsChanged, object: nil)
                    }
                Text("Genkendte kommandoer: **info**, **update**, **chat**, **spørg**, **oversæt**, **opsummer**.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsCard(
                title: "Wake word (Porcupine)",
                footer: "Lavere strømforbrug end voice commands ovenfor, men mindre fleksibelt — \"Ultron\" alene starter bare Q&A. Aktiveres fuldt i β med SPM-pakken."
            ) {
                Toggle("Aktivér 'Ultron' wake word", isOn: $wakeWordEnabled)
                    .onChange(of: wakeWordEnabled) { _, _ in
                        NotificationCenter.default.post(name: .ultronWakeWordSettingsChanged, object: nil)
                    }

                LabeledContent("Picovoice AccessKey") {
                    HStack {
                        SecureField("paste nøglen her", text: $porcupineKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Gem") {
                            keychainService.clearCache()
                            if keychainService.savePorcupineKey(porcupineKey) {
                                wakeWordStatus = "Gemt"
                                NotificationCenter.default.post(name: .ultronWakeWordSettingsChanged, object: nil)
                            } else {
                                wakeWordStatus = "Kunne ikke gemme nøglen"
                            }
                        }
                        .disabled(porcupineKey.isEmpty)
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack {
                    if let status = wakeWordStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Få gratis AccessKey →", destination: URL(string: "https://picovoice.ai/console/")!)
                        .font(.caption)
                }
            }

            SettingsCard(
                title: "Offline STT (WhisperKit)",
                footer: "Modellen på 632 MB hentes én gang og caches lokalt. Ultron bruger den som standard for dikterings-modes, så dine stemmeoptagelser aldrig forlader maskinen."
            ) {
                whisperStatusRow
                HStack {
                    Button("Forhåndsindlæs nu") {
                        triggerPreload()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWhisperBusy)
                    Spacer()
                }
            }
        }
        .onAppear {
            if let existing = keychainService.getPorcupineKey() { porcupineKey = existing }
        }
    }

    // MARK: - WhisperKit status helpers

    @ViewBuilder
    private var whisperStatusRow: some View {
        #if canImport(WhisperKit)
        let state = WhisperKitTranscriber.preloadState
        HStack(spacing: Constants.Spacing.sm) {
            Image(systemName: whisperIcon(for: state.phase))
                .foregroundStyle(whisperTint(for: state.phase))
            Text(whisperLabel(for: state.phase, progress: state.progress))
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
        #else
        HStack(spacing: Constants.Spacing.sm) {
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            Text("WhisperKit-pakken er ikke wired up i dette build").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        #endif
    }

    #if canImport(WhisperKit)
    private var isWhisperBusy: Bool {
        switch WhisperKitTranscriber.preloadState.phase {
        case .downloading, .warming: return true
        default: return false
        }
    }

    private func whisperIcon(for phase: WhisperPreloadState.Phase) -> String {
        switch phase {
        case .idle:         return "circle"
        case .downloading:  return "arrow.down.circle"
        case .warming:      return "flame"
        case .ready:        return "checkmark.circle.fill"
        case .failed:       return "exclamationmark.triangle.fill"
        }
    }

    private func whisperTint(for phase: WhisperPreloadState.Phase) -> Color {
        switch phase {
        case .ready:  return .green
        case .failed: return .red
        default:      return .secondary
        }
    }

    private func whisperLabel(for phase: WhisperPreloadState.Phase, progress: Double) -> String {
        switch phase {
        case .idle:                 return "Ikke forhåndsindlæst — vent til første optagelse eller tryk \"Forhåndsindlæs nu\""
        case .downloading:          return String(format: "Henter model… %d%%", Int(progress * 100))
        case .warming:              return "Varmer model…"
        case .ready:                return "Klar (632 MB cached)"
        case .failed(let msg):      return "Fejlede: \(msg)"
        }
    }

    private func triggerPreload() {
        // Dispatch onto a detached task so the button press returns immediately.
        // The shared transcriber's `preload()` is idempotent: if already loaded,
        // it returns instantly and the UI just flips to `.ready`.
        Task.detached(priority: .userInitiated) {
            do {
                let transcriber = WhisperKitTranscriber()
                try await transcriber.preload()
            } catch {
                LoggingService.shared.log("Manual WhisperKit preload failed: \(error)", level: .error)
            }
        }
    }
    #else
    private var isWhisperBusy: Bool { true }
    private func triggerPreload() {}
    #endif
}

// MARK: - Claude Code pane

struct SettingsClaudePane: View {
    @AppStorage(Constants.Defaults.claudeDailyLimitTokens)
    private var claudeDailyLimit: Int = Constants.ClaudeStats.defaultDailyLimit
    @AppStorage(Constants.Defaults.claudeWeeklyLimitTokens)
    private var claudeWeeklyLimit: Int = Constants.ClaudeStats.defaultWeeklyLimit

    var body: some View {
        SettingsPane(
            title: "Claude Code",
            subtitle: "Token-budget som Info-mode (⌥I) bruger til progress-bars. Sæt dem så de matcher din plan."
        ) {
            SettingsCard(title: "Budget") {
                tokenRow(label: "Daily", value: $claudeDailyLimit, step: 250_000)
                Divider()
                tokenRow(label: "Ugentlig", value: $claudeWeeklyLimit, step: 1_000_000)
            }
        }
    }

    private func tokenRow(label: String, value: Binding<Int>, step: Int) -> some View {
        HStack(spacing: Constants.Spacing.md) {
            Text(label)
                .frame(width: 80, alignment: .leading)
                .font(.body.weight(.medium))
            TextField("", value: value, formatter: Self.integerFormatter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            Text("tokens").font(.callout).foregroundStyle(.secondary)
            Stepper("", value: value, in: 100_000...100_000_000, step: step)
                .labelsHidden()
            Spacer()
            Text(formatTokensShort(value.wrappedValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.allowsFloats = false
        return f
    }()

    private func formatTokensShort(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%dK", n / 1_000) }
        return String(n)
    }
}

// MARK: - History pane

struct SettingsHistoryPane: View {
    @State private var conversations: [Conversation] = []
    private let conversationStore = ConversationStore()

    var body: some View {
        SettingsPane(
            title: "Samtaler",
            subtitle: conversations.isEmpty ? nil : "Gemte chat-samtaler fra ⌥C."
        ) {
            if conversations.isEmpty {
                SettingsCard {
                    VStack(spacing: Constants.Spacing.md) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("Ingen samtaler endnu")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Brug ⌥C for at starte en chat med Ultron.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Constants.Spacing.xl)
                }
            } else {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        conversationStore.deleteAll()
                        conversations = []
                    } label: {
                        Label("Slet alle", systemImage: "trash")
                    }
                }
                SettingsCard {
                    VStack(spacing: 0) {
                        ForEach(Array(conversations.enumerated()), id: \.element.id) { index, convo in
                            if index > 0 { Divider() }
                            HStack(spacing: Constants.Spacing.md) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(convo.displayTitle).fontWeight(.medium).lineLimit(1)
                                    Text("\(convo.messages.count) beskeder")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(convo.updatedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, Constants.Spacing.sm)
                            .contextMenu {
                                Button("Slet", role: .destructive) {
                                    conversationStore.delete(id: convo.id)
                                    conversations.removeAll { $0.id == convo.id }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            conversations = conversationStore.loadAll()
        }
    }
}

// MARK: - Usage pane

struct SettingsUsagePane: View {
    @Environment(UsageTracker.self) private var usageTracker

    var body: some View {
        SettingsPane(
            title: "Forbrug",
            subtitle: "Dine Gemini API-omkostninger denne måned."
        ) {
            SettingsCard(title: "Denne måned") {
                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text("$\(String(format: "%.4f", usageTracker.currentUsage.totalCostUSD))")
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                Divider()
                usageRow("Flash Input",  tokens: usageTracker.currentUsage.flashInputTokens)
                usageRow("Flash Output", tokens: usageTracker.currentUsage.flashOutputTokens)
                usageRow("Pro Input",    tokens: usageTracker.currentUsage.proInputTokens)
                usageRow("Pro Output",   tokens: usageTracker.currentUsage.proOutputTokens)
            }
        }
    }

    private func usageRow(_ label: String, tokens: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text("\(tokens.formatted()) tokens").monospacedDigit()
        }
        .font(.callout)
    }
}

// MARK: - Agent pane

struct SettingsAgentPane: View {
    @AppStorage(Constants.Defaults.agentClaudeModel) private var claudeModel: String = "claude-sonnet-4-6"
    @AppStorage(Constants.Defaults.agentOllamaModel) private var ollamaModel: String = "llama3.2:latest"
    @State private var workspaceRoots: [String] = []
    @State private var newRoot: String = ""
    @State private var ollamaModels: [String] = []
    @State private var ollamaProbeState: OllamaProbeState = .unknown

    private enum OllamaProbeState: Equatable {
        case unknown
        case probing
        case running(modelCount: Int)
        case notRunning
    }

    private static let availableModels = [
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 — hurtig og billig ($3/$15 per M)"),
        ("claude-opus-4-7",   "Claude Opus 4.7 — stærkere, 5× dyrere ($15/$75 per M)")
    ]

    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ultron/agent.log")
    }

    var body: some View {
        SettingsPane(
            title: "Agent",
            subtitle: "⌥⇧A åbner en chat hvor U.L.T.R.O.N kan læse, skrive og flytte filer — altid med din godkendelse for ændringer. Mode-picker i chat vælger mellem Claude (cloud) og Ollama (lokal)."
        ) {
            SettingsCard(
                title: "Claude-model",
                footer: "Sonnet 4.6 er sjovt billig til de fleste tool-use-flows. Opus 4.7 kan være det værd til meget lange multi-trins-opgaver."
            ) {
                Picker("Model", selection: $claudeModel) {
                    ForEach(Self.availableModels, id: \.0) { pair in
                        Text(pair.1).tag(pair.0)
                    }
                }
                .pickerStyle(.menu)
            }

            SettingsCard(
                title: "Ollama (lokal LLM)",
                footer: "Daemon'en kører typisk via `brew services start ollama`. Hent en tool-kapabel model med fx `ollama pull llama3.2`."
            ) {
                HStack(spacing: Constants.Spacing.sm) {
                    ollamaStatusChip
                    Spacer()
                    Button("Gen-probe") {
                        Task { await probeOllama() }
                    }
                    .controlSize(.small)
                    .disabled(ollamaProbeState == .probing)
                }

                if ollamaModels.isEmpty {
                    Text("Ingen modeller fundet. Kør `ollama pull llama3.2` i terminalen og tryk Gen-probe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $ollamaModel) {
                        ForEach(ollamaModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            SettingsCard(
                title: "Arbejdsområde (allowed roots)",
                footer: "Agent-værktøjer kan kun læse/skrive inden for disse rødder. Destruktive handlinger (skrive, omdøb, slet) kræver stadig din godkendelse pr. gang."
            ) {
                if workspaceRoots.isEmpty {
                    Text("Ingen ekstra rødder — standarden er ~/Desktop, ~/Downloads og ~/Documents/Ultron.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(workspaceRoots.enumerated()), id: \.offset) { index, root in
                            if index > 0 { Divider() }
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(root)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(role: .destructive) {
                                    workspaceRoots.remove(at: index)
                                    saveRoots()
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, Constants.Spacing.sm)
                        }
                    }
                }

                HStack {
                    TextField("~/Documents/Projekter", text: $newRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("Tilføj") {
                        let trimmed = newRoot.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        if !workspaceRoots.contains(trimmed) {
                            workspaceRoots.append(trimmed)
                            saveRoots()
                        }
                        newRoot = ""
                    }
                    .disabled(newRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }

            SettingsCard(
                title: "Audit-log",
                footer: "Hver tool-eksekvering skrives her med argumenter + resultat + varighed."
            ) {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("~/Library/Logs/Ultron/agent.log")
                        .font(.caption.monospaced())
                    Spacer()
                    Button("Åbn") {
                        if FileManager.default.fileExists(atPath: logURL.path) {
                            NSWorkspace.shared.open(logURL)
                        } else {
                            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            workspaceRoots = UserDefaults.standard.stringArray(forKey: Constants.Defaults.agentWorkspaceRoots) ?? []
            Task { await probeOllama() }
        }
    }

    private func saveRoots() {
        UserDefaults.standard.set(workspaceRoots, forKey: Constants.Defaults.agentWorkspaceRoots)
    }

    @ViewBuilder
    private var ollamaStatusChip: some View {
        switch ollamaProbeState {
        case .unknown, .probing:
            Label("Tjekker…", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running(let count):
            Label("Kører (\(count) \(count == 1 ? "model" : "modeller"))", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .notRunning:
            Label("Ikke tilgængelig på :11434", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func probeOllama() async {
        ollamaProbeState = .probing
        let models = await OllamaProvider.probeInstalledModels()
        await MainActor.run {
            if let models {
                ollamaModels = models.sorted()
                ollamaProbeState = .running(modelCount: models.count)
                // Auto-pick the first installed model if the saved preference
                // isn't actually available (fresh install or model uninstalled).
                if !models.contains(ollamaModel), let first = models.first {
                    ollamaModel = first
                }
            } else {
                ollamaModels = []
                ollamaProbeState = .notRunning
            }
        }
    }
}

// MARK: - About pane

struct SettingsAboutPane: View {
    var body: some View {
        SettingsPane(title: "Om Ultron") {
            SettingsCard {
                HStack(alignment: .top, spacing: Constants.Spacing.lg) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil)!)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                        Text(Constants.displayName).font(.title.weight(.bold))
                        Text("Version \(Constants.appVersion)")
                            .foregroundStyle(.secondary)
                        Text("AI voice assistant for macOS. Gemini + Claude + on-device speech.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }

            SettingsCard(title: "Logs") {
                Button {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/Ultron"))
                } label: {
                    Label("Åbn logs-mappen", systemImage: "folder")
                }
            }
        }
    }
}

// MARK: - NewModeView (unchanged, but polished)

struct NewModeView: View {
    let modeManager: ModeManager
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var model: GeminiModel = .flash
    @State private var outputType: OutputType = .paste

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.lg) {
            Text("Ny brugerdefineret mode").font(.title3.weight(.semibold))

            Form {
                TextField("Navn", text: $name)
                Picker("Model", selection: $model) {
                    ForEach(GeminiModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Output", selection: $outputType) {
                    ForEach(OutputType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            .formStyle(.grouped)

            Text("Systemprompt")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $systemPrompt)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("Annuller") { isPresented = false }
                Button("Opret") {
                    let mode = Mode(id: UUID(), name: name, systemPrompt: systemPrompt,
                                    model: model, outputType: outputType, maxTokens: 2048, isBuiltIn: false)
                    modeManager.addCustomMode(mode)
                    isPresented = false
                }
                .disabled(name.isEmpty || systemPrompt.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 480)
    }
}
