import SwiftUI

/// Which Settings tab is frontmost. Exposed so `AppDelegate` can deep-link from
/// the menu bar "Hotkeys…" item straight to the Hotkeys tab.
enum SettingsTab: Hashable {
    case apiKey, modes, hotkeys, history, usage, general
}

struct SettingsView: View {
    @Environment(ModeManager.self) private var modeManager
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(HotkeyBindings.self) private var hotkeys

    @Binding var selectedTab: SettingsTab

    @State private var apiKey = ""
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isTesting = false
    @State private var showingNewMode = false
    @AppStorage("ttsEnabled") private var ttsEnabled = false
    @AppStorage(Constants.Defaults.wakeWordEnabled) private var wakeWordEnabled = false
    @AppStorage(Constants.Defaults.hudStyle) private var hudStyleRaw: String = HUDStylePreference.auto.rawValue
    @State private var porcupineKey = ""
    @State private var wakeWordStatus: String?

    private let keychainService = KeychainService()

    enum ConnectionStatus {
        case unknown, connected, failed(String)

        var label: String {
            switch self {
            case .unknown: return ""
            case .connected: return "Connected"
            case .failed(let msg): return "Failed: \(msg)"
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

    @State private var conversations: [Conversation] = []
    private let conversationStore = ConversationStore()

    var body: some View {
        TabView(selection: $selectedTab) {
            apiKeyTab
                .tabItem { Label("API Key", systemImage: "key") }
                .tag(SettingsTab.apiKey)
            modesTab
                .tabItem { Label("Modes", systemImage: "list.bullet") }
                .tag(SettingsTab.modes)
            hotkeysTab
                .tabItem { Label("Hotkeys", systemImage: "command") }
                .tag(SettingsTab.hotkeys)
            historyTab
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
            usageTab
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag(SettingsTab.usage)
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)
        }
        .frame(width: 520, height: 500)
        .onAppear {
            if let existing = keychainService.getAPIKey() {
                apiKey = existing
            }
            if let existing = keychainService.getPorcupineKey() {
                porcupineKey = existing
            }
        }
    }

    private var apiKeyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gemini API Key").font(.headline)
            Text("Get your API key from aistudio.google.com")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                SecureField("Enter API key...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    keychainService.clearCache()
                    if keychainService.saveAPIKey(apiKey) {
                        LoggingService.shared.log("API key saved to Keychain (cache invalidated)")
                        connectionStatus = .unknown
                        // Drop the cached SDK Chat so the next chat message uses the new key.
                        (NSApp.delegate as? AppDelegate)?.resetChatPipelineForKeyRotation()
                    }
                }
                .disabled(apiKey.isEmpty)
            }

            HStack {
                Button("Test Connection") { testConnection() }
                    .disabled(apiKey.isEmpty || isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                Text(connectionStatus.label)
                    .foregroundStyle(connectionStatus.color).font(.caption)
            }
            Spacer()
        }
        .padding()
    }

