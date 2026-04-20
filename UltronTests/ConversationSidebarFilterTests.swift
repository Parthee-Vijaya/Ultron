import XCTest
@testable import Ultron

/// Exercises the pure filter logic that drives `ConversationSidebar`'s
/// search field. Focused deliberately on `ConversationSidebar.filter(...)` —
/// the SwiftUI view, the `.task(id:)` debounce, and the real
/// `SemanticIndex` actor (which requires `NLEmbedding` vocabularies that
/// aren't guaranteed in a unit-test sandbox) are all out of scope. Those
/// pieces are covered by the build itself plus manual smoke-testing; here
/// we lock in the substring / semantic merge semantics that decide which
/// conversations appear in the sidebar list.
///
/// `@MainActor` because `ConversationSidebar` is a SwiftUI `View` and the
/// Ultron target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// — its static members inherit that isolation, so tests calling them
/// must hop to the main actor too.
@MainActor
final class ConversationSidebarFilterTests: XCTestCase {
    // MARK: - Fixtures

    /// Five conversations covering the ordering the test needs. Kept as a
    /// computed var instead of a stored `let` so Swift 6's "covariant Self
    /// in stored-property initialiser" rule doesn't fire on the `@MainActor`
    /// isolated `ConversationStore.Metadata.init` call.
    private var conversations: [ConversationStore.Metadata] {
        let now = Date(timeIntervalSince1970: 1_714_000_000)
        return [
            .init(id: Self.id1, title: "Budget 2026 forhandlinger",
                  updatedAt: now, messageCount: 3),
            .init(id: Self.id2, title: "Børnehave kapacitet i Vest",
                  updatedAt: now.addingTimeInterval(-60), messageCount: 2),
            .init(id: Self.id3, title: "Trafikplan for centrum",
                  updatedAt: now.addingTimeInterval(-120), messageCount: 4),
            .init(id: Self.id4, title: "Notater om vejarbejde",
                  updatedAt: now.addingTimeInterval(-180), messageCount: 1),
            .init(id: Self.id5, title: "Samtale om skattetryk",
                  updatedAt: now.addingTimeInterval(-240), messageCount: 5),
        ]
    }

    private static let id1 = UUID()
    private static let id2 = UUID()
    private static let id3 = UUID()
    private static let id4 = UUID()
    private static let id5 = UUID()

    // MARK: - Empty query

    func testEmptyQueryReturnsEverythingInCallerOrder() {
        let result = ConversationSidebar.filter(
            conversations: conversations,
            query: "",
            semanticIDs: [],
            semanticOrder: []
        )
        XCTAssertEqual(result.map(\.id), conversations.map(\.id),
                       "Empty query must behave like no filter at all — order preserved.")
    }

    func testWhitespaceQueryCountsAsEmpty() {
        // Users can fat-finger the space bar into the search field; we
        // shouldn't reset the sidebar to "Ingen match" in that case.
        let result = ConversationSidebar.filter(
            conversations: conversations,
            query: "   \t  ",
            semanticIDs: [Self.id1],
            semanticOrder: [Self.id1]
        )
        XCTAssertEqual(result.count, conversations.count)
    }

    // MARK: - Substring tier

    func testSubstringMatchIsCaseInsensitive() {
        // Current production behaviour — must keep working after the
        // semantic merge is layered on.
        let result = ConversationSidebar.filter(
            conversations: conversations,
            query: "BUDGET",
            semanticIDs: [],
            semanticOrder: []
        )
        XCTAssertEqual(result.map(\.id), [Self.id1])
    }

