import AppKit
import Carbon
import HotKey

/// The six hotkey-triggered actions Jarvis supports.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case dictation
    case qna
    case vision
    case translate
    case cycleMode
    case toggleChat
    case uptodate
    case summarize
    case infoMode
    case agent

    var id: String { rawValue }

    /// Human-readable label shown in Settings.
    var displayName: String {
        switch self {
        case .dictation:   return "Dictation (push-to-talk)"
        case .qna:         return "Q&A"
        case .vision:      return "Vision (screenshot + voice)"
        case .translate:   return "Translate"
        case .cycleMode:   return "Cycle active mode"
        case .toggleChat:  return "Toggle chat window"
        case .uptodate:    return "Briefing (nyheder + historie)"
        case .summarize:   return "Summarize dokument"
        case .infoMode:    return "Cockpit (vejr + system)"
        case .agent:       return "Agent (filoperationer via Claude)"
        }
    }

    /// Whether the action is push-to-talk (holds the key down) or a one-shot trigger.
    var isPushToTalk: Bool {
        switch self {
        case .dictation, .qna, .vision, .translate: return true
        case .cycleMode, .toggleChat, .uptodate, .summarize, .infoMode, .agent: return false
        }
    }

    /// The default binding shipped before users customise anything.
    var defaultBinding: HotkeyBinding {
        switch self {
        case .dictation:  return HotkeyBinding(action: self, keyCode: Key.space.carbonKeyCode, modifiersRaw: NSEvent.ModifierFlags.option.rawValue)
        case .qna:        return HotkeyBinding(action: self, keyCode: Key.q.carbonKeyCode,     modifiersRaw: NSEvent.ModifierFlags.option.rawValue)
        case .vision:
            let flags: NSEvent.ModifierFlags = [.option, .shift]
            return HotkeyBinding(action: self, keyCode: Key.space.carbonKeyCode, modifiersRaw: flags.rawValue)
        case .translate:  return HotkeyBinding(action: self, keyCode: Key.t.carbonKeyCode,     modifiersRaw: NSEvent.ModifierFlags.option.rawValue)
        case .cycleMode:  return HotkeyBinding(action: self, keyCode: Key.m.carbonKeyCode,     modifiersRaw: NSEvent.ModifierFlags.option.rawValue)
        case .toggleChat: return HotkeyBinding(action: self, keyCode: Key.c.carbonKeyCode,     modifiersRaw: NSEvent.ModifierFlags.option.rawValue)
        case .uptodate:   return HotkeyBinding(action: self, keyCode: Key.u.carbonKeyCode,     modifiersRaw: NSEvent.ModifierFlags.option.rawValue)
        case .summarize:
            let flags: NSEvent.ModifierFlags = [.option, .shift]
            return HotkeyBinding(action: self, keyCode: Key.s.carbonKeyCode, modifiersRaw: flags.rawValue)
        case .infoMode:
            return HotkeyBinding(action: self, keyCode: Key.i.carbonKeyCode, modifiersRaw: NSEvent.ModifierFlags.option.rawValue)
        case .agent:
            let flags: NSEvent.ModifierFlags = [.option, .shift]
            return HotkeyBinding(action: self, keyCode: Key.a.carbonKeyCode, modifiersRaw: flags.rawValue)
        }
    }
}

