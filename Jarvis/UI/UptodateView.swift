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
                weatherSection
                newsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 500, alignment: .topLeading)
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

    // MARK: - Weather

    @ViewBuilder
    private var weatherSection: some View {
        if let weather = service.weather {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(weather.locationLabel)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(WeatherCode.label(for: weather.current.weatherCode))
                            .font(.callout)
                            .foregroundStyle(JarvisTheme.neonCyan.opacity(0.75))
                    }
                    Spacer()
                    Image(systemName: WeatherCode.symbol(for: weather.current.weatherCode))
                        .font(.system(size: 40))
                        .foregroundStyle(JarvisTheme.brightCyan)
                        .shadow(color: JarvisTheme.neonCyan.opacity(0.6), radius: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(weather.current.temperature.rounded()))°")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("føles \(Int(weather.current.feelsLike.rounded()))°")
                            .font(.caption)
                            .foregroundStyle(JarvisTheme.neonCyan.opacity(0.6))
                    }
                }

                hourlyStrip(weather.hourly)
                dailyStrip(weather.daily)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(JarvisTheme.surfaceElevated.opacity(0.65))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(JarvisTheme.neonCyan.opacity(0.25), lineWidth: 1))
            }
        } else if service.state == .loading {
            HStack {
                ProgressView().controlSize(.small)
                Text("Henter vejr…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(14)
        } else {
            Text("Ingen vejrdata endnu. Klik ⟳ for at opdatere.")
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
    }

    private func hourlyStrip(_ hourly: [WeatherSnapshot.HourlyPoint]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(hourly.prefix(12)) { point in
                    VStack(spacing: 4) {
                        Text(hourFormatter.string(from: point.time))
                            .font(.caption2)
                            .foregroundStyle(JarvisTheme.neonCyan.opacity(0.6))
                        Image(systemName: WeatherCode.symbol(for: point.weatherCode))
                            .foregroundStyle(JarvisTheme.neonCyan)
                        Text("\(Int(point.temperature.rounded()))°")
                            .font(.caption)
                            .foregroundStyle(.white)
                        if let p = point.precipitationProbability, p >= 20 {
                            Text("\(p)%")
                                .font(.caption2)
                                .foregroundStyle(JarvisTheme.brightCyan.opacity(0.85))
                        }
                    }
                    .frame(minWidth: 34)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func dailyStrip(_ daily: [WeatherSnapshot.DailyPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(daily.prefix(7)) { day in
                HStack {
                    Text(dayFormatter.string(from: day.date))
                        .font(.caption)
                        .frame(width: 40, alignment: .leading)
                        .foregroundStyle(JarvisTheme.neonCyan.opacity(0.75))
                    Image(systemName: WeatherCode.symbol(for: day.weatherCode))
                        .frame(width: 18)
                        .foregroundStyle(JarvisTheme.brightCyan)
                    Spacer()
                    Text("\(Int(day.tempMin.rounded()))°")
                        .foregroundStyle(JarvisTheme.neonCyan.opacity(0.65))
                        .font(.caption.monospacedDigit())
                    Text("—").foregroundStyle(JarvisTheme.neonCyan.opacity(0.3))
                    Text("\(Int(day.tempMax.rounded()))°")
                        .foregroundStyle(.white)
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - News

    @ViewBuilder
    private var newsSection: some View {
        if service.news.isEmpty && service.state == .loading {
            HStack { ProgressView().controlSize(.small); Text("Henter nyheder…").font(.caption).foregroundStyle(.secondary); Spacer() }
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
                Image(systemName: "newspaper")
                    .font(.caption2)
                    .foregroundStyle(JarvisTheme.neonCyan.opacity(0.5))
                Spacer()
            }
            ForEach(items.prefix(6)) { item in
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

    // MARK: - Formatters

    private var hourFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "HH"
        return df
    }

    private var dayFormatter: DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "da_DK")
        df.dateFormat = "EEE"
        return df
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)t" }
        return "\(seconds / 86400)d"
    }
}
