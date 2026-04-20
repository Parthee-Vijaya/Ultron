import XCTest
@testable import Ultron

final class CommuteServiceTests: XCTestCase {
    func testTeslaEfficiencyConstant() {
        // 0.180 kWh/km is the tuned Model 3 AWD 2025 mixed-driving value. If
        // this changes we want the adjustment to be deliberate.
        XCTAssertEqual(CommuteService.teslaModel3AWD2025Efficiency, 0.180, accuracy: 0.0001)
    }

    func testTeslaKWhMath() {
        let estimate = CommuteEstimate(
            expectedTravelTime: 23 * 60,
            baselineTravelTime: nil,
            distanceMeters: 14_000,
            fromLabel: "A",
            toLabel: "B",
            teslaKWh: 14 * CommuteService.teslaModel3AWD2025Efficiency
        )
        XCTAssertEqual(estimate.distanceKm, 14)
        XCTAssertEqual(estimate.teslaKWh, 2.52, accuracy: 0.01)
    }

    func testPrettyTravelTimeUnderAnHour() {
        let estimate = CommuteEstimate(expectedTravelTime: 45 * 60, baselineTravelTime: nil,
                                       distanceMeters: 10_000,
                                       fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(estimate.prettyTravelTime, "45 min")
    }

    func testPrettyTravelTimeMultiHour() {
        let estimate = CommuteEstimate(expectedTravelTime: 2 * 3600 + 15 * 60,
                                       baselineTravelTime: nil,
                                       distanceMeters: 10_000, fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(estimate.prettyTravelTime, "2t 15m")
    }

    func testPrettyDistanceMeters() {
        let estimate = CommuteEstimate(expectedTravelTime: 60, baselineTravelTime: nil,
                                       distanceMeters: 350,
                                       fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(estimate.prettyDistance, "350 m")
    }

    func testPrettyDistanceKilometers() {
        let estimate = CommuteEstimate(expectedTravelTime: 60, baselineTravelTime: nil,
                                       distanceMeters: 14_500,
                                       fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(estimate.prettyDistance, "14.5 km")
    }

    // MARK: - Traffic classification (β.4)

    func testTrafficFreeUnder2Minutes() {
        let e = CommuteEstimate(expectedTravelTime: 30 * 60, baselineTravelTime: 29 * 60,
                                distanceMeters: 10_000, fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(e.trafficCondition, .free)
        XCTAssertEqual(e.prettyTrafficDelay, "+1 min trafik")
    }

    func testTrafficLightBetween2And8Minutes() {
        let e = CommuteEstimate(expectedTravelTime: 35 * 60, baselineTravelTime: 30 * 60,
                                distanceMeters: 10_000, fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(e.trafficCondition, .light)
    }

    func testTrafficHeavyBetween8And20Minutes() {
        let e = CommuteEstimate(expectedTravelTime: 45 * 60, baselineTravelTime: 30 * 60,
                                distanceMeters: 10_000, fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(e.trafficCondition, .heavy)
    }

    func testTrafficSevereOver20Minutes() {
        let e = CommuteEstimate(expectedTravelTime: 55 * 60, baselineTravelTime: 30 * 60,
                                distanceMeters: 10_000, fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(e.trafficCondition, .severe)
    }

    func testTrafficUnknownWithoutBaseline() {
        let e = CommuteEstimate(expectedTravelTime: 30 * 60, baselineTravelTime: nil,
                                distanceMeters: 10_000, fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(e.trafficCondition, .unknown)
        XCTAssertEqual(e.prettyTrafficDelay, "")
    }

    func testTrafficDelayClampsNegativeToZero() {
        // Live route is faster than baseline — pin delay to 0, not negative.
        let e = CommuteEstimate(expectedTravelTime: 28 * 60, baselineTravelTime: 30 * 60,
                                distanceMeters: 10_000, fromLabel: "", toLabel: "", teslaKWh: 0)
        XCTAssertEqual(e.trafficDelay, 0, accuracy: 0.01)
    }

    func testNextSunday03IsALaterSundayAt03Local() {
        let now = Date()
        let next = CommuteService.nextSunday03(from: now)
        XCTAssertGreaterThan(next, now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.weekday, from: next), 1) // Sunday
        XCTAssertEqual(cal.component(.hour, from: next), 3)
    }
}