/// A user-adjustable hotkey binding. Persisted as JSON via `HotkeyStore`.
/// `keyCode` is the Carbon virtual-key code (matches `HotKey.Key` raw value and
/// `NSEvent.keyCode`), so bindings captured via NSEvent can be stored and later
/// converted back to `HotKey.Key` without a string round-trip.
struct HotkeyBinding: Codable, Equatable {
    let action: HotkeyAction
    var keyCode: UInt32
    var modifiersRaw: UInt          // NSEvent.ModifierFlags bitmask

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiersRaw) }

    /// Resolve the key code to a `HotKey.Key` — nil if the code isn't one HotKey understands.
    var hotkeyKey: Key? { Key(carbonKeyCode: keyCode) }

    /// Carbon modifier bitmask that `HotKey` expects (converted from NSEvent flags).
    var carbonModifiers: UInt32 { modifiers.carbonFlags }

    /// ⌘⇧⌥⌃-style glyph string for display.
    var displayString: String {
        var parts: [String] = []
        let m = modifiers
        if m.contains(.control) { parts.append("⌃") }
        if m.contains(.option)  { parts.append("⌥") }
        if m.contains(.shift)   { parts.append("⇧") }
        if m.contains(.command) { parts.append("⌘") }
        parts.append(keyGlyph(for: keyCode))
        return parts.joined()
    }

    /// Validation — reject combos that would break normal typing or stomp on reserved system shortcuts.
    func validate() -> ValidationResult {
        let m = modifiers
        let modifierCount = [m.contains(.option), m.contains(.command), m.contains(.control), m.contains(.shift)].filter { $0 }.count

        if modifierCount == 0 {
            return .invalid("En hotkey skal have mindst én modifier (⌘/⌥/⌃/⇧).")
        }
        if modifierCount == 1 && m.contains(.shift) {
            return .invalid("⇧ alene er ikke nok som modifier.")
        }

        // Short deny-list — keyed by HotKey.Key cases that have a stable raw value.
        let reserved: [(code: UInt32, modifiers: NSEvent.ModifierFlags, reason: String)] = [
            (Key.q.carbonKeyCode,      [.command], "⌘Q afslutter apps"),
            (Key.w.carbonKeyCode,      [.command], "⌘W lukker vinduer"),
            (Key.tab.carbonKeyCode,    [.command], "⌘⇥ skifter app"),
            (Key.escape.carbonKeyCode, [.command], "⌘⎋ er reserveret")
        ]
        for r in reserved where r.code == keyCode && m == r.modifiers {
            return .invalid("Reserveret af systemet: \(r.reason).")
        }

        return .valid
    }

    enum ValidationResult: Equatable {
        case valid
        case invalid(String)

        var isValid: Bool { if case .valid = self { return true }; return false }
        var message: String? { if case .invalid(let msg) = self { return msg }; return nil }
    }
}

// MARK: - Glyph lookup

/// Render a Carbon key code as a glyph for the Settings UI. Falls back to the
/// raw code in angle brackets for unknown codes.
private func keyGlyph(for keyCode: UInt32) -> String {
    // Keys where the HotKey rawValue-based name is user-friendly.
    if let key = Key(carbonKeyCode: keyCode) {
        switch key {
        case .space:      return "Space"
        case .return:     return "↩"
        case .tab:        return "⇥"
        case .escape:     return "⎋"
        case .delete:     return "⌫"
        case .forwardDelete: return "⌦"
        case .leftArrow:  return "←"
        case .rightArrow: return "→"
        case .upArrow:    return "↑"
        case .downArrow:  return "↓"
        case .home:       return "↖"
        case .end:        return "↘"
        case .pageUp:     return "⇞"
        case .pageDown:   return "⇟"
        default: break
        }
    }

    // Use NSEvent's character-for-key-code API for letters/digits.
    if let chars = charactersForKeyCode(keyCode) {
        return chars.uppercased()
    }
    return "<\(keyCode)>"
}

/// Ask the current keyboard layout what character the code produces with no modifiers.
private func charactersForKeyCode(_ keyCode: UInt32) -> String? {
    let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
    guard let src,
          let layoutData = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
    return data.withUnsafeBytes { bytes -> String? in
        let layout = bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        let maxLen = 4
        var actualLen = 0
        var chars = [UniChar](repeating: 0, count: maxLen)
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            maxLen,
            &actualLen,
            &chars
        )
        guard status == noErr, actualLen > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLen)
    }
}
