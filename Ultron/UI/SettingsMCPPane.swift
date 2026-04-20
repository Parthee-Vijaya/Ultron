import SwiftUI

/// Settings pane for managing MCP (Model Context Protocol) servers.
/// Wraps the JSON editor at `~/.ultron/mcp.json` in a proper form so users
/// can add, edit, and delete servers without touching a text editor.
struct SettingsMCPPane: View {
    /// Edit form backed by a single server entry. Value-typed so form
    /// mutations don't propagate until the user taps "Gem".
    struct Draft: Identifiable, Equatable {
        var id = UUID()
        /// The server name key in `servers` map. If `originalName` differs
        /// from `name`, the save path deletes the old key + inserts the new.
        var originalName: String?
        var name: String = ""
        var command: String = ""
        var args: [String] = []
        var envPairs: [EnvPair] = []

        struct EnvPair: Identifiable, Equatable {
            let id = UUID()
            var key: String = ""
            var value: String = ""
        }

        var envDict: [String: String] {
            var dict: [String: String] = [:]
            for pair in envPairs where !pair.key.isEmpty {
                dict[pair.key] = pair.value
            }
            return dict
        }

        static func from(name: String, server: MCPRegistry.MCPConfig.Server) -> Draft {
            Draft(
                originalName: name,
                name: name,
                command: server.command,
                args: server.args ?? [],
                envPairs: (server.env ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { EnvPair(key: $0.key, value: $0.value) }
            )
        }

        func toServer() -> MCPRegistry.MCPConfig.Server {
            MCPRegistry.MCPConfig.Server(
                command: command.trimmingCharacters(in: .whitespaces),
                args: args.isEmpty ? nil : args,
                env: envDict.isEmpty ? nil : envDict
            )
        }
    }

    @State private var configSnapshot: [String: MCPRegistry.MCPConfig.Server] = [:]
    @State private var editingDraft: Draft?
    @State private var deletionCandidate: String?
    @State private var isReloading = false
    @State private var saveError: String?

    private var registryState: MCPRegistryState { MCPRegistry.shared.state }

    var body: some View {
        SettingsPane(
            title: "MCP-servere",
            subtitle: "Model Context Protocol-servere eksponerer eksterne værktøjer til Agent-mode. Gemmes i ~/.ultron/mcp.json."
        ) {
            if configSnapshot.isEmpty && editingDraft == nil {
                emptyStateCard
            } else {
                serverListCard
            }

            if let draft = editingDraft {
                editorCard(draft: draft)
            }

            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            bottomBar
        }
        .onAppear {
            reloadSnapshot()
        }
        .alert("Slet MCP-server?",
               isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
               )) {
            Button("Annuller", role: .cancel) { deletionCandidate = nil }
            Button("Slet", role: .destructive) {
                if let name = deletionCandidate {
                    Task { await deleteServer(named: name) }
                }
                deletionCandidate = nil
            }
        } message: {
            if let name = deletionCandidate {
                Text("Vil du slette '\(name)' fra mcp.json? Serveren stoppes med det samme.")
            }
        }
    }

    // MARK: - Top-level cards

