import SwiftUI

/// One agent tool invocation rendered as a compact card. v1.4 Fase 2b.2 —
/// replaces the previous plain-text audit dump so users get a scannable row
/// per tool: icon · name · duration · status-badge, with tap-to-expand for
/// the input / result summaries.
///
/// Kept deliberately shorter than a MessageBubble: tools are scaffolding,
/// not conversation. The card collapses by default and only reveals detail
/// when the user cares.
struct ToolInvocationCard: View {
    let invocation: AgentService.ToolInvocation
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(UltronTheme.surfaceElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            // Left-edge accent bar — subtle "activity" indicator.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accentForStatus)
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.leading, -1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expanded.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(invocation.name) \(invocation.success ? "lykkedes" : "fejlede") på \(invocation.durationMs) ms")
        .accessibilityHint(expanded ? "Tryk for at skjule detaljer" : "Tryk for at vise detaljer")
    }

    // MARK: - Header row (always visible)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentForStatus)
                .frame(width: 14)
            Text(invocation.name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(UltronTheme.textPrimary)
            Spacer(minLength: 8)
            Text(formattedDuration)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(UltronTheme.textSecondary)
            Image(systemName: invocation.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(invocation.success ? UltronTheme.accent : .red)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(UltronTheme.textSecondary.opacity(0.7))
        }
    }

    // MARK: - Expanded detail (input / result)

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !invocation.inputSummary.isEmpty {
                detailRow(label: "Input", body: invocation.inputSummary)
            }
            if !invocation.resultSummary.isEmpty {
                detailRow(label: invocation.success ? "Resultat" : "Fejl", body: invocation.resultSummary)
            }
        }
        .padding(.top, 6)
    }

    private func detailRow(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(UltronTheme.textSecondary.opacity(0.7))
            Text(body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(UltronTheme.textPrimary.opacity(0.85))
                .textSelection(.enabled)
                .lineLimit(8)
                .truncationMode(.middle)
        }
    }

    // MARK: - Derived styling

    private var accentForStatus: Color {
        invocation.success ? UltronTheme.accent : .red.opacity(0.85)
    }

    private var borderColor: Color {
        Color.primary.opacity(0.08)
    }

    /// Map well-known tool names to SF Symbols. Falls back to a generic wrench
    /// so new tools don't need a code change to render sensibly.
    private var iconName: String {
        switch invocation.name.lowercased() {
        case "read_file":       return "doc.text"
        case "write_file":      return "square.and.pencil"
        case "edit_file":       return "pencil"
        case "list_directory":  return "folder"
        case "search_files":    return "magnifyingglass"
        case "stat_file":       return "info.circle"
        case "run_shell":       return "terminal"
        case "delete_file":     return "trash"
        case "rename_file":     return "pencil.and.outline"
        case "create_directory": return "folder.badge.plus"
        default:                return "wrench.adjustable"
        }
    }

    private var formattedDuration: String {
        if invocation.durationMs < 1000 {
            return "\(invocation.durationMs) ms"
        }
        return String(format: "%.1fs", Double(invocation.durationMs) / 1000.0)
    }
}
