import Foundation

/// Auto-configures the Ultron Python sidecar so MCPRegistry can spawn it
/// without the user ever editing `~/.ultron/mcp.json`. Replaces the previous
/// setup where the sidecar entry had to be hand-written with an absolute `uv`
/// path.
///
/// Detection is cached for the process lifetime — paths don't change mid-run.
///
/// Two layout cases are covered:
/// 1. **Bundled** (Phase 5 when we ship): `Ultron.app/Contents/Resources/sidecar/`
///    contains `uv` + the `ultron_sidecar` package + a pre-synced `.venv`.
/// 2. **Development** (today): the app is built from the repo; the sidecar
///    lives at `<repo>/Sidecar/python/`. We walk up from the bundle path to
///    find it.
enum BuiltInSidecar {
    /// Resolved once per session — computing paths is cheap but caching keeps
    /// call sites noise-free.
    static let resolved: Resolution = resolve()

    struct Resolution {
        /// Absolute path to a `uv` binary we trust will run the sidecar.
        /// Nil if we can't find uv anywhere sensible — in that case the
        /// sidecar auto-registration silently skips and the user falls
        /// back to Gemini/Anthropic only.
        let uvPath: String?
        /// Absolute path to the sidecar Python package directory (the one
        /// containing `pyproject.toml` + `ultron_sidecar/`). Nil when we
        /// can't find it — e.g. a stripped build with no sidecar resources.
        let sidecarDir: String?
        /// True when the venv at `<sidecarDir>/.venv` already exists. Hints
        /// the Settings UI to show "ready" vs "first-run sync pending".
        let venvReady: Bool
        /// Human-readable detection diagnostic for the Settings pane.
        let diagnostic: String
    }

    /// Returns the MCPConfig entry for the built-in sidecar, or nil when
    /// detection failed. MCPRegistry merges this into its config before
    /// reading the user's mcp.json so the sidecar is always available
    /// unless the user explicitly disables it.
    static func builtInServer() -> MCPRegistry.MCPConfig.Server? {
        let r = resolved
        guard let uv = r.uvPath, let dir = r.sidecarDir else { return nil }
        return MCPRegistry.MCPConfig.Server(
            command: uv,
            args: [
                "run",
                "--native-tls",
                "--directory", dir,
                "python", "-m", "ultron_sidecar"
            ],
            env: nil
        )
    }

    // MARK: - Resolution

    private static func resolve() -> Resolution {
        let uv = findUV()
        let dir = findSidecarDir()
        let venv = dir.flatMap { FileManager.default.fileExists(atPath: "\($0)/.venv") ? true : false } ?? false

        let diag: String
        switch (uv, dir) {
        case (nil, _):
            diag = "⚠ uv ikke fundet — installér via `brew install uv`, så genindlæser Ultron sidecar'en automatisk."
        case (_, nil):
            diag = "⚠ Sidecar-mappe ikke fundet. Forventet under bundle Resources eller <repo>/Sidecar/python."
        case (let uv?, let dir?):
            if venv {
                diag = "Auto-registreret: \(uv) • \(dir)"
            } else {
                diag = "Auto-registreret: \(uv) • \(dir) — første start kører `uv sync` (~30s)"
            }
        default:
            diag = ""
        }

        return Resolution(uvPath: uv, sidecarDir: dir, venvReady: venv, diagnostic: diag)
    }

    /// Common install locations tried in order. Returns the first one that
    /// exists + is executable.
    private static func findUV() -> String? {
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            NSString(string: "~/.cargo/bin/uv").expandingTildeInPath,
            NSString(string: "~/.local/bin/uv").expandingTildeInPath
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Find the `Sidecar/python/` directory. Priority:
    /// 1. Bundle: `<Ultron.app>/Contents/Resources/sidecar`
    /// 2. Repo: walk up from the bundle looking for `Sidecar/python/pyproject.toml`
    private static func findSidecarDir() -> String? {
        let fm = FileManager.default

        // 1. Bundled layout (production)
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("sidecar")
            if fm.fileExists(atPath: bundled.appendingPathComponent("pyproject.toml").path) {
                return bundled.path
            }
        }

        // 2. Dev layout — bundle path is something like
        // <repo>/build-debug/Build/Products/Debug/Ultron.app. Walk up
        // looking for `Sidecar/python/pyproject.toml`.
        var cursor = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = cursor
                .appendingPathComponent("Sidecar", isDirectory: true)
                .appendingPathComponent("python", isDirectory: true)
            if fm.fileExists(atPath: candidate.appendingPathComponent("pyproject.toml").path) {
                return candidate.path
            }
            cursor = cursor.deletingLastPathComponent()
            if cursor.path == "/" { break }
        }

        return nil
    }
}