    private var emptyStateCard: some View {
        SettingsCard {
            VStack(spacing: Constants.Spacing.md) {
                Image(systemName: "server.rack")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("Ingen MCP-servere konfigureret endnu")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Tilføj fx filesystem, git eller din egen MCP-server for at give Agent-mode flere værktøjer.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button {
                    beginAddingServer()
                } label: {
                    Label("Tilføj første server", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Constants.Spacing.xl)
        }
    }

    private var serverListCard: some View {
        SettingsCard(
            title: "Konfigurerede servere",
            footer: "Tryk på blyanten for at redigere en server inline. Ændringer skrives til ~/.ultron/mcp.json og serverne genindlæses."
        ) {
            VStack(spacing: 0) {
                let names = configSnapshot.keys.sorted()
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    if index > 0 { Divider() }
                    serverRow(name: name)
                }
            }

            HStack {
                Spacer()
                Button {
                    beginAddingServer()
                } label: {
                    Label("Tilføj server", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private func serverRow(name: String) -> some View {
        let status = registryState.servers.first { $0.name == name }
        HStack(spacing: Constants.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                if let status {
                    Text(statusSubtitle(for: status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let server = configSnapshot[name] {
                    Text(server.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            statusChip(for: status)

            Button {
                if let server = configSnapshot[name] {
                    editingDraft = Draft.from(name: name, server: server)
                }
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rediger")

            Button(role: .destructive) {
                deletionCandidate = name
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Slet")
        }
        .padding(.vertical, Constants.Spacing.sm)
    }

    private func statusSubtitle(for status: MCPServerStatus) -> String {
        switch status.state {
        case .starting:
            return "Starter…"
        case .running(let toolCount):
            return "\(toolCount) værktøj\(toolCount == 1 ? "" : "er") · \(status.command)"
        case .crashed(let msg):
            return "Fejl: \(msg)"
        case .stopped:
            return "Stoppet · \(status.command)"
        }
    }

    @ViewBuilder
    private func statusChip(for status: MCPServerStatus?) -> some View {
        let (label, color): (String, Color) = {
            guard let status else { return ("Ikke startet", .gray) }
            switch status.state {
            case .starting:           return ("Starter", .yellow)
            case .running(let count): return ("Kører · \(count)", .green)
            case .crashed:            return ("Fejl", .red)
            case .stopped:            return ("Stoppet", .gray)
            }
        }()
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, Constants.Spacing.sm)
            .padding(.vertical, Constants.Spacing.xxs)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    // MARK: - Editor card

    @ViewBuilder
    private func editorCard(draft: Draft) -> some View {
        let isNew = draft.originalName == nil
        SettingsCard(
            title: isNew ? "Ny MCP-server" : "Redigér '\(draft.originalName ?? "")'",
            footer: "Kommandoen køres via /usr/bin/env så PATH virker for npx, uvx, python osv."
        ) {
            LabeledContent("Navn") {
                TextField("fx filesystem", text: bindingName())
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
            LabeledContent("Kommando") {
                TextField("fx npx", text: bindingCommand())
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            argumentsEditor(draft: draft)
            environmentEditor(draft: draft)

            HStack {
                Spacer()
                Button("Annuller") {
                    editingDraft = nil
                    saveError = nil
                }
                Button("Gem") {
                    Task { await commitDraft() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDraftValid(draft))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func argumentsEditor(draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
            HStack {
                Text("Argumenter")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    editingDraft?.args.append("")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Tilføj argument")
            }
            if draft.args.isEmpty {
                Text("Ingen argumenter.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(draft.args.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        TextField("fx -y eller @modelcontextprotocol/server-filesystem",
                                  text: bindingArg(at: index))
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        Button(role: .destructive) {
                            editingDraft?.args.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func environmentEditor(draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
            HStack {
                Text("Miljøvariabler")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    editingDraft?.envPairs.append(Draft.EnvPair())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Tilføj miljøvariabel")
            }
            if draft.envPairs.isEmpty {
                Text("Ingen miljøvariabler.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(draft.envPairs.enumerated()), id: \.element.id) { index, _ in
                    HStack {
                        TextField("KEY", text: bindingEnvKey(at: index))
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .frame(maxWidth: 160)
                        Text("=").foregroundStyle(.secondary)
                        TextField("value", text: bindingEnvValue(at: index))
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        Button(role: .destructive) {
                            editingDraft?.envPairs.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button {
                Task { await reloadAll() }
            } label: {
                if isReloading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Genindlæs alle", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isReloading)
        }
    }

    // MARK: - Actions

    private func beginAddingServer() {
        saveError = nil
        editingDraft = Draft()
    }

    private func reloadSnapshot() {
        configSnapshot = MCPRegistry.readConfigSnapshot()
    }

    private func isDraftValid(_ draft: Draft) -> Bool {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespaces)
        let trimmedCmd = draft.command.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedCmd.isEmpty else { return false }
        // Unique-name check (unless we're editing the same server).
        if trimmedName != draft.originalName, configSnapshot.keys.contains(trimmedName) {
            return false
        }
        return true
    }

    private func commitDraft() async {
        guard let draft = editingDraft else { return }
        let trimmedName = draft.name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var next = configSnapshot
        if let original = draft.originalName, original != trimmedName {
            next.removeValue(forKey: original)
        }
        next[trimmedName] = draft.toServer()

        do {
            try await MCPRegistry.shared.save(servers: next)
            editingDraft = nil
            saveError = nil
            reloadSnapshot()
        } catch {
            saveError = "Kunne ikke gemme: \(error.localizedDescription)"
        }
    }

    private func deleteServer(named name: String) async {
        var next = configSnapshot
        next.removeValue(forKey: name)
        do {
            try await MCPRegistry.shared.save(servers: next)
            reloadSnapshot()
        } catch {
            saveError = "Kunne ikke slette: \(error.localizedDescription)"
        }
    }

    private func reloadAll() async {
        isReloading = true
        await MCPRegistry.shared.reload()
        reloadSnapshot()
        isReloading = false
    }

    // MARK: - Bindings into @State draft

    private func bindingName() -> Binding<String> {
        Binding(
            get: { editingDraft?.name ?? "" },
            set: { editingDraft?.name = $0 }
        )
    }

    private func bindingCommand() -> Binding<String> {
        Binding(
            get: { editingDraft?.command ?? "" },
            set: { editingDraft?.command = $0 }
        )
    }

    private func bindingArg(at index: Int) -> Binding<String> {
        Binding(
            get: { editingDraft?.args[safe: index] ?? "" },
            set: { newValue in
                guard var draft = editingDraft, draft.args.indices.contains(index) else { return }
                draft.args[index] = newValue
                editingDraft = draft
            }
        )
    }

    private func bindingEnvKey(at index: Int) -> Binding<String> {
        Binding(
            get: { editingDraft?.envPairs[safe: index]?.key ?? "" },
            set: { newValue in
                guard var draft = editingDraft, draft.envPairs.indices.contains(index) else { return }
                draft.envPairs[index].key = newValue
                editingDraft = draft
            }
        )
    }

    private func bindingEnvValue(at index: Int) -> Binding<String> {
        Binding(
            get: { editingDraft?.envPairs[safe: index]?.value ?? "" },
            set: { newValue in
                guard var draft = editingDraft, draft.envPairs.indices.contains(index) else { return }
                draft.envPairs[index].value = newValue
                editingDraft = draft
            }
        )
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
