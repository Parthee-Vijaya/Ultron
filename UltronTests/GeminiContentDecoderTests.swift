import XCTest
@testable import Ultron

/// Locks in the v1.3.0-alpha.1 `GeminiContent.init(from:)` hardening
/// (commit b402a32) — Gemini's REST responses occasionally return a
/// `candidates[0].content` object that lacks either `role` or `parts`
/// (safety-filter hit, mid-stream abort, etc.). Before the fix, decoding
/// threw `keyNotFound("parts")` and the whole pipeline crashed with
/// "Kunne ikke læse svar fra Gemini". The fix lets the two fields default
/// to empty so callers can check `.text == nil` and surface a clean empty
/// response instead.
final class GeminiContentDecoderTests: XCTestCase {
    private func decode(_ json: String) throws -> GeminiContent {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GeminiContent.self, from: data)
    }

    func testWellFormedContent() throws {
        let json = """
        {"role":"model","parts":[{"text":"Hej verden"}]}
        """
        let content = try decode(json)
        XCTAssertEqual(content.role, "model")
        XCTAssertEqual(content.parts.count, 1)
        XCTAssertEqual(content.parts.first?.text, "Hej verden")
    }

    func testMissingParts() throws {
        // Observed in the wild when Gemini's safety filter strips content but
        // still returns a candidate envelope. Must decode without throwing.
        let json = """
        {"role":"model"}
        """
        let content = try decode(json)
        XCTAssertEqual(content.role, "model")
        XCTAssertEqual(content.parts.count, 0)
    }

    func testMissingRole() throws {
        // Rarer but seen in stream chunks — role omitted, parts present.
        let json = """
        {"parts":[{"text":"stream chunk"}]}
        """
        let content = try decode(json)
        XCTAssertEqual(content.role, "")
        XCTAssertEqual(content.parts.count, 1)
        XCTAssertEqual(content.parts.first?.text, "stream chunk")
    }

    func testBothMissing() throws {
        // Worst case: empty object. Should still decode to a valid
        // `GeminiContent` that callers can detect via `.text == nil`.
        let json = "{}"
        let content = try decode(json)
        XCTAssertEqual(content.role, "")
        XCTAssertTrue(content.parts.isEmpty)
    }

    func testEmptyPartsRoundTripsToNilText() throws {
        // GeminiResponse.text is nil when the first candidate has no
        // text-bearing parts — callers rely on this to map "empty content"
        // to `GeminiRESTError.emptyResponse` rather than crashing.
        let json = """
        {"candidates":[{"content":{"role":"model"},"finishReason":"SAFETY"}]}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        XCTAssertNil(response.text)
        XCTAssertEqual(response.candidates?.first?.finishReason, "SAFETY")
    }
}
