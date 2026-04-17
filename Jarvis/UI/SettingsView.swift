import SwiftUI

struct SettingsView: View {
    @Environment(ModeManager.self) private var modeManager
    @Environment(UsageTracker.self) private var usageTracker

    @State private var apiKey = ""
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isTesting = false
    @State private var showingNewMode = false
    @AppStorage("ttsEnabled") private var ttsEnabled = false

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

    var body: some View {
        TabView {
            apiKeyTab
                .tabItem { Label("API Key", systemImage: "key") }
            modesTab
                .tabItem { Label("Modes", systemImage: "list.bullet") }
            usageTab
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 500, height: 450)
        .onAppear {
            if let existing = keychainService.getAPIKey() {
                apiKey = existing
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
                    if keychainService.saveAPIKey(apiKey) {
                        LoggingService.shared.log("API key saved to Keychain")
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

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General").font(.headline)
            GroupBox {
                Toggle("Text-to-Speech for HUD responses", isOn: $ttsEnabled)
                Text("When enabled, Q&A and Vision responses will be read aloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keyboard Shortcuts").fontWeight(.medium)
                    ShortcutRow(keys: "⌥ Space", description: "Push-to-talk (active mode)")
                    ShortcutRow(keys: "⌥ Q", description: "Push-to-talk Q&A mode")
                    ShortcutRow(keys: "⌥ ⇧ Space", description: "Vision mode (screenshot + voice)")
                    ShortcutRow(keys: "⌥ M", description: "Cycle modes")
                }
            }
            Spacer()
        }
        .padding()
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
