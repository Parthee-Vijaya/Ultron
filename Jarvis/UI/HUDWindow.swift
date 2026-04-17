import AppKit
import SwiftUI

class HUDWindowController {
    private var window: NSWindow?
    var onSpeakRequested: ((String) -> Void)?

    func show(content: String) {
        close()

        let hudView = HUDContentView(
            text: content,
            onClose: { [weak self] in self?.close() },
            onSpeak: { [weak self] text in self?.onSpeakRequested?(text) }
        )

        let hostingController = NSHostingController(rootView: hudView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.borderless]
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 380
            let windowHeight: CGFloat = 260
            let x = screenFrame.maxX - windowWidth - 20
            let y = screenFrame.maxY - windowHeight - 20
            window.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
        }

        window.makeKeyAndOrderFront(nil)
        self.window = window

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.close()
        }
    }

    func close() {
        window?.close()
        window = nil
    }
}
