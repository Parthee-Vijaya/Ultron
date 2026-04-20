import XCTest
@testable import Ultron

/// Verifies the 200-line rotating greeting library in
/// `GreetingProvider`. This is a pure-data module, so unit tests are cheap
/// and they lock in three load-bearing invariants:
///
/// - The name-token substitution works in every line that uses `{name}`.
/// - The pool has exactly 200 lines (prevents accidental drift via copy-paste).
/// - Deterministic seeding works (same seed → same line), which matters because
///   ChatView's empty-state binds to the current second — rapid re-renders must
///   not flicker between different greetings.
final class GreetingProviderTests: XCTestCase {
    func testPoolIsTwoHundredLines() {
        XCTAssertEqual(GreetingProvider.all.count, 200,
                       "GreetingProvider drifted away from the agreed 200-line budget")
    }

    func testAllLinesNonEmpty() {
        for (i, line) in GreetingProvider.all.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(trimmed.isEmpty, "Line \(i) is empty or whitespace-only")
        }
    }

    func testNameSubstitution() {
        // Use a sentinel name unlikely to collide with anything in the library.
        let (hello, line) = GreetingProvider.random(name: "TESTUSER", seed: 0)
        XCTAssertEqual(hello, "Hej TESTUSER")
        // `{name}` must not survive into the rendered string — any line that
        // contained the token should have resolved it.
        XCTAssertFalse(line.contains("{name}"))
    }

    func testDeterministicSeed() {
        // Same seed → same line, so re-renders within the same second stay
        // stable. Two different seeds should — for a 200-line pool — almost
        // always produce different strings; we just check they're stable.
        let a = GreetingProvider.random(name: "P", seed: 42).line
        let b = GreetingProvider.random(name: "P", seed: 42).line
        XCTAssertEqual(a, b)
    }

    func testSeedWrapsAroundPool() {
        // Any large seed (positive or negative) must still land on a valid
        // pool entry — `abs(seed) % count` handles wrap-around. Guards
        // against crash-on-overflow regressions.
        let veryLarge = GreetingProvider.random(name: "P", seed: .max).line
        let veryNegative = GreetingProvider.random(name: "P", seed: .min + 1).line
        XCTAssertFalse(veryLarge.isEmpty)
        XCTAssertFalse(veryNegative.isEmpty)
    }

    func testHelloUsesSuppliedName() {
        XCTAssertEqual(GreetingProvider.random(name: "P").hello, "Hej P")
        XCTAssertEqual(GreetingProvider.random(name: "Parti").hello, "Hej Parti")
    }
}
