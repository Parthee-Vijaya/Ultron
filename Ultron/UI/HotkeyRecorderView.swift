import AppKit
import SwiftUI

/// A SwiftUI field that records a key combination. When the user clicks the field it
/// becomes first responder and the next key press with modifiers is captured and
/// reported back via the `onCapture` closure (or validation failure via `onError`).
struct HotkeyRecorderView: NSViewRepresentable {
    let currentBinding: HotkeyBinding
    let onCapture: (UInt32, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onCapture = onCapture
        view.updateDisplay(currentBinding.displayString, recording: false)
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.onCapture = onCapture
        if !nsView.isRecording {
            nsView.updateDisplay(currentBinding.displayString, recording: false)
        }
    }
}

/// The underlying AppKit view. Uses `NSEvent.addLocalMonitorForEvents` only while focused.
final class HotkeyRecorderNSView: NSView {
    var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    private(set) var isRecording = false

    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(beginRecording))
        addGestureRecognizer(click)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 26) }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    func updateDisplay(_ text: String, recording: Bool) {
        label.stringValue = recording ? "Tryk en tastkombination…" : text
        label.textColor = recording ? .systemBlue : .labelColor
        layer?.borderColor = (recording ? NSColor.systemBlue : NSColor.separatorColor).cgColor
    }

    @objc private func beginRecording() {
        window?.makeFirstResponder(self)
        guard !isRecording else { return }
        isRecording = true
        updateDisplay("", recording: true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.captured(event)
            return nil  // swallow the event so it doesn't reach the rest of the UI
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    private func captured(_ event: NSEvent) {
        // Allow Escape to cancel the capture without modifying the binding.
        if event.keyCode == 53 {  // kVK_Escape
            stopRecording()
            updateDisplay("", recording: false)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
            .subtracting(.numericPad)
            .subtracting(.function)

        let keyCode = UInt32(event.keyCode)
        stopRecording()
        onCapture?(keyCode, modifiers)
    }
}
