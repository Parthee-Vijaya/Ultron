import AppKit
import Carbon
import HotKey

class HotkeyManager {
    private var dictationHotKey: HotKey?
    private var qnaHotKey: HotKey?
    private var visionHotKey: HotKey?
    private var modeCycleHotKey: HotKey?

    var onDictationKeyDown: (() -> Void)?
    var onDictationKeyUp: (() -> Void)?
    var onQnAKeyDown: (() -> Void)?
    var onQnAKeyUp: (() -> Void)?
    var onVisionKeyDown: (() -> Void)?
    var onVisionKeyUp: (() -> Void)?
    var onModeCycle: (() -> Void)?

    func registerHotkeys() {
        dictationHotKey = HotKey(key: .space, modifiers: [.option])
        dictationHotKey?.keyDownHandler = { [weak self] in self?.onDictationKeyDown?() }
        dictationHotKey?.keyUpHandler = { [weak self] in self?.onDictationKeyUp?() }

        qnaHotKey = HotKey(key: .q, modifiers: [.option])
        qnaHotKey?.keyDownHandler = { [weak self] in self?.onQnAKeyDown?() }
        qnaHotKey?.keyUpHandler = { [weak self] in self?.onQnAKeyUp?() }

        visionHotKey = HotKey(key: .space, modifiers: [.option, .shift])
        visionHotKey?.keyDownHandler = { [weak self] in self?.onVisionKeyDown?() }
        visionHotKey?.keyUpHandler = { [weak self] in self?.onVisionKeyUp?() }

        modeCycleHotKey = HotKey(key: .m, modifiers: [.option])
        modeCycleHotKey?.keyDownHandler = { [weak self] in self?.onModeCycle?() }

        LoggingService.shared.log("Hotkeys registered")
    }

    func unregisterAll() {
        dictationHotKey = nil
        qnaHotKey = nil
        visionHotKey = nil
        modeCycleHotKey = nil
    }
}