    func testSubstringMatchNoResultsAndNoSemanticFallback() {
        // Query matches nothing AND no semantic ids supplied → empty list,
        // which is what triggers the "Ingen match" empty state in the UI.
        let result = ConversationSidebar.filter(
            conversations: conversations,
            query: "zzzzzzz",
            semanticIDs: [],
            semanticOrder: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testSubstringSatisfiedSkipsSemanticMerge() {
        // When the substring tier already clears the
        // `substringSatisfactionThreshold` (3 by design), semantic matches
        // are ignored — otherwise we'd dilute a strong title-match set
        // with weaker topic-based matches.
        let fixture: [ConversationStore.Metadata] = [
            .init(id: Self.id1, title: "Budget overvejelser",
                  updatedAt: .now, messageCount: 1),
            .init(id: Self.id2, title: "Budget 2026",
                  updatedAt: .now, messageCount: 1),
            .init(id: Self.id3, title: "Nyt budget scenarie",
                  updatedAt: .now, messageCount: 1),
            .init(id: Self.id4, title: "Udkast til pris",
                  updatedAt: .now, messageCount: 1),
        ]
        let result = ConversationSidebar.filter(
            conversations: fixture,
            query: "budget",
            semanticIDs: [Self.id4], // semantic-only candidate
            semanticOrder: [Self.id4]
        )
        XCTAssertEqual(Set(result.map(\.id)), [Self.id1, Self.id2, Self.id3],
                       "Semantic id should be dropped — substring tier already has ≥3 hits.")
    }

    // MARK: - Semantic fallback

    func testSemanticFallbackAppendsWhenSubstringCountBelowThreshold() {
        // Substring tier returns 0; semantic tier supplies two
        // conversations in a specific cosine-rank order. We expect the
        // result to be in semantic order.
        let result = ConversationSidebar.filter(
            conversations: conversations,
            query: "roads", // won't match any title
            semanticIDs: [Self.id4, Self.id3], // vejarbejde + trafikplan
            semanticOrder: [Self.id3, Self.id4] // trafikplan ranked higher
        )
        XCTAssertEqual(result.map(\.id), [Self.id3, Self.id4],
                       "Semantic fallback must preserve the cosine ordering.")
    }

    func testSemanticMergeDedupsAgainstSubstringHits() {
        // id1 ("Budget 2026…") matches substring-wise AND appears in the
        // semantic set. Must only appear once, and in the substring slot
        // (substring tier leads the result).
        let result = ConversationSidebar.filter(
            conversations: conversations,
            query: "budget",
            semanticIDs: [Self.id1, Self.id5],
            semanticOrder: [Self.id1, Self.id5]
        )
        XCTAssertEqual(result.map(\.id), [Self.id1, Self.id5],
                       "Substring-match leads, duplicate id is dropped from semantic tail.")
    }

    func testSemanticIDsNotInConversationsAreDroppedSilently() {
        // Simulates the race: semantic search returns an id that has
        // already been deleted from `conversations`. Must not crash, must
        // not leak the stale id to the caller.
        let ghostID = UUID()
        let result = ConversationSidebar.filter(
            conversations: conversations,
            query: "does-not-match",
            semanticIDs: [ghostID, Self.id2],
            semanticOrder: [ghostID, Self.id2]
        )
        XCTAssertEqual(result.map(\.id), [Self.id2])
    }

    func testSemanticOrderIgnoredWhenNotInSemanticIDs() {
        // `semanticOrder` is supposed to mirror `semanticIDs`, but if the
        // caller slips up (e.g. a stale order array left over from a
        // cancelled debounce), the filter must only surface ids that are
        // *both* in the id-set and have scored above the floor.
        let result = ConversationSidebar.filter(
            conversations: conversations,
            query: "unrelated-query",
            semanticIDs: [Self.id3],
            semanticOrder: [Self.id2, Self.id3, Self.id4]
        )
        XCTAssertEqual(result.map(\.id), [Self.id3])
    }

    // MARK: - Threshold constants

    func testSubstringSatisfactionThresholdIsThree() {
        // This is a contract between the filter, the debounce fast-path
        // in `refreshSemanticMatches`, and any future tuning. If we raise
        // the threshold we need to revisit both the UX and the test
        // fixtures, so lock it in.
        XCTAssertEqual(ConversationSidebar.substringSatisfactionThreshold, 3)
    }

    func testSemanticScoreFloorMatchesPRDContract() {
        // 0.35 came from the PRD. If this changes, update the
        // SemanticIndex doc comment in the same PR.
        XCTAssertEqual(ConversationSidebar.semanticScoreFloor, 0.35, accuracy: 0.0001)
    }
}
