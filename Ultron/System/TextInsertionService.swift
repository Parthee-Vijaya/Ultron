import AppKit
import ApplicationServices

class TextInsertionService {
    func insertText(_ text: String) -> Bool {
        if insertAtCursor(text) {
            LoggingService.shared.log("Text inserted via Accessibility API (selectedText)")
            return true
        }
        LoggingService.shared.log("Accessibility insert failed, using pasteboard fallback")
        return insertViaPasteboard(text)
    }

    private func insertAtCursor(_ text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement else { return false }

        // CFTypeRef is always bridgeable to AXUIElement when AX API returns success
        let axElement = element as! AXUIElement  // swiftlint:disable:this force_cast — CF bridging, guaranteed by AX API contract

        // Try inserting at cursor via kAXSelectedTextAttribute (replaces selection or inserts at cursor)
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        if rangeResult == .success {
            let insertResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if insertResult == .success { return true }
        }

        return false
    }

    private func insertViaPasteboard(_ text: String) -> Bool {
        // Capture the target app BEFORE touching the pasteboard so we can verify
        // focus hasn't drifted to another app between setString and the ⌘V post.
        guard let targetApp = NSWorkspace.shared.frontmostApplication else {
            LoggingService.shared.log("Paste fallback aborted — no frontmost app", level: .warning)
            return false
        }
        let targetPID = targetApp.processIdentifier

        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Abort paste if the user switched apps between capture and now — would paste into wrong app.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            LoggingService.shared.log("Paste fallback aborted — focus moved to another app", level: .warning)
            // Restore pasteboard immediately since we didn't paste.
            if let old = oldContents {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)

        // Restore the old pasteboard only if focus is still on the same app — otherwise
        // the user is now working in a different app and the old string is no longer theirs.
        if let old = oldContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
        return true
    }

    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
