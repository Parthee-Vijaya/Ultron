import AppKit
import SwiftUI

/// Popover-style cheat sheet listing every bound hotkey + voice command. Opened
/// from the menu bar ("Hotkeys & kommandoer …") or the chat window's help
/// icon. Reads bindings live from `HotkeyBindings` so user edits show up
/// immediately.
struct HotkeyCheatSheet: View {
    let bindings: HotkeyBindings
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
                    .foregroundStyle(UltronTheme.accent)
                Text("Hotkeys & kommandoer")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(UltronTheme.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UltronTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(UltronTheme.surfaceElevated)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().background(UltronTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(title: "Hotkeys") {
                        ForEach(HotkeyAction.allCases, id: \.self) { action in
                            row(label: action.displayName,
                                shortcut: bindings.binding(for: action).displayString)
                        }
                    }

                    section(title: "Voice commands (hvis aktiveret)") {
                        row(label: "Åbn chat",      shortcut: "„Ultron chat“")
                        row(label: "Åbn Cockpit",   shortcut: "„Ultron cockpit / info“")
                        row(label: "Åbn Briefing",  shortcut: "„Ultron briefing / nyheder“")
                        row(label: "Stil spørgsmål", shortcut: "„Ultron spørg …“")
                        row(label: "Oversæt",       shortcut: "„Ultron oversæt …“")
                        row(label: "Opsummer",      shortcut: "„Ultron opsummer …“")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 420, height: 520)
        .background(UltronTheme.surfaceBase)
        .dynamicTypeSize(.xSmall ... .xxxLarge)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(UltronTheme.textMuted)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }

    private func row(label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(UltronTheme.textPrimary)
            Spacer()
            Text(shortcut)
                .font(.caption2.monospaced())
                .foregroundStyle(UltronTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(UltronTheme.surfaceElevated)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(UltronTheme.hairline, lineWidth: 0.5))
                )
        }
        .padding(.vertical, 2)
    }
}