    private var modesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modes").font(.headline)
            List {
                Section("Built-in") {
                    ForEach(BuiltInModes.all) { mode in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(mode.name).fontWeight(.medium)
                                Text(mode.model.displayName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(mode.outputType.displayName)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.quaternary).clipShape(Capsule())
                        }
                    }
                }
                Section("Custom") {
                    ForEach(modeManager.customModes) { mode in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(mode.name).fontWeight(.medium)
                                Text(mode.model.displayName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                modeManager.deleteCustomMode(id: mode.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if modeManager.customModes.isEmpty {
                        Text("No custom modes yet").foregroundStyle(.secondary)
                    }
                }
            }
            Button("New Custom Mode...") { showingNewMode = true }
                .sheet(isPresented: $showingNewMode) {
                    NewModeView(modeManager: modeManager, isPresented: $showingNewMode)
                }
        }
        .padding()
    }

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Usage This Month").font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Total Cost:")
                        Spacer()
                        Text("$\(String(format: "%.4f", usageTracker.currentUsage.totalCostUSD))")
                            .fontWeight(.bold).monospacedDigit()
                    }
                    Divider()
                    UsageRow(label: "Flash Input", tokens: usageTracker.currentUsage.flashInputTokens)
                    UsageRow(label: "Flash Output", tokens: usageTracker.currentUsage.flashOutputTokens)
                    UsageRow(label: "Pro Input", tokens: usageTracker.currentUsage.proInputTokens)
                    UsageRow(label: "Pro Output", tokens: usageTracker.currentUsage.proOutputTokens)
                }
                .padding(4)
            }
            Spacer()
        }
        .padding()
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation History").font(.headline)
                Spacer()
                if !conversations.isEmpty {
                    Button("Slet alle", role: .destructive) {
                        conversationStore.deleteAll()
                        conversations = []
                    }
                    .controlSize(.small)
                }
            }
            if conversations.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Ingen samtaler endnu")
                        .foregroundStyle(.secondary)
                    Text("Brug ⌥C for at starte en chat")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(conversations) { convo in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(convo.displayTitle)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            HStack {
                                Text("\(convo.messages.count) beskeder")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(convo.updatedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
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
        .padding()
        .onAppear {
            conversations = conversationStore.loadAll()
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General").font(.headline)
            GroupBox {
                Toggle("Text-to-Speech for HUD responses", isOn: $ttsEnabled)
                Text("When enabled, Q&A and Vision responses will be read aloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            hudStyleSection
            GroupBox {
                HStack {
                    Image(systemName: "command").foregroundStyle(.secondary)
                    Text("Tilpas hotkeys i **Hotkeys**-fanen.").font(.callout)
                    Spacer()
                    Button("Gå til Hotkeys") { selectedTab = .hotkeys }
                        .controlSize(.small)
                }
            }
            wakeWordSection
            Spacer()
        }
        .padding()
    }

    private var hudStyleSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HUD-stil").fontWeight(.medium)
                    Spacer()
                    Picker("", selection: $hudStyleRaw) {
                        ForEach(HUDStylePreference.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .labelsHidden()
                }
                Text("**Auto** vælger notch-stil på MacBooks med notch, ellers hjørne øverst til højre. Ændring træder i kraft næste gang HUD åbnes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var wakeWordSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Aktivér 'Jarvis' wake word", isOn: $wakeWordEnabled)
                    .onChange(of: wakeWordEnabled) { _, _ in
                        NotificationCenter.default.post(name: .jarvisWakeWordSettingsChanged, object: nil)
                    }
                Text("Sig \"Jarvis\" for at trigge en Q&A i stedet for at holde hotkeyen. Lyd behandles on-device via Picovoice Porcupine — intet forlader din Mac før wakewordet hører dit navn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    SecureField("Picovoice AccessKey", text: $porcupineKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Gem nøgle") {
                        keychainService.clearCache()
                        if keychainService.savePorcupineKey(porcupineKey) {
                            wakeWordStatus = "Gemt."
                            NotificationCenter.default.post(name: .jarvisWakeWordSettingsChanged, object: nil)
                        } else {
                            wakeWordStatus = "Kunne ikke gemme nøglen."
                        }
                    }
                    .disabled(porcupineKey.isEmpty)
                }
                if let status = wakeWordStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Link("Få en gratis AccessKey på picovoice.ai/console",
                     destination: URL(string: "https://picovoice.ai/console/")!)
                    .font(.caption)
            }
        }
    }

    // MARK: - Hotkeys

    @State private var hotkeyErrorMessage: String?
    @State private var hotkeyErrorAction: HotkeyAction?

    private var hotkeysTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hotkeys").font(.headline)
                Spacer()
                Button("Nulstil til standard") { hotkeys.resetAll() }
                    .controlSize(.small)
            }
            Text("Klik på en felt og tryk en tastkombination. Tryk ⎋ for at annullere.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(HotkeyAction.allCases) { action in
                        hotkeyRow(for: action)
                    }
                }
            }
        }
        .padding()
    }

    private func hotkeyRow(for action: HotkeyAction) -> some View {
        let binding = hotkeys.binding(for: action)
        return GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName).fontWeight(.medium)
                    Text(action.isPushToTalk ? "Hold nede for at optage" : "Tryk én gang")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hotkeyErrorAction == action, let msg = hotkeyErrorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 180, alignment: .trailing)
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
                .frame(width: 130, height: 26)
            }
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

struct UsageRow: View {
    let label: String
    let tokens: Int
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text("\(tokens) tokens").monospacedDigit()
        }
        .font(.caption)
    }
}

struct NewModeView: View {
    let modeManager: ModeManager
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var model: GeminiModel = .flash
    @State private var outputType: OutputType = .paste

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Custom Mode").font(.headline)
            TextField("Mode name", text: $name).textFieldStyle(.roundedBorder)
            Text("System Prompt:").font(.subheadline)
            TextEditor(text: $systemPrompt)
                .font(.body).frame(minHeight: 120)
                .border(Color.secondary.opacity(0.3))
            Picker("Model:", selection: $model) {
                ForEach(GeminiModel.allCases, id: \.self) { m in Text(m.displayName).tag(m) }
            }
            Picker("Output:", selection: $outputType) {
                ForEach(OutputType.allCases, id: \.self) { o in Text(o.displayName).tag(o) }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
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
        .frame(width: 450, height: 400)
    }
}

struct ShortcutRow: View {
    let keys: String
    let description: String
    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
    }
}
