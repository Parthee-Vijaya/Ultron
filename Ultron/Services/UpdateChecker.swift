import AppKit
import Foundation

/// v1.2.0: lightweight auto-update check against the GitHub Releases API.
/// Avoids bundling Sparkle + its EdDSA feed infrastructure — for a solo-dev
/// alpha this is plenty. Queries once per day, compares semver, prompts the
/// user to download the new DMG.
///
/// Upgrade path: if / when we start distributing to a broader audience,
/// swap `UpdateChecker` out for Sparkle without touching callers.
@MainActor
final class UpdateChecker {
    private let repo = "Parthee-Vijaya/UltronHUD"
    private let defaults = UserDefaults.standard
    private let lastCheckKey = "lastUpdateCheckAt"
    private let checkInterval: TimeInterval = 24 * 3600   // once a day

    /// Fire-and-forget: check if enough time has elapsed since the last
    /// probe, and if so ping GitHub. Safe to call on launch — never blocks.
    func checkIfDue() {
        let last = defaults.double(forKey: lastCheckKey)
        if last > 0, Date().timeIntervalSince1970 - last < checkInterval { return }
        Task { await checkNow(userInitiated: false) }
    }

    /// Explicit check triggered from the menu. Shows a dialog even when up
    /// to date, unlike the automatic one.
    func checkNow(userInitiated: Bool) async {
        defer { defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey) }

        guard let release = await fetchLatestRelease() else {
            if userInitiated { showAlert(title: "Ingen forbindelse", body: "Kunne ikke nå GitHub.") }
            return
        }

        let currentVersion = Constants.appVersion
        let remoteVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName

        guard Self.compareSemver(remoteVersion, currentVersion) == .orderedDescending else {
            if userInitiated {
                showAlert(title: "Ultron er opdateret", body: "v\(currentVersion) er den nyeste version.")
            }
            return
        }

        showUpdateAvailable(release: release, currentVersion: currentVersion, remoteVersion: remoteVersion)
    }

    // MARK: - GitHub API

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body, assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }
    }

    private func fetchLatestRelease() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ultron/\(Constants.appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(Release.self, from: data)
        } catch {
            LoggingService.shared.log("UpdateChecker fetch failed: \(error)", level: .info)
            return nil
        }
    }

    // MARK: - UI

    private func showUpdateAvailable(release: Release, currentVersion: String, remoteVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Ny version tilgængelig — v\(remoteVersion)"
        alert.informativeText = """
        Du kører v\(currentVersion). Åbn release-siden for at downloade og installere.

        \(release.body?.prefix(300) ?? "")
        """
        alert.addButton(withTitle: "Åbn release")
        alert.addButton(withTitle: "Senere")
        alert.alertStyle = .informational
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
               let url = URL(string: dmg.browserDownloadUrl) {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Semver comparison

    /// Compares `a` and `b` as semver strings. Handles `X.Y.Z-alpha.N` and
    /// `X.Y.Z-beta.N` pre-release suffixes — any pre-release sorts lower than
    /// the same X.Y.Z without a suffix.
    static func compareSemver(_ a: String, _ b: String) -> ComparisonResult {
        let (aMain, aPre) = Self.splitPre(a)
        let (bMain, bPre) = Self.splitPre(b)
        let aParts = aMain.split(separator: ".").compactMap { Int($0) }
        let bParts = bMain.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv ? .orderedDescending : .orderedAscending }
        }
        // Main versions equal — pre-release suffixes compare.
        switch (aPre.isEmpty, bPre.isEmpty) {
        case (true, true):   return .orderedSame
        case (true, false):  return .orderedDescending  // 1.2.0 > 1.2.0-alpha.1
        case (false, true):  return .orderedAscending
        case (false, false): return aPre.compare(bPre) // alpha.1 < alpha.2 etc.
        }
    }

    private static func splitPre(_ v: String) -> (String, String) {
        guard let dash = v.firstIndex(of: "-") else { return (v, "") }
        return (String(v[..<dash]), String(v[v.index(after: dash)...]))
    }
}
