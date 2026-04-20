import ScreenCaptureKit
import AppKit

class ScreenCaptureService {
    func captureActiveWindow() async throws -> Data {
        let content = try await SCShareableContent.current

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let window = content.windows.first(where: {
                  $0.owningApplication?.processID == frontApp.processIdentifier && $0.isOnScreen
              }) else {
            throw UltronError.screenCaptureDenied
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.scalesToFit = true
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw UltronError.screenCaptureDenied
        }

        LoggingService.shared.log("Screenshot captured: \(pngData.count) bytes")
        return pngData
    }

    func captureFullScreen() async throws -> Data {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw UltronError.screenCaptureDenied
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.scalesToFit = true
        config.width = Int(display.width) * 2
        config.height = Int(display.height) * 2

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw UltronError.screenCaptureDenied
        }
        return pngData
    }
}
