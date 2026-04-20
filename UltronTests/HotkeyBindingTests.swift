import XCTest
@testable import Ultron

final class HotkeyBindingTests: XCTestCase {
    func testBindingRequiresModifier() {
        let noModifier = HotkeyBinding(action: .dictation, keyCode: 49, modifiersRaw: 0)
        let result = noModifier.validate()
        if case .invalid(let message) = result {
            XCTAssertTrue(message.contains("modifier"))
        } else {
            XCTFail("Modifier-free bindings should be rejected")
        }
    }

    func testShiftAloneIsRejected() {
        let shiftOnly = HotkeyBinding(action: .qna, keyCode: 12,
                                      modifiersRaw: NSEvent.ModifierFlags.shift.rawValue)
        let result = shiftOnly.validate()
        XCTAssertFalse(result.isValid)
    }

    func testOptionPlusKeyIsValid() {
        let binding = HotkeyBinding(action: .qna, keyCode: 12,
                                    modifiersRaw: NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(binding.validate(), .valid)
    }

    func testSystemReservedCombosRejected() {
        // ⌘Q is reserved — quit app
        let cmdQ = HotkeyBinding(action: .qna, keyCode: 12,
                                 modifiersRaw: NSEvent.ModifierFlags.command.rawValue)
        let result = cmdQ.validate()
        XCTAssertFalse(result.isValid, "⌘Q should be blocked")
    }

    func testDefaultBindingsAreAllValid() {
        for action in HotkeyAction.allCases {
            let binding = action.defaultBinding
            XCTAssertEqual(binding.validate(), .valid,
                           "Default binding for \(action) must pass its own validator")
        }
    }

    func testDisplayStringRendersModifiers() {
        var flags: NSEvent.ModifierFlags = [.option, .shift]
        let binding = HotkeyBinding(action: .vision, keyCode: 49, modifiersRaw: flags.rawValue)
        XCTAssertTrue(binding.displayString.contains("⌥"))
        XCTAssertTrue(binding.displayString.contains("⇧"))
        XCTAssertTrue(binding.displayString.contains("Space"))
    }
}
