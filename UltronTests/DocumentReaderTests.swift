import XCTest
@testable import Ultron

final class DocumentReaderTests: XCTestCase {
    func testSupportedExtensionsCoverCommonDocFormats() {
        let ext = DocumentReader.supportedExtensions
        XCTAssertTrue(ext.contains("pdf"))
        XCTAssertTrue(ext.contains("docx"))
        XCTAssertTrue(ext.contains("md"))
        XCTAssertTrue(ext.contains("txt"))
        XCTAssertTrue(ext.contains("swift"))
    }

    func testMaxCharactersIsReasonable() {
        // 300k chars ≈ 75k tokens — one full novel chapter without blowing past
        // cheap-Flash pricing.
        XCTAssertEqual(DocumentReader.maxCharacters, 300_000)
    }

    func testReadsPlainUTF8File() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultron-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let body = "Hello Ultron\nLine 2 with æøå"
        try body.write(to: tmp, atomically: true, encoding: .utf8)

        let result = try DocumentReader().read(url: tmp)
        XCTAssertEqual(result.text, body)
        XCTAssertEqual(result.fileExtension, "txt")
        XCTAssertFalse(result.wasTruncated)
    }

    func testRejectsUnsupportedExtension() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultron-test-\(UUID().uuidString).xyz")
        try? "x".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try DocumentReader().read(url: tmp)) { error in
            guard let readerError = error as? DocumentReader.ReaderError,
                  case .unsupportedType = readerError else {
                XCTFail("Expected unsupportedType, got \(error)")
                return
            }
        }
    }
}
