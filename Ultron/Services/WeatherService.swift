import CoreLocation
import Foundation

/// Open-Meteo client (free, no API key). Fetches current + 24 h hourly + 7 day daily.
/// Docs: https://open-meteo.com/en/docs
struct WeatherSnapshot: Codable, Equatable {
    struct CurrentValues: Codable, Equatable {
        let temperature: Double
        let feelsLike: Double
        let weatherCode: Int
        let windSpeed: Double
        let humidity: Int
        let time: Date
    }
    struct HourlyPoint: Codable, Equatable, Identifiable {
        let time: Date
        let temperature: Double
        let precipitationProbability: Int?
        let weatherCode: Int
        var id: Date { time }
    }
    struct DailyPoint: Codable, Equatable, Identifiable {
        let date: Date
        let tempMin: Double
        let tempMax: Double
        let weatherCode: Int
        let precipitationProbability: Int?
        let sunrise: Date?
        let sunset: Date?
        var id: Date { date }

        /// Length of daylight, if both sunrise and sunset are known.
        var daylight: TimeInterval? {
            guard let sunrise, let sunset, sunset > sunrise else { return nil }
            return sunset.timeIntervalSince(sunrise)
        }
    }

    let fetchedAt: Date
    let locationLabel: String
    let current: CurrentValues
    let hourly: [HourlyPoint]
    let daily: [DailyPoint]

    /// Today's sun info, if available.
    var todaySun: (sunrise: Date, sunset: Date)? {
        guard let today = daily.first, let r = today.sunrise, let s = today.sunset else { return nil }
        return (r, s)
    }
}

enum WeatherServiceError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Weather API returned an invalid response"
        case .httpError(let code): return "Weather API HTTP \(code)"
        }
    }
}

final class WeatherService {
    func fetch(for coordinate: CLLocationCoordinate2D, locationLabel: String) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "wind_speed_unit", value: "ms")
        ]
        guard let url = components.url else { throw WeatherServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WeatherServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw WeatherServiceError.httpError(http.statusCode) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WeatherServiceError.invalidResponse
        }

        // ISO-8601 without zone (local-timezone) from open-meteo — parse manually.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        localFormatter.timeZone = TimeZone(identifier: root["timezone"] as? String ?? "UTC")
        let localDayFormatter = DateFormatter()
        localDayFormatter.dateFormat = "yyyy-MM-dd"
        localDayFormatter.timeZone = localFormatter.timeZone

        func parseLocal(_ s: String?) -> Date? {
            guard let s else { return nil }
            return localFormatter.date(from: s) ?? formatter.date(from: s)
        }
        func parseDay(_ s: String?) -> Date? {
            guard let s else { return nil }
            return localDayFormatter.date(from: s)
        }

        // Current
        guard let current = root["current"] as? [String: Any] else {
            throw WeatherServiceError.invalidResponse
        }
        let currentValues = WeatherSnapshot.CurrentValues(
            temperature: (current["temperature_2m"] as? Double) ?? 0,
            feelsLike: (current["apparent_temperature"] as? Double) ?? 0,
            weatherCode: (current["weather_code"] as? Int) ?? 0,
            windSpeed: (current["wind_speed_10m"] as? Double) ?? 0,
            humidity: (current["relative_humidity_2m"] as? Int) ?? 0,
            time: parseLocal(current["time"] as? String) ?? Date()
        )

        // Hourly (keep next 24 points from now)
        let hourly = (root["hourly"] as? [String: Any]) ?? [:]
        let hourTimes = (hourly["time"] as? [String]) ?? []
        let hourTemps = (hourly["temperature_2m"] as? [Double]) ?? []
        let hourPrecip = (hourly["precipitation_probability"] as? [Int?]) ?? []
        let hourCodes = (hourly["weather_code"] as? [Int]) ?? []

        let now = Date()
        var hourlyPoints: [WeatherSnapshot.HourlyPoint] = []
        for i in 0..<min(hourTimes.count, hourTemps.count, hourCodes.count) {
            guard let t = parseLocal(hourTimes[i]), t >= now.addingTimeInterval(-1800) else { continue }
            let probability = i < hourPrecip.count ? hourPrecip[i] : nil
            hourlyPoints.append(WeatherSnapshot.HourlyPoint(
                time: t,
                temperature: hourTemps[i],
                precipitationProbability: probability,
                weatherCode: hourCodes[i]
            ))
            if hourlyPoints.count >= 24 { break }
        }

        // Daily
        let daily = (root["daily"] as? [String: Any]) ?? [:]
        let dayTimes = (daily["time"] as? [String]) ?? []
        let dayMax = (daily["temperature_2m_max"] as? [Double]) ?? []
        let dayMin = (daily["temperature_2m_min"] as? [Double]) ?? []
        let dayCodes = (daily["weather_code"] as? [Int]) ?? []
        let dayPrecip = (daily["precipitation_probability_max"] as? [Int?]) ?? []
        let daySunrise = (daily["sunrise"] as? [String]) ?? []
        let daySunset = (daily["sunset"] as? [String]) ?? []

        var dailyPoints: [WeatherSnapshot.DailyPoint] = []
        for i in 0..<min(dayTimes.count, dayMax.count, dayMin.count, dayCodes.count) {
            guard let d = parseDay(dayTimes[i]) else { continue }
            let probability = i < dayPrecip.count ? dayPrecip[i] : nil
            let sunrise = i < daySunrise.count ? parseLocal(daySunrise[i]) : nil
            let sunset = i < daySunset.count ? parseLocal(daySunset[i]) : nil
            dailyPoints.append(WeatherSnapshot.DailyPoint(
                date: d,
                tempMin: dayMin[i],
                tempMax: dayMax[i],
                weatherCode: dayCodes[i],
                precipitationProbability: probability,
                sunrise: sunrise,
                sunset: sunset
            ))
        }

        return WeatherSnapshot(
            fetchedAt: Date(),
            locationLabel: locationLabel,
            current: currentValues,
            hourly: hourlyPoints,
            daily: dailyPoints
        )
    }
}

// MARK: - Weather code → SF Symbol + description

enum WeatherCode {
    /// WMO weather codes used by open-meteo. Maps each to an SF Symbol + Danish label.
    static func symbol(for code: Int, isNight: Bool = false) -> String {
        switch code {
        case 0:        return isNight ? "moon.stars.fill" : "sun.max.fill"
        case 1...3:    return isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case 45, 48:   return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57:   return "cloud.sleet.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 66, 67:   return "cloud.sleet.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86:   return "cloud.snow.fill"
        case 95:       return "cloud.bolt.rain.fill"
        case 96, 99:   return "cloud.bolt.rain.fill"
        default:       return "cloud.fill"
        }
    }

    static func label(for code: Int) -> String {
        switch code {
        case 0:        return "Klart"
        case 1:        return "For det meste klart"
        case 2:        return "Delvist skyet"
        case 3:        return "Overskyet"
        case 45, 48:   return "Tåge"
        case 51, 53, 55: return "Støvregn"
        case 61, 63, 65: return "Regn"
        case 71, 73, 75: return "Sne"
        case 80, 81, 82: return "Regnbyger"
        case 95:       return "Tordenvejr"
        case 96, 99:   return "Tordenvejr med hagl"
        default:       return "Skyet"
        }
    }
}
