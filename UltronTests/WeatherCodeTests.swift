import XCTest
@testable import Ultron

final class WeatherCodeTests: XCTestCase {
    func testClearDayMapping() {
        XCTAssertEqual(WeatherCode.symbol(for: 0, isNight: false), "sun.max.fill")
        XCTAssertEqual(WeatherCode.label(for: 0), "Klart")
    }

    func testClearNightMapping() {
        XCTAssertEqual(WeatherCode.symbol(for: 0, isNight: true), "moon.stars.fill")
    }

    func testPartlyCloudy() {
        XCTAssertEqual(WeatherCode.symbol(for: 2, isNight: false), "cloud.sun.fill")
        XCTAssertEqual(WeatherCode.label(for: 2), "Delvist skyet")
    }

    func testThunderstorm() {
        XCTAssertEqual(WeatherCode.symbol(for: 95), "cloud.bolt.rain.fill")
        XCTAssertEqual(WeatherCode.label(for: 95), "Tordenvejr")
    }

    func testUnknownCodeFallsBackToCloud() {
        XCTAssertEqual(WeatherCode.symbol(for: 9999), "cloud.fill")
        XCTAssertEqual(WeatherCode.label(for: 9999), "Skyet")
    }

    func testDrizzleCovers51Through55() {
        for code in [51, 53, 55] {
            XCTAssertEqual(WeatherCode.symbol(for: code), "cloud.drizzle.fill",
                           "code \(code) should map to drizzle")
        }
    }
}
