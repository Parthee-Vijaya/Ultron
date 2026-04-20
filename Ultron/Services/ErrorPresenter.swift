import Foundation

/// Single surface for reporting errors to the user + the log. Replaces the
/// scattered `hudController.showError(...)` calls from v4.x with a routed
/// Danish message, proper log level, and consistent context tagging.
@MainActor
final class ErrorPresenter {
    private weak var hudController: HUDWindowController?

    init(hudController: HUDWindowController) {
        self.hudController = hudController
    }

    /// Report an error. Context is a short tag ("RecordingPipeline", "Summary",
    /// "Agent") that makes log lines searchable.
    func surface(_ error: Error, context: String) {
        let classified = classify(error)
        LoggingService.shared.log("[\(context)] \(classified.logMessage)", level: classified.logLevel)
        hudController?.showError(classified.userMessage)
    }

    /// Variant for permission-specific errors where we want the permission HUD
    /// with an "Open Settings" button rather than the generic error card.
    func surfacePermission(permission: String, instructions: String, context: String) {
        LoggingService.shared.log("[\(context)] permission required: \(permission)", level: .warning)
        hudController?.showPermissionError(permission: permission, instructions: instructions)
    }

    // MARK: - Classification

    private struct Classified {
        let userMessage: String
        let logMessage: String
        let logLevel: LoggingService.Level
    }

    private func classify(_ error: Error) -> Classified {
        // 1. Our own typed errors get friendly Danish from their localizedDescription.
        if let gemini = error as? GeminiRESTError {
            return .init(
                userMessage: gemini.errorDescription ?? "Gemini-fejl.",
                logMessage: "Gemini: \(error)",
                logLevel: .error
            )
        }
        if let anthropic = error as? AnthropicError {
            return .init(
                userMessage: anthropic.errorDescription ?? "Anthropic-fejl.",
                logMessage: "Anthropic: \(error)",
                logLevel: .error
            )
        }
        if let wake = error as? WakeWordError {
            return .init(
                userMessage: wake.errorDescription ?? "Wake word-fejl.",
                logMessage: "WakeWord: \(error)",
                logLevel: .warning
            )
        }
        if let commute = error as? CommuteError {
            return .init(
                userMessage: commute.errorDescription ?? "Rutefejl.",
                logMessage: "Commute: \(error)",
                logLevel: .warning
            )
        }
        if let reader = error as? DocumentReader.ReaderError {
            return .init(
                userMessage: reader.errorDescription ?? "Kunne ikke læse filen.",
                logMessage: "DocumentReader: \(error)",
                logLevel: .warning
            )
        }

        // 2. URL / network errors get friendly translation.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return .init(userMessage: "Ingen internetforbindelse.", logMessage: "URL: no internet", logLevel: .warning)
            case NSURLErrorTimedOut:
                return .init(userMessage: "Forbindelsen til serveren timeoutede.", logMessage: "URL: timeout", logLevel: .warning)
            case NSURLErrorNetworkConnectionLost:
                return .init(userMessage: "Netværksforbindelse tabt.", logMessage: "URL: connection lost", logLevel: .warning)
            default:
                return .init(userMessage: "Netværksfejl: \(nsError.localizedDescription)", logMessage: "URL \(nsError.code): \(nsError)", logLevel: .error)
            }
        }

        // 3. Fallback — generic error, no leak of internal types to UI.
        return .init(
            userMessage: "Noget gik galt: \(error.localizedDescription)",
            logMessage: "Unclassified: \(error)",
            logLevel: .error
        )
    }
}
