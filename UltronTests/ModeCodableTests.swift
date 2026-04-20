import XCTest
@testable import Ultron

final class ModeCodableTests: XCTestCase {
    /// v3.x custom modes don't carry `webSearch`; they must decode without error
    /// and default the flag to false.
    func testDecodesLegacyJSONWithoutWebSearch() throws {
        let legacy = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "systemPrompt": "…",
          "model": "gemini-2.5-flash",
          "outputType": "hud",
          "maxTokens": 1024,
          "isBuiltIn": false
        }
        """.data(using: .utf8)!

        let mode = try JSONDecoder().decode(Mode.self, from: legacy)
        XCTAssertEqual(mode.name, "Legacy")
        XCTAssertFalse(mode.webSearch)
    }

    func testEncodesAndDecodesRoundTrip() throws {
        let original = Mode(
            id: UUID(),
            name: "Test",
            systemPrompt: "prompt",
            model: .pro,
            outputType: .chat,
            maxTokens: 4096,
            isBuiltIn: false,
            webSearch: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.webSearch)
        XCTAssertEqual(decoded.model, .pro)
    }

    func testBuiltInModesHaveStableUUIDs() {
        // These IDs are persisted on disk; changing them would break users'
        // saved active-mode selections. Regression guard.
        XCTAssertEqual(BuiltInModes.dictation.id.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(BuiltInModes.qna.id.uuidString,       "00000000-0000-0000-0000-000000000004")
        XCTAssertEqual(BuiltInModes.summarize.id.uuidString, "00000000-0000-0000-0000-000000000008")
    }

    func testQnAAndVisionHaveWebSearchEnabled() {
        XCTAssertTrue(BuiltInModes.qna.webSearch, "Q&A should default to grounded answers")
        XCTAssertTrue(BuiltInModes.vision.webSearch, "Vision should default to grounded answers")
        XCTAssertFalse(BuiltInModes.dictation.webSearch, "Dictation is rewrite-only, no search")
    }

    /// v1.3 added `persistToNotes` — custom modes saved before that release
    /// don't have the key; they must decode with the default (false) so
    /// upgraded users don't see unexpected Notes.app churn.
    func testPersistToNotesDefaultsFalseOnLegacyJSON() throws {
        let legacy = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "name": "Legacy",
          "systemPrompt": "prompt",
          "model": "gemini-2.5-flash",
          "outputType": "paste",
          "maxTokens": 1024,
          "isBuiltIn": false,
          "webSearch": false
        }
        """.data(using: .utf8)!
        let mode = try JSONDecoder().decode(Mode.self, from: legacy)
        XCTAssertFalse(mode.persistToNotes)
    }

    /// Dictation opts into Notes persistence by default. Regression guard.
    func testDictationPersistsToNotes() {
        XCTAssertTrue(BuiltInModes.dictation.persistToNotes,
                      "Dictation should always mirror transcripts to Notes.app")
    }

    /// v1.4 added `preferLocalTranscription` — older custom-mode JSON must
    /// decode with the default (false) so behaviour doesn't flip silently.
    func testPreferLocalTranscriptionDefaultsFalseOnLegacyJSON() throws {
        let legacy = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "name": "Legacy",
          "systemPrompt": "prompt",
          "model": "gemini-2.5-flash",
          "outputType": "paste",
          "maxTokens": 1024,
          "isBuiltIn": false
        }
        """.data(using: .utf8)!
        let mode = try JSONDecoder().decode(Mode.self, from: legacy)
        XCTAssertFalse(mode.preferLocalTranscription)
    }

    /// Dictation opts into WhisperKit local STT explicitly — tighter than
    /// the old `outputType == .paste` proxy.
    func testDictationPrefersLocalTranscription() {
        XCTAssertTrue(BuiltInModes.dictation.preferLocalTranscription,
                      "Dictation should route through WhisperKit, not Gemini-audio")
    }
}
