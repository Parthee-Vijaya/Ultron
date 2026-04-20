import XCTest
@testable import Ultron

/// Guards the two things the Cockpit/MetricsService relies on being correct:
/// 1. `histogram(_:)` returns sensible p50/p95/p99 + mean across sample counts
///    from "2 samples" (where the percentile math edge-cases) up to the full
///    1000-sample ring.
/// 2. The ring buffer caps at `maxPerPhase` — an always-on session can't
///    OOM by accumulating samples indefinitely.
final class MetricsServiceHistogramTests: XCTestCase {

    func testHistogramNilWhenNoSamples() async {
        let service = MetricsService()
        let hist = await service.histogram(.record)
        XCTAssertNil(hist, "Empty phase should return nil, not a zeroed histogram")
    }

    func testHistogramSingleSample() async {
        let service = MetricsService()
        await service.record(phase: .transcribe, durationMs: 420)
        let hist = await service.histogram(.transcribe)
        XCTAssertNotNil(hist)
        XCTAssertEqual(hist?.count, 1)
        XCTAssertEqual(hist?.p50, 420)
        XCTAssertEqual(hist?.p95, 420)
        XCTAssertEqual(hist?.p99, 420)
        XCTAssertEqual(hist?.mean, 420)
    }

    func testHistogramPercentilesMonotonic() async {
        let service = MetricsService()
        for ms in stride(from: 100, through: 1_000, by: 10) {
            await service.record(phase: .modelCall, durationMs: ms)
        }
        let hist = await service.histogram(.modelCall)
        XCTAssertNotNil(hist)
        guard let h = hist else { return }
        XCTAssertEqual(h.count, 91)
        XCTAssertLessThanOrEqual(h.p50, h.p95, "p50 must not exceed p95")
        XCTAssertLessThanOrEqual(h.p95, h.p99, "p95 must not exceed p99")
        // Mean of 100…1000 in 10-step = 550
        XCTAssertEqual(h.mean, 550)
    }

    func testRingBufferCapsAt1000PerPhase() async {
        let service = MetricsService()
        for i in 0..<1_500 {
            await service.record(phase: .paste, durationMs: i)
        }
        let hist = await service.histogram(.paste)
        XCTAssertEqual(hist?.count, 1_000,
                       "Ring buffer should cap at 1000 per phase — otherwise a long session leaks memory")
    }

    /// Different phases are independent buckets; recording into one doesn't
    /// affect another's histogram.
    func testPhaseIsolation() async {
        let service = MetricsService()
        await service.record(phase: .record, durationMs: 50)
        await service.record(phase: .record, durationMs: 60)
        await service.record(phase: .transcribe, durationMs: 9_000)

        let recordHist = await service.histogram(.record)
        let transcribeHist = await service.histogram(.transcribe)

        XCTAssertEqual(recordHist?.count, 2)
        XCTAssertEqual(transcribeHist?.count, 1)
        XCTAssertEqual(transcribeHist?.mean, 9_000)
        // record hist mean = (50 + 60) / 2 = 55 (integer division)
        XCTAssertEqual(recordHist?.mean, 55)
    }
}
