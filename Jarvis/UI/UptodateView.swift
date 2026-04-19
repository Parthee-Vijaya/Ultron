import AppKit
import SwiftUI

struct UptodateView: View {
    @Bindable var service: UpdatesService
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 12) {
                topRow
                middleRow
                historyTile
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 720, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        // v1.4 Fase 2c: same chat-family backdrop as Cockpit + corner HUD
        // so Briefing slots into the unified visual system.
        .jarvisChatBackdrop()
        .task {
            await service.refresh()
        }
    }

    // MARK: - Header (chat-family minimal chrome)

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            JarvisWordmark(fontSize: 13)
            Text("Briefing")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(JarvisTheme.textPrimary)
                .padding(.leading, 4)
            if let last = service.lastRefresh {
                Text("opdateret \(timeAgo(last))")
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.textMuted)
            }
            Spacer()
            Button {
                Task { await service.refresh(force: true) }
            } label: {
                Image(systemName: service.state == .loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textSecondary)
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(JarvisTheme.surfaceElevated.opacity(0.55))
                    )
            }
            .buttonStyle(.plain)
            .help("Opdater")
            .accessibilityLabel("Opdater")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textSecondary)
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(JarvisTheme.surfaceElevated.opacity(0.55))
                    )
            }
            .buttonStyle(.plain)
            .help("Luk")
            .accessibilityLabel("Luk")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Rows

    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            newsSourceTile(.dr)
            newsSourceTile(.politiken)
            newsSourceTile(.bbc)
        }
    }

    private var middleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            newsSourceTile(.guardian)
            newsSourceTile(.reddit)
            newsSourceTile(.hackernews)
        }
    }

    // MARK: - News source tile

    private func newsSourceTile(_ source: NewsHeadline.Source) -> some View {
        let items = service.news[source] ?? []
        return tile(title: source.displayName, icon: sourceIcon(for: source)) {
            if items.isEmpty {
                placeholder(service.state == .loading ? "Henter…" : "Ingen nyheder")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items.prefix(3)) { item in
                        Button {
                            if let link = item.link { NSWorkspace.shared.open(link) }
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(Color.white.opacity(0.5))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 5)
                                Text(item.title)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sourceIcon(for source: NewsHeadline.Source) -> String {
        switch source {
        case .dr, .politiken, .bbc, .guardian: return "newspaper"
        case .reddit:                          return "bubble.left.and.bubble.right"
        case .hackernews:                      return "terminal"
        }
    }

    // MARK: - History tile

    @ViewBuilder
    private var historyTile: some View {
        tile(title: "Denne dag i historien", icon: "calendar", fullWidth: true) {
            if service.history.isEmpty {
                placeholder(service.state == .loading ? "Henter historie…" : "Ingen events")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(service.history) { event in
                        Button {
                            if let url = event.pageURL { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(event.year))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 44, alignment: .leading)
                                    .padding(.top, 1)
                                Text(event.text)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Shared tile shell (mirrors InfoModeView.tile)

    @ViewBuilder
    private func tile<Content: View>(
        title: String,
        icon: String,
        fullWidth: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Color.white)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .frame(maxHeight: fullWidth ? nil : .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(JarvisTheme.surfaceElevated.opacity(0.65))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack(spacing: 6) {
            if service.state == .loading {
                ProgressView().controlSize(.mini)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Formatters

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)t" }
        return "\(seconds / 86400)d"
    }
}
