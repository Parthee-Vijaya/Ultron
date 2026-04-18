import AppKit
import SwiftUI

struct UptodateView: View {
    @Bindable var service: UpdatesService
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(JarvisTheme.neonCyan.opacity(0.2))
            VStack(alignment: .leading, spacing: 14) {
                newsSection
                historySection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 520, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await service.refresh()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(JarvisTheme.neonCyan)
                .shadow(color: JarvisTheme.neonCyan.opacity(0.7), radius: 4)
            Text("Uptodate")
                .font(.headline)
                .foregroundStyle(JarvisTheme.brightCyan)
            if let last = service.lastRefresh {
                Text("· opdateret \(timeAgo(last))")
                    .font(.caption2)
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.5))
            }
            Spacer()
            Button {
                Task { await service.refresh(force: true) }
            } label: {
                Image(systemName: service.state == .loading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.8))
                    .rotationEffect(.degrees(service.state == .loading ? 360 : 0))
                    .animation(
                        service.state == .loading
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: service.state
                    )
            }
            .buttonStyle(.borderless)
            .help("Opdater")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.55))
            }
            .buttonStyle(.borderless)
            .help("Luk")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - News

    @ViewBuilder
    private var newsSection: some View {
        if service.news.isEmpty && service.state == .loading {
            HStack {
                ProgressView().controlSize(.small)
                Text("Henter nyheder…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            ForEach(NewsHeadline.Source.allCases) { source in
                if let items = service.news[source], !items.isEmpty {
                    newsSectionFor(source: source, items: items)
                }
            }
        }
    }

    private func newsSectionFor(source: NewsHeadline.Source, items: [NewsHeadline]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(source.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule()
                            .fill(JarvisTheme.neonCyan.opacity(0.15))
                            .overlay(Capsule().stroke(JarvisTheme.neonCyan.opacity(0.5), lineWidth: 0.75))
                    }
                    .foregroundStyle(JarvisTheme.brightCyan)
                Image(systemName: sourceIcon(for: source))
                    .font(.caption2)
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.5))
                Spacer()
            }
            ForEach(items.prefix(5)) { item in
                Button {
                    if let link = item.link { NSWorkspace.shared.open(link) }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(JarvisTheme.neonCyan.opacity(0.5))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if let date = item.publishedAt {
                            Text(timeAgo(date))
                                .font(.caption2)
                                .foregroundStyle(JarvisTheme.neonCyan.opacity(0.45))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sourceIcon(for source: NewsHeadline.Source) -> String {
        switch source {
        case .dr, .tv2, .bbc, .cnn: return "newspaper"
        case .reddit:               return "bubble.left.and.bubble.right"
        case .hackernews:           return "terminal"
        }
    }

    // MARK: - Denne dag i historien

    @ViewBuilder
    private var historySection: some View {
        if !service.history.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Denne dag i historien")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(JarvisTheme.neonCyan.opacity(0.15))
                                .overlay(Capsule().stroke(JarvisTheme.neonCyan.opacity(0.5), lineWidth: 0.75))
                        }
                        .foregroundStyle(JarvisTheme.brightCyan)
                    Image(systemName: "calendar")
                        .font(.caption2)
                        .foregroundStyle(JarvisTheme.neonCyan.opacity(0.5))
                    Spacer()
                }
                ForEach(service.history) { event in
                    Button {
                        if let url = event.pageURL { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(String(event.year))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(JarvisTheme.brightCyan)
                                .frame(width: 40, alignment: .leading)
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

    // MARK: - Formatters

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)t" }
        return "\(seconds / 86400)d"
    }
}
